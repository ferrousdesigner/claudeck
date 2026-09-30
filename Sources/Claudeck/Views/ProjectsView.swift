import SwiftUI
import AppKit

struct ProjectsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    @State private var projects: [ProjectHealth] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Projects").font(.largeTitle.weight(.bold))
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 14)], spacing: 14) {
                    ForEach(projects) { p in ProjectCard(p: p) }
                }
            }
            .padding(24)
        }
        .fabClearance()
        .task(id: sessions.isLoading) { await load() }
        .overlay {
            if !loading && projects.isEmpty { ContentUnavailableView("No projects yet", systemImage: "folder", description: Text("Projects appear once you've used Claude Code in a folder.")) }
        }
    }

    private func load() async {
        guard !sessions.isLoading else { return }
        loading = true
        let s = sessions.sessions
        projects = await Task.detached { Projects.health(s) }.value
        loading = false
    }
}

struct ProjectCard: View {
    @EnvironmentObject var state: AppState
    let p: ProjectHealth

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                    Text(p.name).font(.title3.weight(.semibold))
                    Spacer()
                    Text(Fmt.ago(p.lastActive)).font(.caption).foregroundStyle(.secondary)
                }
                Text((p.path as NSString).abbreviatingWithTildeInPath).font(.caption.monospaced()).foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    stat("\(p.sessions.count)", "sessions")
                    stat(Fmt.tokens(p.tokens.total), "tokens")
                    stat(Fmt.usd(p.cost), "API cost")
                }

                HStack(spacing: 8) {
                    if p.git.isRepo {
                        Tag(text: p.git.branch ?? "detached", color: .blue)
                        Tag(text: p.git.changedFiles == 0 ? "clean" : "\(p.git.changedFiles) uncommitted", color: p.git.changedFiles == 0 ? .green : .orange)
                        if p.git.ahead > 0 { Tag(text: "↑\(p.git.ahead) to push", color: .purple) }
                        if p.git.behind > 0 { Tag(text: "↓\(p.git.behind) to pull", color: .red) }
                    } else {
                        Tag(text: "not a git repo")
                    }
                    Tag(text: p.hasClaudeMD ? "CLAUDE.md ✓" : "no CLAUDE.md", color: p.hasClaudeMD ? .green : .secondary)
                }
                if let c = p.git.lastCommit {
                    Text("Last commit: \(c) · \(Fmt.ago(p.git.lastCommitDate))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                if !p.nextSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Open threads").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(p.nextSteps, id: \.self) { step in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "circle").font(.system(size: 6)).foregroundStyle(.secondary)
                                Text(LocalizedStringKey(step)).font(.callout).lineLimit(2)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent sessions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(p.sessions.prefix(3)) { s in
                        Button { state.openSession(s.id) } label: {
                            HStack { Text(s.title).lineLimit(1); Spacer(); Text(Fmt.ago(s.end)).foregroundStyle(.secondary) }.font(.callout)
                        }.buttonStyle(.plain)
                    }
                }

                HStack {
                    Button { state.compose(cwd: p.path) } label: { Label("Ask Claude here", systemImage: "sparkle") }
                        .buttonStyle(.borderedProminent).tint(.deckAccent)
                    Button { Handoff.newSessionInTerminal(p.path) } label: { Label("Terminal", systemImage: "terminal") }
                    Menu {
                        ForEach(Handoff.editors, id: \.bundle) { e in Button(e.name) { Handoff.open(p.path, inEditor: e.bundle) } }
                        Divider()
                        Button("Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: p.path)) }
                    } label: { Label("Open in", systemImage: "arrow.up.forward.app") }
                        .fixedSize()
                }
            }
        }
    }

    private func stat(_ v: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct SecurityView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    @State private var findings: [SecretFinding] = []
    @State private var scanning = false
    @State private var progress = 0.0
    @State private var scannedAt: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Security").font(.largeTitle.weight(.bold))
                        Text("Secrets that ended up in Claude's context were sent to the model and are stored in your session files.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await scan() } } label: {
                        if scanning { ProgressView(value: progress).frame(width: 80) } else { Label(scannedAt == nil ? "Scan all sessions" : "Scan again", systemImage: "lock.shield") }
                    }
                    .buttonStyle(.borderedProminent).disabled(scanning)
                }

                if let scannedAt {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        Metric(title: "Findings", value: "\(findings.count)", caption: "scanned \(Fmt.ago(scannedAt))", icon: "exclamationmark.shield",
                               tint: findings.isEmpty ? .green : .orange)
                        Metric(title: "Secrets exposed", value: "\(findings.filter { $0.kind != "Read a sensitive file" }.count)", icon: "key", tint: .red)
                        Metric(title: "Sensitive files read", value: "\(findings.filter { $0.kind == "Read a sensitive file" }.count)", icon: "doc.badge.ellipsis", tint: .orange)
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("What to do", systemImage: "lightbulb").font(.headline)
                            Text("• Rotate any real key listed below — treat it as leaked.\n• Stop Claude reading secrets: Extensions → Permissions → add deny rules for Read(./.env) and Read(./.env.*).\n• Keep secrets in a keychain or env vars that aren't printed, rather than in files Claude opens.")
                                .font(.callout)
                        }
                    }
                    ForEach(Dictionary(grouping: findings, by: \.kind).sorted { $0.value.count > $1.value.count }, id: \.key) { kind, list in
                        Text("\(kind) (\(list.count))").font(.headline).padding(.top, 6)
                        ForEach(list) { f in
                            Card(padding: 10) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(f.masked).font(.callout.monospaced().weight(.semibold))
                                        Text(f.context).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                                        Text("\(sessions.session(id: f.sessionID)?.title ?? f.sessionID) · \(Fmt.ago(f.timestamp))").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Button("Open session") { state.openSession(f.sessionID) }.font(.caption)
                                }
                            }
                        }
                    }
                } else if !scanning {
                    ContentUnavailableView("Not scanned yet", systemImage: "lock.shield",
                                           description: Text("Looks for API keys, tokens, private keys, passwords and database URLs in every transcript, plus times Claude opened .env or credential files. Everything stays on this Mac."))
                }
            }
            .padding(24)
        }
        .fabClearance()
        .task(id: sessions.isLoading) {
            if !sessions.isLoading && scannedAt == nil && CommandLine.arguments.contains("--scan") { await scan() }
        }
    }

    private func scan() async {
        scanning = true; progress = 0
        let s = sessions.sessions
        findings = await Task.detached {
            SecurityScan.scan(s) { p in Task { @MainActor in progress = p } }
        }.value
        scannedAt = Date()
        scanning = false
    }
}
