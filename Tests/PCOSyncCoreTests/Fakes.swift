// In-memory fakes of the PCO Services API and the ProPresenter API, served
// through ClosureTransport so the real clients run unchanged.
//
// FakePCO models LIVE as a cursor over (service time, item) slots. Behaviours
// that are NOT yet confirmed against real PCO are switchable:
//   skipHeaders   go_to_next/previous skip header items (assumed true)

import Foundation
@testable import PCOSyncCore

let ST = "111"
let PLAN = "222"
let ME = "9001"
let FAKE_APP_ID = "fake-app-id-0123456789"
let FAKE_SECRET = "pco_pat_fake_secret_abcdef"

struct FakeItem {
    let id: String
    let title: String
    var itemType = "song"
    var description = ""
    init(_ id: String, _ title: String, _ itemType: String = "song", _ description: String = "") {
        self.id = id
        self.title = title
        self.itemType = itemType
        self.description = description
    }
}

func defaultItems() -> [FakeItem] {
    [
        FakeItem("h1", "PRE-SERVICE", "header"),
        FakeItem("i1", "Countdown", "item"),
        FakeItem("h2", "WORSHIP", "header"),
        FakeItem("s1", "Way Maker"),
        FakeItem("s2", "Goodness of God"),
        FakeItem("s3", "Build My Life"),
        FakeItem("i2", "Welcome & Announcements", "item"),
        FakeItem("i3", "Sermon", "item"),
        FakeItem("s4", "Doxology"),
    ]
}

enum Failure {
    case status(Int)
    case transport(String)
}

func jsonResponse(_ obj: Any, status: Int = 200) -> HTTPResponse {
    .json(obj, status: status)
}

final class FakePCO {
    var items: [FakeItem]
    var planTimes: [(String, String, String)] = [
        ("pt9", "service", "2026-10-18T13:00:00Z"),
        ("pt11", "service", "2026-10-18T15:00:00Z"),
        ("rh", "rehearsal", "2026-10-18T11:00:00Z"),
    ]
    var skipHeaders: Bool
    var serviceMarkers: Bool  // a "service start" stop before each service's items
    var controller: String?
    var cursor: Int?  // index into slots, nil = not started
    var failQueue: [Failure] = []
    var requests: [(String, String)] = []
    lazy var transport = ClosureTransport { [self] in try self.handle($0) }

    init(items: [FakeItem] = defaultItems(), skipHeaders: Bool = true, serviceMarkers: Bool = true) {
        self.items = items
        self.skipHeaders = skipHeaders
        self.serviceMarkers = serviceMarkers
    }

    var slots: [(String, FakeItem?)] {
        var out: [(String, FakeItem?)] = []
        for pt in planTimes where pt.1 == "service" {
            if serviceMarkers { out.append((pt.0, nil)) }
            out += items.map { (pt.0, $0) }
        }
        return out
    }

    func current() -> (String, FakeItem?)? {
        cursor.map { slots[$0] }
    }

    func place(_ itemId: String, _ planTime: String = "pt9") {
        cursor = slots.firstIndex { $0.0 == planTime && $0.1?.id == itemId }
    }

    var writes: [(String, String)] { requests.filter { $0.0 != "GET" } }

    func step(_ delta: Int) {
        let s = slots
        var pos = cursor ?? -1
        while true {
            pos += delta
            if pos < 0 || pos >= s.count { return }  // at an end: no movement
            if !(skipHeaders && s[pos].1?.itemType == "header") {
                cursor = pos
                return
            }
        }
    }

