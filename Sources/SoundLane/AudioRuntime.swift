import Foundation
import AVFoundation
import AudioBridge

struct RouteDevice: Equatable {
    let deviceID: UInt32
    let uid: String
    let name: String
    let inputChannels: UInt32
    let outputChannels: UInt32
    let sampleRate: Double
    init(_ device: SLDevice) {
        deviceID = device.deviceID; uid = device.uid; name = device.name
        inputChannels = device.inputChannels; outputChannels = device.outputChannels; sampleRate = device.sampleRate
    }
    init(id: UInt32, uid: String, inputs: UInt32, outputs: UInt32, rate: Double = 48000) {
        deviceID = id; self.uid = uid; name = uid
        inputChannels = inputs; outputChannels = outputs; sampleRate = rate
    }
    var signature: String { "\(deviceID):\(uid):\(sampleRate):\(inputChannels):\(outputChannels)" }
}

@MainActor protocol AudioPipeline: AnyObject {
    var running: Bool { get }
    var outputPeak: Float { get }
    var consecutiveRenderErrors: UInt64 { get }
    var callbackCount: UInt64 { get }
    var sampleRate: Double { get }
    var bypass: Bool { get set }
    var muted: Bool { get set }
    var gain: Float { get set }
    func startSystem(to output: UInt32, units: [AVAudioUnit]) throws
    func startMicrophone(_ input: UInt32, to output: UInt32, units: [AVAudioUnit]) throws
    func stop()
}
extension SLPipeline: AudioPipeline {}

struct AudioComponentInstallation: Equatable {
    let installedBuild: Int?
    let bundledBuild: Int
    var needsSetup: Bool { installedBuild == nil || installedBuild! < bundledBuild }
    static func readVersion(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let build = plist["CFBundleVersion"] as? String else { return nil }
        return Int(build)
    }
    static func current() -> Self {
        let installed = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/SoundLane.driver/Contents/Info.plist")
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Audio/Plug-Ins/HAL/SoundLane.driver/Contents/Info.plist")
        return Self(installedBuild: readVersion(installed), bundledBuild: readVersion(bundled) ?? 1)
    }
}
