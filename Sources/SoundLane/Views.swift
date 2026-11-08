import AppKit
import AVFoundation
import AudioBridge
import SwiftUI

// CLT SDKs may export the State macro without shipping SwiftUIMacros.
typealias StoredState<Value> = SwiftUI.State<Value>

extension LaneKind {
    var title: String { self == .system ? "System Audio" : "Microphone" }
    var symbol: String { self == .system ? "speaker.wave.2" : "mic" }
    var subtitle: String { self == .system ? "Audio effects for your apps." : "Audio effects for your voice." }
}
extension Lane {
    var status: String { enabled ? (muted ? "Muted" : "Processing") : (waiting ? "Waiting for device" : "Off") }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @StoredState private var selection: LaneKind? = .system
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Audio") {
                    SidebarLane(lane: model.system).tag(LaneKind.system)
                    SidebarLane(lane: model.microphone).tag(LaneKind.microphone)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 260)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path")
                    Text("SoundLane").fontWeight(.medium)
                    Spacer()
                    if model.restoring { ProgressView().controlSize(.mini).help("Loading Audio Units…") }
                }
                .font(.caption).foregroundStyle(.secondary).padding(16)
            }
        } detail: {
            LaneDetail(lane: model.lane(selection ?? .system), model: model)
                .id(selection ?? .system)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, idealWidth: 860, minHeight: 580, idealHeight: 680)
    }
}

struct SidebarLane: View {
    @ObservedObject var lane: Lane
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(lane.kind.title)
                Text(lane.status).font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 3)
        } icon: {
            Image(systemName: lane.kind.symbol).symbolVariant(lane.enabled ? .fill : .none)
        }
        .accessibilityElement(children: .combine)
    }
}

