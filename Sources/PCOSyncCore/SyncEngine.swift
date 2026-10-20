// Closed-loop sync: keep LIVE on the PCO item that matches ProPresenter.
//
// Each tick:
//   1. Read ProPresenter's active playlist item. Unreachable -> do nothing.
//   2. Debounce: the item must stay put for `debounceSeconds`.
//   3. If it's the same item we already handled, do nothing (re-firing a cue
//      is harmless). Optional periodic resync re-checks anyway.
//   4. Match it to a PCO item. Ignored/unmatched -> do nothing, log why.
//   5. Read LIVE's current item. Same as target -> do nothing.
//   6. Guards: another controller holds LIVE; move larger than `maxJump`.
//   7. Dry-run: log what would happen. Armed: take control if needed, then
//      step next/previous ONE at a time, re-reading LIVE after every step,
//      until LIVE is on the target. Abort on no progress or overshoot.
//
// Positions: LIVE walks through each *service* plan time in order (9:00 items,
// then 11:00 items). A position is a slot (plan_time, item) in that global
// order. Each service time also has a "service start" slot ahead of its first
// item: PCO reports it as an ItemTime whose item is null (seen in the real API
// as LIVE's next_item_time before a service begins). The target is the matched
// item within the "selected" service time, which follows LIVE's current
// service time unless the operator overrides it with next-service /
// prev-service.
//
// Service times switch on their own: from `serviceLeadMinutes` before a
// service starts, ProPresenter going *back* (the playlist starting over for
// the next service) moves into that service instead of rewinding the last one.
// When armed, LIVE only moves from `serviceLeadMinutes` before a service until
// `serviceWindowMinutes` after it starts, so rehearsals and run-throughs never
// record times.
//
// Max jump counts only plan items ProPresenter could have fired. Skipping
// items with no slide in the playlist (a host prayer, a setup moment) is
// expected and never needs confirming.

import Foundation

public struct SyncSettings: Codable, Equatable {
    public var debounceSeconds = 1.0
    public var maxJump = 3
    public var takeOver = false
    public var resyncSeconds = 0.0
    public var planRefreshSeconds = 300.0
    public var playlistNameContains = ""
    public var releaseOnExit = true
    /// Move into the next service time on its own (see the header comment).
    public var autoServiceTime = true
    /// How long before a service starts it counts as started (preroll).
    public var serviceLeadMinutes = 20.0
    /// Armed: only move LIVE around service times, never in rehearsals.
    public var onlyDuringServices = true
    /// How long after a service starts it may still be running.
    public var serviceWindowMinutes = 180.0

    public init(debounceSeconds: Double = 1.0, maxJump: Int = 3, takeOver: Bool = false, resyncSeconds: Double = 0,
                planRefreshSeconds: Double = 300, playlistNameContains: String = "", releaseOnExit: Bool = true,
                autoServiceTime: Bool = true, serviceLeadMinutes: Double = 20, onlyDuringServices: Bool = true,
                serviceWindowMinutes: Double = 180) {
        self.debounceSeconds = debounceSeconds
        self.maxJump = maxJump
        self.takeOver = takeOver
        self.resyncSeconds = resyncSeconds
        self.planRefreshSeconds = planRefreshSeconds
        self.playlistNameContains = playlistNameContains
        self.releaseOnExit = releaseOnExit
        self.autoServiceTime = autoServiceTime
        self.serviceLeadMinutes = serviceLeadMinutes
        self.onlyDuringServices = onlyDuringServices
        self.serviceWindowMinutes = serviceWindowMinutes
    }
}

public struct Decision {
    /// paused|debounce|unchanged|skip|in_sync|dry_run|moved|refused|error
    public var action: String
    public var reason = ""
    public var ppName: String?
    public var target: PlanItem?
    public var liveItem: PlanItem?
    public var steps = 0
    public var liveNote = ""
    /// From the matcher: something about this match to double-check.
    public var warning = ""

