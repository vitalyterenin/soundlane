import AppKit
import AVFoundation
import AudioBridge
import Combine
import CoreAudioKit
import SwiftUI

let microphoneUID = "in.teren.soundlane.microphone"

enum LaneKind: String, Codable { case system, microphone }

@MainActor final class MeterState: ObservableObject {
    @Published var level: Float = 0
}

struct PluginRecord: Codable {
    var id: UUID
    var name: String
    var manufacturer: String
    var type: UInt32
    var subtype: UInt32
    var maker: UInt32
    var bypass: Bool
    var state: Data?
    var description: AudioComponentDescription {
        .init(componentType: type, componentSubType: subtype, componentManufacturer: maker,
              componentFlags: 0, componentFlagsMask: 0)
    }
}

@MainActor final class EffectSlot: ObservableObject, Identifiable {
    let id: UUID
    let name: String
    let manufacturer: String
    let unit: AVAudioUnit?
    private let unavailableRecord: PluginRecord?
    @Published var bypass: Bool { didSet { unit?.auAudioUnit.shouldBypassEffect = bypass } }
    init(unit: AVAudioUnit, name: String, manufacturer: String, id: UUID = UUID(), bypass: Bool = false) {
        self.unit = unit; self.name = name; self.manufacturer = manufacturer; self.id = id; self.bypass = bypass
        self.unavailableRecord = nil
        unit.auAudioUnit.shouldBypassEffect = bypass
    }
    init(unavailable record: PluginRecord) {
        id = record.id; name = record.name; manufacturer = record.manufacturer
        unit = nil; bypass = record.bypass; unavailableRecord = record
    }
    var record: PluginRecord {
        guard let unit else { return unavailableRecord! }
        let d = unit.audioComponentDescription
        let state = unit.auAudioUnit.fullState.flatMap {
            try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
        }
        return PluginRecord(id: id, name: name, manufacturer: manufacturer,
            type: d.componentType, subtype: d.componentSubType, maker: d.componentManufacturer,
            bypass: bypass, state: state)
    }
}

@MainActor final class Lane: ObservableObject {
    let kind: LaneKind
    let engine: any AudioPipeline
    @Published var effects: [EffectSlot] = []
    @Published var deviceUID = ""
    @Published var enabled = false
    @Published var requestedEnabled = false
    @Published var waiting = false
    var generation = 0
    var recoveryDeadline: Date?
    var lastCallbackCount: UInt64 = 0
    var lastCallbackAt = Date()
    @Published var busy = false
    @Published var bypass = false { didSet { engine.bypass = bypass } }
    @Published var muted = false { didSet { engine.muted = muted } }
    @Published var gainDB: Float = 0 { didSet { engine.gain = pow(10, gainDB / 20) } }
    let meter = MeterState()
    @Published var error: String?
    @Published var rate: Double = 0
    var activeDeviceSignature = ""
    init(_ kind: LaneKind, engine: any AudioPipeline = SLPipeline()) { self.kind = kind; self.engine = engine }
    func stop() {
        engine.stop(); enabled = false; rate = 0; meter.level = 0
    }
}

private struct SavedLane: Codable {
    var deviceUID: String
    var effects: [PluginRecord]
    var gainDB: Float
}
private struct SavedConfiguration: Codable { var system: SavedLane; var microphone: SavedLane }

@MainActor final class AppModel: ObservableObject {
    let system: Lane
    let microphone: Lane
    @Published var devices: [RouteDevice] = []
    @Published var restoring = true
    @Published var restoreMessage: String?
    @Published var installing = false
    @Published var audioComponent = AudioComponentInstallation.current()
    private var meterTimer: Timer?
    private var deviceTimer: Timer?
    private var saveTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var editorWindows: [UUID: NSWindow] = [:]
    private(set) var sleeping = false
    private var shuttingDown = false
    private let enumerateDevices: () -> [RouteDevice]
    private let authorizeMicrophone: () async -> Bool
    private let now: () -> Date
    private let settingsURL: URL
    var virtualMicrophone: RouteDevice? { devices.first { $0.uid == microphoneUID } }
    var inputs: [RouteDevice] { devices.filter { $0.inputChannels > 0 && $0.uid != microphoneUID } }
    var outputs: [RouteDevice] { devices.filter { $0.outputChannels >= 2 && $0.uid != microphoneUID } }
    var anyRunning: Bool { system.enabled || microphone.enabled }

