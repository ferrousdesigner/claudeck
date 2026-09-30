import Foundation

/// One suggestion on the Improvements tab: what we saw, why it costs tokens, and what to change.
struct Improvement: Identifiable {
    enum Impact: Int, Comparable {
        case low, medium, high
        static func < (a: Impact, b: Impact) -> Bool { a.rawValue < b.rawValue }
        var label: String { ["Low", "Medium", "High"][rawValue] }
    }
    enum Destination { case extensions(ExtensionsView.Section), status }

    let id: String
    let title: String
    let icon: String
    var impact: Impact
    /// Estimated saving over the analysed window (about a month), API list prices.
    let savings: Double
    let finding: String
    let why: String
    let fixes: [String]
    var sessions: [(id: String, note: String)] = []
    var files: [(path: String, tokens: Int)] = []
    var destination: (label: String, to: Destination)? = nil
}

struct AdvisorReport {
    var windowDays = 30
    var sessionCount = 0
    var cost = 0.0
    var improvements: [Improvement] = []
    var strengths: [String] = []
    // Headline numbers
    var cacheHitRate = 0.0
    var medianStartContext = 0
    var avgContextPerReply = 0
    var toolErrorRate = 0.0

    var totalSavings: Double { improvements.reduce(0) { $0 + $1.savings } }
}

enum CostAdvisor {
    static let cheaperModel = "claude-sonnet-5"

    static func analyze(sessions all: [SessionSummary], instructionFiles: [InstructionFile], mcpServers: Int, days: Int = 30) -> AdvisorReport {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let recent = all.filter { ($0.end ?? $0.fileModified) >= cutoff && $0.assistantTurns > 0 }
        var r = AdvisorReport(windowDays: days, sessionCount: recent.count)
        guard !recent.isEmpty else { return r }
        r.cost = recent.reduce(0) { $0 + $1.cost }

        let tokens = recent.reduce(TokenUsage()) { $0 + $1.tokens }
        let contextTokens = tokens.input + tokens.cacheCreate + tokens.cacheRead
        let replies = recent.reduce(0) { $0 + $1.assistantTurns }
        r.cacheHitRate = contextTokens > 0 ? Double(tokens.cacheRead) / Double(contextTokens) : 0
        r.avgContextPerReply = replies > 0 ? contextTokens / replies : 0
        let starts = recent.map(\.firstContextTokens).filter { $0 > 0 }.sorted()
        r.medianStartContext = starts.isEmpty ? 0 : starts[starts.count / 2]
        let calls = recent.reduce(0) { $0 + $1.toolCalls }, errors = recent.reduce(0) { $0 + $1.toolErrors }
        r.toolErrorRate = calls > 0 ? Double(errors) / Double(calls) : 0

        var out: [Improvement?] = [
            premiumModel(recent),
            longSessions(recent),
            cacheMisses(recent),
            startupContext(recent, median: r.medianStartContext, files: instructionFiles, mcpServers: mcpServers),
            toolOutput(recent),
            toolErrors(recent),
            outputHeavy(recent),
        ]
        out.append(largeInstructionFiles(instructionFiles))

        r.improvements = out.compactMap { $0 }.map { imp in
            var imp = imp
            if imp.savings > 0 {
                let share = imp.savings / max(r.cost, 0.01)
                imp.impact = share >= 0.10 ? .high : share >= 0.03 ? .medium : .low
            }
            return imp
        }
        .sorted { ($0.impact, $0.savings) > ($1.impact, $1.savings) }

        if r.cacheHitRate >= 0.9 { r.strengths.append("\(Int(r.cacheHitRate * 100))% of context is served from the cache, so repeat reads are cheap.") }
        if r.toolErrorRate < 0.05, calls > 50 { r.strengths.append(String(format: "Only %.1f%% of tool calls fail.", r.toolErrorRate * 100)) }
        if r.medianStartContext > 0, r.medianStartContext < 20_000 { r.strengths.append("Sessions start lean, at about \(Fmt.tokens(r.medianStartContext)) tokens of fixed context.") }
        if !out.contains(where: { $0?.id == "long" }) { r.strengths.append("Sessions stay focused and don't drag a huge context along.") }
        return r
    }

    // MARK: - Helpers

    /// Cost of part of a session's tokens, priced per model.
    static func cost(_ s: SessionSummary, _ part: (TokenUsage) -> TokenUsage) -> Double {
        s.tokensByModel.reduce(0) { $0 + Pricing.cost(part($1.value), model: $1.key) }
    }

    private static func price(_ s: SessionSummary) -> ModelPrice { Pricing.price(for: s.lastModel ?? "") }

