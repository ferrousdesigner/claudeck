import Foundation

/// Read-modify-write access to a Claude Code settings.json. Every write keeps the file's other keys,
/// and the first write in a session backs the original up to settings.json.claudeck.bak.
enum ClaudeSettings {
    enum Scope: String, CaseIterable, Identifiable {
        case user = "User (~/.claude/settings.json)"
        case project = "Project (.claude/settings.json)"
        case local = "Project, just me (.claude/settings.local.json)"
        var id: String { rawValue }
        var short: String { switch self { case .user: return "user"; case .project: return "project"; case .local: return "local" } }
    }

    static func url(_ scope: Scope, project: String? = nil) -> URL {
        switch scope {
        case .user: return Paths.settingsFile
        case .project: return URL(fileURLWithPath: project ?? "").appendingPathComponent(".claude/settings.json")
        case .local: return URL(fileURLWithPath: project ?? "").appendingPathComponent(".claude/settings.local.json")
        }
    }

    static func read(_ url: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: url), !d.isEmpty,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    private static var backedUp = Set<String>()

    static func write(_ obj: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path), !backedUp.contains(url.path) {
            let bak = url.appendingPathExtension("claudeck.bak")
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: url, to: bak)
            backedUp.insert(url.path)
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static func modify(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
        var o = read(url)
        change(&o)
        try write(o, to: url)
    }

    // MARK: Hooks

    struct HookEntry: Identifiable, Hashable {
        var id: String { "\(event)|\(matcher)|\(command)" }
        var event: String
        var matcher: String
        var command: String
        var timeout: Int?
    }

    static let hookEvents = ["PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "UserPromptSubmit",
                             "Stop", "SubagentStop", "PreCompact", "SessionStart", "SessionEnd"]

    static func hooks(_ url: URL) -> [HookEntry] {
        guard let h = read(url)["hooks"] as? [String: Any] else { return [] }
        var out: [HookEntry] = []
        for (event, groups) in h {
            for g in groups as? [[String: Any]] ?? [] {
                let matcher = g["matcher"] as? String ?? ""
                for hk in g["hooks"] as? [[String: Any]] ?? [] {
                    out.append(HookEntry(event: event, matcher: matcher, command: hk["command"] as? String ?? (hk["prompt"] as? String ?? ""),
                                         timeout: hk["timeout"] as? Int))
                }
            }
        }
        return out.sorted { ($0.event, $0.matcher) < ($1.event, $1.matcher) }
    }

    static func addHook(_ e: HookEntry, to url: URL) throws {
        try modify(url) { o in
            var hooks = o["hooks"] as? [String: Any] ?? [:]
            var groups = hooks[e.event] as? [[String: Any]] ?? []
            var cmd: [String: Any] = ["type": "command", "command": e.command]
            if let t = e.timeout { cmd["timeout"] = t }
            if let i = groups.firstIndex(where: { ($0["matcher"] as? String ?? "") == e.matcher }) {
                var list = groups[i]["hooks"] as? [[String: Any]] ?? []
                if !list.contains(where: { $0["command"] as? String == e.command }) { list.append(cmd) }
                groups[i]["hooks"] = list
            } else {
                var g: [String: Any] = ["hooks": [cmd]]
                if !e.matcher.isEmpty { g["matcher"] = e.matcher }
                groups.append(g)
            }
            hooks[e.event] = groups
            o["hooks"] = hooks
        }
    }

    static func removeHook(_ e: HookEntry, from url: URL) throws {
        try modify(url) { o in
            guard var hooks = o["hooks"] as? [String: Any], var groups = hooks[e.event] as? [[String: Any]] else { return }
            for i in groups.indices where (groups[i]["matcher"] as? String ?? "") == e.matcher {
                var list = groups[i]["hooks"] as? [[String: Any]] ?? []
                list.removeAll { ($0["command"] as? String ?? $0["prompt"] as? String) == e.command }
                groups[i]["hooks"] = list
            }
            groups.removeAll { ($0["hooks"] as? [Any])?.isEmpty ?? true }
            if groups.isEmpty { hooks.removeValue(forKey: e.event) } else { hooks[e.event] = groups }
            if hooks.isEmpty { o.removeValue(forKey: "hooks") } else { o["hooks"] = hooks }
        }
    }

    // MARK: Permissions

    struct Permissions: Equatable {
        var allow: [String] = []
        var ask: [String] = []
        var deny: [String] = []
        var defaultMode: String = ""
        var additionalDirectories: [String] = []
    }

    static func permissions(_ url: URL) -> Permissions {
        let p = read(url)["permissions"] as? [String: Any] ?? [:]
        return Permissions(allow: p["allow"] as? [String] ?? [], ask: p["ask"] as? [String] ?? [], deny: p["deny"] as? [String] ?? [],
                           defaultMode: p["defaultMode"] as? String ?? "", additionalDirectories: p["additionalDirectories"] as? [String] ?? [])
    }

    static func setPermissions(_ perm: Permissions, _ url: URL) throws {
        try modify(url) { o in
            var p = o["permissions"] as? [String: Any] ?? [:]
            func set(_ k: String, _ v: [String]) { if v.isEmpty { p.removeValue(forKey: k) } else { p[k] = v } }
            set("allow", perm.allow); set("ask", perm.ask); set("deny", perm.deny)
            set("additionalDirectories", perm.additionalDirectories)
            if perm.defaultMode.isEmpty { p.removeValue(forKey: "defaultMode") } else { p["defaultMode"] = perm.defaultMode }
            if p.isEmpty { o.removeValue(forKey: "permissions") } else { o["permissions"] = p }
        }
    }

    /// Plain-English warnings about risky permission setups.
    static func risks(_ p: Permissions, settings: [String: Any]) -> [String] {
        var r: [String] = []
        if p.defaultMode == "bypassPermissions" { r.append("Default mode is “bypass permissions”: Claude can run any command and edit any file without asking.") }
        if (settings["skipDangerousModePermissionPrompt"] as? Bool) == true { r.append("The safety prompt for bypass mode is switched off (skipDangerousModePermissionPrompt).") }
        for rule in p.allow {
            if rule == "Bash" || rule == "Bash(*)" || rule == "Bash(:*)" { r.append("“\(rule)” allows every shell command without asking.") }
            if rule.hasPrefix("Bash(rm") || rule.hasPrefix("Bash(sudo") || rule.contains("git push --force") { r.append("“\(rule)” auto-approves a destructive command.") }
            if rule == "Edit" || rule == "Write" { r.append("“\(rule)” allows editing any file without asking.") }
            if rule.hasPrefix("WebFetch") && !rule.contains("domain:") { r.append("“\(rule)” allows fetching any website.") }
        }
        let protected = ["Read(./.env)", "Read(./.env.*)", "Read(./secrets/**)"]
        if !protected.contains(where: { p.deny.contains($0) }) { r.append("Nothing stops Claude reading .env files. Consider denying Read(./.env) and Read(./.env.*).") }
        return r
    }
}