    init(automatic: Bool = true, settings: URL? = nil,
         systemEngine: any AudioPipeline = SLPipeline(), microphoneEngine: any AudioPipeline = SLPipeline(),
         devices: @escaping () -> [RouteDevice] = { SLDevice.allDevices().map(RouteDevice.init) },
         now: @escaping () -> Date = Date.init,
         authorize: @escaping () async -> Bool = {
             switch AVCaptureDevice.authorizationStatus(for: .audio) {
             case .authorized: return true
             case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
             default: return false
             }
         }) {
        system = Lane(.system, engine: systemEngine); microphone = Lane(.microphone, engine: microphoneEngine)
        enumerateDevices = devices; authorizeMicrophone = authorize; self.now = now
        settingsURL = settings ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundLane/Configuration.json")
        refreshDevices()
        guard automatic else { restoring = false; return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.prepareForSleep()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeFromSleep() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.save()
                if let closed = notification.object as? NSWindow,
                   self.editorWindows.values.contains(where: { $0 === closed }) {
                    // AU editors are standalone AppKit windows. Restore keyboard
                    // focus to the main window after AppKit finishes closing one.
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        NSApp.windows.first { candidate in
                            candidate.isVisible && candidate !== closed &&
                            !self.editorWindows.values.contains(where: { $0 === candidate })
                        }?.makeKeyAndOrderFront(nil)
                    }
                }
            }
        })
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for lane in [self.system, self.microphone] where lane.enabled {
                    let peak = max(lane.engine.outputPeak, lane.meter.level * 0.8)
                    if abs(peak - lane.meter.level) > 0.000001 { lane.meter.level = peak }
                    self.checkRenderHealth(lane)
                }
            }
        }
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDevices(); self?.checkCallbacks() }
        }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        Task { await restore() }
    }
    func lane(_ kind: LaneKind) -> Lane { kind == .system ? system : microphone }
    func routeSignature(_ lane: Lane) -> String? {
        guard let source = devices.first(where: { $0.uid == lane.deviceUID }),
              lane.kind == .system ? source.outputChannels >= 2 : source.inputChannels > 0 else { return nil }
        if lane.kind == .microphone {
            guard let destination = virtualMicrophone, destination.outputChannels == 2 else { return nil }
            return source.signature + "/" + destination.signature
        }
        return source.signature
    }
    func disable(_ lane: Lane) {
        lane.generation += 1; lane.requestedEnabled = false; lane.waiting = false
        lane.recoveryDeadline = nil; lane.stop()
    }
    func prepareForSleep() {
        guard !sleeping, !shuttingDown else { return }
        sleeping = true
        for lane in [system, microphone] {
            lane.generation += 1; lane.stop(); lane.waiting = lane.requestedEnabled
            lane.recoveryDeadline = nil
        }
    }
    func resumeFromSleep() {
        guard sleeping, !shuttingDown else { return }
        sleeping = false
        for lane in [system, microphone] where lane.requestedEnabled {
            lane.recoveryDeadline = now().addingTimeInterval(20)
        }
        refreshDevices()
    }
    func refreshDevices() {
        let component = AudioComponentInstallation.current()
        if component != audioComponent { audioComponent = component }
        let current = enumerateDevices()
        if current != devices { devices = current }
        if system.deviceUID.isEmpty {
            system.deviceUID = outputs.first { $0.deviceID == SLDevice.defaultOutput() }?.uid ?? outputs.first?.uid ?? ""
        }
        if microphone.deviceUID.isEmpty {
            microphone.deviceUID = inputs.first { $0.deviceID == SLDevice.defaultInput() }?.uid ?? inputs.first?.uid ?? ""
        }
        guard !sleeping, !shuttingDown else { return }
        for lane in [system, microphone] {
            if lane.enabled && routeSignature(lane) != lane.activeDeviceSignature {
                lane.generation += 1; lane.stop(); lane.waiting = lane.requestedEnabled
                lane.recoveryDeadline = now().addingTimeInterval(20)
                lane.error = "The audio device changed. Waiting for your selected device…"
            }
            if lane.requestedEnabled && lane.waiting && !lane.busy {
                if let deadline = lane.recoveryDeadline, now() >= deadline {
                    disable(lane)
                    lane.error = "The selected device is not ready. Connect it and turn processing on again."
                } else if routeSignature(lane) != nil {
                    scheduleStart(lane)
                }
            }
        }
        if virtualMicrophone != nil { installing = false }
    }
    func checkRenderHealth(_ lane: Lane) {
        guard lane.enabled, lane.engine.consecutiveRenderErrors > 8 else { return }
        // Device loss can surface as render errors before the device timer fires.
        // Let route recovery handle it instead of discarding the user's intent.
        refreshDevices()
        guard lane.enabled else { return }
        disable(lane)
        lane.error = "Processing stopped because the audio engine reported repeated errors. Bypass the last effect you added and try again."
    }
    func checkCallbacks() {
        for lane in [system, microphone] where lane.enabled {
            let count = lane.engine.callbackCount
            if count != lane.lastCallbackCount {
                lane.lastCallbackCount = count; lane.lastCallbackAt = now()
            } else if now().timeIntervalSince(lane.lastCallbackAt) > 3 {
                disable(lane)
                lane.error = "The audio device stopped responding. Turn processing on again to reconnect."
            }
        }
    }
    func toggle(_ lane: Lane) {
        if lane.requestedEnabled { disable(lane); save() }
        else {
            lane.requestedEnabled = true; lane.waiting = true; lane.generation += 1
            lane.recoveryDeadline = nil; scheduleStart(lane)
        }
    }
    private func scheduleStart(_ lane: Lane) {
        guard !sleeping, !shuttingDown, !lane.busy, lane.requestedEnabled else { return }
        let generation = lane.generation
        lane.busy = true
        Task { await start(lane, generation: generation) }
    }
    func start(_ lane: Lane, generation: Int) async {
        defer { lane.busy = false }
        guard !sleeping, !shuttingDown, !restoring, lane.requestedEnabled, generation == lane.generation else { return }
        if lane.kind == .microphone {
            let granted = await authorizeMicrophone()
            guard !sleeping, !shuttingDown, lane.requestedEnabled, generation == lane.generation else { return }
            guard granted else {
                disable(lane)
                lane.error = "Allow microphone access for SoundLane in System Settings → Privacy & Security → Microphone."
                return
            }
        }
        guard let signature = routeSignature(lane),
              let device = devices.first(where: { $0.uid == lane.deviceUID }) else {
            if lane.recoveryDeadline == nil { disable(lane) }
            lane.error = "The selected device is currently unavailable."
            return
        }
        do {
            lane.engine.bypass = lane.bypass; lane.engine.muted = lane.muted
            lane.engine.gain = pow(10, lane.gainDB / 20)
            if lane.kind == .system {
                try lane.engine.startSystem(to: device.deviceID, units: lane.effects.compactMap(\.unit))
            } else {
                guard let virtual = virtualMicrophone else { return }
                try lane.engine.startMicrophone(device.deviceID, to: virtual.deviceID, units: lane.effects.compactMap(\.unit))
            }
            lane.activeDeviceSignature = signature
            lane.enabled = true; lane.waiting = false; lane.rate = lane.engine.sampleRate
            lane.recoveryDeadline = nil; lane.error = nil
            lane.lastCallbackCount = lane.engine.callbackCount; lane.lastCallbackAt = now()
            save()
        } catch {
            lane.stop()
            // After wake HAL can publish devices before they accept I/O. Retry
            // only within this bounded recovery window, never change the UID.
            if lane.recoveryDeadline == nil { disable(lane) }
            lane.error = error.localizedDescription
        }
    }
    func selectDevice(_ uid: String, lane: Lane) {
        lane.generation += 1; lane.stop(); lane.deviceUID = uid; lane.error = nil
        lane.waiting = lane.requestedEnabled; lane.recoveryDeadline = nil; save()
        if lane.requestedEnabled { scheduleStart(lane) }
    }
    func add(_ component: AVAudioUnitComponent, to lane: Lane) async {
        guard !lane.busy else { return }
        lane.busy = true; lane.error = nil
        do {
            let unit = try await instantiate(component.audioComponentDescription)
            let restart = lane.enabled; lane.stop()
            lane.effects.append(EffectSlot(unit: unit, name: component.name, manufacturer: component.manufacturerName))
            lane.busy = false; save()
            if restart && lane.requestedEnabled { scheduleStart(lane) }
        } catch { lane.error = error.localizedDescription; lane.busy = false }
    }
    func remove(_ slot: EffectSlot, from lane: Lane) {
        let restart = lane.enabled; lane.stop()
        editorWindows.removeValue(forKey: slot.id)?.close()
        lane.effects.removeAll { $0.id == slot.id }; save()
        if restart && lane.requestedEnabled { scheduleStart(lane) }
    }
    func move(_ slot: EffectSlot, in lane: Lane, by amount: Int) {
        guard let index = lane.effects.firstIndex(where: { $0.id == slot.id }), lane.effects.indices.contains(index+amount) else { return }
        let restart = lane.enabled; lane.stop()
        lane.effects.swapAt(index, index+amount); save()
        if restart && lane.requestedEnabled { scheduleStart(lane) }
    }
    func showEditor(_ slot: EffectSlot) {
        guard let unit = slot.unit else { return }
        if let window = editorWindows[slot.id] { window.makeKeyAndOrderFront(nil); return }
        unit.auAudioUnit.requestViewController { [weak self, weak slot] controller in
            Task { @MainActor in
                guard let self, let slot else { return }
                if let existing = self.editorWindows[slot.id] { existing.makeKeyAndOrderFront(nil); return }
                let content = controller ?? NSHostingController(rootView: ParameterEditor(slot: slot))
                let window = NSWindow(contentViewController: content)
                window.title = slot.name; window.isReleasedWhenClosed = false
                window.styleMask.formUnion([.titled, .closable, .resizable])
                let size = content.preferredContentSize
                window.setContentSize(NSSize(width: max(440, size.width > 0 ? size.width : content.view.frame.width),
                    height: max(280, size.height > 0 ? size.height : content.view.frame.height)))
                window.center(); window.makeKeyAndOrderFront(nil)
                self.editorWindows[slot.id] = window
            }
        }
    }
    func installDriver() {
        guard let url = Bundle.main.url(forResource: "SoundLane Audio Component", withExtension: "pkg") else {
            microphone.error = "The audio component installer is missing. Reinstall SoundLane to restore it."; return
        }
        installing = true
        NSWorkspace.shared.open(url)
    }
    func openAudioPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    func save() {
        guard !restoring else { return }
        func saved(_ lane: Lane) -> SavedLane {
            SavedLane(deviceUID: lane.deviceUID, effects: lane.effects.map(\.record), gainDB: lane.gainDB)
        }
        do {
            let data = try JSONEncoder().encode(SavedConfiguration(system: saved(system), microphone: saved(microphone)))
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: settingsURL, options: .atomic)
        } catch { restoreMessage = "Could not save settings: \(error.localizedDescription)" }
    }
    private func restore() async {
        defer { restoring = false }
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        do {
            let config = try JSONDecoder().decode(SavedConfiguration.self, from: Data(contentsOf: settingsURL))
            for (lane, saved) in [(system, config.system), (microphone, config.microphone)] {
                lane.deviceUID = saved.deviceUID; lane.gainDB = min(6, max(-24, saved.gainDB))
                for record in saved.effects {
                    do {
                        let unit = try await instantiate(record.description)
                        if let data = record.state,
                           let state = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                            unit.auAudioUnit.fullState = state
                        }
                        lane.effects.append(EffectSlot(unit: unit, name: record.name, manufacturer: record.manufacturer,
                                                       id: record.id, bypass: record.bypass))
                    } catch {
                        lane.effects.append(EffectSlot(unavailable: record))
                        lane.error = "Could not restore \(record.name). Its settings are preserved. This effect will be skipped during processing."
                    }
                }
            }
        } catch { restoreMessage = "Could not read saved settings: \(error.localizedDescription)" }
    }
    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true; save(); disable(system); disable(microphone)
        meterTimer?.invalidate(); deviceTimer?.invalidate(); saveTimer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
}

func instantiate(_ description: AudioComponentDescription) async throws -> AVAudioUnit {
    try await withCheckedThrowingContinuation { continuation in
        AVAudioUnit.instantiate(with: description, options: []) { unit, error in
            if let unit { continuation.resume(returning: unit) }
            else { continuation.resume(throwing: error ?? NSError(domain: "SoundLane", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The Audio Unit could not be loaded."])) }
        }
    }
}
