import SwiftUI
import AppKit

struct SessionsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    @State private var search = ""
    @State private var project = "All projects"
    @AppStorage("sessionsListWidth") private var listWidth = 330.0
    @State private var dragStart: Double?

    private var filtered: [SessionSummary] {
        sessions.sessions.filter { s in
            (project == "All projects" || s.cwd == project) &&
            (search.isEmpty || s.title.localizedCaseInsensitiveContains(search)
             || (s.firstPrompt ?? "").localizedCaseInsensitiveContains(search)
             || s.projectName.localizedCaseInsensitiveContains(search)
             || s.id.hasPrefix(search))
        }
    }

    private var grouped: [(String, [SessionSummary])] {
        let cal = Calendar.current
        var groups: [(String, [SessionSummary])] = []
        for s in filtered {
            let d = s.end ?? s.fileModified
            let key: String
            if cal.isDateInToday(d) { key = "Today" }
            else if cal.isDateInYesterday(d) { key = "Yesterday" }
            else if d > cal.date(byAdding: .day, value: -7, to: Date())! { key = "This week" }
            else if d > cal.date(byAdding: .day, value: -30, to: Date())! { key = "This month" }
            else { key = d.formatted(.dateTime.month(.wide).year()) }
            if groups.last?.0 == key { groups[groups.count - 1].1.append(s) } else { groups.append((key, [s])) }
        }
        return groups
    }

    var body: some View {
        // A plain HStack instead of HSplitView: HSplitView sizes the detail pane from its content's ideal
        // width, which pushed the window's sidebar off-screen or left the detail not filling its pane.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search sessions", text: $search).textFieldStyle(.plain)
                }
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .top], 10)
                Picker("", selection: $project) {
                    Text("All projects").tag("All projects")
                    ForEach(sessions.knownProjects, id: \.self) { p in Text((p as NSString).abbreviatingWithTildeInPath).tag(p) }
                }
                .labelsHidden()
                .padding(10)

                List(selection: $state.selectedSessionID) {
                    ForEach(grouped, id: \.0) { group in
                        Section(group.0) {
                            ForEach(group.1) { s in
                                SessionListRow(s: s, live: sessions.liveSession(for: s.id)).tag(s.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .fabClearance()
            }
            .frame(width: listWidth)

            Divider()
                .overlay {
                    Color.clear.frame(width: 8).contentShape(Rectangle())
                        .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                if dragStart == nil { dragStart = listWidth }
                                listWidth = min(max((dragStart ?? listWidth) + v.translation.width, 280), 440)
                            }
                            .onEnded { _ in dragStart = nil })
                }

            Group {
                if let id = state.selectedSessionID, let s = sessions.session(id: id) {
                    SessionDetailView(session: s).id(s.id)
                } else {
                    ContentUnavailableView("Pick a session", systemImage: "books.vertical",
                                           description: Text("Every Claude Code session is saved as a memory doc in \((Paths.sessionDocsDir.path as NSString).abbreviatingWithTildeInPath)."))
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SessionListRow: View {
    let s: SessionSummary
    let live: LiveSession?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let live { StatusDot(busy: live.isBusy) }
                Text(s.title).lineLimit(1).font(.body.weight(.medium))
            }
            HStack {
                Text(s.projectName)
                Spacer()
                Text(Fmt.tokens(s.tokens.total)).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct SessionDetailView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    let session: SessionSummary

    @State private var summary: CachedSummary?
    @State private var summarizing = false
    @State private var summaryError: String?
    @State private var transcript: [TranscriptEntry] = []
    @State private var loadingTranscript = true
    @State private var showTools = false
    @State private var changes: [ChangedFile] = []
    @State private var diffFile: ChangedFile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                TokenChips(t: session.tokens)
                statsGrid
                summaryCard
                actions
                if !changes.isEmpty { changesSection }
                transcriptSection
            }
            .padding(24)
        }
        .fabClearance()
        .task(id: session.id) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let l = sessions.liveSession(for: session.id) { StatusDot(busy: l.isBusy) }
                Text(session.title).font(.title.weight(.bold)).textSelection(.enabled)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { where_; when }
                VStack(alignment: .leading, spacing: 4) { HStack(spacing: 12) { where_ }; HStack(spacing: 12) { when } }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var where_: some View {
        Label((session.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }) ?? session.projectKey, systemImage: "folder")
        if let b = session.gitBranch { Label(b, systemImage: "arrow.triangle.branch") }
    }
    @ViewBuilder private var when: some View {
        Label(session.start.map { Fmt.dateTime.string(from: $0) } ?? "—", systemImage: "calendar")
        Text(session.shortID).font(.caption.monospaced()).foregroundStyle(.tertiary)
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
            Metric(title: "Total tokens", value: Fmt.tokens(session.tokens.total), caption: "\(Fmt.tokens(session.tokens.fresh)) excl. cache reads", icon: "number")
            Metric(title: "API cost", value: Fmt.usd(session.cost), caption: session.tokensByModel.keys.sorted().joined(separator: ", "), icon: "dollarsign.circle")
            Metric(title: "Prompts", value: "\(session.userTurns)", caption: "\(session.assistantTurns) replies · \(session.toolCalls) tool calls", icon: "text.bubble")
            Metric(title: "Duration", value: Fmt.duration(session.start, session.end), caption: "last \(Fmt.ago(session.end))", icon: "timer")
        }
    }

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("AI summary", systemImage: "sparkles").font(.headline)
                    Spacer()
                    if summarizing {
                        ProgressView().controlSize(.small)
                        Text("Summarizing with \(Summarizer.model)…").font(.caption).foregroundStyle(.secondary)
                    } else if let summary {
                        if Summarizer.isStale(summary, for: session) {
                            Text("Session has new activity").font(.caption).foregroundStyle(.orange)
                        }
                        Text("\(summary.model) · \(Fmt.ago(summary.generatedAt))").font(.caption).foregroundStyle(.tertiary)
                    }
                    Button { Task { await summarize() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(summarizing).help("Regenerate summary")
                }
                if let summaryError {
                    Text(summaryError).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                }
                if let summary {
                    MarkdownText(summary.text)
                } else if summarizing {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<4) { i in RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: [320, 420, 260, 380][i], height: 12) }
                    }
                    .redacted(reason: .placeholder)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ContextMeter(used: session.lastContextTokens, window: session.contextWindow).frame(maxWidth: 420)
            // Wraps onto two rows when the pane is narrow, so the buttons never force the window wider.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { primaryActions; secondaryActions }
                VStack(alignment: .leading, spacing: 8) { HStack(spacing: 10) { primaryActions }; HStack(spacing: 10) { secondaryActions } }
            }
        }
    }

    @ViewBuilder private var primaryActions: some View {
        Button { state.compose(resume: session) } label: { Label("Continue here", systemImage: "arrowshape.turn.up.right") }
            .buttonStyle(.borderedProminent)
        Button { Handoff.resumeInTerminal(session) } label: { Label("Resume in Terminal", systemImage: "terminal") }
        Menu {
            if let cwd = session.cwd {
                ForEach(Handoff.editors, id: \.bundle) { e in Button("Open folder in \(e.name)") { Handoff.open(cwd, inEditor: e.bundle) } }
                Button("Open folder in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: cwd)) }
                Divider()
            }
            if let url = sessions.liveSession(for: session.id)?.remoteURL.flatMap(URL.init(string:)) {
                Button("Open on claude.ai / phone") { NSWorkspace.shared.open(url) }
            }
            Button("Copy resume command") {
                let cmd = "cd \(Handoff.shellQuote(session.cwd ?? "~")) && claude --resume \(session.id)"
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
            }
            Button("Copy summary") {
                let text = "# \(session.title)\n\n" + (summary?.text ?? "")
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            }
        } label: { Label("Hand off", systemImage: "arrow.up.forward.app") }.fixedSize()
    }

    @ViewBuilder private var secondaryActions: some View {
        Button { NSWorkspace.shared.open(MemoryWriter.shared.docURL(for: session)) } label: { Label("Memory doc", systemImage: "doc.text") }
        Button {
            let md = (try? String(contentsOf: MemoryWriter.shared.docURL(for: session), encoding: .utf8)) ?? "# \(session.title)"
            Exporter.exportWithPanel(markdown: md, title: session.title, defaultName: session.title)
        } label: { Label("Export…", systemImage: "square.and.arrow.up") }
        ShareLink(item: MemoryWriter.shared.docURL(for: session)) { Image(systemName: "square.and.arrow.up.on.square") }
            .help("Share the memory doc (Mail, AirDrop, Notes…)")
    }

    private var changesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Files Claude changed (\(changes.count))", systemImage: "doc.on.doc").font(.headline)
                Spacer()
                Text("Compared with the version from before this session").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(changes) { f in
                    HStack {
                        Image(systemName: f.wasCreated ? "doc.badge.plus" : f.exists ? "doc.badge.gearshape" : "doc.badge.ellipsis")
                            .foregroundStyle(f.wasCreated ? .green : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((f.path as NSString).lastPathComponent).font(.callout.weight(.medium))
                            Text((f.path as NSString).abbreviatingWithTildeInPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if f.wasCreated { Tag(text: "new", color: .green) }
                        if !f.exists { Tag(text: "deleted since", color: .red) }
                        Button("Diff") { diffFile = f }.controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    Divider()
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
        .sheet(item: $diffFile) { f in DiffSheet(file: f) }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Memory", systemImage: "text.alignleft").font(.headline)
                Spacer()
                Toggle("Show tool calls", isOn: $showTools).toggleStyle(.switch).controlSize(.small)
            }
            if loadingTranscript { ProgressView().frame(maxWidth: .infinity) }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(transcript.filter { showTools ? $0.role != .system : ($0.role == .user || $0.role == .assistant) }) { e in
                    TranscriptBubble(e: e)
                }
            }
        }
    }

    private func load() async {
        summary = Summarizer.cached(for: session)
        let url = session.path
        let t = await Task.detached { SessionParser.transcript(url: url) }.value
        transcript = t
        loadingTranscript = false
        let s = session
        changes = await Task.detached { FileHistory.changes(for: s) }.value
        // Generate a summary the first time this memory page is opened (or when it's out of date).
        // A session that's mid-task keeps its old summary until it goes idle, to avoid churning the model.
        let busy = sessions.liveSession(for: session.id)?.isBusy ?? false
        if let s = summary {
            if Summarizer.isStale(s, for: session) && !busy { await summarize() }
        } else {
            await summarize()
        }
    }

    private func summarize() async {
        summarizing = true; summaryError = nil
        do { summary = try await Summarizer.generate(for: session) }
        catch { summaryError = error.localizedDescription }
        summarizing = false
    }
}