struct LaneDetail: View {
    @ObservedObject var lane: Lane
    @ObservedObject var model: AppModel
    @StoredState private var choosing = false
    var isMic: Bool { lane.kind == .microphone }
    var choices: [RouteDevice] { isMic ? model.inputs : model.outputs }
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: lane.kind.symbol).font(.system(size: 26, weight: .regular))
                        .foregroundStyle(.secondary).frame(width: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lane.kind.title).font(.title2.weight(.semibold))
                        Text(lane.kind.subtitle).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if lane.busy { ProgressView().controlSize(.small) }
                    Toggle("Enable \(lane.kind.title)", isOn: Binding(
                        get: { lane.requestedEnabled }, set: { _ in model.toggle(lane) }))
                        .toggleStyle(.switch).labelsHidden()
                        .disabled((lane.busy && !lane.requestedEnabled) || model.restoring ||
                                  (isMic && model.virtualMicrophone == nil && !lane.requestedEnabled))
                        .help(lane.requestedEnabled ? "Turn processing off" : "Turn processing on")
                }.padding(.vertical, 6)
            }
            Section {
                Picker(isMic ? "Input Device" : "Output Device", selection: Binding(
                    get: { lane.deviceUID }, set: { model.selectDevice($0, lane: lane) })) {
                    if !choices.contains(where: { $0.uid == lane.deviceUID }) {
                        Text(lane.deviceUID.isEmpty ? "No Devices" : "Device Unavailable").tag(lane.deviceUID)
                    }
                    ForEach(choices, id: \.uid) { Text($0.name).tag($0.uid) }
                }.disabled(lane.busy)
                if isMic {
                    LabeledContent("Send To", value: "SoundLane Microphone")
                }
            } header: { Text("Routing") } footer: {
                Text(isMic ? "Choose SoundLane Microphone as the input in Zoom or your calling app." :
                     "Audio from your apps plays through this device after processing.")
            }
            Section {
                if lane.effects.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(.tertiary)
                        Text("No Effects").font(.headline)
                        Text("Add an Audio Unit to start shaping your sound.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    ForEach(Array(lane.effects.enumerated()), id: \.element.id) { index, slot in
                        EffectRow(slot: slot, index: index, count: lane.effects.count,
                                  edit: { model.showEditor(slot) },
                                  move: { model.move(slot, in: lane, by: $0) },
                                  remove: { model.remove(slot, from: lane) })
                            .disabled(lane.busy || model.restoring)
                    }
                }
                HStack {
                    Button { choosing = true } label: { Label("Add Effect…", systemImage: "plus") }
                        .disabled(lane.busy || model.restoring)
                    Spacer()
                    Toggle("Bypass All", isOn: $lane.bypass).toggleStyle(.checkbox)
                        .help("Listen without Audio Unit processing")
                }.padding(.vertical, 2)
            } header: {
                HStack { Text("Effects"); Spacer(); Text("Applied from top to bottom").font(.caption).textCase(nil) }
            }
            Section("Output") {
                HStack(spacing: 12) {
                    Text("Gain").frame(width: 48, alignment: .leading)
                    Slider(value: $lane.gainDB, in: -24...6)
                        .accessibilityLabel("\(lane.kind.title) gain")
                    Text(String(format: "%+.0f dB", lane.gainDB)).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                    Button { lane.gainDB = 0 } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).help("Reset gain to 0 dB")
                        .accessibilityLabel("Reset gain")
                }
                HStack(spacing: 12) {
                    Text("Level").frame(width: 48, alignment: .leading)
                    LevelMeter(meter: lane.meter, active: lane.enabled && !lane.muted)
                        .frame(height: 6)
                    Toggle("Mute", isOn: $lane.muted).toggleStyle(.checkbox).frame(width: 86, alignment: .trailing)
                }.padding(.vertical, 3)
            }
            if let error = lane.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if let message = model.restoreMessage {
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            }
            if isMic && (model.virtualMicrophone == nil || model.audioComponent.needsSetup) {
                Section {
                    if !model.audioComponent.needsSetup {
                        Label("Restart your Mac to make SoundLane Microphone available.", systemImage: "restart")
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent {
                            Button(model.audioComponent.installedBuild == nil ? "Set Up…" : "Update Component…") { model.installDriver() }
                        } label: {
                            Text("Virtual Microphone").fontWeight(.medium)
                            Text(model.installing ? "Finish installation, then restart your Mac." :
                                 "One-time setup connects your microphone to other apps. Administrator access is required.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(lane.kind.title)
        .toolbar {
            ToolbarItem(placement: .status) {
                HStack(spacing: 6) {
                    Circle().fill(lane.enabled ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    Text(lane.status)
                    if lane.enabled { Text("·"); Text("\(lane.rate / 1000, specifier: "%g") kHz") }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $choosing) { PluginPicker { component in
            choosing = false
            Task { await model.add(component, to: lane) }
        } }
    }
}

struct EffectRow: View {
    @ObservedObject var slot: EffectSlot
    let index: Int
    let count: Int
    let edit: () -> Void
    let move: (Int) -> Void
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Toggle("Enable \(slot.name)", isOn: Binding(get: { !slot.bypass }, set: { slot.bypass = !$0 }))
                .toggleStyle(.checkbox).labelsHidden().disabled(slot.unit == nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(slot.name).fontWeight(.medium).lineLimit(1)
                Text(slot.unit == nil ? "Unavailable · Settings preserved" : slot.manufacturer)
                    .font(.caption).foregroundStyle(.secondary)
            }.opacity(slot.bypass ? 0.5 : 1)
            Spacer(minLength: 8)
            Button("Open", action: edit).disabled(slot.unit == nil).help("Open effect controls")
            Menu {
                Button("Move Up", systemImage: "arrow.up") { move(-1) }.disabled(index == 0)
                Button("Move Down", systemImage: "arrow.down") { move(1) }.disabled(index + 1 == count)
                Divider()
                Button("Remove Effect", systemImage: "trash", role: .destructive, action: remove)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                .help("Effect options").accessibilityLabel("Options for \(slot.name)")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Open Effect", action: edit).disabled(slot.unit == nil)
            Divider()
            Button("Move Up") { move(-1) }.disabled(index == 0)
            Button("Move Down") { move(1) }.disabled(index + 1 == count)
            Divider()
            Button("Remove Effect", role: .destructive, action: remove)
        }
    }
}

struct LevelMeter: View {
    @ObservedObject var meter: MeterState
    var active: Bool
    var normalized: Double { active && meter.level > 0 ? max(0, min(1, (20 * log10(Double(meter.level)) + 60) / 60)) : 0 }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(meter.level >= 0.98 ? Color.orange : Color.accentColor)
                    .frame(width: max(0, geometry.size.width * normalized))
            }
        }
        .accessibilityLabel("Output level")
        .accessibilityValue(active ? "\(Int(normalized * 100)) percent" : "No signal")
    }
}

struct PluginPicker: View {
    @Environment(\.dismiss) private var dismiss
    @StoredState private var query = ""
    @StoredState private var components: [AVAudioUnitComponent] = []
    @StoredState private var selection: Int?
    let select: (AVAudioUnitComponent) -> Void
    var filtered: [AVAudioUnitComponent] {
        components.filter { query.isEmpty || "\($0.name) \($0.manufacturerName)".localizedCaseInsensitiveContains(query) }
    }
    var selected: AVAudioUnitComponent? {
        guard let selection, filtered.indices.contains(selection) else { return nil }
        return filtered[selection]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Add an Effect").font(.title2.weight(.semibold))
                Text("Audio Units installed on your Mac.").foregroundStyle(.secondary)
            }
            TextField("Search effects", text: $query).textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, _ in selection = nil }
            List(selection: $selection) {
                ForEach(Array(filtered.enumerated()), id: \.offset) { index, component in
                    HStack(spacing: 10) {
                        Image(systemName: "waveform").foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(component.name)
                            Text(component.manufacturerName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(.vertical, 4).tag(index)
                }
            }.listStyle(.inset).overlay {
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.title2)
                        Text("No Effects Found").font(.headline)
                        Text("Try another name or manufacturer.").font(.callout)
                    }.foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(filtered.count == 1 ? "1 effect" : "\(filtered.count) effects").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Effect") { if let selected { select(selected) } }
                    .keyboardShortcut(.defaultAction).disabled(selected == nil)
            }
        }.padding(24).frame(width: 480, height: 480)
        .task {
            let d = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0,
                componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            components = AVAudioUnitComponentManager.shared().components(matching: d)
                .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
        }
    }
}

struct ParameterEditor: View {
    let slot: EffectSlot
    var body: some View {
        Form {
            Section(slot.name) {
                if let parameters = slot.unit?.auAudioUnit.parameterTree?.allParameters, !parameters.isEmpty {
                    ForEach(parameters, id: \.address) { parameter in ParameterControl(parameter: parameter) }
                } else { Text("This Audio Unit does not provide an editor or accessible parameters.").foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped).frame(minWidth: 440, minHeight: 300)
    }
}
struct ParameterControl: View {
    let parameter: AUParameter
    @StoredState private var value: AUValue = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(parameter.displayName); Spacer(); Text(parameter.string(fromValue: nil)).monospacedDigit().foregroundStyle(.secondary) }
            if parameter.maxValue > parameter.minValue {
                Slider(value: $value, in: parameter.minValue...parameter.maxValue)
                    .onChange(of: value) { _, new in parameter.value = new }
                    .disabled(!parameter.flags.contains(.flag_IsWritable))
            }
        }.onAppear { value = parameter.value }
    }
}