    public init(_ action: String, _ reason: String = "", ppName: String? = nil, target: PlanItem? = nil,
                liveItem: PlanItem? = nil, steps: Int = 0, liveNote: String = "") {
        self.action = action
        self.reason = reason
        self.ppName = ppName
        self.target = target
        self.liveItem = liveItem
        self.steps = steps
        self.liveNote = liveNote
    }

    public func describe() -> String {
        var head = ""
        if let pp = ppName { head = "ProPresenter '\(pp)'" }
        if let t = target { head += " -> PCO '\(t.title)'" }
        if ["in_sync", "dry_run", "moved", "refused"].contains(action) || liveItem != nil {
            head += "; LIVE on \(liveNote.isEmpty ? titleOf(liveItem) : liveNote)"
        }
        head = head.trimmingCharacters(in: CharacterSet(charactersIn: "; "))
        let check = warning.isEmpty ? "" : " (check: \(warning))"
        return head.isEmpty ? "[\(action)] \(reason)" : "[\(action)] \(head): \(reason)\(check)"
    }
}

func titleOf(_ item: PlanItem?) -> String {
    item.map { "'\($0.title)'" } ?? "(not started)"
}

struct Slot {
    let planTimeId: String?
    let item: PlanItem?  // nil = the service-start slot
}

struct SlotKey: Hashable {
    let pt: String?
    let item: String?
}

struct ActiveKey: Equatable {
    let playlist: String?
    let uuid: String?
    let index: Int?
    let name: String?

    init(_ a: PPActive) {
        playlist = a.playlist?.uuid
        uuid = a.item?.uuid
        index = a.item?.index
        name = a.item?.name
    }
}

public final class SyncEngine {
    public let pco: PCOClient
    public let pp: ProPresenterClient
    public let serviceTypeId: String
    public let planId: String
    public var settings: SyncSettings
    public let matchSettings: MatchSettings
    public let armed: Bool
    let clock: () -> Double
    /// Wall-clock time, for service times.
    let now: () -> Date
    let log: Logger?

    public private(set) var me: String?
    public private(set) var items: [PlanItem] = []
    public private(set) var planTimes: [PlanTime] = []
    public private(set) var matcher: Matcher
    /// Most recent LIVE read, for the dashboard.
    public private(set) var lastLive: LiveState?
    /// Most recent ProPresenter active item, for the dashboard.
    public private(set) var lastActive: PPActive?

    var slots: [Slot] = []
    var slotIndex: [SlotKey: Int] = [:]
    var ptRank: [String?: Int] = [:]
    var itemsById: [String: PlanItem] = [:]
    var lastPtRank = 0

    // state
    var candidateKey: ActiveKey?
    var candidateSince = 0.0
    var handledKey: ActiveKey?
    var lastCheck = 0.0
    var loadedAt = 0.0
    public private(set) var selectedPt: Int?  // explicit service-time rank, nil = follow LIVE
    public private(set) var confirmOnce = false
    public private(set) var paused = false
    public private(set) var tookControl = false
    // Dry-run only: (real LIVE slot when simulated, simulated slot). Lets a
    // dry-run behave as if earlier moves had happened.
    var simulated: (Int, Int)?
    var playlistCache: [String: [PPPlaylistItem]] = [:]

    public init(pco: PCOClient, pp: ProPresenterClient, serviceTypeId: String, planId: String,
                settings: SyncSettings = SyncSettings(), matchSettings: MatchSettings = MatchSettings(),
                armed: Bool = false, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                now: @escaping () -> Date = Date.init, log: Logger? = nil) {
        self.pco = pco
        self.pp = pp
        self.serviceTypeId = serviceTypeId
        self.planId = planId
        self.settings = settings
        self.matchSettings = matchSettings
        self.armed = armed
        self.clock = clock
        self.now = now
        self.log = log
        self.matcher = Matcher([], matchSettings)
    }

    var st: String { serviceTypeId }
    var plan: String { planId }

    // MARK: plan loading

