import SwiftUI
import AppKit
import UserNotifications

// MARK: - Guide content

/// One page of the user guide. Topics tied to a tab also power that tab's "?" help popover.
struct GuideTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    var tab: Tab? = nil
    let summary: String
    var steps: [String] = []
    var tips: [String] = []
}

enum Guide {
    static let topics: [GuideTopic] = [
        GuideTopic(id: "start", title: "Getting started", icon: "flag.checkered",
                   summary: "Claudeck is a dashboard for Claude Code on this Mac. It reads the session files Claude Code already keeps in ~/.claude, so there's nothing to connect: open it and your history is there.",
                   steps: [
                    "Use Claude Code as usual, in the terminal or in your editor. Claudeck picks up new sessions within a few seconds.",
                    "Watch what's running on **Status**, and read or search past work on **Sessions** and **Search**.",
                    "Press **⌘K** (or the **Ask Claude** button) to send a prompt to Claude Code from anywhere in the app.",
                    "Add MCP servers, plugins, hooks and permissions on **Extensions**, without editing JSON.",
                   ],
                   tips: [
                    "Everything stays on this Mac. The only network calls are the Claude Code runs you start (including AI summaries and digests).",
                    "Every screen has a **?** button in the toolbar that explains it.",
                   ]),
        GuideTopic(id: "ask", title: "Ask Claude (⌘K)", icon: "sparkle",
                   summary: "The floating button at the bottom of every screen sends a prompt to the Claude Code installed on this Mac. It runs `claude -p` in the folder you pick and streams the reply.",
                   steps: [
                    "Press **⌘K** or click **Ask Claude**.",
                    "Pick a project folder, a model and a permission mode. **Ask-only** lets Claude read but not edit. **Auto-accept file edits** lets it change files.",
                    "Type your prompt, or start from a saved template. `{{blanks}}` in a template become fields to fill in.",
                    "Optional: set **Parallel** to 2–4 to run the same prompt in separate git worktrees, then compare the results side by side on Status.",
                   ],
                   tips: [
                    "To continue an existing conversation, open it in Sessions and click **Continue here**.",
                    "Runs keep going if you close the composer. Progress shows on Status and in the menu bar.",
                   ]),
        GuideTopic(id: "status", title: "Status", icon: Tab.status.icon, tab: .status,
                   summary: "What Claude is doing right now: every running Claude Code session, the prompts you sent from Claudeck, approvals waiting for you, and today's spend.",
                   steps: [
                    "An **orange dot** means Claude is working. A **green dot** means it's idle and waiting for you.",
                    "The **context meter** shows how full a session's context window is. Near the limit, Claude starts compacting and forgetting detail, so it's a good time to start fresh.",
                    "Click a session card to open its full history.",
                    "Runs from ⌘K show their live output here. Parallel attempts appear side by side with a diff of what each changed.",
                   ],
                   tips: ["Set a budget in Settings (⌘,) → Budget to see daily, weekly and monthly progress bars here."]),
        GuideTopic(id: "sessions", title: "Sessions & memory docs", icon: Tab.sessions.icon, tab: .sessions,
                   summary: "Every Claude Code session, newest first. Each one is saved as a readable Markdown memory doc in ~/Documents/Claudeck/Sessions.",
                   steps: [
                    "Pick a session to see its tokens, cost, the tools used and the full conversation.",
                    "An **AI summary** is written the first time you open a session (using Haiku by default) and cached. Click **Regenerate summary** after the session grows.",
                    "**Files changed** lists every file Claude edited, with a diff against the version from before the session and a **Restore original** button.",
                    "**Continue here** resumes the session from Claudeck. **Resume in Terminal** resumes it with `claude --resume`.",
                    "**Export** saves the session as Markdown, Word or PDF, or shares it.",
                   ],
                   tips: ["Change the memory folder or the summary model in Settings → General."]),
        GuideTopic(id: "search", title: "Search", icon: Tab.search.icon, tab: .search,
                   summary: "Full-text search over everything you and Claude wrote, and every command it ran, across all projects.",
                   steps: [
                    "Type a few words. Only results containing all of them are shown.",
                    "Filter by **You**, **Claude** or **Tools** to narrow it down.",
                    "Click a result to jump to that session.",
                   ],
                   tips: ["Press ⇧⌘F from anywhere to jump here."]),
        GuideTopic(id: "usage", title: "Cost & Tokens", icon: Tab.usage.icon, tab: .usage,
                   summary: "Tokens and estimated cost per day, session, model and project.",
                   steps: [
                    "Switch between **$** and **tokens** with the toggle above the chart.",
                    "**Cache read** tokens are cheap re-reads of context Claude already saw. A high share means caching is working well.",
                    "Sort the sessions table by cost to find your most expensive ones.",
                   ],
                   tips: [
                    "Costs use API list prices. On a Pro or Max plan you aren't billed per token, so treat them as a measure of how hard you're using your plan.",
                    "Budgets (Settings → Budget) send a notification at 80% and at 100%.",
                   ]),
        GuideTopic(id: "improvements", title: "Improvements", icon: Tab.improvements.icon, tab: .improvements,
                   summary: "Concrete ways to spend fewer tokens, ranked by how much each would save, worked out from your last 30 days of sessions.",
                   steps: [
                    "The top row shows the total you could save, how much context comes from the cache, how big sessions are before you type, and the average context carried per reply.",
                    "Each card says what was found, why it costs tokens, and how to fix it. **Show sessions** lists the sessions that triggered it; click one to open it.",
                    "Buttons jump to the right place to act, such as MCP servers, Permissions or CLAUDE.md.",
                   ],
                   tips: [
                    "Savings are estimates at API list prices. On a Pro or Max plan they mean more work before you hit usage limits.",
                    "Run `/context` inside a Claude Code session to see exactly what fills its context window.",
                   ]),
        GuideTopic(id: "insights", title: "Insights & digests", icon: Tab.insights.icon, tab: .insights,
                   summary: "Patterns in how you use Claude Code, and an AI-written digest of what you got done.",
                   steps: [
                    "See your busiest hours, the tools Claude uses most, and how often tool calls fail.",
                    "Click **Generate** for a summary of the last day or week, with a standup blurb you can paste. Digests are saved in ~/Documents/Claudeck/Digests.",
                   ]),
        GuideTopic(id: "projects", title: "Projects", icon: Tab.projects.icon, tab: .projects,
                   summary: "Every folder you've used Claude Code in, with its git state and the threads left open.",
                   steps: [
                    "Tags show the branch, uncommitted files, and commits waiting to push or pull.",
                    "**Open threads** are next steps taken from your session summaries. Open a few sessions first to fill them in.",
                    "**Ask Claude here** opens ⌘K in that folder. **Terminal** starts a new `claude` session there. **Open in** opens it in your editor.",
                   ]),
        GuideTopic(id: "security", title: "Security", icon: Tab.security.icon, tab: .security,
                   summary: "Finds secrets that ended up in Claude's context: API keys, tokens, private keys, passwords and database URLs. It also lists the times Claude opened .env or credential files.",
                   steps: [
                    "Click **Scan all sessions**. The scan runs locally and only shows masked values.",
                    "Rotate any real key it finds. It was sent to the model and is stored in your session files.",
                    "Prevent it happening again: Extensions → Permissions → add deny rules for `Read(./.env)` and `Read(./.env.*)`.",
                   ]),
        GuideTopic(id: "library", title: "Prompts & Schedules", icon: Tab.library.icon, tab: .library,
                   summary: "Save prompts you reuse, and run them automatically on a schedule.",
                   steps: [
                    "Create a template. Use `{{name}}` for parts that change and you'll be asked for them each time.",
                    "Create a schedule: pick a template, a folder, and when to run it (daily at a time, on chosen weekdays, or every N minutes).",
                    "Scheduled runs show on Status and send a notification when they finish.",
                   ],
                   tips: ["Schedules only run while Claudeck is open. Keep it in the menu bar and turn on Open at login (Settings → General)."]),
        GuideTopic(id: "extensions", title: "Extensions", icon: Tab.extensions.icon, tab: .extensions,
                   summary: "Everything that extends Claude Code, in one place, and editable without touching JSON.",
                   steps: [
                    "**Skills**, **Agents & commands**: see what's installed, or click **Create** to make a new skill, subagent or slash command.",
                    "**Plugins**: browse your marketplaces, install, enable, disable and uninstall.",
                    "**MCP**: add a server with the form, choose one from the gallery of popular servers, or import the ones from Claude Desktop. Pick the scope: you, this project (shared), or this project (just you).",
                    "**Hooks**: add hooks from ready-made recipes, such as a sound when Claude finishes or blocking edits to .env.",
                    "**Permissions**: allow or deny tools. Risky rules are flagged.",
                    "**CLAUDE.md & memory**: edit your instruction files. References to files that no longer exist are highlighted.",
                   ],
                   tips: ["Before its first change to a settings file, Claudeck saves a backup next to it (*.claudeck.bak)."]),
        GuideTopic(id: "menubar", title: "Menu bar & approvals", icon: "menubar.rectangle",
                   summary: "The ✦ icon in the menu bar shows live sessions, today's cost and budget, and approvals waiting for you, even when the window is closed.",
                   steps: [
                    "The icon changes to ✦✦ with a count while Claude is working, and to a speech bubble when it needs permission.",
                    "To approve Claude's permission prompts from Claudeck, turn on Settings (⌘,) → Alerts → **Answer Claude's permission prompts here**.",
                    "After that, when Claude asks to run a command or edit a file, you get a notification with **Allow** and **Deny**. The request also appears in the menu bar and on Status.",
                    "If you don't answer within the wait time, or Claudeck isn't running, the terminal asks you as usual.",
                   ]),
        GuideTopic(id: "shortcuts", title: "Keyboard shortcuts", icon: "keyboard",
                   summary: "Everything you can do from the keyboard.",
                   steps: [
                    "**⌘K**: ask Claude",
                    "**⌘1 … ⌘9**: switch tabs",
                    "**⇧⌘F**: search every session",
                    "**⌘R**: refresh",
                    "**⌘,**: settings",
                    "**⌘?**: this guide",
                   ]),
        GuideTopic(id: "privacy", title: "Privacy & data", icon: "hand.raised",
                   summary: "Claudeck has no server and no account. It reads Claude Code's local files and runs the claude CLI you already have.",
                   steps: [
                    "**Reads**: ~/.claude (sessions, settings, skills, plugins, file history).",
                    "**Writes**: memory docs and digests in ~/Documents/Claudeck, app data in ~/Library/Application Support/Claudeck, and ~/.claude settings only when you change them here.",
                    "**Network**: only the Claude Code runs you start. AI summaries and digests are Claude Code runs too, and they aren't saved as sessions.",
                   ]),
        GuideTopic(id: "troubleshooting", title: "Troubleshooting", icon: "wrench.and.screwdriver",
                   summary: "Fixes for the most common problems.",
                   steps: [
                    "**No sessions show up**: use Claude Code at least once, then press ⌘R. Sessions are read from ~/.claude/projects.",
                    "**Ask Claude does nothing**: check Settings → General → Claude Code CLI. If it says *Not found*, install Claude Code or make sure `claude` is on your PATH, then reopen the app.",
                    "**No notifications**: allow Claudeck in System Settings → Notifications, then use Settings → Alerts → *Send a test notification*.",
                    "**Approvals don't appear**: turn the approval toggle off and on again. It re-writes the hook in ~/.claude/settings.json.",
                    "**Summary failed**: summaries need a signed-in claude CLI. Run `claude` once in Terminal to sign in.",
                   ]),
    ]

