import Foundation
import Combine
import AppKit

/// Lets you approve Claude Code permission prompts from Claudeck.
///
/// Claudeck installs itself as a `PermissionRequest` hook. When Claude needs approval the hook
/// (this same binary, run with `--hook permission`) drops a request file and waits briefly for an answer
/// from the app. No answer, or the app isn't open, means the normal terminal prompt appears.
/// A `Notification` hook forwards "Claude needs your permission" events so the app can alert you.
struct PermissionRequest: Identifiable, Codable, Hashable {
    let id: String
    let sessionID: String
    let cwd: String
    let toolName: String
    let summary: String
    let created: Date
}

enum HookMode {
    static var dir: URL { Paths.appSupport.appendingPathComponent("bridge") }
    static var requestsDir: URL { dir.appendingPathComponent("requests") }
    static var responsesDir: URL { dir.appendingPathComponent("responses") }
    static var eventsFile: URL { dir.appendingPathComponent("events.jsonl") }
    static var aliveFile: URL { dir.appendingPathComponent("app.pid") }

    static var waitSeconds: Double {
        let v = UserDefaults.standard.double(forKey: "approvalWait")
        return v > 0 ? v : 30
    }

    /// Entry point when launched as a hook. Never blocks Claude Code for long and never fails loudly.
    static func run(_ kind: String) -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let obj = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
        try? FileManager.default.createDirectory(at: requestsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: responsesDir, withIntermediateDirectories: true)

        switch kind {
        case "event":
            var line = obj
            line["received_at"] = ISO8601DateFormatter().string(from: Date())
            if let d = try? JSONSerialization.data(withJSONObject: line), let h = try? FileHandle(forWritingTo: eventsFile) ?? {
                FileManager.default.createFile(atPath: eventsFile.path, contents: nil); return try FileHandle(forWritingTo: eventsFile)
            }() {
                h.seekToEndOfFile(); h.write(d + Data([0x0A])); try? h.close()
            }
            exit(0)

        case "permission":
            guard appIsRunning() else { exit(0) }   // fall back to the terminal prompt
            let id = UUID().uuidString
            let tool = obj["tool_name"] as? String ?? "tool"
            let input = obj["tool_input"] as? [String: Any] ?? [:]
            let req = PermissionRequest(id: id, sessionID: obj["session_id"] as? String ?? "", cwd: obj["cwd"] as? String ?? "",
                                        toolName: tool, summary: describe(tool: tool, input: input), created: Date())
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let reqURL = requestsDir.appendingPathComponent("\(id).json")
            try? enc.encode(req).write(to: reqURL)
            let respURL = responsesDir.appendingPathComponent("\(id).json")
            let deadline = Date().addingTimeInterval(waitSeconds)
            while Date() < deadline {
                if let d = try? Data(contentsOf: respURL), let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let behavior = r["behavior"] as? String {
                    try? FileManager.default.removeItem(at: respURL)
                    try? FileManager.default.removeItem(at: reqURL)
                    var decision: [String: Any] = ["behavior": behavior]
                    if behavior == "deny" { decision["message"] = "Denied from Claudeck." }
                    let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
                    if let od = try? JSONSerialization.data(withJSONObject: out) { FileHandle.standardOutput.write(od) }
                    exit(0)
                }
                usleep(250_000)
            }
            try? FileManager.default.removeItem(at: reqURL)
            exit(0)

        default:
            exit(0)
        }
    }

    static func appIsRunning() -> Bool {
        guard let s = try? String(contentsOf: aliveFile, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        if let c = input["command"] as? String { return c }
        if let f = input["file_path"] as? String { return f }
        if let u = input["url"] as? String { return u }
        if let p = input["pattern"] as? String { return p }
        let d = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return String(d.prefix(300))
    }
}

@MainActor
final class PermissionBridge: ObservableObject {
    @Published private(set) var pending: [PermissionRequest] = []
    @Published private(set) var installed = false
    private var timer: Timer?
    private var eventsOffset: UInt64 = 0
    private var notified = Set<String>()