    public func loadPlan() throws {
        let newItems = try pco.planItems(st, plan)
        let times = try pco.planTimes(st, plan).filter { $0.timeType == "service" }
        let changed = newItems != items || loadedAt == 0
        items = newItems
        planTimes = times.enumerated().sorted { ($0.element.startsAt ?? "", $0.offset) < ($1.element.startsAt ?? "", $1.offset) }.map(\.element)
        matcher = Matcher(items, matchSettings)
        for bad in matcher.badPatterns { log?.warning("Ignoring invalid ignore pattern \(bad)") }
        itemsById = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ptIds: [String?] = planTimes.isEmpty ? [nil] : planTimes.map { $0.id }
        ptRank = [:]
        for (n, pid) in ptIds.enumerated() { ptRank[pid] = n }
        slots = []
        for pid in ptIds {
            slots.append(Slot(planTimeId: pid, item: nil))
            slots += items.map { Slot(planTimeId: pid, item: $0) }
        }
        slotIndex = [:]
        for (n, s) in slots.enumerated() { slotIndex[SlotKey(pt: s.planTimeId, item: s.item?.id)] = n }
        if me == nil { me = pco.meId() }
        loadedAt = clock()
        playlistCache.removeAll()
        let msg = "Loaded plan \(plan): \(items.count) items (\(items.filter(\.isHeader).count) headers), \(planTimes.count) service time(s)"
        if changed { log?.info(msg) } else { log?.debug(msg) }
    }

    // MARK: operator commands

    public static let commandHelp = "Commands: status, pause, resume, confirm, next-service, prev-service, auto-service, reload, quit"

    public func command(_ line: String) -> String {
        let cmd = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nPts = max(planTimes.count, 1)
        switch cmd {
        case "pause":
            paused = true
            return "Paused: LIVE will not be moved until 'resume'."
        case "resume":
            paused = false
            forceRecheck()
            return "Resumed."
        case "confirm":
            confirmOnce = true
            forceRecheck()
            return "Next move may exceed max_jump=\(settings.maxJump) once."
        case "next-service", "prev-service":
            let base = selectedPt ?? lastPtRank
            let delta = cmd == "next-service" ? 1 : -1
            selectedPt = min(max(base + delta, 0), nPts - 1)
            forceRecheck()
            return "Targeting service time \(selectedPt! + 1) of \(nPts)\(ptLabel(selectedPt!))."
        case "auto-service":
            selectedPt = nil
            forceRecheck()
            return "Service time follows LIVE again."
        case "reload":
            do {
                try loadPlan()
            } catch {
                return "Reload failed: \(error)"
            }
            forceRecheck()
            return "Plan reloaded."
        case "status":
            return status()
        default:
            return Self.commandHelp
        }
    }

    public func setServiceTime(_ oneBased: Int) {
        selectedPt = max(0, min(oneBased - 1, max(planTimes.count, 1) - 1))
    }

    public func status() -> String {
        let svc = selectedPt.map { "\($0 + 1)\(ptLabel($0))" } ?? "follow LIVE"
        return "mode=\(armed ? "ARMED" : "dry-run") paused=\(paused ? "True" : "False") service_time=\(svc) max_jump=\(settings.maxJump) take_over=\(settings.takeOver ? "True" : "False")"
    }

    func ptLabel(_ rank: Int) -> String {
        if rank < planTimes.count, let s = planTimes[rank].startsAt, !s.isEmpty { return " (\(s))" }
        return ""
    }

    func forceRecheck() { handledKey = nil }

    /// Rank of the service time LIVE was last seen in (or the operator chose).
    public var effectiveServiceTime: Int { selectedPt ?? lastPtRank }

    // MARK: main tick

    public func tick() -> Decision {
        let now = clock()
        if paused { return Decision("paused", "paused by operator") }

        if settings.planRefreshSeconds > 0 && now - loadedAt >= settings.planRefreshSeconds {
            do {
                try loadPlan()
            } catch {
                log?.warning("Plan refresh failed, keeping previous copy: \(error)")
                loadedAt = now
            }
        }

        let active: PPActive
        do {
            active = try pp.active()
        } catch {
            return Decision("error", "\(error)")
        }
        lastActive = active

        let key = ActiveKey(active)
        if key != candidateKey {
            candidateKey = key
            candidateSince = now
        }
        if now - candidateSince < settings.debounceSeconds {
            return Decision("debounce", "waiting for ProPresenter to settle")
        }

        let resyncDue = settings.resyncSeconds > 0 && now - lastCheck >= settings.resyncSeconds
        if key == handledKey && !resyncDue {
            return Decision("unchanged", "same ProPresenter item as last time")
        }

        let decision = evaluate(active)
        if decision.action != "error" {
            handledKey = key
            lastCheck = now
        }
        return decision
    }

