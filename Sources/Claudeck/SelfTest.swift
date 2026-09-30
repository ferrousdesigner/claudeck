import Foundation

/// `Claudeck --selftest` exercises the non-UI features against real data and temp files, printing PASS/FAIL.
enum SelfTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail().isEmpty ? "" : "  — \(detail())")")
    }

    static func run() -> Never {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("deck-selftest-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let (sessions, _) = SessionWorker().scan()
        check("sessions parsed", !sessions.isEmpty, "\(sessions.count) sessions")

        // Pricing
        let u = TokenUsage(input: 1_000_000, output: 1_000_000, cacheCreate: 1_000_000, cacheRead: 1_000_000, cacheCreate1h: 1_000_000)
        let opus55 = Pricing.cost(u, model: "claude-opus-5-5")
        check("pricing opus 5.5 (4 + 20 + 8 + 0.2)", abs(opus55 - 32.2) < 0.001, Fmt.usd(opus55))
        let haiku = Pricing.cost(TokenUsage(input: 1_000_000, output: 0, cacheCreate: 1_000_000, cacheRead: 0), model: "claude-haiku-4-5-20251001")
        check("pricing haiku 5m cache write (1 + 1.25)", abs(haiku - 2.25) < 0.001, Fmt.usd(haiku))
        check("pricing fable", Pricing.price(for: "claude-fable-5-1").output == 50)
        check("pricing opus 5", Pricing.price(for: "claude-opus-5").input == 5)
        let total = sessions.reduce(0) { $0 + $1.cost }
        check("all-time API-equivalent cost > 0", total > 0, Fmt.usd(total))
        for s in sessions.sorted(by: { $0.cost > $1.cost }).prefix(3) { print("      \(s.shortID) \(Fmt.usd(s.cost))  \(s.title)") }
        let dayCost = sessions.reduce(0.0) { acc, s in acc + s.tokensByDay.keys.reduce(0) { $0 + s.cost(onDay: $1) } }
        check("per-day costs add up to total", abs(dayCost - total) < 0.01 * max(total, 1), "\(Fmt.usd(dayCost)) vs \(Fmt.usd(total))")

        // Stats
        let tools = sessions.reduce(into: [String: Int]()) { acc, s in for (k, v) in s.toolCounts { acc[k, default: 0] += v } }
        check("tool usage counted", (tools["Bash"] ?? 0) > 0, tools.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        let hours = sessions.reduce(into: [Int: Int]()) { acc, s in for (k, v) in s.hourCounts { acc[k, default: 0] += v } }
        check("prompt hours counted", hours.values.reduce(0, +) == sessions.reduce(0) { $0 + $1.userTurns }, "\(hours.values.reduce(0, +)) prompts")
        let live = sessions.max { $0.fileModified < $1.fileModified }!
        check("context size of latest session", live.lastContextTokens > 0, "\(Fmt.tokens(live.lastContextTokens)) of \(Fmt.tokens(live.contextWindow))")

        // Improvements
        check("starting context recorded", sessions.contains { $0.firstContextTokens > 0 }, "median \(Fmt.tokens(sessions.map(\.firstContextTokens).sorted()[sessions.count / 2]))")
        check("tool result sizes attributed", sessions.contains { !$0.toolResultChars.isEmpty && $0.toolResultChars["tool"] == nil })
        let advisorFiles = InstructionFiles.all(projects: Array(Set(sessions.compactMap(\.cwd))), projectKeys: [:])
        let report = CostAdvisor.analyze(sessions: sessions, instructionFiles: advisorFiles, mcpServers: 0)
        check("advisor savings don't exceed spend", report.totalSavings <= report.cost, "\(Fmt.usd(report.totalSavings)) of \(Fmt.usd(report.cost)), \(report.improvements.count) suggestions")
        for i in report.improvements { print("      [\(i.impact.label)] \(i.title) ~\(Fmt.usd(i.savings)) — \(i.finding)") }
        for s in report.strengths { print("      ✓ \(s)") }

        // Search
        let store = SearchStorage()
        _ = store.update(sessions)
        let hits = store.search("shoppio", limit: 50)
        check("full-text search finds 'shoppio'", !hits.isEmpty, "\(hits.count) hits, e.g. “\(hits.first?.snippet.prefix(70) ?? "")”")
        check("multi-word search", !store.search("clone repo", limit: 5).isEmpty)
        check("search misses nonsense", store.search("zzqxj-not-a-word", limit: 5).isEmpty)

        // Settings: hooks + permissions round trip on a temp file
        let sf = tmp.appendingPathComponent("settings.json")
        try? #"{"theme":"dark","env":{"A":"1"}}"#.write(to: sf, atomically: true, encoding: .utf8)
        let hook = ClaudeSettings.HookEntry(event: "PostToolUse", matcher: "Edit|Write", command: "npx prettier --write \"$CLAUDE_FILE_PATHS\"", timeout: 30)
        try? ClaudeSettings.addHook(hook, to: sf)
        try? ClaudeSettings.addHook(hook, to: sf) // duplicate is ignored
        check("hook added once", ClaudeSettings.hooks(sf).count == 1)
        check("other settings kept", (ClaudeSettings.read(sf)["theme"] as? String) == "dark" && (ClaudeSettings.read(sf)["env"] as? [String: String])?["A"] == "1")
        check("backup written", FileManager.default.fileExists(atPath: sf.path + ".claudeck.bak"))
        try? ClaudeSettings.removeHook(hook, from: sf)
        check("hook removed and empty keys cleaned", ClaudeSettings.hooks(sf).isEmpty && ClaudeSettings.read(sf)["hooks"] == nil)
        var perm = ClaudeSettings.Permissions(allow: ["Bash(npm test:*)", "Bash"], deny: ["Read(./.env)"], defaultMode: "acceptEdits")
        try? ClaudeSettings.setPermissions(perm, sf)
        check("permissions round trip", ClaudeSettings.permissions(sf) == perm)
        let risks = ClaudeSettings.risks(perm, settings: [:])
        check("risk: blanket Bash flagged", risks.contains { $0.contains("every shell command") })
        check("no .env warning when denied", !risks.contains { $0.contains(".env") })
        perm.deny = []
        check("risk: .env unprotected flagged", ClaudeSettings.risks(perm, settings: [:]).contains { $0.contains(".env") })

        // MCP
        var d = MCPDraft(); d.name = "pg"; d.commandOrURL = "npx"; d.args = "-y @x/server \"postgres://a b\""
        d.env = [.init(key: "TOKEN", value: "abc")]
        check("mcp stdio args", d.cliArgs == ["mcp", "add", "--scope", "user", "--transport", "stdio", "pg", "-e", "TOKEN=abc", "--", "npx", "-y", "@x/server", "postgres://a b"], d.cliArgs.joined(separator: " "))
        var h = MCPDraft(); h.name = "sentry"; h.transport = .http; h.commandOrURL = "https://mcp.sentry.dev/mcp"; h.headers = [.init(key: "Authorization", value: "Bearer x")]
        check("mcp http args", h.cliArgs == ["mcp", "add", "--scope", "user", "--transport", "http", "sentry", "https://mcp.sentry.dev/mcp", "-H", "Authorization: Bearer x"])
        check("mcp validation", !MCPDraft().isValid && d.isValid)
        check("mcp list parse", Scanner.parseMCP("Checking MCP server health…\n\nfoo: npx foo - ✔ Connected\nbar: https://x/mcp - ✗ Failed to connect").count == 2)

        // Plugins
        let plugins = Scanner.marketplacePlugins()
        let bundled = plugins.first { $0.name == "code-review" }
        check("marketplace plugins listed", plugins.count > 100, "\(plugins.count) plugins")
        check("plugin offline details include README", bundled?.offlineDetails.contains("Contains: commands") == true && (bundled?.offlineDetails.count ?? 0) > 300)

        // Library
        let t = PromptTemplate(name: "t", prompt: "Write tests for {{file}} in {{ lang }} and {{file}}")
        check("template variables", t.variables == ["file", "lang"], t.variables.joined(separator: ","))
        check("template fill", t.filled(["file": "a.swift", "lang": "Swift"]) == "Write tests for a.swift in Swift and a.swift")
        let cal = Calendar.current
        let monday9 = cal.nextDate(after: Date(), matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime)!
        var sch = Schedule(templateID: t.id)
        check("schedule due at 9:00 on a weekday", sch.isDue(now: monday9.addingTimeInterval(30)))
        sch.lastRun = monday9.addingTimeInterval(30)
        check("schedule not due twice", !sch.isDue(now: monday9.addingTimeInterval(120)))
        check("schedule next fire is Tuesday 9:00", sch.nextFire(after: monday9.addingTimeInterval(60)) == monday9.addingTimeInterval(86400))
        let saturday = cal.nextDate(after: Date(), matching: DateComponents(hour: 9, minute: 0, weekday: 7), matchingPolicy: .nextTime)!
        check("weekday schedule skips Saturday", !Schedule(templateID: t.id).isDue(now: saturday.addingTimeInterval(30)))
        var iv = Schedule(templateID: t.id); iv.kind = .interval; iv.intervalMinutes = 30; iv.lastRun = Date().addingTimeInterval(-29 * 60)
        check("interval schedule waits", !iv.isDue(now: Date()))
        iv.lastRun = Date().addingTimeInterval(-31 * 60)
        check("interval schedule fires", iv.isDue(now: Date()))

        // File history
        if let s = sessions.max(by: { FileHistory.changes(for: $0).count < FileHistory.changes(for: $1).count }) {
            let ch = FileHistory.changes(for: s)
            check("file history: changed files found", !ch.isEmpty, "\(ch.count) files in “\(s.title)”")
            if let f = ch.first(where: { !$0.wasCreated && $0.exists }) ?? ch.first {
                let diff = FileHistory.diff(f)
                let st = FileHistory.stats(diff)
                check("file history: diff", !diff.isEmpty, "\((f.path as NSString).lastPathComponent) +\(st.added) −\(st.removed)")
            }
        }
        let rf = tmp.appendingPathComponent("restore.txt")
        try? "new".write(to: rf, atomically: true, encoding: .utf8)
        let backup = tmp.appendingPathComponent("backup@v1"); try? "old".write(to: backup, atomically: true, encoding: .utf8)
        try? FileHistory.restore(ChangedFile(path: rf.path, originalBackup: backup, firstEdit: nil))
        check("file history: restore", (try? String(contentsOf: rf, encoding: .utf8)) == "old")

        // Security scan
        let fake = tmp.appendingPathComponent("fake.jsonl")
        let key = "sk-ant-api03-" + String(repeating: "A1b2", count: 8)
        try? """
        {"type":"user","timestamp":"2026-09-01T10:00:00Z","message":{"content":"my key is \(key) ok"}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/p/.env"}}]}}
        {"type":"user","message":{"content":"DATABASE_URL=postgres://admin:hunter22@db.example.com/app"}}
        """.write(to: fake, atomically: true, encoding: .utf8)
        let findings = SecurityScan.scan([SessionSummary(id: "fake", path: fake, projectKey: "x")])
        check("security: API key found and masked", findings.contains { $0.kind == "Anthropic API key" && !$0.masked.contains("A1b2A1b2") })
        check("security: .env read found", findings.contains { $0.kind == "Read a sensitive file" && $0.masked.contains(".env") })
        check("security: DB password found", findings.contains { $0.kind == "Database URL with password" })
        let real = SecurityScan.scan(sessions)
        check("security: scanned real sessions", true, "\(real.count) findings: " + Dictionary(grouping: real, by: \.kind).map { "\($0.key) \($0.value.count)" }.joined(separator: ", "))

        // Projects
        let health = Projects.health(sessions)
        check("project health", !health.isEmpty, health.prefix(4).map { "\($0.name) \($0.git.isRepo ? "git:\($0.git.branch ?? "?") Δ\($0.git.changedFiles)" : "no git")" }.joined(separator: "; "))
        let deck = Projects.gitStatus(FileManager.default.currentDirectoryPath)
        check("git status on the current folder", deck.isRepo && deck.changedFiles > 0, "branch \(deck.branch ?? "?"), \(deck.changedFiles) changed")

        // Worktrees on a scratch repo
        let repo = tmp.appendingPathComponent("repo").path
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = Projects.git(repo, ["init", "-q"]); try? "hi".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        _ = Projects.git(repo, ["add", "."]); _ = Projects.git(repo, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"])
        if let wts = try? Worktrees.create(repo: repo, count: 2, slug: "Fix bug!") {
            check("worktrees created", wts.count == 2 && wts.allSatisfy { FileManager.default.fileExists(atPath: $0.path + "/a.txt") }, wts.map(\.branch).joined(separator: ", "))
            try? "changed".write(toFile: wts[0].path + "/a.txt", atomically: true, encoding: .utf8)
            check("worktree diff stat", Worktrees.diffStat(wts[0].path).contains("a.txt") && Worktrees.diffStat(wts[1].path) == "No changes")
            check("worktrees removed", wts.allSatisfy { Worktrees.remove($0.path) } && !FileManager.default.fileExists(atPath: wts[0].path))
        } else { check("worktrees created", false) }

        // Instruction files
        let files = InstructionFiles.all(projects: Array(Set(sessions.compactMap(\.cwd))), projectKeys: Dictionary(sessions.map { ($0.projectKey, $0.cwd ?? "") }, uniquingKeysWith: { a, _ in a }))
        check("instruction files listed", files.contains { $0.kind == .memory }, "\(files.filter(\.exists).count) existing, \(files.filter { $0.kind != .claudeMD }.count) memories")
        var realStale: [(String, StaleReference)] = []
        for f in files where f.exists {
            if let t = try? String(contentsOfFile: f.path, encoding: .utf8) { realStale += InstructionFiles.staleReferences(in: t, file: f).map { (f.name, $0) } }
        }
        print("      real stale refs: \(realStale.count), e.g. " + realStale.prefix(6).map { "\($0.0): \($0.1.reference)" }.joined(separator: " | "))
        let memFile = InstructionFile(path: tmp.path + "/m.md", kind: .memory, scope: "t", projectDir: tmp.path, exists: true)
        let stale = InstructionFiles.staleReferences(in: "see `src/missing/file.ts` and `/Users/nobody/x.swift` and [[ghost-memory]]\nok `\(tmp.path)` `origin/main` `/api/sheet` `spaces/AAQ`", file: memFile)
        check("stale references found (no false positives)", stale.count == 2, stale.map(\.reference).joined(separator: " | "))

        // Creator
        let skillURL = try? Creator.create(kind: .skill, name: "deck-test", projectDir: tmp.path,
                                           content: Creator.template(kind: .skill, name: "deck-test", description: "Use when \"testing\"", body: "", tools: "", model: ""))
        let fm = skillURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(Scanner.frontmatter) ?? [:]
        check("skill created with valid frontmatter", fm["name"] == "deck-test" && fm["description"]?.contains("testing") == true, skillURL?.path ?? "")
        check("creator refuses to overwrite", (try? Creator.create(kind: .skill, name: "deck-test", projectDir: tmp.path, content: "")) == nil)

        // Export
        if let s = sessions.first(where: { Summarizer.cached(for: $0) != nil }) ?? sessions.first {
            let md = (try? String(contentsOf: MemoryWriter.shared.docURL(for: s), encoding: .utf8)) ?? "# Test\n\n- a\n- b"
            let docx = tmp.appendingPathComponent("out.docx")
            try? Exporter.docx(markdown: md, title: s.title, to: docx)
            let size = (try? FileManager.default.attributesOfItem(atPath: docx.path)[.size] as? Int) ?? 0
            check("export .docx", size > 2000, "\(size) bytes")
            let html = Exporter.html(fromMarkdown: md, title: s.title)
            check("export html has table + list", html.contains("<table>") && html.contains("<li>"))
        }

        // Guide: every screen has help, topic ids are unique, and all guide markdown parses.
        let missing = Tab.allCases.filter { Guide.topic(for: $0) == nil }
        check("guide covers every tab", missing.isEmpty, missing.map(\.rawValue).joined(separator: ", "))
        check("guide topic ids unique", Set(Guide.topics.map(\.id)).count == Guide.topics.count)
        let texts = Guide.topics.flatMap { [$0.summary] + $0.steps + $0.tips }
        let bad = texts.filter { (try? AttributedString(markdown: $0, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) == nil || $0.contains("**") && (try? AttributedString(markdown: $0, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))?.description.contains("**") == true }
        check("guide markdown renders", bad.isEmpty, bad.first ?? "\(texts.count) paragraphs")
        check("walkthrough ends on setup", WalkthroughView.pages.last?.icon == "checklist", "\(WalkthroughView.pages.count) pages")

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        try? FileManager.default.removeItem(at: tmp)
        exit(failures == 0 ? 0 : 1)
    }
}
