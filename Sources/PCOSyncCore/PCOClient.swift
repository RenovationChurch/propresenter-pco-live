// Planning Center Services API client (only the parts this app needs).
//
// Endpoints and LIVE action names used here:
//   GET  /services/v2/me
//   GET  /services/v2/service_types
//   GET  /services/v2/service_types/{st}/plans?filter=future
//   GET  /services/v2/service_types/{st}/plans/{plan}/items
//   GET  /services/v2/service_types/{st}/plans/{plan}/plan_times
//   GET  /services/v2/service_types/{st}/plans/{plan}/live?include=current_item_time,controller
//   POST /services/v2/service_types/{st}/plans/{plan}/live/go_to_next_item
//   POST /services/v2/service_types/{st}/plans/{plan}/live/go_to_previous_item
//   POST /services/v2/service_types/{st}/plans/{plan}/live/toggle_control
//
// No "jump to item" action exists, so the sync engine steps next/previous and
// re-reads after each step. See docs/API_NOTES.md for what's verified.

import Foundation

public let pcoBaseURL = "https://api.planningcenteronline.com"
let maxRetryAfter = 30.0

/// Any failure talking to Planning Center. Messages never contain secrets.
public struct PCOError: Error, CustomStringConvertible {
    public let message: String
    public let writeBlocked: Bool
    public init(_ message: String, writeBlocked: Bool = false) {
        self.message = message
        self.writeBlocked = writeBlocked
    }
    public var description: String { message }
}

public struct PlanItem: Equatable {
    public let id: String
    public let title: String
    public let itemType: String
    public let sequence: Int
    /// The item's notes in the plan ("Gospel of John Week 4", "Alex lead").
    public let description: String
    public var isHeader: Bool { itemType == "header" }

    public init(id: String, title: String, itemType: String, sequence: Int, description: String = "") {
        self.id = id
        self.title = title
        self.itemType = itemType
        self.sequence = sequence
        self.description = description
    }
}

public struct PlanTime: Equatable {
    public let id: String
    public let timeType: String
    public let startsAt: String?
    public let name: String?

    public var start: Date? { startsAt.flatMap(parseISODate) }
}

func parseISODate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
}

public struct LiveState: Equatable {
    public let currentItemId: String?
    public let currentPlanTimeId: String?
    public let controllerId: String?
    public let hasController: Bool
}

public struct PlanSummary {
    public let id: String
    public let title: String
    public let dates: String
}

/// A plan and the service type it belongs to.
public struct PlanRef: Equatable {
    public let serviceTypeId: String
    public let planId: String
    public var label = ""

    public init(serviceTypeId: String, planId: String, label: String = "") {
        self.serviceTypeId = serviceTypeId
        self.planId = planId
        self.label = label
    }

    public static func == (a: PlanRef, b: PlanRef) -> Bool {
        a.serviceTypeId == b.serviceTypeId && a.planId == b.planId
    }
}

public final class PCOClient {
    public let allowWrites: Bool
    private let baseURL: String
    private let auth: String
    private let transport: HTTPTransport
    private let timeout: TimeInterval
    private let maxRetries: Int
    private let sleep: (Double) -> Void
    private let log: Logger?