    func handle(_ req: HTTPRequest) throws -> HTTPResponse {
        let path = req.path
        requests.append((req.method, path))
        if !failQueue.isEmpty {
            switch failQueue.removeFirst() {
            case .transport(let kind): throw TransportError(kind)
            case .status(let code):
                return .json(["errors": [["detail": "fake failure"]]], status: code, headers: code == 429 ? ["Retry-After": "1"] : [:])
            }
        }
        let base = "/services/v2/service_types/\(ST)/plans/\(PLAN)"
        switch path {
        case "/services/v2/me":
            return jsonResponse(["data": ["type": "Person", "id": ME]])
        case "/services/v2/service_types":
            return jsonResponse(["data": [["type": "ServiceType", "id": ST, "attributes": ["name": "Sunday"]]], "links": [:]])
        case "/services/v2/service_types/\(ST)/plans":
            return jsonResponse(["data": [["type": "Plan", "id": PLAN, "attributes": ["title": "", "dates": "October 18, 2026"]]], "links": [:]])
        case base + "/items":
            return itemsPage(req)
        case base + "/plan_times":
            let data = planTimes.map { ["type": "PlanTime", "id": $0.0, "attributes": ["time_type": $0.1, "starts_at": $0.2, "name": NSNull()]] as [String: Any] }
            return jsonResponse(["data": data, "links": [:]])
        case base + "/live" where req.method == "GET":
            return jsonResponse(liveDoc())
        default:
            break
        }
        if path.hasPrefix(base + "/live/") && req.method == "POST" {
            let action = String(path.dropFirst((base + "/live/").count))
            switch action {
            case "toggle_control":
                controller = controller == ME ? nil : ME
            case "go_to_next_item", "go_to_previous_item":
                if controller != ME { return .json(["errors": [["detail": "not controller"]]], status: 403) }
                step(action == "go_to_next_item" ? 1 : -1)
            default:
                return HTTPResponse(status: 404)
            }
            return jsonResponse(liveDoc())
        }
        return .json(["errors": [["detail": "no fake route \(path)"]]], status: 404)
    }

    func itemsPage(_ req: HTTPRequest) -> HTTPResponse {
        // Two pages to exercise pagination.
        let offset = Int(req.queryValue("offset") ?? "0") ?? 0
        let size = 5
        let chunk = items[min(offset, items.count)..<min(offset + size, items.count)]
        let data = chunk.enumerated().map { n, it in
            ["type": "Item", "id": it.id, "attributes": ["title": it.title, "item_type": it.itemType, "sequence": offset + n + 1, "description": it.description]] as [String: Any]
        }
        var links: [String: Any] = [:]
        if offset + size < items.count {
            var comps = URLComponents(url: req.url, resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "offset", value: String(offset + size))]
            links["next"] = comps.url!.absoluteString
        }
        return jsonResponse(["data": data, "links": links])
    }

    func liveDoc() -> [String: Any] {
        let cur = current()
        let rels: [String: Any] = [
            "controller": ["data": controller.map { ["type": "Person", "id": $0] as Any } ?? NSNull()],
            "current_item_time": ["data": cur != nil ? ["type": "ItemTime", "id": "it-x"] as Any : NSNull()],
        ]
        var included: [[String: Any]] = []
        if let c = cur {
            included.append([
                "type": "ItemTime",
                "id": "it-x",
                "relationships": [
                    "item": ["data": c.1.map { ["type": "Item", "id": $0.id] as Any } ?? NSNull()],
                    "plan_time": ["data": ["type": "PlanTime", "id": c.0]],
                ],
            ])
        }
        if let c = controller { included.append(["type": "Person", "id": c, "attributes": [:] as [String: Any]]) }
        return ["data": ["type": "Live", "id": PLAN, "attributes": ["title": "", "dates": "October 18, 2026"], "relationships": rels], "included": included]
    }
}

struct FakePPEntry {
    let name: String
    var type = "presentation"
    var isPCO = true
    var uuid = ""
    init(_ name: String, _ type: String = "presentation", isPCO: Bool = true) {
        self.name = name
        self.type = type
        self.isPCO = isPCO
    }
}

func defaultPlaylist() -> [FakePPEntry] {
    [
        FakePPEntry("PRE-SERVICE", "header"),
        FakePPEntry("Countdown"),
        FakePPEntry("Pre-Service Loop", isPCO: false),
        FakePPEntry("WORSHIP", "header"),
        FakePPEntry("Way Maker"),
        FakePPEntry("Goodness Of God"),
        FakePPEntry("Build My Life"),
        FakePPEntry("Welcome and Announcements"),
        FakePPEntry("Sermon"),
        FakePPEntry("Doxology"),
    ]
}

final class FakeProPresenter {
    var playlist: [FakePPEntry] {
        didSet { assignUUIDs() }
    }
    var playlistName = "Sunday - Oct 18"
    var activeIndex: Int?
    var reachable = true
    lazy var transport = ClosureTransport { [self] in try self.handle($0) }