    private static func top(_ list: [(SessionSummary, Double)], _ note: (SessionSummary, Double) -> String) -> [(id: String, note: String)] {
        list.sorted { $0.1 > $1.1 }.prefix(5).map { (id: $0.0.id, note: note($0.0, $0.1)) }
    }

    private static func pct(_ a: Double, _ b: Double) -> String { String(format: "%.0f%%", b > 0 ? a / b * 100 : 0) }

    // MARK: - Checks

    /// Opus/Fable used for quick sessions that a cheaper model would handle.
    static func premiumModel(_ recent: [SessionSummary]) -> Improvement? {
        let sonnet = Pricing.price(for: cheaperModel)
        let light = recent.compactMap { s -> (SessionSummary, Double)? in
            let premium = s.tokensByModel.keys.filter { Pricing.price(for: $0).output > sonnet.output }
            guard !premium.isEmpty, s.toolCalls <= 8, s.tokens.output < 30_000 else { return nil }
            let saving = premium.reduce(0.0) { acc, m in
                let t = s.tokensByModel[m] ?? .init()
                return acc + Pricing.cost(t, model: m) - Pricing.cost(t, model: cheaperModel)
            }
            return saving > 0.01 ? (s, saving) : nil
        }
        let saving = light.reduce(0) { $0 + $1.1 }
        guard light.count >= 3, saving >= 0.5 else { return nil }
        return Improvement(
            id: "model", title: "Use a lighter model for quick tasks", icon: "hare", impact: .medium, savings: saving,
            finding: "\(light.count) short sessions (8 or fewer tool calls) ran on a top-tier model. On Sonnet they would have cost about \(Fmt.usd(saving)) less.",
            why: "Top-tier models cost 2–5× more per token. Questions, small edits and lookups rarely need them.",
            fixes: [
                "Switch with `/model sonnet` (or `/model haiku` for lookups) before quick questions, and switch back for hard problems.",
                "Start one-off questions with `claude --model sonnet`, or pick Sonnet in the ⌘K composer.",
                "Give read-only subagents `model: haiku` in their frontmatter so exploration runs on the cheap model.",
            ],
            sessions: top(light) { s, v in "\(s.toolCalls) tool calls · save \(Fmt.usd(v))" })
    }

    /// Sessions that keep going long after the context got big: every reply re-reads all of it.
    static func longSessions(_ recent: [SessionSummary]) -> Improvement? {
        let long = recent.compactMap { s -> (SessionSummary, Double)? in
            let ctx = s.tokens.input + s.tokens.cacheCreate + s.tokens.cacheRead
            guard s.assistantTurns >= 40, ctx / max(s.assistantTurns, 1) > 80_000 else { return nil }
            // Splitting work into fresh sessions roughly halves the average context carried per reply.
            return (s, 0.5 * cost(s) { TokenUsage(input: $0.input, cacheRead: $0.cacheRead) })
        }
        let saving = long.reduce(0) { $0 + $1.1 }
        guard !long.isEmpty, saving >= 0.5 else { return nil }
        return Improvement(
            id: "long", title: "Start fresh sessions more often", icon: "arrow.counterclockwise", impact: .medium, savings: saving,
            finding: "\(long.count) sessions averaged more than 80K tokens of context on every reply. Clearing between tasks could save about \(Fmt.usd(saving)).",
            why: "Each reply re-sends the whole conversation. Late in a long session, a one-line question can cost 150K+ tokens because everything before it comes along.",
            fixes: [
                "Run `/clear` when you move to an unrelated task. Use `/compact focus on <topic>` when you need to keep the thread but not the detail.",
                "Keep an eye on the context meter on **Status**; past about half full is a good time to wrap up.",
                "Before clearing, ask Claude to write a short handoff note (or save it to CLAUDE.md) so the next session starts with just what matters.",
            ],
            sessions: top(long) { s, v in "avg \(Fmt.tokens((s.tokens.input + s.tokens.cacheCreate + s.tokens.cacheRead) / max(s.assistantTurns, 1))) per reply · save \(Fmt.usd(v))" },
            destination: ("Open Status", .status))
    }

