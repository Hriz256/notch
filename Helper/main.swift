import Foundation
import os

let logger = Logger(subsystem: "app.notch", category: "helper.main")
let bridge = MediaRemoteBridge()
if bridge == nil { logger.error("MediaRemote could not be loaded") }
let monitor = bridge.map { NowPlayingMonitor(bridge: $0) }
let delegate = ServiceDelegate(monitor: monitor)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
