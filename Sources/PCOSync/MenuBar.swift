// macOS menu-bar UI. Everything here is a thin layer over SyncService; the
// dashboard has the full controls and settings.

#if canImport(AppKit)
import AppKit
import PCOSyncCore
import ServiceManagement

@MainActor
func runMenuBarApp(service: SyncService, dashboardURL: URL, webError: String?, onQuit: @escaping () -> Void) {
    let app = NSApplication.shared
    let controller = MenuBarController(service: service, dashboardURL: dashboardURL, webError: webError, onQuit: onQuit)
    app.delegate = controller
    app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
    withExtendedLifetime(controller) { app.run() }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let service: SyncService
    let dashboardURL: URL
    let webError: String?
    let onQuit: () -> Void
    var statusItem: NSStatusItem!
    var timer: Timer?

    init(service: SyncService, dashboardURL: URL, webError: String?, onQuit: @escaping () -> Void) {
        self.service = service
        self.dashboardURL = dashboardURL
        self.webError = webError
        self.onQuit = onQuit
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshButton()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshButton() }

        if let err = webError {
            alert("The PCOSync dashboard couldn't start", "\(err)\n\nIf PCOSync is already running, use that copy (look for it in the menu bar).")
        } else if service.store.credentials == nil {
            // First run: go straight to setup.
            openDashboard()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stopping may release LIVE control over the network; don't block the UI.
        DispatchQueue.global().async { [onQuit] in
            onQuit()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    // MARK: status button

    func refreshButton() {
        guard let button = statusItem.button else { return }
        let s = service.snapshot()
        let running = s["running"] as? Bool ?? false
        let armed = s["armed"] as? Bool ?? false
        let paused = s["paused"] as? Bool ?? false
        let state = s["state"] as? String ?? ""
        let problem = state == "needs_setup" || state == "waiting"
            || ((s["propresenter"] as? [String: Any])?["ok"] as? Bool == false)
            || ((s["live"] as? [String: Any])?["ok"] as? Bool == false)

        let symbol: String
        let text: String
        if !running {
            symbol = "pause.circle"; text = ""
        } else if problem {
            symbol = "exclamationmark.triangle"; text = armed ? " ARMED" : ""
        } else if paused {
            symbol = "pause.circle.fill"; text = armed ? " ARMED" : " DRY"
        } else {
            symbol = armed ? "dot.radiowaves.left.and.right" : "eye"; text = armed ? " ARMED" : " DRY"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "PCOSync")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: armed && running ? NSColor.systemRed : NSColor.labelColor,
        ])
        button.toolTip = "PCOSync: " + statusLine(s)
    }

    func statusLine(_ s: [String: Any]) -> String {
        let running = s["running"] as? Bool ?? false
        if !running { return "Not syncing" }
        let armed = s["armed"] as? Bool ?? false
        let state = s["state"] as? String ?? ""
        let paused = s["paused"] as? Bool ?? false
        let mode = armed ? "ARMED" : "Dry-run"
        switch state {
        case "needs_setup": return "Needs setup: \(s["detail"] as? String ?? "")"
        case "waiting": return "Waiting to connect: \(s["detail"] as? String ?? "")"
        case "starting": return "\(mode): starting…"
        default: return paused ? "\(mode): paused" : "\(mode): syncing"
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = service.snapshot()
        let running = s["running"] as? Bool ?? false
        let armed = s["armed"] as? Bool ?? false
        let paused = s["paused"] as? Bool ?? false
        let isRunningState = (s["state"] as? String) == "running"

        menu.addItem(disabled(statusLine(s)))
        if running {
            let pp = (s["propresenter"] as? [String: Any]) ?? [:]
            let ppItem = pp["item"] as? String ?? ""
            menu.addItem(disabled("ProPresenter: " + (pp["ok"] as? Bool == false ? "not reachable" : (ppItem.isEmpty ? "—" : ppItem))))
            menu.addItem(disabled("LIVE: " + liveTitle(s)))
            if let ld = s["lastDecision"] as? [String: Any], let text = ld["text"] as? String {
                menu.addItem(disabled(String(text.prefix(90))))
            }
        }
        if let err = webError { menu.addItem(disabled("Dashboard unavailable: \(err)")) }
        menu.addItem(.separator())
        menu.addItem(item("Open Dashboard…", #selector(openDashboardAction), key: "d"))
        menu.addItem(.separator())

        if !running || armed { menu.addItem(item("Start Dry-Run", #selector(startDry))) }
        if !running || !armed { menu.addItem(item("Arm (Move LIVE)…", #selector(arm))) }
        if running { menu.addItem(item("Stop", #selector(stop))) }
        if isRunningState {
            menu.addItem(item(paused ? "Resume" : "Pause", #selector(togglePause)))
            menu.addItem(item("Confirm Big Move", #selector(confirmMove)))
            let svc = NSMenuItem(title: "Service Time", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(item("Next Service", #selector(nextService)))
            sub.addItem(item("Previous Service", #selector(prevService)))
            sub.addItem(item("Follow LIVE", #selector(autoService)))
            svc.submenu = sub
            menu.addItem(svc)
            menu.addItem(item("Reload Plan", #selector(reload)))
        }
        menu.addItem(.separator())
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit PCOSync", #selector(quit), key: "q"))
    }

    func liveTitle(_ s: [String: Any]) -> String {
        let live = (s["live"] as? [String: Any]) ?? [:]
        if live["ok"] as? Bool == false { return "PCO not reachable" }
        let id = live["itemId"] as? String ?? ""
        if let items = s["items"] as? [[String: Any]], let it = items.first(where: { $0["id"] as? String == id && !id.isEmpty }) {
            return it["title"] as? String ?? "?"
        }
        if live["serviceStart"] as? Bool == true { return "service start" }
        return live["controller"] == nil ? "—" : "not started"
    }

    func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    // MARK: actions

    func openDashboard() { NSWorkspace.shared.open(dashboardURL) }
    @objc func openDashboardAction() { openDashboard() }

    @objc func startDry() { background { $0.start(armed: false) } }

    @objc func arm() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Arm PCOSync?"
        a.informativeText = "It will take LIVE control in Planning Center and move LIVE to follow ProPresenter.\n\nReset rehearsal times in LIVE before the real service."
        a.addButton(withTitle: "Arm")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn { background { $0.start(armed: true) } }
    }

    @objc func stop() { background { $0.stop() } }
    @objc func togglePause() {
        let paused = service.snapshot()["paused"] as? Bool ?? false
        command(paused ? "resume" : "pause")
    }
    @objc func confirmMove() { command("confirm") }
    @objc func nextService() { command("next-service") }
    @objc func prevService() { command("prev-service") }
    @objc func autoService() { command("auto-service") }
    @objc func reload() { command("reload") }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Couldn't change Open at Login", "\(error.localizedDescription)\n\nYou can also add PCOSync in System Settings › General › Login Items.")
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    func command(_ c: String) { background { _ = $0.command(c) } }

    /// Service calls can block on the network; keep them off the main thread.
    func background(_ work: @escaping (SyncService) -> Void) {
        let svc = service
        DispatchQueue.global().async {
            work(svc)
            DispatchQueue.main.async { [weak self] in self?.refreshButton() }
        }
    }

    func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
#endif
