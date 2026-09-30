import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var runner: ClaudeRunner
    @EnvironmentObject var bridge: PermissionBridge
    @EnvironmentObject var library: Library

    private var today: String { Fmt.day.string(from: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Color.deckAccent)
                Text("Claudeck").font(.headline)
                Spacer()
                Button { AppDelegate.showMainWindow() } label: { Image(systemName: "macwindow") }.buttonStyle(.borderless).help("Open dashboard")
            }

            if !bridge.pending.isEmpty {
                ForEach(bridge.pending) { r in PermissionCard(request: r, compact: true) }
            }

            HStack(spacing: 10) {
                mini("Today", Fmt.usd(sessions.cost(onDay: today)), Fmt.tokens(sessions.tokens(onDay: today).total) + " tokens")
                mini("7 days", Fmt.usd(sessions.cost(days: 7)), Fmt.tokens(sessions.tokens(days: 7).total) + " tokens")
            }
            BudgetBars(compact: true)

            Divider()
            Text("LIVE").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            if sessions.live.isEmpty && runner.activeCount == 0 {
                Text("Nothing running").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(sessions.live) { l in
                let s = sessions.session(id: l.sessionId)
                Button { state.openSession(l.sessionId) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        StatusDot(busy: l.isBusy).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s?.title ?? l.name ?? "Session").lineLimit(1).font(.callout.weight(.medium))
                            Text(s?.lastActivity ?? (l.cwd as NSString).lastPathComponent).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                            if let s { ContextMeter(used: s.lastContextTokens, window: s.contextWindow, compact: true) }
                        }
                        Spacer()
                        Text(l.isBusy ? "working" : "idle").font(.caption2).foregroundStyle(l.isBusy ? .orange : .green)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(runner.runs.filter { $0.state == .running }) { r in
                HStack { ProgressView().controlSize(.mini); Text(r.title).lineLimit(1).font(.callout); Spacer() }
            }

            if !library.schedules.filter(\.enabled).isEmpty {
                Divider()
                let next = library.schedules.compactMap { s in s.nextFire(after: Date()).map { (s, $0) } }.min { $0.1 < $1.1 }
                if let (s, at) = next, let t = library.template(s.templateID) {
                    Label("Next: \(t.name) \(Fmt.ago(at))", systemImage: "alarm").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack {
                Button { state.compose() } label: { Label("Ask Claude", systemImage: "sparkle") }
                    .buttonStyle(.borderedProminent).tint(.deckAccent)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func mini(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PermissionCard: View {
    @EnvironmentObject var bridge: PermissionBridge
    @EnvironmentObject var sessions: SessionStore
    let request: PermissionRequest
    var compact = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Claude wants to use \(request.toolName)").font(compact ? .callout.weight(.semibold) : .headline)
                Spacer()
                let left = max(0, Int(HookMode.waitSeconds - now.timeIntervalSince(request.created)))
                Text("\(left)s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("After this the question goes back to the terminal")
            }
            Text(request.summary).font(.caption.monospaced()).lineLimit(compact ? 3 : 8).textSelection(.enabled)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text("\(sessions.session(id: request.sessionID)?.title ?? (request.cwd as NSString).lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Deny", role: .destructive) { bridge.answer(request, allow: false) }
                Button("Allow") { bridge.answer(request, allow: true) }.buttonStyle(.borderedProminent).tint(.green)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.4)))
        .onReceive(tick) { now = $0 }
    }
}

struct ContextMeter: View {
    let used: Int
    let window: Int
    var compact = false
    var fraction: Double { min(Double(used) / Double(max(window, 1)), 1) }
    var color: Color { fraction > 0.85 ? .red : fraction > 0.6 ? .orange : .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if !compact { Text("Context").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                Text("\(Fmt.tokens(used)) / \(Fmt.tokens(window))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                if fraction > 0.75 { Text("consider /compact").font(.caption2).foregroundStyle(color) }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: g.size.width * fraction)
                }
            }
            .frame(height: compact ? 3 : 5)
        }
        .help("How full the model's context window was on the latest reply")
    }
}

struct BudgetBars: View {
    @EnvironmentObject var sessions: SessionStore
    var compact = false
    @AppStorage("budgetDaily") private var daily = 0.0
    @AppStorage("budgetWeekly") private var weekly = 0.0
    @AppStorage("budgetMonthly") private var monthly = 0.0

    var body: some View {
        let rows: [(String, Double, Double)] = [("Today", daily, sessions.cost(days: 1)), ("This week", weekly, sessions.cost(days: 7)),
                                                ("This month", monthly, sessions.cost(days: 30))].filter { $0.1 > 0 }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.0) { label, limit, spent in
                    let f = spent / limit
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(label) budget").font(.caption)
                            Spacer()
                            Text("\(Fmt.usd(spent)) of \(Fmt.usd(limit))").font(.caption.monospacedDigit()).foregroundStyle(f >= 1 ? .red : .secondary)
                        }
                        ProgressView(value: min(f, 1)).tint(f >= 1 ? .red : f >= 0.8 ? .orange : .green)
                    }
                }
            }
        }
    }
}

extension Color {
    static let deckAccent = Color(red: 0.85, green: 0.47, blue: 0.34)
}
