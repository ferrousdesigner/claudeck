import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var runner: ClaudeRunner
    @EnvironmentObject var bridge: PermissionBridge
    @EnvironmentObject var library: Library
    @EnvironmentObject var extensions: ExtensionsStore

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { state.tab }, set: { if let t = $0 { state.tab = t } })) {
                Section {
                    ForEach([Tab.status, .sessions, .search]) { tab in
                        Label(tab.rawValue, systemImage: tab.icon)
                            .badge(badge(for: tab))
                            .tag(tab)
                    }
                }
                Section("Understand") {
                    ForEach([Tab.usage, .improvements, .insights, .projects, .security]) { tab in
                        Label(tab.rawValue, systemImage: tab.icon)
                            .badge(badge(for: tab))
                            .tag(tab)
                    }
                }
                Section("Automate & configure") {
                    ForEach([Tab.library, .extensions]) { tab in
                        Label(tab.rawValue, systemImage: tab.icon)
                            .badge(badge(for: tab))
                            .tag(tab)
                    }
                }
                Section("Live") {
                    if sessions.live.isEmpty {
                        Text("No running sessions").foregroundStyle(.secondary).font(.callout)
                    }
                    ForEach(sessions.live) { l in
                        Button {
                            state.openSession(l.sessionId)
                        } label: {
                            HStack(spacing: 8) {
                                StatusDot(busy: l.isBusy)
                                Text(sessions.session(id: l.sessionId)?.title ?? l.name ?? (l.cwd as NSString).lastPathComponent)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.caption2)
                    Text("Updated \(Fmt.ago(sessions.lastRefresh))").font(.caption2)
                    Spacer()
                    Button { state.openGuide() } label: { Label("Guide", systemImage: "questionmark.circle").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("User guide (⌘?)")
                }
                .foregroundStyle(.tertiary)
                .padding(10)
            }
        } detail: {
            ZStack(alignment: .bottom) {
                Group {
                    switch state.tab {
                    case .status: StatusView()
                    case .sessions: SessionsView()
                    case .search: SearchView()
                    case .usage: UsageView()
                    case .improvements: ImprovementsView()
                    case .insights: InsightsView()
                    case .projects: ProjectsView()
                    case .library: LibraryView()
                    case .security: SecurityView()
                    case .extensions: ExtensionsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                PromptFAB()
                    .padding(.bottom, 22)
            }
            .toolbar { ToolbarItem(placement: .primaryAction) { TabHelpButton() } }
            .sheet(isPresented: $state.showWalkthrough) {
                WalkthroughView()
                    .environmentObject(state)
                    .environmentObject(sessions)
                    .environmentObject(bridge)
                    .interactiveDismissDisabled()
            }
        }
        .overlay(alignment: .topTrailing) { DebugPreview() }
        .sheet(isPresented: $state.showPrompt) {
            PromptComposer()
                .environmentObject(state)
                .environmentObject(sessions)
                .environmentObject(runner)
                .environmentObject(library)
        }
    }

    private func badge(for tab: Tab) -> Int {
        switch tab {
        case .status: return sessions.live.filter(\.isBusy).count + runner.activeCount + bridge.pending.count
        case .library: return library.schedules.filter(\.enabled).count
        default: return 0
        }
    }
}

struct StatusDot: View {
    let busy: Bool
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(busy ? Color.orange : Color.green)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(busy ? Color.orange : .clear, lineWidth: 2).scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 0.8))
            .onAppear { if busy { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true } } }
            .help(busy ? "Working" : "Idle — waiting for input")
    }
}

/// Floating prompt button, always visible, centred at the bottom of the window.
struct PromptFAB: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var runner: ClaudeRunner
    @State private var hover = false

    var body: some View {
        Button { state.compose() } label: {
            HStack(spacing: 10) {
                Image(systemName: runner.activeCount > 0 ? "sparkles" : "sparkle")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolEffect(.pulse, isActive: runner.activeCount > 0)
                Text(runner.activeCount > 0 ? "Claude is working · Ask more" : "Ask Claude")
                    .font(.system(size: 14, weight: .semibold))
                Text("⌘K").font(.caption.monospaced()).opacity(0.7)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 13)
            .background(
                Capsule().fill(LinearGradient(colors: [Color.deckAccent, Color(red: 0.73, green: 0.35, blue: 0.25)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .shadow(color: .black.opacity(0.3), radius: hover ? 16 : 10, y: 6)
            .scaleEffect(hover ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hover = h } }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.6)))
    }
}

struct Metric: View {
    let title: String
    let value: String
    var caption: String? = nil
    var icon: String
    var tint: Color = .accentColor
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(tint)
                    .contentTransition(.numericText())
                Text(caption ?? " ").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct TokenChips: View {
    let t: TokenUsage
    var body: some View {
        // One row when there's room, two when the pane is narrow, so the chips never force the window wider.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { inputs; caches }
            VStack(alignment: .leading, spacing: 6) { HStack(spacing: 6) { inputs }; HStack(spacing: 6) { caches } }
        }
    }
    @ViewBuilder private var inputs: some View {
        chip("Input", t.input, .blue)
        chip("Output", t.output, .purple)
    }
    @ViewBuilder private var caches: some View {
        chip("Cache write", t.cacheCreate, .orange)
        chip("Cache read", t.cacheRead, .teal)
    }
    private func chip(_ label: String, _ n: Int, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
            Text(Fmt.tokens(n)).monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(c.opacity(0.1), in: Capsule())
    }
}

extension View {
    /// Leaves room under scrolling content so the floating prompt button never hides the last row.
    func fabClearance() -> some View { safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) } }
}


/// `--preview menubar|settings|parallel <repo>` renders hard-to-reach UI inside the window (used for screenshots/testing).
struct DebugPreview: View {
    @EnvironmentObject var runner: ClaudeRunner
    @EnvironmentObject var state: AppState
    private var arg: String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--preview"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    @State private var started = false

    var body: some View {
        switch arg {
        case "menubar":
            MenuBarView().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(20).shadow(radius: 20)
        case "settings":
            SettingsView().background(.background, in: RoundedRectangle(cornerRadius: 12)).padding(20).shadow(radius: 20)
        case "parallel":
            Color.clear.frame(width: 1, height: 1).onAppear {
                guard !started, let i = CommandLine.arguments.firstIndex(of: "parallel"), i + 1 < CommandLine.arguments.count else { return }
                started = true
                let repo = CommandLine.arguments[i + 1]
                if let wts = try? Worktrees.create(repo: repo, count: 2, slug: "preview") {
                    let g = UUID()
                    for (n, wt) in wts.enumerated() {
                        runner.send("Create a file named hello.txt containing a one-line greeting (variant \(n + 1)). Reply DONE.",
                                    options: PromptOptions(cwd: wt.path, resumeId: nil, model: "haiku", permissionMode: "acceptEdits"),
                                    label: "#\(n + 1) · hello file", groupID: g)
                    }
                }
            }
        default:
            EmptyView()
        }
    }
}
