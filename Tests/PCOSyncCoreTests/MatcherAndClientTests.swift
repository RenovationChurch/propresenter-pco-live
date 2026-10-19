import XCTest
@testable import PCOSyncCore

let ITEMS = [
    PlanItem(id: "h", title: "WORSHIP", itemType: "header", sequence: 1),
    PlanItem(id: "1", title: "Way Maker", itemType: "song", sequence: 2),
    PlanItem(id: "2", title: "Goodness of God", itemType: "song", sequence: 3),
    PlanItem(id: "3", title: "Welcome & Announcements", itemType: "item", sequence: 4),
]

func ref(_ name: String, _ uuid: String = "", _ index: Int? = nil) -> PPRef {
    PPRef(uuid: uuid, name: name, index: index)
}

func entry(_ name: String, _ index: Int, _ type: String = "presentation", isPCO: Bool = true) -> PPPlaylistItem {
    PPPlaylistItem(uuid: "u\(index)", name: name, index: index, type: type, isPCO: isPCO, isHidden: false)
}

final class MatcherTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(normalize("  Goodness Of God! "), "goodness of god")
        XCTAssertEqual(normalize("Welcome & Announcements"), normalize("welcome and announcements"))
        XCTAssertEqual(normalize("Who You Say I’m"), normalize("Who You Say Im"))
        XCTAssertEqual(normalize("Él Shaddai"), "el shaddai")
        XCTAssertEqual(normalize("Way Maker (Live) - Key of B"), "way maker live key of b")
    }

    func testTitleMatch() {
        let r = Matcher(ITEMS).match(ref("goodness of GOD"))
        XCTAssertEqual(r.item?.id, "2")
        XCTAssertEqual(r.method, "title")
    }

    func testHeadersNeverMatchByTitle() {
        XCTAssertNil(Matcher(ITEMS).match(ref("Worship")).item)
    }

    func testAlias() {
        let r = Matcher(ITEMS, MatchSettings(aliases: ["Way Maker (Live)": "Way Maker"])).match(ref("Way Maker (live)"))
        XCTAssertEqual(r.item?.id, "1")
        XCTAssertEqual(r.method, "alias")
    }

    func testIgnoreExactAndRegex() {
        let m = Matcher(ITEMS, MatchSettings(ignore: ["Way Maker", "regex:^backup"]))
        XCTAssertEqual(m.match(ref("way maker")).method, "ignored")
        XCTAssertEqual(m.match(ref("BACKUP slides")).method, "ignored")
    }

    func testBadRegexIsReportedNotFatal() {
        let m = Matcher(ITEMS, MatchSettings(ignore: ["regex:(unclosed"]))
        XCTAssertEqual(m.badPatterns, ["regex:(unclosed"])
        XCTAssertEqual(m.match(ref("Way Maker")).item?.id, "1")
    }

    func testPositionalFallbackUsesIsPCOEntriesOnly() {
        let playlist = [entry("WORSHIP", 0, "header"), entry("Loop", 1, isPCO: false), entry("WM - Key of B", 2), entry("GOG", 3), entry("Welcome", 4)]
        let m = Matcher(ITEMS)
        let r = m.match(ref("GOG", "u3", 3), playlist)
        XCTAssertEqual(r.item?.id, "2")
        XCTAssertEqual(r.method, "position")
        XCTAssertNil(m.match(ref("Loop", "u1", 1), playlist).item)
    }

    func testPositionalFallbackDisabled() {
        let playlist = [entry("WORSHIP", 0, "header"), entry("WM", 1), entry("GOG", 2), entry("Welcome", 3)]
        XCTAssertNil(Matcher(ITEMS, MatchSettings(positionalFallback: false)).match(ref("GOG", "u2", 2), playlist).item)
    }

    func testPositionalRequiresEqualCounts() {
        XCTAssertNil(Matcher(ITEMS).match(ref("GOG", "u1", 1), [entry("WM", 0), entry("GOG", 1)]).item)
    }

    func testPPHeaderNeverMatches() {
        XCTAssertEqual(Matcher(ITEMS).match(ref("Way Maker", "u0", 0), [entry("Way Maker", 0, "header")]).method, "header")
    }
}

