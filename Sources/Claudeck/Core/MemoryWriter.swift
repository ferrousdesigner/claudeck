import Foundation

/// Writes one Markdown "memory doc" per Claude Code session into ~/Documents/Claudeck/Sessions.
/// Docs are regenerated whenever the session transcript grows, and include the AI summary once generated.
final class MemoryWriter: @unchecked Sendable {
    static let shared = MemoryWriter()
    private let queue = DispatchQueue(label: "claudeck.memory", qos: .utility)
    private var index: [String: String] = [:] // session id -> file name
    private var indexLoaded = false

    private var indexURL: URL { Paths.sessionDocsDir.appendingPathComponent(".index.json") }

    func sync(_ sessions: [SessionSummary]) {
        guard !sessions.isEmpty else { return }
        queue.async { for s in sessions { self.write(s) } }
    }

    func rewrite(_ session: SessionSummary) { queue.async { self.write(session) } }

    func docURL(for session: SessionSummary) -> URL {
        queue.sync {
            loadIndex()
            return Paths.sessionDocsDir.appendingPathComponent(index[session.id] ?? fileName(for: session))
        }
    }

    private func fileName(for s: SessionSummary) -> String {
        let date = s.start.map { Fmt.day.string(from: $0) } ?? "undated"
        let slug = s.title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, c in if !(c == "-" && acc.last == "-") { acc.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(48)
        return "\(date) \(s.projectName) — \(slug.isEmpty ? "session" : String(slug)) [\(s.shortID)].md"
    }

    private func loadIndex() {
        guard !indexLoaded else { return }
        indexLoaded = true
        if let d = try? Data(contentsOf: indexURL), let m = try? JSONDecoder().decode([String: String].self, from: d) { index = m }
    }

    private func write(_ s: SessionSummary) {
        loadIndex()
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.sessionDocsDir, withIntermediateDirectories: true)
        let name = fileName(for: s)
        if let old = index[s.id], old != name { try? fm.removeItem(at: Paths.sessionDocsDir.appendingPathComponent(old)) }
        index[s.id] = name
        let doc = render(s, transcript: SessionParser.transcript(url: s.path))
        try? doc.write(to: Paths.sessionDocsDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        if let d = try? JSONEncoder().encode(index) { try? d.write(to: indexURL) }
    }

    private func render(_ s: SessionSummary, transcript: [TranscriptEntry]) -> String {
        var md = "# \(s.title)\n\n"
        md += "| | |\n|---|---|\n"
        md += "| Session | `\(s.id)` |\n"
        md += "| Project | `\(s.cwd ?? s.projectKey)` |\n"
        if let b = s.gitBranch { md += "| Branch | `\(b)` |\n" }
        md += "| Started | \(s.start.map(Fmt.dateTime.string) ?? "—") |\n"
        md += "| Last activity | \(s.end.map(Fmt.dateTime.string) ?? "—") |\n"
        md += "| Duration | \(Fmt.duration(s.start, s.end)) |\n"
        md += "| Prompts / replies / tool calls | \(s.userTurns) / \(s.assistantTurns) / \(s.toolCalls) |\n"
        md += "| Total tokens | **\(Fmt.tokens(s.tokens.total))** (in \(Fmt.tokens(s.tokens.input)), out \(Fmt.tokens(s.tokens.output)), cache write \(Fmt.tokens(s.tokens.cacheCreate)), cache read \(Fmt.tokens(s.tokens.cacheRead))) |\n"
        if !s.tokensByModel.isEmpty {
            md += "| Models | \(s.tokensByModel.sorted { $0.value.total > $1.value.total }.map { "\($0.key) (\(Fmt.tokens($0.value.total)))" }.joined(separator: ", ")) |\n"
        }
        md += "\nResume in a terminal: `cd \"\(s.cwd ?? "~")\" && claude --resume \(s.id)`\n\n"

        if let summary = Summarizer.cached(for: s) {
            md += "## Summary\n\n\(summary.text)\n\n"
        }

        md += "## Prompts\n\n"
        let prompts = transcript.filter { $0.role == .user }
        if prompts.isEmpty { md += "_None_\n" }
        for (i, p) in prompts.enumerated() {
            md += "\(i + 1). \(p.text.replacingOccurrences(of: "\n", with: " ").prefix(400))\n"
        }

        md += "\n## Transcript\n\n"
        for e in transcript {
            let time = e.timestamp.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? ""
            switch e.role {
            case .user: md += "\n### 🧑 You · \(time)\n\n\(e.text)\n\n"
            case .assistant: md += "**Claude:** \(e.text)\n\n"
            case .tool: md += "- `\(e.text.replacingOccurrences(of: "`", with: "'").prefix(220))`\n"
            case .system: break // tool output is left out to keep docs readable
            }
        }
        return md
    }
}
