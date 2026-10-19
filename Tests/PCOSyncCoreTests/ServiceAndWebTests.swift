import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PCOSyncCore

/// Routes requests to the fake PCO or fake ProPresenter by host.
final class FakeWorld {
    let pco = FakePCO()
    let pp = FakeProPresenter()
    let lock = NSLock()
    func transport() -> HTTPTransport {
        ClosureTransport { [self] req in
            lock.lock(); defer { lock.unlock() }
            if req.url.host == "api.planningcenteronline.com" { return try pco.handle(req) }
            return try pp.handle(req)
        }
    }
}

final class ServiceAndWebTests: XCTestCase {
    var dir: URL!
    var world: FakeWorld!
    var store: ConfigStore!
    var log: Logger!
    var service: SyncService!
    var api: WebAPI!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pcosync-test-\(UUID().uuidString)")
        world = FakeWorld()
        store = try ConfigStore(directory: dir)
        log = Logger(level: .debug, echoToStderr: false)
        let w = world!
        service = SyncService(store: store, log: log, transportFactory: { w.transport() }, pcoSleep: { _ in })
        api = WebAPI(service: service, transportFactory: { w.transport() })
    }

    override func tearDown() {
        service.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func req(_ method: String, _ path: String, _ body: Any? = nil, host: String = "127.0.0.1:8642", csrf: Bool = true) -> WebRequest {
        var headers = ["Host": host]
        if csrf { headers["X-PCOSync"] = "1" }
        let data = body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let comps = URLComponents(string: path)!
        var q: [String: String] = [:]
        for i in comps.queryItems ?? [] { q[i.name] = i.value }
        return WebRequest(method: method, path: comps.path, query: q, headers: headers, body: data)
    }

    func call(_ r: WebRequest) -> (Int, JSONObject) {
        let resp = api.handle(r)
        return (resp.status, resp.jsonObject() ?? [:])
    }

    func configure() throws {
        try store.saveCredentials(Credentials(appId: FAKE_APP_ID, secret: FAKE_SECRET))
        var cfg = store.config
        cfg.pco.serviceTypeId = ST
        cfg.sync.debounceSeconds = 0
        cfg.propresenter.pollInterval = 0.1
        try store.save(cfg)
    }

    func waitFor(_ what: String, timeout: Double = 5, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: access control

    func testDashboardServed() {
        let resp = api.handle(req("GET", "/"))
        XCTAssertEqual(resp.status, 200)
        XCTAssertTrue(String(decoding: resp.body, as: UTF8.self).contains("<title>PCOSync</title>"))
    }

    func testRejectsForeignHostHeader() {
        XCTAssertEqual(call(req("GET", "/api/status", host: "evil.example:8642")).0, 403)
        XCTAssertEqual(call(req("GET", "/api/status", host: "localhost:8642")).0, 200)
    }

    func testWritesNeedCSRFHeader() {
        XCTAssertEqual(call(req("POST", "/api/start", ["armed": true], csrf: false)).0, 403)
        XCTAssertFalse(service.isRunning)
    }

    func testRemoteAccessNeedsPassword() throws {
        var cfg = store.config
        cfg.web.allowRemote = true
        cfg.web.password = "hunter22"
        try store.save(cfg)
        XCTAssertEqual(call(req("GET", "/api/status", host: "10.0.0.5:8642")).0, 401)
        var r = req("GET", "/api/status", host: "10.0.0.5:8642")
        r.headers["authorization"] = "Basic " + Data("x:hunter22".utf8).base64EncodedString()
        XCTAssertEqual(call(r).0, 200)
        r.headers["authorization"] = "Basic " + Data("x:wrong".utf8).base64EncodedString()
        XCTAssertEqual(call(r).0, 401)
    }

    func testRemoteAccessWithoutPasswordIsRejected() {
        var cfg = store.config
        cfg.web.allowRemote = true
        XCTAssertThrowsError(try store.save(cfg))
    }

    // MARK: settings

    func testConfigRoundTripNeverReturnsSecret() throws {
        let (status, body) = call(req("POST", "/api/credentials", ["appId": FAKE_APP_ID, "secret": FAKE_SECRET]))
        XCTAssertEqual(status, 200, "\(body)")
        let resp = api.handle(req("GET", "/api/config"))
        let text = String(decoding: resp.body, as: UTF8.self)
        XCTAssertFalse(text.contains(FAKE_SECRET))
        XCTAssertFalse(text.contains(FAKE_APP_ID))
        XCTAssertTrue(text.contains("\"saved\":true"))

        // Saved with mode 600.
        let perms = try FileManager.default.attributesOfItem(atPath: store.credentialsURL.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(perms.intValue & 0o077, 0)
    }

    func testBadCredentialsAreNotSaved() {
        world.pco.failQueue = [.status(401)]
        let (status, body) = call(req("POST", "/api/credentials", ["appId": "a", "secret": "b"]))
        XCTAssertEqual(status, 502)
        XCTAssertTrue((body["error"] as? String ?? "").contains("401"))
        XCTAssertNil(store.credentials)
    }

    func testSaveConfigAndReload() throws {
        var (_, cfg) = call(req("GET", "/api/config"))
        var c = cfg["config"] as! JSONObject
        var pp = c["propresenter"] as! JSONObject
        pp["port"] = 1025
        c["propresenter"] = pp
        var match = c["match"] as! JSONObject
        match["aliases"] = ["Way Maker (Live)": "Way Maker"]
        c["match"] = match
        let (status, body) = call(req("PUT", "/api/config", c))
        XCTAssertEqual(status, 200, "\(body)")
        let reread = try ConfigStore(directory: dir)
        XCTAssertEqual(reread.config.propresenter.port, 1025)
        XCTAssertEqual(reread.config.match.aliases, ["Way Maker (Live)": "Way Maker"])
        (_, cfg) = call(req("GET", "/api/config"))
        XCTAssertEqual(((cfg["config"] as! JSONObject)["propresenter"] as! JSONObject)["port"] as? Int, 1025)
    }

    func testInvalidConfigRejected() {
        let (status, body) = call(req("PUT", "/api/config", ["propresenter": ["port": 0]]))
        XCTAssertEqual(status, 400)
        XCTAssertTrue((body["error"] as? String ?? "").contains("port"))
    }

    func testPartialConfigFillsDefaults() throws {
        let cfg = try AppConfig.decode(Data(#"{"pco": {"serviceTypeId": "42"}}"#.utf8))
        XCTAssertEqual(cfg.pco.serviceTypeId, "42")
        XCTAssertEqual(cfg.pco.plan, "next")
        XCTAssertEqual(cfg.sync.maxJump, 3)
        XCTAssertEqual(cfg.match.ignore.count, 3)
    }

    // MARK: running

    func testNeedsSetupWithoutCredentials() {
        service.start(armed: false)
        waitFor("needs_setup") { service.state == .needsSetup }
        XCTAssertTrue((service.snapshot()["detail"] as? String ?? "").contains("Application ID"))
        XCTAssertEqual(service.command("pause"), "Enter your Planning Center Application ID and Secret in Settings.")
    }

    func testDryRunViaAPIThenArmedMoves() throws {
        try configure()
        XCTAssertEqual(call(req("POST", "/api/start", ["armed": false])).0, 200)
        waitFor("running") { service.state == .running }
        world.lock.lock(); world.pp.fire("Countdown"); world.lock.unlock()
        waitFor("dry_run decision") { (service.snapshot()["lastDecision"] as? JSONObject)?["action"] as? String == "dry_run" }
        XCTAssertTrue(world.pco.writes.isEmpty)

        XCTAssertEqual(call(req("POST", "/api/start", ["armed": true])).0, 200)
        waitFor("LIVE on Countdown") {
            world.lock.lock(); defer { world.lock.unlock() }
            return world.pco.current()?.1?.title == "Countdown"
        }
        let s = call(req("GET", "/api/status")).1
        XCTAssertEqual(s["armed"] as? Bool, true)
        XCTAssertEqual((s["propresenter"] as? JSONObject)?["item"] as? String, "Countdown")

        let (_, r) = call(req("POST", "/api/command", ["command": "pause"]))
        XCTAssertEqual(r["message"] as? String, "Paused: LIVE will not be moved until 'resume'.")

        // Stopping gives control back.
        XCTAssertEqual(call(req("POST", "/api/stop")).0, 200)
        XCTAssertEqual(service.state, .stopped)
        world.lock.lock(); defer { world.lock.unlock() }
        XCTAssertNil(world.pco.controller)
    }

    func testWaitsAndRecoversWhenPCODown() throws {
        try configure()
        world.pco.failQueue = Array(repeating: .status(500), count: 5)
        service.start(armed: false)
        waitFor("waiting") { service.state == .waiting }
        waitFor("running after recovery", timeout: 10) { service.state == .running }
    }

    func testMappingEndpoint() throws {
        try configure()
        world.pp.fire("Way Maker")
        let (status, m) = call(req("GET", "/api/mapping"))
        XCTAssertEqual(status, 200, "\(m)")
        let rows = m["rows"] as! [JSONObject]
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows[5]["target"] as? String, "Goodness of God")
        XCTAssertEqual(rows[2]["method"] as? String, "ignored")
    }

    func testTestConnectionEndpoint() throws {
        try configure()
        let (_, r) = call(req("GET", "/api/test-connection"))
        XCTAssertEqual((r["propresenter"] as? JSONObject)?["ok"] as? Bool, true)
        XCTAssertEqual((r["pco"] as? JSONObject)?["ok"] as? Bool, true)
    }

    // MARK: real socket

    func testWebServerOverSocket() throws {
        let port = 18642 + Int.random(in: 0..<1000)
        let server = WebServer(port: port, bindAll: false, handler: api.handle)
        try server.start()
        defer { server.stop() }
        let t = URLSessionTransport()
        let r = try t.send(HTTPRequest(method: "GET", url: URL(string: "http://127.0.0.1:\(port)/api/status")!), timeout: 5)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.jsonObject()?["state"] as? String, "stopped")

        let post = HTTPRequest(method: "POST", url: URL(string: "http://127.0.0.1:\(port)/api/command")!,
                               headers: ["X-PCOSync": "1", "Content-Type": "application/json"], body: Data(#"{"command":"status"}"#.utf8))
        let p = try t.send(post, timeout: 5)
        XCTAssertEqual(p.jsonObject()?["message"] as? String, "Not running. Start syncing first.")

        // Second server on the same port fails with a clear message.
        XCTAssertThrowsError(try WebServer(port: port, bindAll: false, handler: api.handle).start()) {
            XCTAssertTrue("\($0)".contains("already in use"))
        }
    }
}