    public init(
        appId: String?,
        secret: String?,
        baseURL: String = pcoBaseURL,
        allowWrites: Bool = false,
        transport: HTTPTransport = URLSessionTransport(),
        timeout: TimeInterval = 10,
        maxRetries: Int = 4,
        sleep: @escaping (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
        log: Logger? = nil
    ) throws {
        guard let appId = appId, !appId.isEmpty, let secret = secret, !secret.isEmpty else {
            throw PCOError("Planning Center credentials missing: enter them in Settings")
        }
        self.allowWrites = allowWrites
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.auth = "Basic " + Data("\(appId):\(secret)".utf8).base64EncodedString()
        self.transport = transport
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.sleep = sleep
        self.log = log
    }

    // MARK: HTTP plumbing

    func request(_ method: String, _ path: String, params: [(String, String)] = []) throws -> JSONObject {
        let isWrite = method != "GET"
        if isWrite && !allowWrites {
            throw PCOError("refusing \(method) \(path): client is not armed", writeBlocked: true)
        }
        let url = try makeURL(path, params)
        let req = HTTPRequest(method: method, url: url, headers: [
            "Authorization": auth,
            "User-Agent": "propresenter-pco-live (PCOSync)",
            "Accept": "application/json",
        ])
        let shown = url.path
        var attempt = 0
        while true {
            attempt += 1
            let resp: HTTPResponse
            do {
                resp = try transport.send(req, timeout: timeout)
            } catch let e as TransportError {
                // A write whose outcome is unknown is never retried blindly;
                // the engine re-reads LIVE to find out where it landed.
                if isWrite || attempt > maxRetries { throw PCOError("\(method) \(shown): \(e.kind)") }
                backoff(attempt, e.kind)
                continue
            }
            if resp.status == 429 {
                if attempt > maxRetries { throw PCOError("\(method) \(shown): rate limited (429) after \(attempt) tries") }
                let wait = Self.retryAfter(resp)
                log?.warning("PCO rate limit hit; waiting \(String(format: "%.1f", wait))s")
                sleep(wait)
                continue
            }
            if resp.status >= 500 {
                if isWrite || attempt > maxRetries { throw PCOError("\(method) \(shown): server error \(resp.status)") }
                backoff(attempt, "HTTP \(resp.status)")
                continue
            }
            if resp.status == 401 {
                throw PCOError("Planning Center rejected the credentials (401). Check the Application ID and Secret.")
            }
            if resp.status == 403 {
                throw PCOError("\(method) \(shown): forbidden (403). Does this PCO user have LIVE control permission?")
            }
            if resp.status >= 400 {
                throw PCOError("\(method) \(shown): HTTP \(resp.status) \(Self.errorDetail(resp))")
            }
            if resp.body.isEmpty { return [:] }
            guard let doc = resp.jsonObject() else { throw PCOError("\(method) \(shown): response was not JSON") }
            return doc
        }
    }

    private func makeURL(_ path: String, _ params: [(String, String)]) throws -> URL {
        let raw = path.hasPrefix("http://") || path.hasPrefix("https://") ? path : baseURL + path
        guard var comps = URLComponents(string: raw) else { throw PCOError("bad URL for \(path)") }
        if !params.isEmpty {
            comps.queryItems = (comps.queryItems ?? []) + params.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = comps.url else { throw PCOError("bad URL for \(path)") }
        return url
    }

    private func backoff(_ attempt: Int, _ why: String) {
        let wait = Double(min(1 << (attempt - 1), 8))
        log?.warning("PCO request failed (\(why)); retrying in \(Int(wait))s")
        sleep(wait)
    }

    func get(_ path: String, _ params: [(String, String)] = []) throws -> JSONObject {
        try request("GET", path, params: params)
    }

    func paginate(_ path: String, _ params: [(String, String)] = []) throws -> [JSONObject] {
        var doc = try get(path, [("per_page", "100")] + params)
        var out: [JSONObject] = []
        while true {
            out += doc.arr("data")
            guard let next = doc.obj("links")?.str("next"), !next.isEmpty else { return out }
            doc = try get(next)
        }
    }

    // MARK: Read-only helpers

    public func meId() -> String? {
        for path in ["/services/v2/me", "/people/v2/me"] {
            do {
                if let id = try get(path).obj("data")?.str("id") { return id }
            } catch {
                log?.debug("could not read \(path): \(error)")
            }
        }
        return nil
    }

    public func serviceTypes() throws -> [(id: String, name: String)] {
        try paginate("/services/v2/service_types").map { d in
            (d.str("id") ?? "", d.obj("attributes")?.str("name") ?? "")
        }
    }

    public func futurePlans(_ serviceTypeId: String) throws -> [PlanSummary] {
        try paginate("/services/v2/service_types/\(serviceTypeId)/plans", [("filter", "future"), ("order", "sort_date")]).map { d in
            let a = d.obj("attributes") ?? [:]
            return PlanSummary(id: d.str("id") ?? "", title: a.str("title") ?? "", dates: a.str("dates") ?? "")
        }
    }

    public func resolvePlanId(_ serviceTypeId: String, _ plan: String) throws -> String {
        if plan != "next" { return plan }
        guard let first = try futurePlans(serviceTypeId).first else {
            throw PCOError("no future plans in service type \(serviceTypeId)")
        }
        return first.id
    }

    /// The plan to follow for these settings. "auto" looks across service
    /// types (all of them unless `serviceTypeIds` names some) for the plan
    /// that has songs and whose services are on now or come up soonest. A
    /// plan counts as on until `windowMinutes` after its last service starts.
    public func resolvePlan(_ s: PCOSettings, now: Date = Date(), windowMinutes: Double = 180) throws -> PlanRef {
        if s.plan != "auto" {
            if s.serviceTypeId.isEmpty { throw PCOError("choose a service type in Settings first") }
            return PlanRef(serviceTypeId: s.serviceTypeId, planId: try resolvePlanId(s.serviceTypeId, s.plan))
        }
        let names = Dictionary(try serviceTypes().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let types = s.serviceTypeIds.isEmpty ? names.keys.sorted() : s.serviceTypeIds
        var candidates: [(start: Date, ref: PlanRef)] = []
        for st in types {
            // Only the next few plans per service type can be "now". The most
            // recent past ones too, in case "future" drops a multi-day plan
            // (Easter) once its first day has passed.
            let path = "/services/v2/service_types/\(st)/plans"
            let future = try get(path, [("filter", "future"), ("order", "sort_date"), ("per_page", "3")]).arr("data")
            let past = try get(path, [("filter", "past"), ("order", "-sort_date"), ("per_page", "2")]).arr("data")
            var seen = Set<String>()
            for d in future + past {
                guard let id = d.str("id"), seen.insert(id).inserted else { continue }
                let starts = try planTimes(st, id).filter { $0.timeType == "service" }.compactMap(\.start).sorted()
                guard let first = starts.first, let last = starts.last,
                      last.addingTimeInterval(windowMinutes * 60) >= now else { continue }
                let a = d.obj("attributes") ?? [:]
                let title = a.str("title") ?? ""
                let label = "\(names[st] ?? st): \(a.str("dates") ?? id)\(title.isEmpty ? "" : " – " + title)"
                candidates.append((first, PlanRef(serviceTypeId: st, planId: id, label: label)))
            }
        }
        for c in candidates.sorted(by: { $0.start < $1.start }) {
            // Plans with songs are services; workshops and meetings aren't.
            if try planItems(c.ref.serviceTypeId, c.ref.planId).contains(where: { $0.itemType == "song" }) {
                return c.ref
            }
        }
        throw PCOError("no upcoming plan with songs in \(s.serviceTypeIds.isEmpty ? "any service type" : "the chosen service types")")
    }

    private func planPath(_ st: String, _ plan: String) -> String {
        "/services/v2/service_types/\(st)/plans/\(plan)"
    }

    public func planItems(_ st: String, _ plan: String) throws -> [PlanItem] {
        let items = try paginate(planPath(st, plan) + "/items").map { d -> PlanItem in
            let a = d.obj("attributes") ?? [:]
            return PlanItem(
                id: d.str("id") ?? "",
                title: a.str("title") ?? "",
                itemType: a.str("item_type").flatMap { $0.isEmpty ? nil : $0 } ?? "item",
                sequence: a.int("sequence") ?? 0,
                description: a.str("description") ?? ""
            )
        }
        return items.enumerated().sorted { ($0.element.sequence, $0.offset) < ($1.element.sequence, $1.offset) }.map(\.element)
    }

    public func planTimes(_ st: String, _ plan: String) throws -> [PlanTime] {
        try paginate(planPath(st, plan) + "/plan_times").map { d in
            let a = d.obj("attributes") ?? [:]
            return PlanTime(id: d.str("id") ?? "", timeType: a.str("time_type") ?? "", startsAt: a.str("starts_at"), name: a.str("name"))
        }
    }

    public func liveState(_ st: String, _ plan: String) throws -> LiveState {
        parseLive(try get(planPath(st, plan) + "/live", [("include", "current_item_time,controller")]))
    }

    // MARK: LIVE writes (only when armed)

    public func goToNextItem(_ st: String, _ plan: String) throws {
        _ = try request("POST", planPath(st, plan) + "/live/go_to_next_item")
    }

    public func goToPreviousItem(_ st: String, _ plan: String) throws {
        _ = try request("POST", planPath(st, plan) + "/live/go_to_previous_item")
    }

    public func toggleControl(_ st: String, _ plan: String) throws {
        _ = try request("POST", planPath(st, plan) + "/live/toggle_control")
    }

    static func retryAfter(_ resp: HTTPResponse) -> Double {
        guard let v = resp.header("Retry-After"), let n = Double(v) else { return 5.0 }
        return max(0.5, min(n, maxRetryAfter))
    }

    static func errorDetail(_ resp: HTTPResponse) -> String {
        let errors = resp.jsonObject()?.arr("errors") ?? []
        return String(errors.map { $0.str("detail") ?? $0.str("title") ?? "" }.joined(separator: "; ").prefix(300))
    }
}

public func parseLive(_ doc: JSONObject) -> LiveState {
    let data = doc.obj("data") ?? [:]
    let rels = data.obj("relationships") ?? [:]
    let included = doc.arr("included")

    let ctrl = relData(rels, "controller")
    let controllerId = ctrl?.str("id")
    let linkController = data.obj("links")?.str("controller").map { !$0.isEmpty } ?? false
    let hasController = controllerId != nil || linkController

    let itemTimes = included.filter { $0.str("type") == "ItemTime" }
    var itemTime: JSONObject?
    if let cur = relData(rels, "current_item_time") {
        itemTime = itemTimes.first { $0.str("id") == cur.str("id") }
    } else if itemTimes.count == 1 && rels["current_item_time"] == nil {
        itemTime = itemTimes[0]
    }

    var itemId: String?
    var planTimeId: String?
    if let it = itemTime {
        let r = it.obj("relationships") ?? [:]
        itemId = relData(r, "item")?.str("id")
        planTimeId = relData(r, "plan_time")?.str("id")
    }
    return LiveState(currentItemId: itemId, currentPlanTimeId: planTimeId, controllerId: controllerId, hasController: hasController)
}

private func relData(_ rels: JSONObject, _ name: String) -> JSONObject? {
    rels.obj(name)?.obj("data")
}