    /// The prompt cache expired or was invalidated, so a big context was written again at the higher rate.
    static func cacheMisses(_ recent: [SessionSummary]) -> Improvement? {
        let hit = recent.compactMap { s -> (SessionSummary, Double)? in
            guard s.cacheMisses > 0 else { return nil }
            let p = price(s)
            return (s, Double(s.cacheMissTokens) * (p.cacheWrite5m - p.cacheRead) / 1_000_000)
        }
        let saving = hit.reduce(0) { $0 + $1.1 }
        let misses = hit.reduce(0) { $0 + $1.0.cacheMisses }
        guard misses >= 3, saving >= 0.25 else { return nil }
        return Improvement(
            id: "cache", title: "Avoid breaking the prompt cache", icon: "memorychip", impact: .medium, savings: saving,
            finding: "\(misses) times, a session had to re-write its whole context to the cache instead of reading it. That cost about \(Fmt.usd(saving)) extra.",
            why: "Cached context costs about a tenth of the normal input price to read, but the cache only lives for about 5 minutes. After a longer pause, a model switch, or a change to CLAUDE.md, tools or MCP servers mid-session, everything is written again at 1.25× the input price.",
            fixes: [
                "Send follow-ups while the session is warm; batch small asks into one prompt instead of returning after a break.",
                "Avoid `/model` switches and MCP or CLAUDE.md edits in the middle of a long session. Make them between sessions.",
                "Instead of resuming a big session from yesterday, start a new one and paste a short summary. The first reply of a resumed session re-writes everything.",
            ],
            sessions: top(hit) { s, v in "\(s.cacheMisses) cache rebuilds · \(Fmt.usd(v))" })
    }

    /// Fixed context every session pays before you type anything: system prompt, tool schemas, MCP, CLAUDE.md, memory.
    static func startupContext(_ recent: [SessionSummary], median: Int, files: [InstructionFile], mcpServers: Int) -> Improvement? {
        let baseline = 20_000
        guard median > baseline + 5_000 else { return nil }
        let excess = median - baseline
        let saving = recent.reduce(0.0) { acc, s in
            let p = price(s)
            return acc + Double(excess) * (p.cacheWrite5m + Double(s.assistantTurns) * p.cacheRead) / 1_000_000
        }
        guard saving >= 0.25 else { return nil }
        var parts: [String] = []
        let md = files.filter { $0.exists && $0.kind != .memory }.map { ($0.path, approxTokens($0.path)) }.filter { $0.1 > 0 }
        let mdTokens = md.reduce(0) { $0 + $1.1 }
        if mdTokens > 0 { parts.append("CLAUDE.md and memory index files add up to about \(Fmt.tokens(mdTokens)) tokens") }
        if mcpServers > 0 { parts.append("\(mcpServers) MCP server\(mcpServers == 1 ? "" : "s") add their tool definitions") }
        return Improvement(
            id: "startup", title: "Trim what loads into every session", icon: "shippingbox", impact: .medium, savings: saving,
            finding: "A typical session starts with \(Fmt.tokens(median)) tokens of context before your first word. Every reply carries it." + (parts.isEmpty ? "" : " " + parts.joined(separator: "; ") + "."),
            why: "Instructions, tool schemas and memory are re-sent with every single reply. Shaving \(Fmt.tokens(excess)) off the start would save about \(Fmt.usd(saving)) this month.",
            fixes: [
                "Disable MCP servers you don't use in most projects (`/mcp`), or add them at project scope instead of user scope.",
                "Keep CLAUDE.md to the rules Claude needs every time. Move long reference material into a skill or a linked doc Claude reads only when relevant.",
                "Prune old auto-memories and disable plugins or skills you no longer use. Run `/context` in a session to see what takes up space.",
            ],
            files: md.sorted { $0.1 > $1.1 }.prefix(5).map { (path: $0.0, tokens: $0.1) },
            destination: ("Review MCP servers", .extensions(.mcp)))
    }

    /// Huge tool results (logs, full files, build output) sit in context and are re-read on every later reply.
    static func toolOutput(_ recent: [SessionSummary]) -> Improvement? {
        var byTool: [String: Int] = [:]
        for s in recent { for (k, v) in s.toolResultChars { byTool[k, default: 0] += v } }
        let large = recent.reduce(0) { $0 + $1.largeToolResults }
        let heavy = recent.compactMap { s -> (SessionSummary, Double)? in
            guard s.largeToolResults > 0 else { return nil }
            let p = price(s)
            let t = Double(s.toolResultChars.values.reduce(0, +)) / 4
            // Assume a third of that output was avoidable; it's written once and read back on about half the later replies.
            return (s, 0.33 * t * (p.cacheWrite5m + Double(s.assistantTurns) / 2 * p.cacheRead) / 1_000_000)
        }
        let saving = heavy.reduce(0) { $0 + $1.1 }
        guard large >= 3, saving >= 0.25 else { return nil }
        let worst = byTool.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \(Fmt.tokens($0.value / 4))" }.joined(separator: ", ")
        return Improvement(
            id: "tooloutput", title: "Keep tool output small", icon: "text.alignleft", impact: .medium, savings: saving,
            finding: "\(large) tool results were over 10K tokens each. Biggest sources: \(worst) tokens.",
            why: "Everything a tool returns stays in the conversation, so a 30K-token log is paid for again on every reply after it.",
            fixes: [
                "Ask for focused commands: `| tail -50`, `grep -n`, `--quiet`, or test runners that print only failures.",
                "Point Claude at the relevant function or line range instead of whole large files.",
                "Deny reads of generated files (`Read(./dist/**)`, lockfiles, minified bundles) in **Permissions**.",
            ],
            sessions: top(heavy) { s, _ in "\(s.largeToolResults) large results" },
            destination: ("Edit permissions", .extensions(.permissions)))
    }