    var hookCommand: String { "\(Handoff.shellQuote(Bundle.main.executablePath ?? "/Applications/Claudeck.app/Contents/MacOS/Claudeck"))" }

    init() {
        try? FileManager.default.createDirectory(at: HookMode.requestsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: HookMode.responsesDir, withIntermediateDirectories: true)
        try? String(ProcessInfo.processInfo.processIdentifier).write(to: HookMode.aliveFile, atomically: true, encoding: .utf8)
        eventsOffset = (try? FileManager.default.attributesOfItem(atPath: HookMode.eventsFile.path)[.size] as? UInt64) ?? 0
        refreshInstalled()
        repointHooks()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func refreshInstalled() {
        installed = ClaudeSettings.hooks(Paths.settingsFile).contains { $0.command.contains("--hook permission") }
    }

    /// If the hooks point at another copy of the app (such as "Claude Deck.app" from before the rename),
    /// re-install them for this one. Only an installed .app does this, so debug builds leave them alone.
    private func repointHooks() {
        guard installed, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let ours = ClaudeSettings.hooks(Paths.settingsFile).filter { $0.command.contains("--hook permission") || $0.command.contains("--hook event") }
        guard ours.contains(where: { !$0.command.hasPrefix(hookCommand + " ") }) else { return }
        try? uninstall()
        try? install()
    }

    func install() throws {
        try ClaudeSettings.addHook(.init(event: "PermissionRequest", matcher: "", command: "\(hookCommand) --hook permission",
                                         timeout: Int(HookMode.waitSeconds) + 5), to: Paths.settingsFile)
        try ClaudeSettings.addHook(.init(event: "Notification", matcher: "", command: "\(hookCommand) --hook event", timeout: 5),
                                   to: Paths.settingsFile)
        refreshInstalled()
    }

    func uninstall() throws {
        for h in ClaudeSettings.hooks(Paths.settingsFile) where h.command.contains("--hook permission") || h.command.contains("--hook event") {
            try ClaudeSettings.removeHook(h, from: Paths.settingsFile)
        }
        refreshInstalled()
    }

    func answer(_ r: PermissionRequest, allow: Bool) {
        let d = try? JSONSerialization.data(withJSONObject: ["behavior": allow ? "allow" : "deny"])
        try? d?.write(to: HookMode.responsesDir.appendingPathComponent("\(r.id).json"))
        pending.removeAll { $0.id == r.id }
    }

    private func poll() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: HookMode.requestsDir, includingPropertiesForKeys: nil)) ?? []
        let reqs = files.compactMap { try? dec.decode(PermissionRequest.self, from: Data(contentsOf: $0)) }
            .filter { Date().timeIntervalSince($0.created) < HookMode.waitSeconds + 2 }
            .sorted { $0.created < $1.created }
        if reqs.map(\.id) != pending.map(\.id) { pending = reqs }
        for r in reqs where notified.insert(r.id).inserted {
            Notifier.shared.postPermission(r)
        }
        readEvents()
    }

    /// Notification-hook events (e.g. "Claude needs your permission") from sessions without the approval hook.
    private func readEvents() {
        guard let h = try? FileHandle(forReadingFrom: HookMode.eventsFile) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < eventsOffset { eventsOffset = 0 }
        guard size > eventsOffset else { return }
        try? h.seek(toOffset: eventsOffset)
        let data = (try? h.readToEnd()) ?? Data()
        eventsOffset = size
        for line in data.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let type = o["notification_type"] as? String ?? ""
            let msg = o["message"] as? String ?? "Claude Code needs your attention"
            let sid = o["session_id"] as? String
            // Idle is already detected from session status; forward everything else.
            if type == "idle_prompt" { continue }
            if type == "permission_prompt" && !pending.isEmpty { continue }
            Notifier.shared.post(type == "permission_prompt" ? "Permission needed" : "Claude Code", msg,
                                 id: "evt-\(UUID().uuidString)", sessionID: sid)
        }
    }
}