    func evaluate(_ active: PPActive) -> Decision {
        guard let item = active.item else { return Decision("skip", "no active ProPresenter playlist item") }
        let name = item.name
        let filt = settings.playlistNameContains
        let plName = active.playlist?.name ?? ""
        if !filt.isEmpty && !plName.lowercased().contains(filt.lowercased()) {
            return Decision("skip", "active playlist '\(plName)' doesn't contain '\(filt)'", ppName: name)
        }

        let playlist = self.playlist(active)
        let result = matcher.match(item, playlist)
        guard let matched = result.item else {
            return Decision("skip", "unmatched (\(result.reason))", ppName: name)
        }

        let live: LiveState
        do {
            live = try pco.liveState(st, plan)
        } catch {
            return Decision("error", "PCO unreachable: \(error)", ppName: name, target: matched)
        }
        lastLive = live

        var liveItem = itemsById[live.currentItemId ?? ""]
        let cur = position(live)
        var note = liveNote(live, cur)
        if live.currentItemId != nil && cur == nil {
            return Decision("skip", "LIVE is on an item not in the loaded plan; try 'reload'", ppName: name, target: matched, liveItem: liveItem, liveNote: note)
        }
        var curI = cur ?? -1
        if !armed, let sim = simulated, sim.0 == curI {
            curI = sim.1
            if curI >= 0 {
                let s = slots[curI]
                note = s.item.map { "simulated '\($0.title)'" } ?? "simulated service start"
                liveItem = nil
            }
        }
        guard let choice = chooseTarget(live, curI, [matched] + result.alternatives) else {
            return Decision("skip", "target item not in loaded plan; try 'reload'", ppName: name, target: matched, liveItem: liveItem, liveNote: note)
        }
        let (target, tgt) = choice
        var base = Decision("", ppName: name, target: target, liveItem: liveItem, liveNote: note)
        base.warning = result.warning
        if curI == tgt {
            base.action = "in_sync"
            base.reason = "already there (\(result.method))"
            return base
        }

        let steps = estimateSteps(curI, tgt)
        let jump = jumpSize(curI, tgt, playlist)
        let direction = tgt > curI ? "forward" : "back"
        base.steps = steps

        if jump > settings.maxJump && !confirmOnce {
            base.action = "refused"
            base.reason = "would move \(direction) past \(jump - 1) matched item(s) (> max_jump \(settings.maxJump)); "
                + "type 'confirm' to allow once, or 'next-service' if a new service time started"
            return base
        }

        let outside = outsideServiceTimes()
        if armed && outside {
            base.action = "skip"
            base.reason = "not near a service time (rehearsal or run-through?); LIVE not moved"
            return base
        }

        let ctrl = controlSituation(live)
        if ctrl == "other" && !settings.takeOver {
            base.action = "refused"
            base.reason = "another person controls LIVE; not taking over (enable take-over to allow)"
            return base
        }

        if !armed {
            simulated = (cur ?? -1, tgt)
            let ctrlNote = ["none": "; would take control", "other": "; would TAKE OVER control"][ctrl] ?? ""
            let timeNote = outside ? "; armed would not move now: not near a service time" : ""
            base.action = "dry_run"
            base.reason = "would move \(direction) \(steps) item(s) [\(result.method)]\(ctrlNote)\(timeNote)"
            return base
        }

        confirmOnce = false
        return move(live, curI, tgt, ctrl, base)
    }

