import Foundation

// Replaced in Task 7 with the real XPC listener.
final class PlaceholderDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        false
    }
}

let delegate = PlaceholderDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
