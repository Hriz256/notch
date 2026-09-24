import Foundation

// Probe for the MediaRemote calls the helper uses to follow the player the user hears
// (docs/superpowers/specs/2026-09-24-music-player-choice-design.md). Signatures were read from
// `dyld_info -disassemble` on MediaRemote; the comments note where a guess would crash.
//
//   ./spike                 every now-playing client with its own state and info
//   ./spike watch 60        MediaRemote notifications for 60 s, with the client they name
//   ./spike pause-chrome    sends Pause to Chrome only (harmless while it is paused)
//   ./spike seek-chrome     seeks Chrome to 1 s through command 24

setvbuf(stdout, nil, _IOLBF, 0)

typealias GetLocalOriginFn = @convention(c) () -> Unmanaged<AnyObject>?
typealias GetClientsFn = @convention(c) (DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void
typealias GetClientFn = @convention(c) (DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void
typealias ClientStringFn = @convention(c) (AnyObject?) -> Unmanaged<CFString>?
/// The state block takes the state alone; declaring a second (error) parameter reads garbage and crashes.
typealias StateForClientFn = @convention(c) (AnyObject?, AnyObject?, DispatchQueue, @escaping @convention(block) (UInt32) -> Void) -> Void
/// The info block's second parameter is not an object; only the dictionary is read.
typealias InfoForClientFn = @convention(c) (AnyObject?, AnyObject?, Bool, DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
typealias SendToClientFn = @convention(c) (UInt32, CFDictionary?, AnyObject?, AnyObject?, UInt32, DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Bool
typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
typealias RegisterFn = @convention(c) (DispatchQueue) -> Void

let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)!
func sym<T>(_ name: String, _ type: T.Type) -> T { unsafeBitCast(dlsym(handle, name)!, to: type) }
let localOrigin = sym("MRMediaRemoteGetLocalOrigin", GetLocalOriginFn.self)
let getClients = sym("MRMediaRemoteGetNowPlayingClients", GetClientsFn.self)
let getElected = sym("MRMediaRemoteGetNowPlayingClient", GetClientFn.self)
let bundleID = sym("MRNowPlayingClientGetBundleIdentifier", ClientStringFn.self)
let stateFor = sym("MRMediaRemoteGetPlaybackStateForClient", StateForClientFn.self)
let infoFor = sym("MRMediaRemoteGetNowPlayingInfoForClient", InfoForClientFn.self)
let sendTo = sym("MRMediaRemoteSendCommandToClient", SendToClientFn.self)
let getElectedInfo = sym("MRMediaRemoteGetNowPlayingInfo", GetInfoFn.self)
let register = sym("MRMediaRemoteRegisterForNowPlayingNotifications", RegisterFn.self)

let args = CommandLine.arguments
let q = DispatchQueue(label: "spike")
let origin = localOrigin()?.takeUnretainedValue()

func name(_ client: AnyObject?) -> String {
    client.flatMap { bundleID($0)?.takeUnretainedValue() as String? } ?? "-"
}

func describe(_ info: CFDictionary?) -> String {
    guard let d = info as NSDictionary? else { return "no info" }
    func v(_ key: String) -> Any { d["kMRMediaRemoteNowPlayingInfo\(key)"] ?? "-" }
    let art = (d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data)?.count ?? 0
    return "title=\(v("Title")) artist=\(v("Artist")) duration=\(v("Duration")) elapsed=\(v("ElapsedTime")) rate=\(v("PlaybackRate")) artwork=\(art)B"
}

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

if let i = args.firstIndex(of: "watch") {
    let seconds = Double(args.dropFirst(i + 1).first ?? "") ?? 60
    register(q)
    NotificationCenter.default.addObserver(forName: nil, object: nil, queue: nil) { n in
        guard n.name.rawValue.hasPrefix("kMR") else { return }
        let info = n.userInfo ?? [:]
        let path = info["kMRNowPlayingPlayerPathUserInfoKey"] as? NSObject
        let client = path?.value(forKey: "client") as AnyObject?
        let playing = info["kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey"].map { " isPlaying=\($0)" } ?? ""
        let state = info["kMRMediaRemotePlaybackStateUserInfoKey"].map { " state=\($0)" } ?? ""
        print("\(stamp()) \(n.name.rawValue) client=\(name(client))\(playing)\(state)")
    }
    print("watching for \(seconds) s")
    q.asyncAfter(deadline: .now() + seconds) { exit(0) }
} else {
    getElected(q) { print("elected: \(name($0))") }
    getElectedInfo(q) { print("elected info: \(describe($0))") }
    getClients(q) { list in
        let clients = list as? [AnyObject] ?? []
        print("clients: \(clients.count)")
        for c in clients {
            let id = name(c)
            stateFor(c, origin, q) { print("  \(id) state=\($0) (1 playing, 2 paused, 3 stopped)") }
            infoFor(c, origin, true, q) { print("  \(id) \(describe($0))") }
            guard id == "com.google.Chrome" else { continue }
            if args.contains("pause-chrome") {
                print("  pause → Chrome returned \(sendTo(1, nil, origin, c, 0, q) { _ in })")
            }
            if args.contains("seek-chrome") {
                let options = ["kMRMediaRemoteOptionPlaybackPosition": 1.0] as CFDictionary
                print("  seek → Chrome returned \(sendTo(24, options, origin, c, 0, q) { _ in })")
                q.asyncAfter(deadline: .now() + 1) { infoFor(c, origin, false, q) { print("  after seek: \(describe($0))") } }
            }
        }
    }
    q.asyncAfter(deadline: .now() + 3) { exit(0) }
}
dispatchMain()
