import Foundation
import WatchConnectivity
import Combine

final class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private var transferCompletion: ((Bool, Error?) -> Void)?

    private override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    /// Transfer a file URL to the paired iPhone.
    /// Calls completion(true, nil) on success, completion(false, error) on failure.
    func transferFile(_ fileURL: URL, metadata: [String: Any]? = nil, completion: @escaping (Bool, Error?) -> Void) {
        guard let session = session else {
            completion(false, nil)
            return
        }

        guard session.activationState == .activated else {
            completion(false, nil)
            return
        }

        transferCompletion = completion

        // Use transferFile which queues the transfer and returns a WCSessionFileTransfer
        session.transferFile(fileURL, metadata: metadata)
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let err = error {
            print("WatchConnectivity activation error: \(err)")
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if let err = error {
            print("File transfer failed: \(err)")
            transferCompletion?(false, err)
        } else {
            let fileDesc = String(describing: fileTransfer.file)
            print("File transfer completed: \(fileDesc)")
            transferCompletion?(true, nil)
        }
        transferCompletion = nil
    }

    // iOS callbacks not needed on watch side for now
    func sessionReachabilityDidChange(_ session: WCSession) {}
}