final class ClientTests: XCTestCase {
    func testUnarmedClientCannotWrite() throws {
        let fake = FakePCO()
        let pco = try PCOClient(appId: FAKE_APP_ID, secret: FAKE_SECRET, transport: fake.transport)
        XCTAssertThrowsError(try pco.goToNextItem(ST, PLAN)) { XCTAssertTrue(($0 as! PCOError).writeBlocked) }
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testMissingCredentials() {
        XCTAssertThrowsError(try PCOClient(appId: nil, secret: "x"))
    }

    func test401MessageHasNoSecret() throws {
        let pco = try PCOClient(appId: FAKE_APP_ID, secret: FAKE_SECRET, transport: ClosureTransport { _ in HTTPResponse(status: 401) })
        XCTAssertThrowsError(try pco.serviceTypes()) {
            let msg = "\($0)"
            XCTAssertFalse(msg.contains(FAKE_SECRET))
            XCTAssertFalse(msg.contains(FAKE_APP_ID))
        }
    }

    func testSendsBasicAuth() throws {
        var auth = ""
        let pco = try PCOClient(appId: "app", secret: "sec", transport: ClosureTransport { req in
            auth = req.headers["Authorization"] ?? ""
            return .json(["data": []])
        })
        _ = try pco.serviceTypes()
        XCTAssertEqual(auth, "Basic " + Data("app:sec".utf8).base64EncodedString())
    }

    func testPaginationReadsAllItems() throws {
        let fake = FakePCO()
        let pco = try PCOClient(appId: FAKE_APP_ID, secret: FAKE_SECRET, transport: fake.transport)
        XCTAssertEqual(try pco.planItems(ST, PLAN).map(\.id), fake.items.map(\.id))
    }

    func testLiveStateParse() throws {
        let fake = FakePCO()
        fake.place("s2", "pt11")
        fake.controller = ME
        let pco = try PCOClient(appId: FAKE_APP_ID, secret: FAKE_SECRET, transport: fake.transport)
        let live = try pco.liveState(ST, PLAN)
        XCTAssertEqual(live, LiveState(currentItemId: "s2", currentPlanTimeId: "pt11", controllerId: ME, hasController: true))
    }

    func testLiveParseLinkOnlyControllerAndNotStarted() {
        let live = parseLive(["data": ["links": ["controller": "https://x/people/1"], "relationships": [:] as JSONObject], "included": []])
        XCTAssertTrue(live.hasController)
        XCTAssertNil(live.controllerId)
        XCTAssertNil(live.currentItemId)
    }

    func testParseRealServiceStartItemTime() throws {
        // Shape captured from the real API (next_item_time before a service starts).
        let raw = """
        {"data": {"type": "Live", "links": {"controller": null, "current_item_time": null},
          "relationships": {"current_item_time": {"data": {"type": "ItemTime", "id": "224515872"}}, "controller": {"data": null}}},
         "included": [{"type": "ItemTime", "id": "224515872",
           "attributes": {"exclude": false, "length": 7870.0, "live_end_at": null, "live_start_at": null},
           "relationships": {"item": {"data": null}, "plan_time": {"data": {"type": "PlanTime", "id": "224515872"}},
             "plan": {"data": {"type": "Plan", "id": "90700203"}}}}]}
        """
        let doc = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! JSONObject
        let live = parseLive(doc)
        XCTAssertNil(live.currentItemId)
        XCTAssertEqual(live.currentPlanTimeId, "224515872")
        XCTAssertFalse(live.hasController)
    }

    func testProPresenterActiveNoneIndex() throws {
        let pp = ProPresenterClient(host: "h", port: 1, transport: FakeProPresenter().transport)
        let active = try pp.active()
        XCTAssertNil(active.item)
        XCTAssertNil(active.playlist)
    }

    func testProPresenterActiveAndPlaylist() throws {
        let fake = FakeProPresenter()
        fake.fire("Way Maker")
        let pp = ProPresenterClient(host: "h", port: 1, transport: fake.transport)
        let active = try pp.active()
        XCTAssertEqual(active.item?.name, "Way Maker")
        XCTAssertEqual(active.item?.index, 4)
        let items = try pp.playlistItems(active.playlist!)
        XCTAssertEqual(items[0].type, "header")
        XCTAssertFalse(items[2].isPCO)
    }

    func testRedaction() {
        let log = Logger(echoToStderr: false)
        log.setSecrets([FAKE_SECRET])
        log.info("token is \(FAKE_SECRET)")
        let msg = log.entries().last!.message
        XCTAssertFalse(msg.contains(FAKE_SECRET))
        XCTAssertTrue(msg.contains("***"))
    }

    func testSecretsNeverLoggedDuringSync() {
        let h = Harness()
        h.fire("Countdown")
        h.fire("Way Maker")
        h.engine.release()
        let all = h.log.entries().map(\.message).joined(separator: "\n")
        XCTAssertFalse(all.isEmpty)
        XCTAssertFalse(all.contains(FAKE_SECRET))
        XCTAssertFalse(all.contains(FAKE_APP_ID))
    }

    func testLogFileRotates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pcosync-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.log")
        let log = Logger(fileURL: url, echoToStderr: false)
        let line = String(repeating: "x", count: 1000)
        for _ in 0..<2500 { log.info(line) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".1"))
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
        XCTAssertLessThan(size.intValue, 2_000_000)
    }
}