    /// Which of the candidate plan items (the match, plus identical items it
    /// could equally be) to target, and in which service time.
    func chooseTarget(_ live: LiveState, _ cur: Int, _ candidates: [PlanItem]) -> (PlanItem, Int)? {
        func pick(_ rank: Int) -> (PlanItem, Int)? {
            let options = candidates.compactMap { c in slotIndex[SlotKey(pt: ptId(rank), item: c.id)].map { (c, $0) } }
            guard let first = options.first else { return nil }
            // The next one at or ahead of LIVE, else the match itself.
            return options.filter { $0.1 >= cur }.min { $0.1 < $1.1 } ?? first
        }
        let rank = effectivePt(live)
        guard let choice = pick(rank) else { return nil }
        // ProPresenter went back to the start while the next service is about
        // to begin: that's the next service starting, not a rewind.
        if selectedPt == nil, settings.autoServiceTime, let c = clockRank(), c > rank,
           livePt(live) == nil || choice.1 < cur || slots[max(cur, 0)].item == nil {
            if let next = pick(c) {
                if lastPtRank != c { log?.info("Service time \(c + 1) of \(planTimes.count)\(ptLabel(c)) has started") }
                lastPtRank = c
                return next
            }
        }
        return choice
    }

    /// The service time the clock says is on (from `serviceLeadMinutes` before
    /// it starts), or nil before the first one / without times.
    func clockRank() -> Int? {
        let t = now()
        var rank: Int?
        for (n, pt) in planTimes.enumerated() {
            if let s = pt.start, s.addingTimeInterval(-settings.serviceLeadMinutes * 60) <= t { rank = n }
        }
        return rank
    }

    /// True when the plan has service times and none is on now.
    func outsideServiceTimes() -> Bool {
        guard settings.onlyDuringServices else { return false }
        let starts = planTimes.compactMap(\.start)
        if starts.isEmpty { return false }
        let t = now()
        return !starts.contains {
            $0.addingTimeInterval(-settings.serviceLeadMinutes * 60) <= t && t <= $0.addingTimeInterval(settings.serviceWindowMinutes * 60)
        }
    }

    /// How big a move is, counting only plan items ProPresenter could fire:
    /// matched items passed over, plus the target.
    func jumpSize(_ cur: Int, _ tgt: Int, _ playlist: [PPPlaylistItem]?) -> Int {
        guard let pl = playlist, !pl.isEmpty else { return estimateSteps(cur, tgt) }
        let reachable = matcher.reachableItemIds(pl)
        let lo = min(cur, tgt), hi = max(cur, tgt)
        if hi - lo <= 1 { return 1 }
        let passed = slots[(lo + 1)..<hi].filter { s in s.item.map { !$0.isHeader && reachable.contains($0.id) } ?? false }.count
        return passed + 1
    }

    // MARK: writes

    func move(_ startLive: LiveState, _ start: Int, _ tgt: Int, _ ctrl: String, _ baseIn: Decision) -> Decision {
        var base = baseIn
        func done(_ action: String, _ reason: String) -> Decision {
            base.action = action
            base.reason = reason
            return base
        }
        var live = startLive
        var cur = start
        do {
            if ctrl != "me" {
                log?.info("Taking LIVE control (\(ctrl == "other" ? "taking over" : "no current controller"))")
                try pco.toggleControl(st, plan)
                live = try pco.liveState(st, plan)
                lastLive = live
                tookControl = true
                if controlSituation(live) != "me" {
                    return done("error", "tried to take LIVE control but don't hold it")
                }
            }
            let limit = base.steps + 3
            for n in 0..<limit {
                if tgt > cur {
                    try pco.goToNextItem(st, plan)
                } else {
                    try pco.goToPreviousItem(st, plan)
                }
                live = try pco.liveState(st, plan)
                lastLive = live
                let new = position(live)
                let newI = new ?? -1
                base.liveItem = itemsById[live.currentItemId ?? ""]
                base.liveNote = liveNote(live, new)
                if newI == tgt { return done("moved", "moved in \(n + 1) step(s)") }
                if newI == cur { return done("error", "LIVE did not move after step \(n + 1); stopping") }
                if (tgt - cur) * (tgt - newI) < 0 { return done("error", "LIVE overshot the target after step \(n + 1); stopping") }
                cur = newI
            }
            return done("error", "LIVE not on target after \(limit) steps; stopping")
        } catch {
            return done("error", "PCO write failed: \(error)")
        }
    }

