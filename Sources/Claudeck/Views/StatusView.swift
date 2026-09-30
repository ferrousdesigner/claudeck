import SwiftUI

struct StatusView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var runner: ClaudeRunner
    @EnvironmentObject var bridge: PermissionBridge

    private var today: String { Fmt.day.string(from: Date()) }
    private var todaySessions: [SessionSummary] {
        sessions.sessions.filter { ($0.end ?? .distantPast) > Calendar.current.startOfDay(for: Date()) }
    }
    private var weekTokens: Int {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
            .map { sessions.tokens(onDay: Fmt.day.string(from: $0)).total }.reduce(0, +)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if !bridge.pending.isEmpty {
                    Label("Waiting for your approval", systemImage: "hand.raised").font(.headline)
                    ForEach(bridge.pending) { r in PermissionCard(request: r) }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    Metric(title: "Running now", value: "\(sessions.live.count)",
                           caption: "\(sessions.live.filter(\.isBusy).count) working · \(sessions.live.filter { !$0.isBusy }.count) idle",
                           icon: "bolt.horizontal.circle", tint: sessions.live.contains(where: \.isBusy) ? .orange : .green)
                    Metric(title: "Spent today", value: Fmt.usd(sessions.cost(onDay: today)),
                           caption: "\(Fmt.tokens(sessions.tokens(onDay: today).total)) tokens", icon: "dollarsign.circle")
                    Metric(title: "Last 7 days", value: Fmt.usd(sessions.cost(days: 7)), caption: "\(Fmt.tokens(weekTokens)) tokens", icon: "calendar")
                    Metric(title: "Sessions today", value: "\(todaySessions.count)",
                           caption: "\(sessions.sessions.count) all time", icon: "books.vertical")
                }

                BudgetBars()

                sectionTitle("Live sessions", "terminal")
                if sessions.live.isEmpty {
                    Card { Text("No Claude Code sessions are running. Start one in a terminal, or use Ask Claude below.").foregroundStyle(.secondary) }
                }
                ForEach(sessions.live) { l in LiveSessionCard(live: l, summary: sessions.session(id: l.sessionId)) }

                if !runner.runs.isEmpty {
                    HStack {
                        sectionTitle("Prompts sent from Claudeck", "paperplane")
                        Spacer()
                        Button("Clear finished") { runner.clearFinished() }.buttonStyle(.link)
                    }
                    let groups = Dictionary(grouping: runner.runs.filter { $0.groupID != nil }, by: { $0.groupID! })
                    ForEach(Array(groups.keys), id: \.self) { g in WorktreeCompare(runs: groups[g]!.sorted { $0.title < $1.title }) }
                    ForEach(runner.runs.filter { $0.groupID == nil }) { run in RunCard(run: run) }
                }

                sectionTitle("Recent activity", "clock")
                VStack(spacing: 0) {
                    ForEach(sessions.sessions.prefix(8)) { s in
                        Button { state.openSession(s.id) } label: { SessionRow(s: s, live: sessions.liveSession(for: s.id)) }
                            .buttonStyle(.plain)
                        Divider()
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(24)
        }
        .fabClearance()
        .overlay { if sessions.isLoading { ProgressView("Reading your Claude Code history…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Current status").font(.largeTitle.weight(.bold))
                Text(statusLine).foregroundStyle(.secondary)
            }
            Spacer()
            Button { sessions.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    private var statusLine: String {
        let busy = sessions.live.filter(\.isBusy)
        if let b = busy.first {
            let title = sessions.session(id: b.sessionId)?.title ?? (b.cwd as NSString).lastPathComponent
            return busy.count == 1 ? "Claude is working on “\(title)”" : "Claude is working in \(busy.count) sessions"
        }
        if !sessions.live.isEmpty { return "All sessions idle, waiting for you" }
        return "Nothing running right now"
    }

    private func sectionTitle(_ t: String, _ icon: String) -> some View {
        Label(t, systemImage: icon).font(.headline).padding(.top, 4)
    }
}

struct LiveSessionCard: View {
    @EnvironmentObject var state: AppState
    let live: LiveSession
    let summary: SessionSummary?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    StatusDot(busy: live.isBusy)
                    Text(summary?.title ?? live.name ?? "Session").font(.title3.weight(.semibold)).lineLimit(1)
                    Text(live.isBusy ? "WORKING" : "IDLE")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((live.isBusy ? Color.orange : .green).opacity(0.15), in: Capsule())
                        .foregroundStyle(live.isBusy ? .orange : .green)
                    Spacer()
                    if let s = summary {
                        Text("\(Fmt.tokens(s.tokens.total)) tokens · \(Fmt.usd(s.cost))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 14) {
                    Label((live.cwd as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    if let b = summary?.gitBranch { Label(b, systemImage: "arrow.triangle.branch") }
                    Label("PID \(live.pid)", systemImage: "cpu")
                    Label("up \(Fmt.duration(live.startedAt, Date()))", systemImage: "timer")
                    if let v = live.version { Text("v\(v)") }
                }
                .font(.caption).foregroundStyle(.secondary)

                if let p = summary?.lastPrompt {
                    HStack(alignment: .top) {
                        Text("Last prompt").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        Text(p).lineLimit(2)
                    }
                }
                if let a = summary?.lastActivity {
                    HStack(alignment: .top) {
                        Text("Latest").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        Text(a).lineLimit(3).foregroundStyle(.primary.opacity(0.85))
                    }
                }
                if let s = summary { ContextMeter(used: s.lastContextTokens, window: s.contextWindow).frame(maxWidth: 360) }
                HStack {
                    Text("Status changed \(Fmt.ago(live.updatedAt))").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    if let url = live.remoteURL.flatMap(URL.init(string:)) {
                        Link(destination: url) { Label("Open remote", systemImage: "iphone") }.font(.caption)
                    }
                    if let s = summary {
                        Button("Open in Terminal") { Handoff.resumeInTerminal(s) }.font(.caption)
                            .help("Opens a new terminal tab resuming this session. Close the original first to avoid two copies.")
                    }
                    Button("Open memory") { state.openSession(live.sessionId) }.font(.caption)
                }
            }
        }
    }
}

struct RunCard: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var run: PromptRun
    @State private var expanded = true

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    stateIcon
                    Text(run.title).font(.headline).lineLimit(1)
                    Spacer()
                    if run.tokens.total > 0 { Text(Fmt.tokens(run.tokens.total) + " tokens").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    if let c = run.costUSD { Text(String(format: "$%.3f", c)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    if run.state == .running { Button("Stop", role: .destructive) { run.cancel() } }
                    Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }.buttonStyle(.borderless)
                }
                Text("\((run.cwd as NSString).abbreviatingWithTildeInPath)\(run.resumeId != nil ? " · continuing session" : " · new session") · \(Fmt.ago(run.startedAt))")
                    .font(.caption).foregroundStyle(.secondary)
                if expanded {
                    RunLog(run: run).frame(maxHeight: 260)
                }
                if let sid = run.sessionId, run.state != .running {
                    HStack {
                        Spacer()
                        Button("Open memory") { state.openSession(sid) }.font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch run.state {
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        }
    }
}

struct RunLog: View {
    @ObservedObject var run: PromptRun
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(run.events) { e in
                        Group {
                            switch e.kind {
                            case .text, .result:
                                Text(LocalizedStringKey(e.text)).textSelection(.enabled)
                            case .tool:
                                Text(e.text).font(.caption.monospaced()).foregroundStyle(.secondary)
                            case .error:
                                Text(e.text).foregroundStyle(.red).textSelection(.enabled)
                            case .info:
                                Text(e.text).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(e.id)
                    }
                    if run.state == .running {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Working…").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .padding(10)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: run.events.count) { _, _ in
                if let last = run.events.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}

struct SessionRow: View {
    let s: SessionSummary
    var live: LiveSession? = nil
    var body: some View {
        HStack(spacing: 12) {
            if let live { StatusDot(busy: live.isBusy) } else { Circle().fill(.quaternary).frame(width: 8, height: 8) }
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title).lineLimit(1).font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Text(s.projectName)
                    if let b = s.gitBranch { Text("· \(b)") }
                    Text("· \(s.userTurns) prompts")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.tokens(s.tokens.total)).font(.callout.monospacedDigit().weight(.medium))
                Text(Fmt.ago(s.end)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}


/// Side-by-side view of the same prompt run in several git worktrees.
struct WorktreeCompare: View {
    let runs: [PromptRun]
    @State private var stats: [UUID: String] = [:]
    @State private var removed = Set<UUID>()

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Parallel attempts", systemImage: "square.split.2x2").font(.headline)
                    Text(runs.first?.prompt.prefix(60) ?? "").foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Refresh diffs") { refresh() }.controlSize(.small)
                }
                HStack(alignment: .top, spacing: 10) {
                    ForEach(runs) { run in
                        AttemptColumn(run: run, stat: stats[run.id] ?? "…", removed: removed.contains(run.id)) {
                            if Worktrees.remove(run.cwd) { removed.insert(run.id) }
                        }
                    }
                }
                Text("Each attempt is on its own branch. To keep one: open its folder, review, then merge its branch (e.g. git merge deck/…) in your main checkout. Remove the others when done.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: runs.map { $0.state == .running }) { _, _ in refresh() }
    }

    private func refresh() {
        for r in runs { let p = r.cwd; let id = r.id
            Task.detached { let s = Worktrees.diffStat(p); await MainActor.run { stats[id] = s } }
        }
    }
}

struct AttemptColumn: View {
    @ObservedObject var run: PromptRun
    let stat: String
    let removed: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                switch run.state {
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                default: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Text(run.title.components(separatedBy: " · ").first ?? "").font(.headline)
                Spacer()
                if run.tokens.total > 0 { Text(Fmt.usd(run.costUSD ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            Text(stat).font(.caption.monospaced()).lineLimit(6).frame(maxWidth: .infinity, alignment: .leading)
                .padding(6).background(.background, in: RoundedRectangle(cornerRadius: 6))
            Text(run.finalText ?? "").font(.caption).lineLimit(6).foregroundStyle(.secondary)
            HStack {
                Button("Open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: run.cwd)) }.controlSize(.small).disabled(removed)
                Spacer()
                Button(removed ? "Removed" : "Remove", role: .destructive, action: onRemove).controlSize(.small).disabled(removed || run.state == .running)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}