    static func topic(for tab: Tab) -> GuideTopic? { topics.first { $0.tab == tab } }
    static func topic(id: String) -> GuideTopic? { topics.first { $0.id == id } }
}

// MARK: - Shared rendering

struct GuideTopicBody: View {
    let topic: GuideTopic
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            Text(md(topic.summary)).font(compact ? .callout : .title3).foregroundStyle(compact ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if !topic.steps.isEmpty {
                VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                    ForEach(Array(topic.steps.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 18, height: 18).background(Color.deckAccent, in: Circle())
                            Text(md(s)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !topic.tips.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(topic.tips, id: \.self) { t in
                        Label { Text(md(t)).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "lightbulb").foregroundStyle(.yellow) }
                            .font(.callout)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: - "?" help for the current tab

struct TabHelpButton: View {
    @EnvironmentObject var state: AppState
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: { Image(systemName: "questionmark.circle") }
            .help("What's on this screen?")
            .popover(isPresented: $show, arrowEdge: .bottom) {
                if let t = Guide.topic(for: state.tab) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(t.title, systemImage: t.icon).font(.title3.weight(.semibold))
                        GuideTopicBody(topic: t, compact: true)
                        Divider()
                        HStack {
                            Button("Open the full guide") { show = false; state.openGuide(t.id) }
                            Spacer()
                            Button("Take the tour again") { show = false; state.showWalkthrough = true }
                        }
                        .buttonStyle(.link)
                    }
                    .padding(18)
                    .frame(width: 420)
                }
            }
            .onAppear { if CommandLine.arguments.contains("--tabhelp") { show = true } }
    }
}

// MARK: - Guide window

struct GuideWindow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $state.guideTopic) {
                Section("Guide") {
                    ForEach(Guide.topics.filter { $0.tab == nil && !["shortcuts", "privacy", "troubleshooting"].contains($0.id) }) { row($0) }
                }
                Section("Screens") {
                    ForEach(Guide.topics.filter { $0.tab != nil }) { row($0) }
                }
                Section("Reference") {
                    ForEach(["shortcuts", "privacy", "troubleshooting"].compactMap(Guide.topic(id:))) { row($0) }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            let t = Guide.topic(id: state.guideTopic ?? "start") ?? Guide.topics[0]
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(t.title, systemImage: t.icon).font(.largeTitle.weight(.bold))
                    GuideTopicBody(topic: t)
                    HStack {
                        if let tab = t.tab {
                            Button { state.tab = tab; AppDelegate.showMainWindow() } label: { Label("Go to \(tab.rawValue)", systemImage: "arrow.right.circle") }
                                .buttonStyle(.borderedProminent).tint(.deckAccent)
                        }
                        if t.id == "start" {
                            Button { state.showWalkthrough = true; AppDelegate.showMainWindow() } label: { Label("Take the tour", systemImage: "play.circle") }
                                .buttonStyle(.borderedProminent).tint(.deckAccent)
                        }
                        if t.id == "menubar" || t.id == "troubleshooting" {
                            SettingsLink { Label("Open Settings", systemImage: "gear") }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(32)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private func row(_ t: GuideTopic) -> some View {
        Label(t.title, systemImage: t.icon).tag(t.id)
    }
}

// MARK: - First-run walkthrough

struct WalkthroughView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    @AppStorage("didOnboard") private var didOnboard = false
    @State private var page = 0

    struct Page {
        let icon: String
        let title: String
        let body: String
        var tab: Tab? = nil
        var bullets: [String] = []
    }

    static let pages: [Page] = [
        Page(icon: "sparkles", title: "Welcome to Claudeck",
             body: "A home for your Claude Code work. See what's running, find anything from past sessions, track cost, and set up MCP servers, plugins and hooks without editing JSON.",
             bullets: ["Works with the Claude Code you already use: terminal, VS Code or JetBrains.", "Reads ~/.claude locally. No account and no server."]),
        Page(icon: Tab.status.icon, title: "Know what Claude is doing", body: "Status shows every running session, whether it's working or waiting for you, how full its context is, and what you've spent today.",
             tab: .status, bullets: ["Orange: working. Green: waiting for you.", "The ✦ in the menu bar shows the same at a glance."]),
        Page(icon: Tab.sessions.icon, title: "Every session, remembered", body: "Each session is saved as a Markdown memory doc. When you open one, Claude writes a summary of what was done and what's left.",
             tab: .sessions, bullets: ["See the files it changed, with diffs and restore.", "Continue a session, or export it to Word or PDF."]),
        Page(icon: "sparkle", title: "Ask Claude from anywhere", body: "The Ask Claude button is always at the bottom of the window. Press ⌘K, pick a folder and send a prompt to your local Claude Code.",
             bullets: ["Save prompts as templates and run them on a schedule.", "Run 2–4 attempts in parallel and compare them."]),
        Page(icon: Tab.usage.icon, title: "Tokens and cost", body: "See tokens and estimated cost per session, day, model and project, and set budgets that warn you at 80% and 100%. **Improvements** shows what to change to spend fewer tokens.",
             tab: .usage),
        Page(icon: Tab.extensions.icon, title: "Set up Claude Code visually", body: "Add MCP servers from a gallery, install plugins, create skills and slash commands, build hooks from recipes, and manage permissions.",
             tab: .extensions, bullets: ["A backup is kept before any settings file is changed."]),
        Page(icon: "checklist", title: "Quick setup", body: "A few optional settings. You can change all of them later in Settings (⌘,)."),
    ]

    var body: some View {
        let p = Self.pages[page]
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<Self.pages.count, id: \.self) { i in
                    Capsule().fill(i == page ? Color.deckAccent : Color.secondary.opacity(0.25))
                        .frame(width: i == page ? 22 : 8, height: 8)
                        .onTapGesture { go(i) }
                }
            }
            .padding(.top, 22)

            VStack(spacing: 14) {
                Image(systemName: p.icon)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.deckAccent)
                    .frame(height: 60)
                    .contentTransition(.symbolEffect(.replace))
                Text(p.title).font(.title.weight(.bold)).multilineTextAlignment(.center)
                Text(p.body).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if page == Self.pages.count - 1 {
                    SetupChecklist().padding(.top, 6)
                } else if !p.bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(p.bullets, id: \.self) { b in
                            Label(b, systemImage: "checkmark.circle.fill").foregroundStyle(.primary)
                                .symbolRenderingMode(.multicolor)
                        }
                    }
                    .padding(.top, 6)
                }
                if let tab = p.tab {
                    Text("The \(tab.rawValue) screen is behind this window. You'll find it in the sidebar.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 48)
            .frame(maxHeight: .infinity)
            .id(page)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))

