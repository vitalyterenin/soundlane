import AppKit
import AudioBridge
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.identifier?.rawValue == "main" || $0.title == "SoundLane" }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main struct SoundLaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var updater = UpdateController()
    @StateObject private var model: AppModel
    init() {
        if CommandLine.arguments.contains("--status") { exit(RuntimeStatus.query() ? 0 : 1) }
        if CommandLine.arguments.contains("--self-test") {
            do { try SLPipeline.selfTest(); print("PASS: realtime AU graph, -6 dB EQ, bypass, mute") }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
            exit(0)
        }
        if CommandLine.arguments.contains("--list-devices") {
            for d in SLDevice.allDevices() { print("\(d.deviceID)\t\(d.uid)\t\(d.name)\tin=\(d.inputChannels) out=\(d.outputChannels) \(d.sampleRate)Hz") }
            exit(0)
        }
        _model = StateObject(wrappedValue: AppModel())
    }
    var body: some Scene {
        Window("SoundLane", id: "main") {
            MainView(model: model).onAppear { delegate.model = model; RuntimeStatus.install(model: model); updater.start() }
        }
        .defaultSize(width: 860, height: 680)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
                Divider()
                Menu("Licenses") {
                    Button("SoundLane License") { openLicense("LICENSE", extension: nil) }
                    Button("Third-Party Notices") { openLicense("THIRD_PARTY_NOTICES", extension: "md") }
                }
            }
        }
        Settings { UpdateSettings(updater: updater) }
        MenuBarExtra("SoundLane", systemImage: "waveform.path") {
            MenuContent(model: model, updater: updater)
        }
    }
    private func openLicense(_ name: String, extension ext: String?) {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Licenses") { NSWorkspace.shared.open(url) }
    }

}
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: UpdateController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open SoundLane") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        LaneMenuButton(lane: model.system, model: model, name: "System Audio")
        LaneMenuButton(lane: model.microphone, model: model, name: "Microphone")
        Divider()
        Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
        Divider()
        Button("Quit SoundLane") { model.shutdown(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
struct LaneMenuButton: View {
    @ObservedObject var lane: Lane
    @ObservedObject var model: AppModel
    let name: String
    var body: some View {
        Toggle(name, isOn: Binding(get: { lane.requestedEnabled }, set: { _ in model.toggle(lane) }))
            .disabled((lane.busy && !lane.requestedEnabled) || model.restoring || (lane.kind == .microphone && model.virtualMicrophone == nil && !lane.requestedEnabled))
    }
}
