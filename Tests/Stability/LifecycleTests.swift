import Foundation
import AVFoundation

@MainActor final class FakePipeline: AudioPipeline {
    var running = false
    var outputPeak: Float = 0
    var consecutiveRenderErrors: UInt64 = 0
    var callbackCount: UInt64 = 0
    var sampleRate: Double = 48000
    var bypass = false
    var muted = false
    var gain: Float = 1
    var starts: [(UInt32, UInt32)] = []
    var failNextStart = false
    func begin(_ input: UInt32, _ output: UInt32) throws {
        if failNextStart { failNextStart = false; throw NSError(domain: "HAL not ready", code: 1) }
        running = true; starts.append((input, output))
    }
    func startSystem(to output: UInt32, units: [AVAudioUnit]) throws { try begin(0, output) }
    func startMicrophone(_ input: UInt32, to output: UInt32, units: [AVAudioUnit]) throws { try begin(input, output) }
    func stop() { running = false }
}

@MainActor final class LifecycleTests {
    var hardware: [RouteDevice] = []
    var date = Date(timeIntervalSince1970: 1000)
    var app: AppModel!
    var system: FakePipeline!
    var mic: FakePipeline!
    var directory: URL!
    let speaker = RouteDevice(id: 1, uid: "speaker", inputs: 0, outputs: 2)
    let physicalMic = RouteDevice(id: 2, uid: "mic", inputs: 1, outputs: 0)
    let virtual = RouteDevice(id: 3, uid: microphoneUID, inputs: 2, outputs: 2)

