// PCOSync: keeps Planning Center Services LIVE on the same item as ProPresenter.
//
// On macOS it runs as a menu-bar app (no Dock icon). Everywhere, it serves a
// dashboard at http://127.0.0.1:8642 for monitoring and settings.
//
//   PCOSync                  menu-bar app (macOS)
//   PCOSync --headless       no menu bar; stop with Ctrl-C / SIGTERM
//   PCOSync --data-dir DIR   keep settings and logs in DIR
//   PCOSync --port N         dashboard port (overrides settings)

import Foundation
import PCOSyncCore
#if canImport(Glibc)
import Glibc
#endif

let appVersion = "1.0.0"

signal(SIGPIPE, SIG_IGN)

var headless = false
var dataDir: URL?
var portOverride: Int?
var argv = CommandLine.arguments.dropFirst().makeIterator()
while let a = argv.next() {
    switch a {
    case "--headless": headless = true
    case "--data-dir": dataDir = argv.next().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    case "--port": portOverride = argv.next().flatMap(Int.init)
    case "--version":
        print("PCOSync \(appVersion)")
        exit(0)
    case "-h", "--help":
        print("usage: PCOSync [--headless] [--data-dir DIR] [--port N]")
        exit(0)
    default:
        // macOS passes -psn_... and -NSDocumentRevisionsDebugMode etc. Ignore.
        continue
    }
}
#if !canImport(AppKit)
headless = true
#endif

let store: ConfigStore
do {
    store = try ConfigStore(directory: dataDir ?? ConfigStore.defaultDirectory())
} catch {
    FileHandle.standardError.write(Data("PCOSync: can't load settings: \(error)\n".utf8))
    exit(2)
}

let logURL: URL = {
    #if os(macOS)
    if dataDir == nil {
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PCOSync/pcosync.log")
    }
    #endif
    return store.directory.appendingPathComponent("logs/pcosync.log")
}()

let log = Logger(level: LogLevel(name: store.config.app.logLevel), fileURL: logURL, echoToStderr: true)
if let c = store.credentials { log.setSecrets([c.appId, c.secret]) }
log.info("PCOSync \(appVersion) starting; settings in \(store.directory.path)")

let service = SyncService(store: store, log: log)
let api = WebAPI(service: service, version: appVersion)
let webPort = portOverride ?? store.config.web.port
let dashboardURL = URL(string: "http://127.0.0.1:\(webPort)/")!
let server = WebServer(port: webPort, bindAll: store.config.web.allowRemote, handler: api.handle)
var webError: String?
do {
    try server.start()
    log.info("Dashboard at \(dashboardURL.absoluteString)\(store.config.web.allowRemote ? " (also on this Mac's network addresses, password protected)" : "")")
} catch {
    webError = "\(error)"
    log.error("Dashboard could not start: \(error)")
}

if store.config.app.autoStart {
    service.start(armed: store.config.app.startArmed)
}

func shutdown() {
    log.info("Shutting down")
    service.stop()
    server.stop()
}

if headless {
    if webError != nil && portOverride == nil {
        // Nothing to talk to; most likely another copy is already running.
        exit(1)
    }
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler {
            shutdown()
            exit(0)
        }
        src.resume()
        sources.append(src)
    }
    dispatchMain()
} else {
    #if canImport(AppKit)
    MainActor.assumeIsolated {
        runMenuBarApp(service: service, dashboardURL: dashboardURL, webError: webError, onQuit: shutdown)
    }
    #endif
}
