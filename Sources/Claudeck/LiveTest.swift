import Foundation
import AppKit

/// `Claudeck --livetest` runs end-to-end checks that talk to the real `claude` CLI (uses a few cheap Haiku calls).
enum LiveTest {
    static func run() -> Never {
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await body()
            done.signal()
        }
        // Keep the main run loop alive for MainActor work, timers and WebKit.
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        print(SelfTest.failures == 0 ? "\nALL PASSED" : "\n\(SelfTest.failures) FAILED")
        exit(SelfTest.failures == 0 ? 0 : 1)
    }

    @MainActor static func body() async {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { SelfTest.check(name, ok, detail) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("deck-live-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // 1. MCP add → list → details → remove, through the same code the UI uses.
        var d = MCPDraft(); d.name = "deck-selftest"; d.commandOrURL = "npx"; d.args = "-y @modelcontextprotocol/server-memory"
        d.env = [.init(key: "DECK_TEST", value: "1")]
        let add = await MCPManager.add(d)
        check("MCP add via CLI", add.ok, add.message.prefix(80).description)
        let list = Scanner.parseMCP(await CLI.run(["mcp", "list"]).out)
        check("MCP server listed", list.contains { $0.name == "deck-selftest" }, list.map(\.name).joined(separator: ", "))
        let det = await MCPManager.details("deck-selftest")
        check("MCP details show env + command", det.contains("npx") && det.contains("DECK_TEST"), det.split(separator: "\n").prefix(3).joined(separator: " / "))
        let rm = await MCPManager.remove("deck-selftest", scope: "user", projectDir: nil)
        check("MCP remove", rm.ok, rm.message.prefix(60).description)
        check("MCP gone", !Scanner.parseMCP(await CLI.run(["mcp", "list"]).out).contains { $0.name == "deck-selftest" })
        var h = MCPDraft(); h.name = "deck-selftest-http"; h.transport = .http; h.commandOrURL = "https://example.com/mcp"
        h.headers = [.init(key: "X-Deck-Test", value: "yes")]
        let addH = await MCPManager.add(h)
        let detH = await MCPManager.details("deck-selftest-http")
        check("MCP http + header added", addH.ok && detH.contains("example.com") && detH.contains("X-Deck-Test"), addH.message.prefix(60).description)
        check("MCP http removed", (await MCPManager.remove("deck-selftest-http", scope: "user", projectDir: nil)).ok)

        // 2. A schedule fires and runs a real headless Claude prompt.
        let runner = ClaudeRunner()
        let library = Library()
        let saved = (library.templates, library.schedules)
        library.runner = runner
        let t = PromptTemplate(name: "livetest", prompt: "Reply with exactly: DECK-OK", cwd: tmp.path, model: "haiku", permissionMode: "plan")
        library.templates.append(t)
        var s = Schedule(templateID: t.id); s.kind = .interval; s.intervalMinutes = 5
        library.schedules.append(s)
        library.tick()
        check("schedule fired a run", runner.runs.count == 1 && library.schedules.last?.lastRun != nil)
        if let run = runner.runs.first {
            let deadline = Date().addingTimeInterval(120)
            while run.state == .running && Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
            check("scheduled run finished", run.state == .done, "\(run.state)")
            check("streamed reply", run.events.contains { $0.text.contains("DECK-OK") }, run.finalText ?? "")
            check("run tokens + cost captured", run.tokens.total > 0 && (run.costUSD ?? 0) > 0, "\(Fmt.tokens(run.tokens.total)), \(Fmt.usd(run.costUSD ?? 0))")
            check("run got a session id", run.sessionId != nil)
        }
        library.tick()
        check("schedule doesn't refire immediately", runner.runs.count == 1)
        library.templates = saved.0; library.schedules = saved.1

        // 3. Weekly digest via the CLI.
        let (sessions, _) = SessionWorker().scan()
        do {
            let url = try await Digest.generate(sessions: sessions, days: 7)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            check("digest generated", text.contains("Highlights") || text.contains("highlights"), "\(url.lastPathComponent), \(text.count) chars")
        } catch { check("digest generated", false, error.localizedDescription) }

        // 4. PDF export through WebKit.
        let pdf = tmp.appendingPathComponent("x.pdf")
        do {
            try await Exporter.pdf(markdown: "# Title\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- one\n- **two**", title: "t", to: pdf)
            let head = (try? Data(contentsOf: pdf))?.prefix(4)
            check("export .pdf", head == Data("%PDF".utf8), "\((try? Data(contentsOf: pdf))?.count ?? 0) bytes")
        } catch { check("export .pdf", false, error.localizedDescription) }

        // 5. Permission bridge: a real `claude -p` run asks permission through our hook; we answer Allow.
        let bridge = PermissionBridge()
        let marker = tmp.appendingPathComponent("approved.txt")
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let hookSettings = #"{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"\#(Handoff.shellQuote(exe)) --hook permission","timeout":40}]}]}}"#
        let claudeTask = Task.detached {
            await CLI.run(["-p", "Use the Bash tool to run exactly this command and nothing else: touch \(marker.path)",
                           "--model", "haiku", "--permission-mode", "default", "--no-session-persistence",
                           "--settings", hookSettings, "--allowedTools", ""], cwd: tmp)
        }
        var answered: PermissionRequest?
        let deadline = Date().addingTimeInterval(90)
        while answered == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))   // let the bridge's timer poll
            if let r = bridge.pending.first(where: { $0.toolName == "Bash" }) { answered = r; bridge.answer(r, allow: true) }
        }
        check("permission request reached the app", answered != nil, answered.map { "\($0.toolName): \($0.summary)" } ?? "none")
        let res = await claudeTask.value
        check("approved command actually ran", FileManager.default.fileExists(atPath: marker.path), res.out.prefix(80).description)

        // 6. …and Deny blocks it.
        let marker2 = tmp.appendingPathComponent("denied.txt")
        let t2 = Task.detached {
            await CLI.run(["-p", "Use the Bash tool to run exactly this command and nothing else: touch \(marker2.path). If it is denied, just say DENIED.",
                           "--model", "haiku", "--permission-mode", "default", "--no-session-persistence",
                           "--settings", hookSettings], cwd: tmp)
        }
        var denied = false
        let d2 = Date().addingTimeInterval(90)
        while !denied && Date() < d2 {
            try? await Task.sleep(for: .milliseconds(300))
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            if let r = bridge.pending.first(where: { $0.toolName == "Bash" }) { bridge.answer(r, allow: false); denied = true }
        }
        _ = await t2.value
        check("denied command did not run", denied && !FileManager.default.fileExists(atPath: marker2.path))

        // 7. Hook falls back instantly when the app isn't running.
        try? "999999".write(to: HookMode.aliveFile, atomically: true, encoding: .utf8)
        let start = Date()
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["--hook", "permission"]
        let inp = Pipe(); p.standardInput = inp; p.standardOutput = Pipe()
        try? p.run(); inp.fileHandleForWriting.write(Data(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)); try? inp.fileHandleForWriting.close()
        p.waitUntilExit()
        check("hook falls back to terminal when app closed", Date().timeIntervalSince(start) < 3 && p.terminationStatus == 0,
              String(format: "%.2fs", Date().timeIntervalSince(start)))
        try? String(ProcessInfo.processInfo.processIdentifier).write(to: HookMode.aliveFile, atomically: true, encoding: .utf8)

        try? FileManager.default.removeItem(at: tmp)
        // Remove the transcripts the test runs created so they don't show up as sessions.
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: Paths.projectsDir.path)) ?? [] where dir.contains("deck-live-") {
            try? FileManager.default.removeItem(at: Paths.projectsDir.appendingPathComponent(dir))
        }
    }
}
