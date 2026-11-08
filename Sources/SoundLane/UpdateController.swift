import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor final class UpdateController: ObservableObject {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = true
    @Published private(set) var automaticInstallation = true
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    var configured: Bool { Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String }
    func start() {
        guard configured, controller == nil else { return }
        let standard = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = standard
        automaticChecks = standard.updater.automaticallyChecksForUpdates
        automaticInstallation = standard.updater.automaticallyDownloadsUpdates
        observation = standard.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }
    func check() { guard canCheck else { return }; controller?.checkForUpdates(nil) }
    func setChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
        automaticChecks = enabled
    }
    func setInstallation(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
        automaticInstallation = enabled
    }
}
struct UpdateSettings: View {
    @ObservedObject var updater: UpdateController
    var body: some View {
        Form {
            Section("Software Updates") {
                Toggle("Automatically check for updates", isOn: Binding(get: { updater.automaticChecks }, set: updater.setChecks))
                Toggle("Automatically download and install updates", isOn: Binding(get: { updater.automaticInstallation }, set: updater.setInstallation))
                LabeledContent("SoundLane", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
            }
        }.formStyle(.grouped).frame(width: 470, height: 240)
    }
}
