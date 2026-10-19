// Runs the sync engine on a background thread for the lifetime of the app.
// The web UI and the menu bar talk to this, never to the engine directly:
// the engine isn't thread-safe, so commands are queued to the worker thread
// and the worker publishes a status snapshot after every tick.

import Foundation

public final class SyncService {
    public enum State: String {
        case stopped, starting, running, waiting, needsSetup = "needs_setup", stopping
    }

    public let store: ConfigStore
    public let log: Logger
    let transportFactory: () -> HTTPTransport
    let clock: () -> Double
    let pcoSleep: (Double) -> Void

    private let cond = NSCondition()
    // Everything below is guarded by `cond`.
    private var generation = 0
    private var stopRequested = false
    private var workerDone: DispatchSemaphore?
    private var pending: [(String, (String) -> Void)] = []
    private var _state: State = .stopped
    private var _detail = ""
    private var _armed = false
    private var _snapshot: JSONObject = [:]
    private var _events: [JSONObject] = []
    private var eventSeq = 0

    public init(store: ConfigStore, log: Logger,
                transportFactory: @escaping () -> HTTPTransport = { URLSessionTransport() },
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                pcoSleep: @escaping (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.store = store
        self.log = log
        self.transportFactory = transportFactory
        self.clock = clock
        self.pcoSleep = pcoSleep
    }

    // MARK: public control

    public var state: State { cond.lock(); defer { cond.unlock() }; return _state }
    public var isArmed: Bool { cond.lock(); defer { cond.unlock() }; return _armed }
    public var isRunning: Bool { state != .stopped }

    /// Start syncing. Restarts if already running in the other mode.
    public func start(armed: Bool) {
        cond.lock()
        let running = _state != .stopped
        let same = _armed == armed
        cond.unlock()
        if running && same { return }
        if running { stop() }

        cond.lock()
        generation += 1
        let gen = generation
        stopRequested = false
        _armed = armed
        _state = .starting
        _detail = ""
        let done = DispatchSemaphore(value: 0)
        workerDone = done
        cond.unlock()

        let t = Thread { [weak self] in
            self?.run(gen: gen, armed: armed)
            done.signal()
        }
        t.name = "pcosync-engine"
        t.start()
    }

    /// Stop syncing and give LIVE control back if we hold it. Blocks until done.
    public func stop() {
        cond.lock()
        guard _state != .stopped, let done = workerDone else { cond.unlock(); return }
        stopRequested = true
        _state = .stopping
        cond.broadcast()
        cond.unlock()
        if done.wait(timeout: .now() + 30) == .timedOut {
            log.warning("Sync worker did not stop within 30s")
        }
    }

    /// Restart in the same mode, e.g. after settings change.
    public func restartIfRunning() {
        guard isRunning else { return }
        let armed = isArmed
        stop()
        start(armed: armed)
    }

    /// Run an operator command (pause, resume, confirm, next-service, ...).
    public func command(_ line: String) -> String {
        let cmd = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isRunning else { return "Not running. Start syncing first." }
        let done = DispatchSemaphore(value: 0)
        var reply = "Timed out waiting for the sync engine."
        cond.lock()
        pending.append((cmd, { r in reply = r; done.signal() }))
        cond.broadcast()
        cond.unlock()
        _ = done.wait(timeout: .now() + 60)
        return reply
    }

    public func snapshot() -> JSONObject {
        cond.lock()
        defer { cond.unlock() }
        var s = _snapshot
        s["state"] = _state.rawValue
        s["detail"] = _detail
        s["armed"] = _armed
        s["running"] = _state != .stopped
        s["events"] = _events
        return s
    }

    // MARK: worker

    private func setState(_ st: State, _ detail: String = "") {
        cond.lock()
        if !stopRequested || st == .stopped { _state = st }
        _detail = detail
        cond.unlock()
    }

    private func shouldStop(_ gen: Int) -> Bool {
        cond.lock(); defer { cond.unlock() }
        return stopRequested || gen != generation
    }

    /// Sleep up to `seconds`, waking early for stop or a queued command.
    private func pause(_ seconds: Double) {
        let until = Date(timeIntervalSinceNow: seconds)
        cond.lock()
        while !stopRequested && pending.isEmpty {
            if !cond.wait(until: until) { break }
        }
        cond.unlock()
    }

    private func takeCommands() -> [(String, (String) -> Void)] {
        cond.lock(); defer { cond.unlock() }
        let p = pending
        pending = []
        return p
    }

    private func addEvent(_ action: String, _ text: String) {
        cond.lock()
        eventSeq += 1
        _events.append(["seq": eventSeq, "time": isoNow(), "action": action, "text": text])
        if _events.count > 50 { _events.removeFirst(_events.count - 50) }
        cond.unlock()
    }

    private struct NeedsSetup: Error, CustomStringConvertible { let description: String }

    private func makeEngine(armed: Bool) throws -> SyncEngine {
        let cfg = store.config
        guard let creds = store.credentials else {
            throw NeedsSetup(description: "Enter your Planning Center Application ID and Secret in Settings.")
        }
        if cfg.pco.serviceTypeId.isEmpty {
            throw NeedsSetup(description: "Choose a Planning Center service type in Settings.")
        }
        log.setSecrets([creds.appId, creds.secret])
        log.level = LogLevel(name: cfg.app.logLevel)
        let pco = try PCOClient(appId: creds.appId, secret: creds.secret,
                                baseURL: store.pcoBaseURLOverride ?? pcoBaseURL, allowWrites: armed,
                                transport: transportFactory(), sleep: pcoSleep, log: log)
        let pp = ProPresenterClient(host: cfg.propresenter.host, port: cfg.propresenter.port,
                                    timeout: cfg.propresenter.timeout, transport: transportFactory())
        let planId = try pco.resolvePlanId(cfg.pco.serviceTypeId, cfg.pco.plan)
        let engine = SyncEngine(pco: pco, pp: pp, serviceTypeId: cfg.pco.serviceTypeId, planId: planId,
                                settings: cfg.sync, matchSettings: cfg.match, armed: armed, clock: clock, log: log)
        try engine.loadPlan()
        return engine
    }

    private static let quietActions: Set<String> = ["debounce", "unchanged", "paused"]

    private func run(gen: Int, armed: Bool) {
        var engine: SyncEngine?
        var setupWait = 1.0
        var errorBackoff = 0.0
        var lastShown: [String]?
        var nextResolve = clock() + 300

        while !shouldStop(gen) {
            if engine == nil {
                do {
                    let e = try makeEngine(armed: armed)
                    engine = e
                    setupWait = 1.0
                    nextResolve = clock() + max(store.config.sync.planRefreshSeconds, 60)
                    if armed {
                        log.warning("ARMED: this will take LIVE control and move LIVE for plan \(e.planId). A human controller will not be displaced unless take-over is on.")
                        log.warning("Reset rehearsal times in LIVE before the real service.")
                    } else {
                        log.info("DRY-RUN: nothing will be written to Planning Center. Arm to move LIVE.")
                    }
                    log.info(e.status())
                    addEvent("start", armed ? "Started ARMED on plan \(e.planId)" : "Started dry-run on plan \(e.planId)")
                    setState(.running)
                    publish(e, nil)
                } catch let e as NeedsSetup {
                    setState(.needsSetup, e.description)
                    answerCommandsWhileIdle(e.description)
                    pause(5)
                    continue
                } catch {
                    let msg = "\(error)"
                    if store.credentials != nil { log.warning("Can't start yet: \(msg); retrying in \(Int(setupWait))s") }
                    setState(.waiting, msg)
                    answerCommandsWhileIdle("Not connected yet: \(msg)")
                    pause(setupWait)
                    setupWait = min(setupWait * 2, 30)
                    continue
                }
            }
            guard let e = engine else { continue }

            for (cmd, reply) in takeCommands() {
                let r = e.command(cmd)
                log.info(r)
                addEvent("command", "\(cmd): \(r)")
                reply(r)
                publish(e, nil)
            }
            if shouldStop(gen) { break }

            // "next" plan: pick up next week's plan without a restart.
            let cfg = store.config
            if cfg.pco.plan == "next" && clock() >= nextResolve {
                nextResolve = clock() + max(cfg.sync.planRefreshSeconds, 60)
                if let id = try? e.pco.resolvePlanId(cfg.pco.serviceTypeId, "next"), id != e.planId {
                    log.info("Next plan is now \(id) (was \(e.planId)); switching")
                    e.release()
                    engine = nil
                    continue
                }
            }

            let d = e.tick()
            let shown = [d.action, d.reason, d.ppName ?? ""]
            if Self.quietActions.contains(d.action) {
                log.debug(d.describe())
            } else if shown != lastShown || d.action == "moved" || d.action == "dry_run" {
                log.log(d.action == "error" || d.action == "refused" ? .warning : .info, d.describe())
                addEvent(d.action, d.describe())
            }
            if !Self.quietActions.contains(d.action) { lastShown = shown }
            publish(e, d)

            if d.action == "error" {
                // ProPresenter is local and cheap to poll; come back quickly
                // when it restarts. Planning Center gets a longer backoff.
                let cap = d.reason.hasPrefix("ProPresenter") ? 5.0 : 30.0
                errorBackoff = min(max(errorBackoff * 2, 1), cap)
                pause(errorBackoff)
            } else {
                errorBackoff = 0
                pause(cfg.propresenter.pollInterval)
            }
        }

        log.info("Stopping")
        engine?.release()
        if let e = engine { publish(e, nil) }
        // Anyone still waiting on a command gets an answer.
        answerCommandsWhileIdle("Stopped.")
        addEvent("stop", "Stopped")
        cond.lock()
        if gen == generation {
            _state = .stopped
            _detail = ""
        }
        cond.unlock()
    }

    private func answerCommandsWhileIdle(_ msg: String) {
        for (_, reply) in takeCommands() { reply(msg) }
    }

    private var ppError: String?
    private var pcoError: String?
    private var lastDecision: JSONObject?

    /// Build the dashboard snapshot. Runs on the worker thread.
    private func publish(_ e: SyncEngine, _ d: Decision?) {
        if let d = d, d.action != "paused" {
            if d.action == "error" && d.reason.hasPrefix("ProPresenter") {
                ppError = d.reason
            } else {
                ppError = nil
                if d.action == "error" { pcoError = d.reason } else if d.target != nil { pcoError = nil }
            }
            if !Self.quietActions.contains(d.action) {
                lastDecision = ["action": d.action, "text": d.describe(), "time": isoNow()]
            }
        }
        var s: JSONObject = [:]
        s["planId"] = e.planId
        s["serviceTypeId"] = e.serviceTypeId
        s["paused"] = e.paused
        s["confirmPending"] = e.confirmOnce
        s["maxJump"] = e.settings.maxJump
        s["takeOver"] = e.settings.takeOver
        s["tookControl"] = e.tookControl
        s["status"] = e.status()
        s["items"] = e.items.map { ["id": $0.id, "title": $0.title, "type": $0.itemType, "sequence": $0.sequence] as JSONObject }
        s["planTimes"] = e.planTimes.map { ["id": $0.id, "startsAt": $0.startsAt ?? "", "name": $0.name ?? ""] as JSONObject }
        s["serviceTime"] = ["selected": e.selectedPt.map { $0 as Any } ?? NSNull(), "effective": e.effectiveServiceTime] as JSONObject
        var pp: JSONObject = ["ok": ppError == nil, "error": ppError ?? ""]
        if let a = e.lastActive {
            pp["playlist"] = a.playlist?.name ?? ""
            pp["item"] = a.item?.name ?? ""
        }
        s["propresenter"] = pp
        var live: JSONObject = ["ok": pcoError == nil, "error": pcoError ?? ""]
        if let l = e.lastLive {
            live["itemId"] = l.currentItemId ?? ""
            live["controller"] = e.controlSituation(l)
            if let pos = e.livePosition() {
                live["planTimeRank"] = pos.planTimeRank
                live["serviceStart"] = pos.itemId == nil
            }
        }
        s["live"] = live
        s["lastDecision"] = lastDecision ?? NSNull()
        cond.lock()
        _snapshot = s
        cond.unlock()
    }
}

func isoNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: Date())
}
