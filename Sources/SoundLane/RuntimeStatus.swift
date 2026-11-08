import AppKit
import AVFoundation

@MainActor enum RuntimeStatus {
    private static let request = Notification.Name("in.teren.SoundLane.status.request")
    private static let response = Notification.Name("in.teren.SoundLane.status.response")
    private static var observer: NSObjectProtocol?
    static func install(model: AppModel) {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: request, object: nil, queue: .main) { [weak model] notification in
            MainActor.assumeIsolated {
                guard let model, let id = notification.object as? String, UUID(uuidString: id) != nil else { return }
                let data: [String: Any] = [
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
                    "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
                    "microphoneAuthorized": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                    "systemProcessing": model.system.enabled,
                    "microphoneProcessing": model.microphone.enabled,
                    "systemCallbacks": NSNumber(value: model.system.engine.callbackCount),
                    "microphoneCallbacks": NSNumber(value: model.microphone.engine.callbackCount),
                    "virtualMicrophoneAvailable": model.virtualMicrophone != nil,
                    "componentNeedsSetup": model.audioComponent.needsSetup,
                ]
                DistributedNotificationCenter.default().postNotificationName(response, object: id, userInfo: data, deliverImmediately: true)
            }
        }
    }
    static func query() -> Bool {
        let id = UUID().uuidString
        var result: [AnyHashable: Any]?
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: response, object: id, queue: .main) { notification in
            MainActor.assumeIsolated { result = notification.userInfo }
        }
        defer { center.removeObserver(token) }
        center.postNotificationName(request, object: id, userInfo: nil, deliverImmediately: true)
        let limit = Date().addingTimeInterval(4)
        while result == nil && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let result, JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return false }
        print(text); return true
    }
}
