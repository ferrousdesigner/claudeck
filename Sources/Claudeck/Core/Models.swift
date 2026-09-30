import Foundation

struct TokenUsage: Hashable, Codable {
    var input = 0
    var output = 0
    var cacheCreate = 0
    var cacheRead = 0
    var cacheCreate1h = 0   // portion of cacheCreate written to the 1-hour cache (priced higher)

    var total: Int { input + output + cacheCreate + cacheRead }
    /// Tokens that were actually newly processed (excludes cheap cache reads).
    var fresh: Int { input + output + cacheCreate }

    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output,
                   cacheCreate: a.cacheCreate + b.cacheCreate, cacheRead: a.cacheRead + b.cacheRead,
                   cacheCreate1h: a.cacheCreate1h + b.cacheCreate1h)
    }
    static func - (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input - b.input, output: a.output - b.output, cacheCreate: a.cacheCreate - b.cacheCreate,
                   cacheRead: a.cacheRead - b.cacheRead, cacheCreate1h: a.cacheCreate1h - b.cacheCreate1h)
    }
    static func += (a: inout TokenUsage, b: TokenUsage) { a = a + b }

    init(input: Int = 0, output: Int = 0, cacheCreate: Int = 0, cacheRead: Int = 0, cacheCreate1h: Int = 0) {
        self.input = input; self.output = output; self.cacheCreate = cacheCreate; self.cacheRead = cacheRead
        self.cacheCreate1h = cacheCreate1h
    }

    init(json: [String: Any]) {
        input = json["input_tokens"] as? Int ?? 0
        output = json["output_tokens"] as? Int ?? 0
        cacheCreate = json["cache_creation_input_tokens"] as? Int ?? 0
        cacheRead = json["cache_read_input_tokens"] as? Int ?? 0
        cacheCreate1h = (json["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0
    }
}

struct SessionSummary: Identifiable, Hashable {
    let id: String
    let path: URL
    var projectKey: String
    var cwd: String?
    var aiTitle: String?
    var firstPrompt: String?
    var lastPrompt: String?
    var lastActivity: String?
    var gitBranch: String?
    var start: Date?
    var end: Date?
    var userTurns = 0
    var assistantTurns = 0
    var toolCalls = 0
    var tokens = TokenUsage()
    var tokensByModel: [String: TokenUsage] = [:]
    var tokensByDay: [String: TokenUsage] = [:]
    var fileModified: Date = .distantPast
    var toolCounts: [String: Int] = [:]
    var hourCounts: [Int: Int] = [:]      // local hour of day -> prompts
    var toolErrors = 0
    var lastContextTokens = 0             // size of the context window on the latest reply
    var lastModel: String?
    // Signals for the Improvements tab.
    var firstContextTokens = 0            // context on the first reply: system prompt, tools, CLAUDE.md, memory
    var peakContextTokens = 0
    var cacheMisses = 0                   // replies after the first that had to re-write most of the context
    var cacheMissTokens = 0
    var toolResultChars: [String: Int] = [:]   // tool name -> characters returned into context
    var largeToolResults = 0              // results over ~10K tokens

    var cost: Double { Pricing.cost(byModel: tokensByModel) }
    func cost(onDay day: String) -> Double {
        // Day totals aren't split by model, so price them at the session's blended rate.
        guard let d = tokensByDay[day], tokens.total > 0 else { return 0 }
        return cost * Double(d.total) / Double(tokens.total)
    }
    var contextWindow: Int { (lastModel ?? "").contains("[1m]") || lastContextTokens > 200_000 ? 1_000_000 : 200_000 }

    var title: String {
        if let t = aiTitle, !t.isEmpty { return t }
        if let p = firstPrompt, !p.isEmpty { return String(p.prefix(80)) }
        return "Untitled session"
    }

    var projectName: String {
        if let cwd { return (cwd as NSString).lastPathComponent }
        return projectKey
    }

    var shortID: String { String(id.prefix(8)) }
    var isEmpty: Bool { userTurns == 0 && assistantTurns == 0 }
}

/// A running Claude Code process, from ~/.claude/sessions/<pid>.json
struct LiveSession: Identifiable, Hashable {
    var id: Int { pid }
    let pid: Int
    let sessionId: String
    let cwd: String
    let name: String?
    let status: String
    let kind: String?
    let startedAt: Date?
    let updatedAt: Date?
    let version: String?
    let remoteURL: String?

    var isBusy: Bool { status == "busy" }
}

enum TranscriptRole: String { case user, assistant, tool, system }

struct TranscriptEntry: Identifiable, Hashable {
    let id: Int
    let role: TranscriptRole
    let text: String
    let timestamp: Date?
}

struct SkillInfo: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let description: String
    let source: String
    let path: String
}

struct PluginInfo: Identifiable, Hashable {
    var id: String { "\(name)@\(marketplace)" }
    let name: String
    let description: String
    let category: String?
    let author: String?
    let marketplace: String
    var installed: Bool
    var enabled: Bool
    var localPath: String? = nil      // plugin folder inside the local marketplace checkout, if bundled
    var homepage: String? = nil

    /// What we can show without installing: README from the marketplace checkout, or the source link.
    var offlineDetails: String {
        var out = "\(name)\n\(description)\n"
        if let author { out += "\nAuthor: \(author)" }
        if let category { out += "\nCategory: \(category)" }
        out += "\nMarketplace: \(marketplace)"
        if let homepage { out += "\nHomepage: \(homepage)" }
        if let localPath {
            let fm = FileManager.default
            let parts = ["commands", "agents", "skills", "hooks", ".mcp.json"].filter { fm.fileExists(atPath: localPath + "/" + $0) }
            if !parts.isEmpty { out += "\nContains: " + parts.joined(separator: ", ") }
            if let readme = try? String(contentsOfFile: localPath + "/README.md", encoding: .utf8) { out += "\n\n" + readme }
        }
        return out
    }
}

struct MCPServerInfo: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let target: String
    let status: String
    var ok: Bool { status.contains("✔") || status.lowercased().contains("connected") }
}

struct AgentOrCommand: Identifiable, Hashable {
    var id: String { path }
    let kind: String   // "agent" | "command"
    let name: String
    let description: String
    let source: String
    let path: String
}

// MARK: - Formatting helpers

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch d {
        case 1_000_000_000...: return String(format: "%.2fB", d / 1_000_000_000)
        case 1_000_000...: return String(format: "%.2fM", d / 1_000_000)
        case 10_000...: return String(format: "%.0fK", d / 1_000)
        case 1_000...: return String(format: "%.1fK", d / 1_000)
        default: return "\(n)"
        }
    }

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
    }()

    static func ago(_ d: Date?) -> String {
        guard let d else { return "—" }
        if abs(d.timeIntervalSinceNow) < 45 { return "just now" }
        return relative.localizedString(for: d, relativeTo: Date())
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    static func duration(_ from: Date?, _ to: Date?) -> String {
        guard let from, let to else { return "—" }
        let s = Int(to.timeIntervalSince(from))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }
}

enum ISO {
    private static let withFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return withFrac.date(from: s) ?? plain.date(from: s)
    }
}
