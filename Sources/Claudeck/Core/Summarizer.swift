import Foundation

struct CachedSummary: Codable {
    let text: String
    let generatedAt: Date
    let sourceTurns: Int
    let model: String
}

/// Generates AI summaries of a session's memory by calling the local `claude` CLI (no API key needed).
enum Summarizer {
    static var model: String {
        let m = UserDefaults.standard.string(forKey: "summaryModel") ?? ""
        return m.isEmpty ? "haiku" : m
    }

    private static func url(for id: String) -> URL { Paths.summariesDir.appendingPathComponent("\(id).json") }

    static func cached(for s: SessionSummary) -> CachedSummary? {
        guard let d = try? Data(contentsOf: url(for: s.id)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(CachedSummary.self, from: d)
    }

    /// True when the session has had new turns since the summary was generated.
    static func isStale(_ c: CachedSummary, for s: SessionSummary) -> Bool {
        c.sourceTurns < s.userTurns + s.assistantTurns
    }

    static func generate(for s: SessionSummary) async throws -> CachedSummary {
        let transcript = SessionParser.transcript(url: s.path)
        let body = condensed(transcript)
        let system = """
        You write short memory notes for Claude Code sessions so a developer can instantly recall what happened. \
        Use Markdown with exactly these bold headings, each followed by 1–4 terse bullets: \
        **Goal**, **What got done**, **Key files & decisions**, **Open threads / next steps**. \
        Mention concrete file names, commands, repos and outcomes. No preamble.
        """
        let input = """
        Project: \(s.cwd ?? s.projectKey)
        Session title: \(s.title)
        Started: \(s.start.map(Fmt.dateTime.string) ?? "?") · Duration: \(Fmt.duration(s.start, s.end)) · Tokens: \(Fmt.tokens(s.tokens.total))

        Transcript:
        \(body)
        """
        let res = await CLI.run(["-p", "--model", model, "--no-session-persistence", "--tools", "",
                                 "--strict-mcp-config", "--system-prompt", system],
                                stdin: input)
        let text = res.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard res.status == 0, !text.isEmpty else {
            throw NSError(domain: "Summarizer", code: Int(res.status),
                          userInfo: [NSLocalizedDescriptionKey: res.err.isEmpty ? (text.isEmpty ? "Summary failed (exit \(res.status))" : text) : res.err])
        }
        let summary = CachedSummary(text: text, generatedAt: Date(), sourceTurns: s.userTurns + s.assistantTurns, model: model)
        try? FileManager.default.createDirectory(at: Paths.summariesDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(summary).write(to: url(for: s.id))
        MemoryWriter.shared.rewrite(s) // fold the summary into the memory doc
        return summary
    }

    /// Keeps prompts and Claude's replies, abbreviates tool calls, and trims the middle of very long sessions.
    private static func condensed(_ t: [TranscriptEntry], limit: Int = 90_000) -> String {
        let lines: [String] = t.compactMap { e in
            switch e.role {
            case .user: return "USER: \(e.text.prefix(2000))"
            case .assistant: return "CLAUDE: \(e.text.prefix(1500))"
            case .tool: return "  \(e.text.prefix(160))"
            case .system: return nil
            }
        }
        let full = lines.joined(separator: "\n")
        guard full.count > limit else { return full }
        let head = full.prefix(limit / 4)
        let tail = full.suffix(limit * 3 / 4)
        return "\(head)\n\n[… middle of session omitted …]\n\n\(tail)"
    }
}