            HStack {
                if page < Self.pages.count - 1 {
                    Button("Skip tour") { finish() }.buttonStyle(.link)
                }
                Spacer()
                if page > 0 { Button("Back") { go(page - 1) }.keyboardShortcut(.leftArrow, modifiers: []) }
                Button(page == Self.pages.count - 1 ? "Start using Claudeck" : "Next") {
                    page == Self.pages.count - 1 ? finish() : go(page + 1)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(.deckAccent)
            }
            .padding(20)
        }
        .frame(width: 620, height: 560)
        .onAppear {
            if let i = CommandLine.arguments.firstIndex(of: "--walkthrough"), i + 1 < CommandLine.arguments.count,
               let n = Int(CommandLine.arguments[i + 1]) { go(min(max(n, 0), Self.pages.count - 1)) }
        }
    }

    private func go(_ i: Int) {
        withAnimation(.easeInOut(duration: 0.25)) { page = i }
        if let tab = Self.pages[i].tab { state.tab = tab }
    }

    private func finish() {
        didOnboard = true
        state.tab = .status
        state.showWalkthrough = false
    }
}

/// Last walkthrough page: checks that everything Claudeck needs is in place and offers the optional settings.
struct SetupChecklist: View {
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var bridge: PermissionBridge
    @State private var notifications: UNAuthorizationStatus?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(ok: Paths.claudeBinary != nil,
                title: Paths.claudeBinary != nil ? "Claude Code found" : "Claude Code not found",
                detail: Paths.claudeBinary.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Install Claude Code, then reopen Claudeck. Browsing still works.")
            row(ok: !sessions.sessions.isEmpty,
                title: sessions.isLoading ? "Reading your sessions…" : "\(sessions.sessions.count) sessions found",
                detail: sessions.sessions.isEmpty && !sessions.isLoading ? "Use Claude Code once and they'll appear here." : "Memory docs are saved to \((Paths.memoryDir.path as NSString).abbreviatingWithTildeInPath)")
            HStack {
                row(ok: notifications == .authorized || notifications == .provisional,
                    title: "Notifications",
                    detail: notifications == .denied ? "Turned off. Allow Claudeck in System Settings." : "For finished runs, budgets and approvals.")
                Spacer()
                if notifications == .denied {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                } else if notifications == .notDetermined {
                    Button("Allow") {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                            Task { @MainActor in await refresh() }
                        }
                    }
                }
            }
            Divider()
            Toggle(isOn: Binding(get: { bridge.installed },
                                 set: { on in do { try on ? bridge.install() : bridge.uninstall() } catch { self.error = error.localizedDescription } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Approve Claude's permission prompts from here")
                    Text("Adds a hook to ~/.claude/settings.json. A backup is kept.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open at login")
                    Text("Keeps the menu bar icon and your schedules running.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: launchAtLogin) { _, on in
                do { try LaunchAtLogin.set(on) } catch { self.error = error.localizedDescription; launchAtLogin = LaunchAtLogin.isEnabled }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .toggleStyle(.switch)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .task { await refresh() }
    }

    private func refresh() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func row(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
