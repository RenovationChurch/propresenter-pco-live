// Routes for the web dashboard.
//
// Safety:
// - By default the server only listens on 127.0.0.1.
// - The Host header must be this machine (blocks DNS-rebinding attacks).
// - Every request that changes something must carry `X-PCOSync: 1`. Browsers
//   won't send a custom header cross-site without a CORS preflight, which we
//   never approve, so another web page can't arm or move LIVE.
// - With remote access on, every request needs the password (HTTP Basic).
// - Credentials are write-only: the API never returns the secret.

import Foundation

public final class WebAPI {
    let service: SyncService
    let store: ConfigStore
    let log: Logger
    let transportFactory: () -> HTTPTransport
    public let version: String
    /// Called after settings that need the web server rebuilt (port, remote access).
    public var onWebSettingsChanged: (() -> Void)?

    public init(service: SyncService, version: String = "1.0",
                transportFactory: @escaping () -> HTTPTransport = { URLSessionTransport() }) {
        self.service = service
        self.store = service.store
        self.log = service.log
        self.version = version
        self.transportFactory = transportFactory
    }

    public func handle(_ req: WebRequest) -> HTTPResponse {
        let web = store.config.web
        if let denied = checkAccess(req, web) { return denied }
        do {
            return try route(req)
        } catch let e as PCOError {
            return error(502, e.message)
        } catch let e as ProPresenterError {
            return error(502, e.message)
        } catch {
            return self.error(400, "\(error)")
        }
    }

