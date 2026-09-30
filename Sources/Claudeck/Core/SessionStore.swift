import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var live: [LiveSession] = []
    @Published private(set) var isLoading = true
    @Published private(set) var lastRefresh: Date?

    private let worker = SessionWorker()
    let search = SearchIndex()
    private var timer: Timer?
    private var refreshing = false

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let worker = worker
        Task.detached(priority: .utility) {
            let (sessions, changed) = worker.scan()
            let live = worker.scanLive()
            await MainActor.run {
                self.sessions = sessions
                self.live = live
                self.isLoading = false
                self.lastRefresh = Date()
                self.refreshing = false
                Notifier.shared.observe(live: live, sessions: self)
                self.search.update(sessions)
            }
            MemoryWriter.shared.sync(changed)
        }
    }

    func session(id: String) -> SessionSummary? { sessions.first { $0.id == id } }

    func liveSession(for sessionId: String) -> LiveSession? { live.first { $0.sessionId == sessionId } }

    var knownProjects: [String] {
        var seen = Set<String>(); var out: [String] = []
        for s in sessions { if let c = s.cwd, seen.insert(c).inserted { out.append(c) } }
        return out
    }

    var totalTokens: TokenUsage { sessions.reduce(TokenUsage()) { $0 + $1.tokens } }

    func cost(onDay day: String) -> Double { sessions.reduce(0) { $0 + $1.cost(onDay: day) } }

    /// Cost over the last `days` calendar days, including today.
    func cost(days: Int) -> Double {
        (0..<days).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
            .map { cost(onDay: Fmt.day.string(from: $0)) }.reduce(0, +)
    }

    func tokens(days: Int) -> TokenUsage {
        (0..<days).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
            .map { tokens(onDay: Fmt.day.string(from: $0)) }.reduce(TokenUsage(), +)
    }

    var projectKeys: [String: String] {
        var m: [String: String] = [:]
        for s in sessions { if let c = s.cwd { m[s.projectKey] = c } }
        return m
    }

    func tokens(onDay day: String) -> TokenUsage {
        sessions.reduce(TokenUsage()) { $0 + ($1.tokensByDay[day] ?? .init()) }
    }
}

/// Owns the incremental parse state. Only ever used from one detached task at a time.
final class SessionWorker: @unchecked Sendable {
    private var states: [String: IncrementalParse] = [:]
    private var subStates: [String: IncrementalParse] = [:]
    private let lock = NSLock()

    /// Returns all sessions plus those whose transcript changed since the previous scan.
    func scan() -> ([SessionSummary], [SessionSummary]) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        var results: [SessionSummary] = []
        var changed: [SessionSummary] = []
        let ignoreCwd: Set<String> = [Paths.appSupport.path, Paths.legacyAppSupport.path]

        let projectDirs = (try? fm.contentsOfDirectory(at: Paths.projectsDir, includingPropertiesForKeys: nil)) ?? []
        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let id = file.deletingPathExtension().lastPathComponent
                let state = states[file.path] ?? IncrementalParse(summary: SessionSummary(id: id, path: file, projectKey: dir.lastPathComponent))
                states[file.path] = state
                let before = state.offset
                SessionParser.advance(state, url: file)
                var summary = state.summary
                var didChange = state.offset != before

                // Subagent transcripts live in <session-id>/subagents/*.jsonl — add their tokens.
                let subDir = dir.appendingPathComponent(id).appendingPathComponent("subagents")
                if let subs = try? fm.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil) {
                    for sub in subs where sub.pathExtension == "jsonl" {
                        let st = subStates[sub.path] ?? IncrementalParse(summary: SessionSummary(id: sub.lastPathComponent, path: sub, projectKey: ""))
                        subStates[sub.path] = st
                        let b = st.offset
                        SessionParser.advance(st, url: sub, tokensOnly: true)
                        if st.offset != b { didChange = true }
                        summary.tokens += st.summary.tokens
                        for (k, v) in st.summary.tokensByModel { summary.tokensByModel[k, default: .init()] += v }
                        for (k, v) in st.summary.tokensByDay { summary.tokensByDay[k, default: .init()] += v }
                    }
                }

                if summary.isEmpty || ignoreCwd.contains(summary.cwd ?? "") { continue }
                results.append(summary)
                if didChange { changed.append(summary) }
            }
        }
        results.sort { ($0.end ?? $0.fileModified) > ($1.end ?? $1.fileModified) }
        return (results, changed)
    }

    func scanLive() -> [LiveSession] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Paths.liveSessionsDir, includingPropertiesForKeys: nil)) ?? []
        var out: [LiveSession] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = o["pid"] as? Int, let sid = o["sessionId"] as? String else { continue }
            guard kill(pid_t(pid), 0) == 0 else { continue } // process is gone
            if let cwd = o["cwd"] as? String, [Paths.appSupport.path, Paths.legacyAppSupport.path].contains(cwd) { continue }
            let ms: (String) -> Date? = { key in (o[key] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
            var remote = o["bridgeSessionId"] as? String
            if let r = remote, !r.hasPrefix("http") { remote = "https://claude.ai/code/\(r)" }
            out.append(LiveSession(pid: pid, sessionId: sid, cwd: o["cwd"] as? String ?? "",
                                   name: o["name"] as? String, status: o["status"] as? String ?? "unknown",
                                   kind: o["kind"] as? String, startedAt: ms("startedAt"),
                                   updatedAt: ms("statusUpdatedAt") ?? ms("updatedAt"),
                                   version: o["version"] as? String, remoteURL: remote))
        }
        return out.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }
}