    init(playlist: [FakePPEntry] = defaultPlaylist()) {
        self.playlist = playlist
        assignUUIDs()
    }

    private func assignUUIDs() {
        for n in playlist.indices where playlist[n].uuid.isEmpty { playlist[n].uuid = "pp-\(n)" }
    }

    func fire(_ name: String) {
        activeIndex = playlist.firstIndex { $0.name == name }!
    }

    func handle(_ req: HTTPRequest) throws -> HTTPResponse {
        if !reachable { throw TransportError("connection refused") }
        let refPl: [String: Any] = ["uuid": "pl-1", "name": playlistName, "index": 0]
        switch req.path {
        case "/version":
            return jsonResponse(["name": "Fake", "platform": "mac", "os_version": "26", "host_description": "ProPresenter 21.0"])
        case "/v1/playlist/active":
            guard let i = activeIndex else {
                let none: [String: Any] = ["uuid": "", "name": "", "index": 4_294_967_295]
                return jsonResponse(["presentation": ["playlist": none, "item": none], "announcements": ["playlist": none, "item": none]])
            }
            let e = playlist[i]
            let item: [String: Any] = ["uuid": e.uuid, "name": e.name, "index": i]
            return jsonResponse(["presentation": ["playlist": refPl, "item": item], "announcements": ["playlist": refPl, "item": item]])
        case "/v1/playlist/pl-1", "/v1/playlist/0":
            let items = playlist.enumerated().map { n, e in
                ["id": ["uuid": e.uuid, "name": e.name, "index": n], "type": e.type, "is_hidden": false, "is_pco": e.isPCO] as [String: Any]
            }
            return jsonResponse(["id": refPl, "items": items])
        default:
            return HTTPResponse(status: 404)
        }
    }
}

final class SleepLog {
    var values: [Double] = []
}

final class Clock {
    var t = 1000.0
    /// Wall clock: 30 minutes into the fake 9:00 (13:00Z) service.
    var wall = iso("2026-10-18T13:30:00Z")
    func advance(_ s: Double) {
        t += s
        wall = wall.addingTimeInterval(s)
    }
}

func iso(_ s: String) -> Date {
    ISO8601DateFormatter().date(from: s)!
}

final class Harness {
    let pcoFake: FakePCO
    let ppFake: FakeProPresenter
    let clock = Clock()
    let sleepLog = SleepLog()
    var sleeps: [Double] { sleepLog.values }
    let pco: PCOClient
    let pp: ProPresenterClient
    let engine: SyncEngine
    let log: Logger

    init(armed: Bool = true, settings: SyncSettings? = nil, match: MatchSettings? = nil,
         pco: FakePCO? = nil, pp: FakeProPresenter? = nil) {
        pcoFake = pco ?? FakePCO()
        ppFake = pp ?? FakeProPresenter()
        log = Logger(level: .debug, echoToStderr: false)
        let clock = self.clock
        let sleepLog = self.sleepLog
        self.pco = try! PCOClient(appId: FAKE_APP_ID, secret: FAKE_SECRET, allowWrites: armed,
                                  transport: pcoFake.transport, sleep: { sleepLog.values.append($0) }, log: log)
        self.pp = ProPresenterClient(host: "127.0.0.1", port: 50001, transport: ppFake.transport)
        engine = SyncEngine(
            pco: self.pco, pp: self.pp, serviceTypeId: ST, planId: PLAN,
            settings: settings ?? SyncSettings(debounceSeconds: 1.0, maxJump: 3, planRefreshSeconds: 0),
            matchSettings: match ?? MatchSettings(ignore: ["Pre-Service Loop", "regex:^backup"]),
            armed: armed, clock: { clock.t }, now: { clock.wall }, log: log
        )
        try! engine.loadPlan()
    }

    /// Fire a ProPresenter cue, let debounce elapse, return the acting decision.
    @discardableResult
    func fire(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Decision {
        ppFake.fire(name)
        let first = engine.tick()
        precondition(["debounce", "unchanged"].contains(first.action), "\(first.describe())")
        clock.advance(1.5)
        return engine.tick()
    }

    var liveTitle: String? { pcoFake.current()?.1?.title }
}
