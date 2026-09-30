import Foundation
import UserNotifications
import Combine
import AppKit

/// Posts macOS notifications: session finished, prompt runs done, budget warnings, permission requests.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    @Published var authorized = false
    private var lastStatus: [String: String] = [:]     // sessionId -> busy/idle
    private var firedBudget = Set<String>()
    private var watched = Set<UUID>()
    private var cancellables: [UUID: AnyCancellable] = [:]
    var onOpenSession: ((String) -> Void)?
    weak var bridge: PermissionBridge?

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes when not running from an app bundle (e.g. `swift run`).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setup() {
        guard let center else { return }
        center.delegate = self
        let allow = UNNotificationAction(identifier: "allow", title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: "permission", actions: [allow, deny], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            Task { @MainActor in self.authorized = ok }
        }
    }

    static var enabled: Bool { UserDefaults.standard.object(forKey: "notify") as? Bool ?? true }

    func post(_ title: String, _ body: String, id: String = UUID().uuidString, sessionID: String? = nil, sound: Bool = true) {
        guard Self.enabled, let center else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        if sound { c.sound = .default }
        if let sessionID { c.userInfo = ["session": sessionID] }
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    func postPermission(_ r: PermissionRequest) {
        guard let center else { return }
        let c = UNMutableNotificationContent()
        c.title = "Claude wants to use \(r.toolName)"
        c.subtitle = (r.cwd as NSString).lastPathComponent
        c.body = String(r.summary.prefix(200))
        c.sound = .default
        c.categoryIdentifier = "permission"
        c.userInfo = ["permission": r.id, "session": r.sessionID]
        center.add(UNNotificationRequest(identifier: "perm-\(r.id)", content: c, trigger: nil))
    }

    /// Called after each refresh: notify when a live session goes from working to idle.
    func observe(live: [LiveSession], sessions: SessionStore) {
        for l in live {
            let prev = lastStatus[l.sessionId]
            if prev == "busy" && l.status == "idle" && (UserDefaults.standard.object(forKey: "notifyIdle") as? Bool ?? true) {
                let s = sessions.session(id: l.sessionId)
                post("Claude finished", "\(s?.title ?? "Session") · \((l.cwd as NSString).lastPathComponent) is waiting for you",
                     id: "idle-\(l.sessionId)", sessionID: l.sessionId)
            }
            lastStatus[l.sessionId] = l.status
        }
        checkBudgets(sessions)
    }

    private func checkBudgets(_ sessions: SessionStore) {
        let checks: [(String, Double, Double)] = [
            ("today", Budget.daily, sessions.cost(days: 1)),
            ("this week", Budget.weekly, sessions.cost(days: 7)),
            ("this month", Budget.monthly, sessions.cost(days: 30)),
        ]
        for (label, limit, spent) in checks where limit > 0 {
            for pct in [0.8, 1.0] where spent >= limit * pct {
                let key = "\(label)-\(pct)-\(Fmt.day.string(from: Date()))"
                if firedBudget.insert(key).inserted {
                    post(pct >= 1 ? "Budget reached" : "Budget at 80%",
                         "\(Fmt.usd(spent)) of your \(Fmt.usd(limit)) budget used \(label).", id: key)
                }
            }
        }
    }

    /// Notify when a dashboard-launched run completes.
    func watch(_ run: PromptRun) {
        guard watched.insert(run.id).inserted else { return }
        cancellables[run.id] = run.$state.dropFirst().sink { [weak self] st in
            guard let self else { return }
            switch st {
            case .done: self.post("Prompt finished", run.title, id: "run-\(run.id)", sessionID: run.sessionId)
            case .failed(let why): self.post("Prompt failed", "\(run.title) — \(why)", id: "run-\(run.id)")
            default: return
            }
            self.cancellables[run.id] = nil
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let sid = info["session"] as? String
        let permID = info["permission"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            if let permID, action == "allow" || action == "deny",
               let req = self.bridge?.pending.first(where: { $0.id == permID }) {
                self.bridge?.answer(req, allow: action == "allow")
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            if let sid, !sid.isEmpty { self.onOpenSession?(sid) }
        }
    }
}