struct TranscriptBubble: View {
    let e: TranscriptEntry
    var body: some View {
        switch e.role {
        case .user:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("You").font(.caption.weight(.bold)).foregroundStyle(.tint)
                    if let t = e.timestamp { Text(t.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary) }
                }
                Text(e.text).textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude").font(.caption.weight(.bold)).foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                MarkdownText(e.text)
            }
            .padding(.horizontal, 12)
        case .tool:
            Text(e.text).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 12)
        case .system:
            EmptyView()
        }
    }
}

/// Lightweight Markdown renderer: headings, bullets and inline styles.
struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in b }
        }
        .textSelection(.enabled)
    }

    private var blocks: [AnyView] {
        var out: [AnyView] = []
        var inCode = false
        var code: [String] = []
        for raw in text.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    out.append(AnyView(Text(code.joined(separator: "\n")).font(.caption.monospaced())
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))))
                    code = []
                }
                inCode.toggle(); continue
            }
            if inCode { code.append(raw); continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { out.append(AnyView(Spacer().frame(height: 2))); continue }
            if line.hasPrefix("#") {
                let t = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                out.append(AnyView(Text(inline(t)).font(.headline).padding(.top, 4)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                let indent = CGFloat(raw.prefix { $0 == " " }.count) * 5
                out.append(AnyView(HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(inline(String(line.dropFirst(2))))
                }.padding(.leading, indent)))
            } else {
                out.append(AnyView(Text(inline(line))))
            }
        }
        if !code.isEmpty { out.append(AnyView(Text(code.joined(separator: "\n")).font(.caption.monospaced()))) }
        return out
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}