    func checkAccess(_ req: WebRequest, _ web: WebSettings) -> HTTPResponse? {
        if web.allowRemote {
            let given = req.headers["authorization"] ?? ""
            // Any username is fine; compare the password part.
            let ok: Bool = {
                guard given.hasPrefix("Basic "), let raw = Data(base64Encoded: String(given.dropFirst(6))),
                      let s = String(data: raw, encoding: .utf8), let colon = s.firstIndex(of: ":") else { return false }
                return constantTimeEquals(String(s[s.index(after: colon)...]), web.password)
            }()
            if !ok {
                return HTTPResponse(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"PCOSync\"", "Content-Type": "text/plain"],
                                    body: Data("password required".utf8))
            }
        } else {
            let host = (req.headers["host"] ?? "").lowercased()
            let name = host.split(separator: ":").first.map(String.init) ?? ""
            if !["127.0.0.1", "localhost", "[::1]"].contains(name) && !host.hasPrefix("[::1]") {
                return error(403, "this dashboard only answers on 127.0.0.1 (turn on remote access in Settings)")
            }
        }
        if req.method != "GET" && req.method != "HEAD" && req.headers["x-pcosync"] != "1" {
            return error(403, "missing X-PCOSync header")
        }
        return nil
    }

    func route(_ req: WebRequest) throws -> HTTPResponse {
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return HTTPResponse(status: 200, headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'",
            ], body: Data(dashboardHTML.utf8))
        case ("GET", "/api/status"):
            var s = service.snapshot()
            s["version"] = version
            s["hasCredentials"] = store.credentials != nil
            s["configuredServiceType"] = store.config.pco.serviceTypeId
            s["configuredPlan"] = store.config.pco.plan
            s["logFile"] = log.logFilePath ?? ""
            return .json(s)
        case ("GET", "/api/logs"):
            let after = Int(req.query["after"] ?? "0") ?? 0
            let rows = log.entries(after: after).map { e -> JSONObject in
                ["seq": e.seq, "time": ISO8601DateFormatter().string(from: e.time), "level": e.level.name, "message": e.message]
            }
            return .json(["entries": rows])
        case ("GET", "/api/config"):
            return .json(try configJSON())
        case ("PUT", "/api/config"):
            return try saveConfig(req)
        case ("POST", "/api/credentials"):
            return try saveCredentials(req)
        case ("POST", "/api/start"):
            let armed = req.json()?["armed"] as? Bool ?? false
            service.start(armed: armed)
            return .json(["ok": true, "message": armed ? "Started ARMED" : "Started dry-run"])
        case ("POST", "/api/stop"):
            service.stop()
            return .json(["ok": true, "message": "Stopped"])
        case ("POST", "/api/command"):
            guard let cmd = req.json()?["command"] as? String else { return error(400, "command missing") }
            return .json(["ok": true, "message": service.command(cmd)])
        case ("GET", "/api/pco/service-types"):
            let rows = try pcoClient().serviceTypes().map { ["id": $0.id, "name": $0.name] }
            return .json(["serviceTypes": rows])
        case ("GET", "/api/pco/plans"):
            let st = req.query["serviceType"] ?? store.config.pco.serviceTypeId
            if st.isEmpty { return error(400, "choose a service type first") }
            let rows = try pcoClient().futurePlans(st).prefix(20).map { ["id": $0.id, "title": $0.title, "dates": $0.dates] }
            return .json(["plans": Array(rows)])
        case ("GET", "/api/mapping"):
            return .json(try mapping())
        case ("GET", "/api/test-connection"):
            return .json(testConnection())
        default:
            if req.path.hasPrefix("/api/") { return error(404, "no such endpoint") }
            return error(404, "not found")
        }
    }

    func error(_ status: Int, _ message: String) -> HTTPResponse {
        .json(["ok": false, "error": message], status: status)
    }

    // MARK: settings

    func configJSON() throws -> JSONObject {
        let data = try JSONEncoder().encode(store.config)
        var cfg = try JSONSerialization.jsonObject(with: data) as! JSONObject
        if var web = cfg["web"] as? JSONObject {
            web["password"] = ""
            web["hasPassword"] = !store.config.web.password.isEmpty
            cfg["web"] = web
        }
        let creds = store.credentials
        return [
            "config": cfg,
            "credentials": ["saved": creds != nil, "appIdHint": creds.map { "…" + String($0.appId.suffix(4)) } ?? ""],
            "dataDirectory": store.directory.path,
        ]
    }

    func saveConfig(_ req: WebRequest) throws -> HTTPResponse {
        guard var obj = req.json() else { return error(400, "expected JSON") }
        let old = store.config
        // An empty password field means "keep the current one".
        if var web = obj["web"] as? JSONObject {
            if (web["password"] as? String ?? "").isEmpty { web["password"] = old.web.password }
            web.removeValue(forKey: "hasPassword")
            obj["web"] = web
        }
        let cfg = try AppConfig.decode(JSONSerialization.data(withJSONObject: obj))
        try store.save(cfg)
        log.info("Settings saved")
        var message = "Saved."
        if cfg.pco != old.pco || cfg.propresenter != old.propresenter || cfg.sync != old.sync || cfg.match != old.match || cfg.app.logLevel != old.app.logLevel {
            if service.isRunning {
                service.restartIfRunning()
                message += " Sync restarted with the new settings."
            }
        }
        if cfg.web != old.web {
            message += " Web settings take effect when the app restarts."
            onWebSettingsChanged?()
        }
        return .json(["ok": true, "message": message])
    }

    func saveCredentials(_ req: WebRequest) throws -> HTTPResponse {
        guard let obj = req.json() else { return error(400, "expected JSON") }
        if obj["clear"] as? Bool == true {
            try store.saveCredentials(nil)
            log.info("Planning Center credentials removed")
            service.stop()
            return .json(["ok": true, "message": "Credentials removed."])
        }
        let appId = (obj["appId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = (obj["secret"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if appId.isEmpty || secret.isEmpty { return error(400, "enter both the Application ID and the Secret") }
        // Check them before saving, read-only.
        let client = try PCOClient(appId: appId, secret: secret, baseURL: store.pcoBaseURLOverride ?? pcoBaseURL,
                                   transport: transportFactory(), maxRetries: 1, log: log)
        log.setSecrets([appId, secret] + [store.credentials?.appId, store.credentials?.secret])
        let types = try client.serviceTypes()
        try store.saveCredentials(Credentials(appId: appId, secret: secret))
        log.info("Planning Center credentials saved (\(types.count) service types visible)")
        service.restartIfRunning()
        return .json(["ok": true, "message": "Credentials work. \(types.count) service type(s) found."])
    }

    // MARK: read-only helpers

    func pcoClient() throws -> PCOClient {
        guard let c = store.credentials else { throw PCOError("Planning Center credentials missing: enter them in Settings") }
        return try PCOClient(appId: c.appId, secret: c.secret, baseURL: store.pcoBaseURLOverride ?? pcoBaseURL,
                             transport: transportFactory(), maxRetries: 1, log: log)
    }

    func ppClient() -> ProPresenterClient {
        let p = store.config.propresenter
        return ProPresenterClient(host: p.host, port: p.port, timeout: p.timeout, transport: transportFactory())
    }

    func testConnection() -> JSONObject {
        var out: JSONObject = [:]
        let pp = ppClient()
        do {
            let v = try pp.version()
            let a = try pp.active()
            out["propresenter"] = [
                "ok": true,
                "address": pp.baseURL,
                "version": v.str("host_description") ?? v.str("name") ?? "",
                "playlist": a.playlist?.name ?? "",
                "item": a.item?.name ?? "",
            ] as JSONObject
        } catch {
            out["propresenter"] = ["ok": false, "address": pp.baseURL, "error": "\(error)"] as JSONObject
        }
        do {
            let c = try pcoClient()
            let me = c.meId()
            let types = try c.serviceTypes()
            out["pco"] = ["ok": true, "personId": me ?? "", "serviceTypes": types.count] as JSONObject
        } catch {
            out["pco"] = ["ok": false, "error": "\(error)"] as JSONObject
        }
        return out
    }

    func mapping() throws -> JSONObject {
        let cfg = store.config
        let pco = try pcoClient()
        let ref = try pco.resolvePlan(cfg.pco, now: service.now(), windowMinutes: cfg.sync.serviceWindowMinutes)
        let items = try pco.planItems(ref.serviceTypeId, ref.planId)
        let matcher = Matcher(items, cfg.match)
        let pp = ppClient()
        let active = try pp.active()
        guard let pl = active.playlist else {
            return ["planId": ref.planId, "planLabel": ref.label, "playlist": "", "rows": [], "unmatchedItems": [],
                    "message": "ProPresenter has no active playlist. Click an item in the service playlist first."]
        }
        let playlist = try pp.playlistItems(pl)
        var hit = Set<String>()
        let rows = playlist.map { entry -> JSONObject in
            let r = matcher.match(PPRef(uuid: entry.uuid, name: entry.name, index: entry.index), playlist)
            for i in [r.item].compactMap({ $0 }) + r.alternatives { hit.insert(i.id) }
            return [
                "index": entry.index.map { $0 as Any } ?? NSNull(),
                "name": entry.name,
                "type": entry.type,
                "isPCO": entry.isPCO,
                "target": r.item?.title ?? "",
                "sequence": r.item?.sequence ?? 0,
                "alternatives": r.alternatives.map(\.sequence),
                "method": r.method,
                "score": (r.score * 100).rounded() / 100,
                "reason": r.reason,
                "warning": r.warning,
            ]
        }
        // Plan items no ProPresenter entry fires: LIVE passes over these.
        let unmatched = items.filter { !$0.isHeader && !hit.contains($0.id) }.map { ["sequence": $0.sequence, "title": $0.title] as JSONObject }
        return ["planId": ref.planId, "planLabel": ref.label, "playlist": pl.name, "rows": rows, "unmatchedItems": unmatched]
    }
}

func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var diff = x.count ^ y.count
    for i in 0..<max(x.count, y.count) {
        diff |= Int((i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0))
    }
    return diff == 0
}