    /// Failed tool calls each cost a full round trip.
    static func toolErrors(_ recent: [SessionSummary]) -> Improvement? {
        let calls = recent.reduce(0) { $0 + $1.toolCalls }, errors = recent.reduce(0) { $0 + $1.toolErrors }
        guard errors >= 10, calls > 0, Double(errors) / Double(calls) > 0.08 else { return nil }
        let bad = recent.compactMap { s -> (SessionSummary, Double)? in
            guard s.toolErrors > 0, s.assistantTurns > 0 else { return nil }
            return (s, Double(s.toolErrors) * s.cost / Double(s.assistantTurns))
        }
        let saving = bad.reduce(0) { $0 + $1.1 }
        return Improvement(
            id: "errors", title: "Cut down failed tool calls", icon: "exclamationmark.triangle", impact: .low, savings: saving,
            finding: "\(errors) of \(calls) tool calls failed (\(pct(Double(errors), Double(calls)))). Each failure is a wasted reply worth about \(Fmt.usd(saving / Double(max(errors, 1)))).",
            why: "A failed command or a denied permission still costs a full reply with the whole context, then another to retry.",
            fixes: [
                "Put the exact build, test and lint commands in CLAUDE.md so Claude doesn't guess.",
                "Allow commands you always approve in **Permissions** so they aren't denied and retried.",
                "Open the sessions below to see which tools fail most.",
            ],
            sessions: top(bad) { s, _ in "\(s.toolErrors) of \(s.toolCalls) failed" },
            destination: ("Edit permissions", .extensions(.permissions)))
    }

    /// Output (including extended thinking) is the priciest token type.
    static func outputHeavy(_ recent: [SessionSummary]) -> Improvement? {
        let total = recent.reduce(0) { $0 + $1.cost }
        let output = recent.reduce(0.0) { $0 + cost($1) { TokenUsage(output: $0.output) } }
        guard total > 1, output / total > 0.35 else { return nil }
        let saving = output * 0.25
        let heavy = recent.map { s in (s, cost(s) { TokenUsage(output: $0.output) }) }.filter { $0.1 > 0.1 }
        return Improvement(
            id: "output", title: "Ask for shorter answers", icon: "text.badge.minus", impact: .low, savings: saving,
            finding: "Output and thinking make up \(pct(output, total)) of your spend. Trimming a quarter of it would save about \(Fmt.usd(saving)).",
            why: "Output tokens cost 5× input tokens, and thinking counts as output.",
            fixes: [
                "Ask for diffs or the changed function, not whole rewritten files, and skip summaries you won't read.",
                "Add a line like *\"Be concise. No recap at the end.\"* to your personal CLAUDE.md.",
                "Use a lower effort or thinking level for routine edits, and save deep thinking for hard problems.",
            ],
            sessions: top(heavy) { s, v in "\(Fmt.tokens(s.tokens.output)) output · \(Fmt.usd(v))" },
            destination: ("Edit CLAUDE.md", .extensions(.memory)))
    }

    /// Individual instruction files that are big enough to matter.
    static func largeInstructionFiles(_ files: [InstructionFile]) -> Improvement? {
        let big = files.filter { $0.exists && $0.kind != .memory }.map { ($0.path, approxTokens($0.path)) }.filter { $0.1 >= 4_000 }
        guard !big.isEmpty else { return nil }
        return Improvement(
            id: "claudemd", title: "Slim down large CLAUDE.md files", icon: "doc.text.magnifyingglass", impact: .low, savings: 0,
            finding: "\(big.count) instruction file\(big.count == 1 ? " is" : "s are") over 4K tokens. \(big.count == 1 ? "It loads" : "They load") into every session in \(big.count == 1 ? "its" : "their") scope.",
            why: "CLAUDE.md is sent with every reply. Detail Claude only needs occasionally is cheaper as a skill or a separate doc it can open on demand.",
            fixes: [
                "Cut history, changelogs and long examples. Keep commands, conventions and gotchas.",
                "Move topic-specific guides into skills (`.claude/skills/<name>/SKILL.md`), which load only when relevant.",
            ],
            files: big.sorted { $0.1 > $1.1 }.map { (path: $0.0, tokens: $0.1) },
            destination: ("Edit CLAUDE.md", .extensions(.memory)))
    }

    /// ~4 characters per token.
    static func approxTokens(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) / 4
    }
}