    func setUp() async throws {
        hardware = [speaker, physicalMic, virtual]
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        system = FakePipeline(); mic = FakePipeline()
        app = makeApp()
        app.system.deviceUID = "speaker"; app.microphone.deviceUID = "mic"
    }
    func makeApp(authorize: @escaping () async -> Bool = { true }) -> AppModel {
        AppModel(automatic: false, settings: directory.appendingPathComponent("state.json"),
                 systemEngine: system, microphoneEngine: mic, devices: { self.hardware },
                 now: { self.date }, authorize: authorize)
    }
    func tearDown() async throws {
        app.shutdown(); app = nil
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    func drain() async { try? await Task.sleep(for: .milliseconds(10)) }
    func enableBoth() async {
        app.toggle(app.system); app.toggle(app.microphone); await drain()
        expectTrue(app.system.enabled); expectTrue(app.microphone.enabled)
    }
    func testDuplicateSleepAndWakeRestoreOnlyRequestedRoutes() async {
        await enableBoth()
        app.prepareForSleep(); app.prepareForSleep()
        expectFalse(app.system.enabled); expectFalse(app.microphone.enabled)
        app.resumeFromSleep(); app.resumeFromSleep(); await drain()
        expectEqual(system.starts.count, 2); expectEqual(mic.starts.count, 2)
    }
    func testOffDuringWakeCancelsQueuedStart() async {
        await enableBoth(); app.prepareForSleep(); app.resumeFromSleep()
        app.toggle(app.microphone); await drain()
        expectFalse(app.microphone.enabled); expectFalse(app.microphone.requestedEnabled)
        expectEqual(mic.starts.count, 1)
        expectTrue(app.system.enabled)
    }
    func testSecondSleepCancelsFirstWake() async {
        await enableBoth(); app.prepareForSleep(); app.resumeFromSleep(); app.prepareForSleep()
        await drain(); expectFalse(app.microphone.enabled); expectFalse(app.system.enabled)
        app.resumeFromSleep(); await drain(); expectTrue(app.microphone.enabled)
    }
    func testSlowDeviceReturnAndChangedHALID() async {
        await enableBoth(); app.prepareForSleep()
        hardware = [speaker, virtual]; app.resumeFromSleep(); await drain()
        expectTrue(app.microphone.waiting); expectTrue(app.system.enabled)
        date.addTimeInterval(5)
        hardware.append(RouteDevice(id: 20, uid: "mic", inputs: 1, outputs: 0))
        app.refreshDevices(); await drain()
        expectTrue(app.microphone.enabled); expectEqual(mic.starts.last?.0, 20)
    }
    func testDisconnectNeverSubstitutesDifferentMicrophoneAndCanCancelWait() async {
        await enableBoth()
        hardware = [speaker, virtual, RouteDevice(id: 9, uid: "another-mic", inputs: 1, outputs: 0)]
        app.refreshDevices(); await drain()
        expectFalse(app.microphone.enabled); expectTrue(app.microphone.waiting)
        expectTrue(app.system.enabled); expectEqual(mic.starts.count, 1)
        app.toggle(app.microphone)
        hardware.append(physicalMic); app.refreshDevices(); await drain()
        expectFalse(app.microphone.enabled); expectEqual(mic.starts.count, 1)
    }
    func testRecoveryTimeoutAndTransientStartFailure() async {
        await enableBoth(); app.prepareForSleep(); mic.failNextStart = true
        app.resumeFromSleep(); await drain()
        expectFalse(app.microphone.enabled); expectTrue(app.microphone.waiting)
        date.addTimeInterval(2); app.refreshDevices(); await drain()
        expectTrue(app.microphone.enabled)
        hardware.removeAll { $0.uid == "mic" }; app.refreshDevices(); await drain()
        date.addTimeInterval(21); app.refreshDevices(); await drain()
        expectFalse(app.microphone.requestedEnabled); expectNotNil(app.microphone.error)
        hardware.append(physicalMic); app.refreshDevices(); await drain()
        expectFalse(app.microphone.enabled)
    }
    func testVirtualDeviceRestartAndSourceRateChangeRebuildOnlyAffectedLane() async {
        await enableBoth()
        hardware[2] = RouteDevice(id: 30, uid: microphoneUID, inputs: 2, outputs: 2)
        app.refreshDevices(); await drain()
        expectEqual(mic.starts.last?.1, 30); expectEqual(system.starts.count, 1)
        hardware[0] = RouteDevice(id: 1, uid: "speaker", inputs: 0, outputs: 2, rate: 44100)
        app.refreshDevices(); await drain()
        expectEqual(system.starts.count, 2); expectEqual(mic.starts.count, 2)
    }
    func testSelectionDuringSleepUsesExplicitNewDevice() async {
        await enableBoth(); app.prepareForSleep()
        hardware.append(RouteDevice(id: 9, uid: "chosen-mic", inputs: 1, outputs: 0))
        app.selectDevice("chosen-mic", lane: app.microphone)
        app.resumeFromSleep(); await drain()
        expectEqual(mic.starts.last?.0, 9)
    }
    func testLatePermissionReplyCannotStartAfterSleepOrShutdown() async {
        app.shutdown()
        var reply: CheckedContinuation<Bool, Never>?
        app = makeApp { await withCheckedContinuation { reply = $0 } }
        app.microphone.deviceUID = "mic"; app.toggle(app.microphone); await drain()
        expectNotNil(reply)
        app.prepareForSleep(); reply?.resume(returning: true); await drain()
        expectFalse(app.microphone.enabled); expectEqual(mic.starts.count, 0)
        app.shutdown(); app.resumeFromSleep(); await drain()
        expectEqual(mic.starts.count, 0)
    }
    func testDeviceLossWithRenderErrorsKeepsRecoveryIntent() async {
        await enableBoth()
        hardware.removeAll { $0.uid == "mic" }; mic.consecutiveRenderErrors = 9
        app.checkRenderHealth(app.microphone)
        expectTrue(app.microphone.requestedEnabled); expectTrue(app.microphone.waiting)
        expectFalse(app.microphone.enabled); expectTrue(app.system.enabled)
        hardware.append(physicalMic); mic.consecutiveRenderErrors = 0
        app.refreshDevices(); await drain(); expectTrue(app.microphone.enabled)
        mic.consecutiveRenderErrors = 9; app.checkRenderHealth(app.microphone)
        expectFalse(app.microphone.requestedEnabled) // a failing AU on a valid route stops
    }
    func testCompatibleComponentDoesNotNeedReinstallation() async {
        expectTrue(AudioComponentInstallation(installedBuild: nil, bundledBuild: 1).needsSetup)
        expectTrue(AudioComponentInstallation(installedBuild: 1, bundledBuild: 2).needsSetup)
        expectFalse(AudioComponentInstallation(installedBuild: 1, bundledBuild: 1).needsSetup)
        expectFalse(AudioComponentInstallation(installedBuild: 2, bundledBuild: 1).needsSetup)
    }
    func testStalledCallbackStopsWithoutCallingSilenceAFailure() async {
        await enableBoth()
        date.addTimeInterval(2); mic.callbackCount += 100; system.callbackCount += 100; app.checkCallbacks()
        expectTrue(app.microphone.enabled) // silent samples still have callbacks
        date.addTimeInterval(4); system.callbackCount += 100; app.checkCallbacks()
        expectFalse(app.microphone.enabled); expectTrue(app.system.enabled)
    }
}

func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, "Expected true", file: file, line: line) }
func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(!value, "Expected false", file: file, line: line) }
func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { precondition(a == b, "Expected \(b), got \(a)", file: file, line: line) }
func expectNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) { precondition(value != nil, "Expected non-nil", file: file, line: line) }
@main struct StabilityTestRunner {
    @MainActor static func main() async throws {
        do { let test = LifecycleTests(); try await test.setUp(); await test.testCompatibleComponentDoesNotNeedReinstallation(); try await test.tearDown(); print("PASS: testCompatibleComponentDoesNotNeedReinstallation") }
        do { let test = LifecycleTests(); try await test.setUp(); await test.testDeviceLossWithRenderErrorsKeepsRecoveryIntent(); try await test.tearDown(); print("PASS: testDeviceLossWithRenderErrorsKeepsRecoveryIntent") }
        do { let test = LifecycleTests(); try await test.setUp(); await test.testDuplicateSleepAndWakeRestoreOnlyRequestedRoutes(); try await test.tearDown(); print("PASS: testDuplicateSleepAndWakeRestoreOnlyRequestedRoutes") }
        do { let test = LifecycleTests(); try await test.setUp(); await test.testOffDuringWakeCancelsQueuedStart(); try await test.tearDown(); print("PASS: testOffDuringWakeCancelsQueuedStart") }
        do { let test = LifecycleTests(); try await test.setUp(); await test.testSecondSleepCancelsFirstWake(); try await test.tearDown(); print("PASS: testSecondSleepCancelsFirstWake") }
        do { let test = LifecycleTests(); try await test.setUp(); await test.testSlowDeviceReturnAndChangedHALID(); try await test.tearDown(); print("PASS: testSlowDeviceReturnAndChangedHALID") }
        do { let test = LifecycleTests(); try await test.setUp(); await test.testDisconnectNeverSubstitutesDifferentMicrophoneAndCanCancelWait(); try await test.tearDown(); print("PASS: testDisconnectNeverSubstitutesDifferentMicrophoneAndCanCancelWait") }
        do { let test = LifecycleTests(); try await test.setUp(); await test.testRecoveryTimeoutAndTransientStartFailure(); try await test.tearDown(); print("PASS: testRecoveryTimeoutAndTransientStartFailure") }
        do { let test = LifecycleTests(); try await test.setUp(); await test.testVirtualDeviceRestartAndSourceRateChangeRebuildOnlyAffectedLane(); try await test.tearDown(); print("PASS: testVirtualDeviceRestartAndSourceRateChangeRebuildOnlyAffectedLane") }
        do { let test = LifecycleTests(); try await test.setUp(); await test.testSelectionDuringSleepUsesExplicitNewDevice(); try await test.tearDown(); print("PASS: testSelectionDuringSleepUsesExplicitNewDevice") }
        do { let test = LifecycleTests(); try await test.setUp(); await test.testLatePermissionReplyCannotStartAfterSleepOrShutdown(); try await test.tearDown(); print("PASS: testLatePermissionReplyCannotStartAfterSleepOrShutdown") }
        do { let test = LifecycleTests(); try await test.setUp(); await test.testStalledCallbackStopsWithoutCallingSilenceAFailure(); try await test.tearDown(); print("PASS: testStalledCallbackStopsWithoutCallingSilenceAFailure") }
    }
}