    /// Give LIVE control back, only if we hold it. toggle_control is a toggle,
    /// so calling it when we don't hold control would *take* it.
    public func release() {
        guard armed && settings.releaseOnExit && tookControl else { return }
        do {
            let live = try pco.liveState(st, plan)
            if controlSituation(live) == "me" {
                try pco.toggleControl(st, plan)
                tookControl = false
                log?.info("Released LIVE control")
            } else {
                log?.info("Not releasing LIVE control: we no longer hold it")
            }
        } catch {
            log?.warning("Could not release LIVE control: \(error)")
        }
    }

    // MARK: helpers

    /// "none", "me" or "other".
    public func controlSituation(_ live: LiveState) -> String {
        if !live.hasController { return "none" }
        if let c = live.controllerId, let me = me { return c == me ? "me" : "other" }
        // Controller identity unknown: trust our own record of taking it.
        return tookControl ? "me" : "other"
    }

    func playlist(_ active: PPActive) -> [PPPlaylistItem]? {
        guard let pl = active.playlist else { return nil }
        let key = !pl.uuid.isEmpty ? pl.uuid : "#\(pl.index.map(String.init) ?? "")"
        let cached = playlistCache[key]
        if let c = cached, contains(c, active) { return c }
        do {
            let items = try pp.playlistItems(pl)
            playlistCache[key] = items
            return items
        } catch {
            log?.warning("Could not read ProPresenter playlist: \(error)")
            return cached
        }
    }

    func livePt(_ live: LiveState) -> Int? {
        ptRank[live.currentPlanTimeId]
    }

    func effectivePt(_ live: LiveState) -> Int {
        if let s = selectedPt { return s }
        if let l = livePt(live) {
            lastPtRank = l
            return l
        }
        return lastPtRank
    }

    func liveNote(_ live: LiveState, _ pos: Int?) -> String {
        if let p = pos, slots[p].item == nil {
            return "service start \((ptRank[live.currentPlanTimeId] ?? 0) + 1)"
        }
        if let p = pos, planTimes.count > 1, let cid = live.currentItemId {
            guard let item = itemsById[cid] else { return "" }
            return "'\(item.title)' (service \((ptRank[slots[p].planTimeId] ?? 0) + 1))"
        }
        return ""
    }

    func ptId(_ rank: Int) -> String? {
        planTimes.isEmpty ? nil : planTimes[rank].id
    }

    func position(_ live: LiveState) -> Int? {
        guard let itemId = live.currentItemId else {
            // Service-start slot if LIVE names a plan time; otherwise LIVE is
            // not started (or has finished).
            if let pt = live.currentPlanTimeId, ptRank[pt] != nil {
                return slotIndex[SlotKey(pt: pt, item: nil)]
            }
            return nil
        }
        let rank = livePt(live) ?? effectivePt(live)
        return slotIndex[SlotKey(pt: ptId(rank), item: itemId)]
    }

    func estimateSteps(_ cur: Int, _ tgt: Int) -> Int {
        let lo = min(cur, tgt), hi = max(cur, tgt)
        let n = slots[(lo + 1)...hi].filter { $0.item == nil || !$0.item!.isHeader }.count
        return n == 0 ? 1 : n
    }

    /// Slot position LIVE is in, for the dashboard (nil = not started).
    public func livePosition() -> (planTimeRank: Int, itemId: String?)? {
        guard let live = lastLive, let p = position(live) else { return nil }
        return (ptRank[slots[p].planTimeId] ?? 0, slots[p].item?.id)
    }
}

func contains(_ playlist: [PPPlaylistItem], _ active: PPActive) -> Bool {
    guard let it = active.item else { return true }
    return playlist.contains { (!it.uuid.isEmpty && $0.uuid == it.uuid) || ($0.index == it.index && $0.name == it.name) }
}