struct DiffSheet: View {
    let file: ChangedFile
    @Environment(\.dismiss) private var dismiss
    @State private var diff = ""
    @State private var confirm = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text((file.path as NSString).lastPathComponent).font(.headline)
                    let st = FileHistory.stats(diff)
                    Text("+\(st.added)  −\(st.removed) since before the session").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(file.wasCreated ? "Move to Trash…" : "Restore original…", role: .destructive) { confirm = true }
                    .disabled(file.wasCreated && !file.exists)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            if let message { Text(message).font(.callout).foregroundStyle(.green).padding(.horizontal) }
            Divider()
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        Text(String(line).isEmpty ? " " : String(line))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("+") ? Color.green : line.hasPrefix("-") ? Color.red : line.hasPrefix("@@") ? Color.purple : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.hasPrefix("+") ? Color.green.opacity(0.08) : line.hasPrefix("-") ? Color.red.opacity(0.08) : .clear)
                    }
                }
                .padding(12)
                .textSelection(.enabled)
            }
        }
        .frame(width: 860, height: 620)
        .task { diff = await Task.detached { FileHistory.diff(file) }.value }
        .confirmationDialog(file.wasCreated ? "Move \((file.path as NSString).lastPathComponent) to the Trash?" : "Replace \((file.path as NSString).lastPathComponent) with the version from before this session?",
                            isPresented: $confirm) {
            Button(file.wasCreated ? "Move to Trash" : "Restore", role: .destructive) {
                do {
                    try FileHistory.restore(file)
                    message = file.wasCreated ? "Moved to the Trash." : "Restored. Any later edits to this file were undone too."
                    diff = FileHistory.diff(file)
                } catch { message = error.localizedDescription }
            }
        } message: {
            Text("This also undoes any changes made to the file after the session. Claude Code keeps its own backup, so you can compare again afterwards.")
        }
    }
}

