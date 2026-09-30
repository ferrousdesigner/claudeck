import SwiftUI
import AppKit

// MARK: - MCP

struct MCPAddSheet: View {
    @EnvironmentObject var ext: ExtensionsStore
    @EnvironmentObject var sessions: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: MCPDraft
    @State private var working = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add MCP server").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $draft.name, prompt: Text("e.g. github"))
                Picker("Type", selection: $draft.transport) {
                    Text("Local command (stdio)").tag(MCPDraft.Transport.stdio)
                    Text("Remote (HTTP)").tag(MCPDraft.Transport.http)
                    Text("Remote (SSE, older)").tag(MCPDraft.Transport.sse)
                }
                if draft.transport == .stdio {
                    TextField("Command", text: $draft.commandOrURL, prompt: Text("npx"))
                    TextField("Arguments", text: $draft.args, prompt: Text("-y @modelcontextprotocol/server-postgres postgres://…"))
                    KeyValueEditor(title: "Environment variables", rows: $draft.env, keyHint: "API_KEY", valueHint: "value")
                } else {
                    TextField("URL", text: $draft.commandOrURL, prompt: Text("https://…/mcp"))
                    KeyValueEditor(title: "Headers", rows: $draft.headers, keyHint: "Authorization", valueHint: "Bearer …")
                }
                Picker("Available in", selection: $draft.scope) {
                    Text("All my projects (user)").tag("user")
                    Text("One project, just me (local)").tag("local")
                    Text("One project, shared via .mcp.json (project)").tag("project")
                }
                if draft.scope != "user" {
                    Picker("Project", selection: Binding(get: { draft.projectDir ?? "" }, set: { draft.projectDir = $0.isEmpty ? nil : $0 })) {
                        Text("Choose…").tag("")
                        ForEach(sessions.knownProjects, id: \.self) { Text(($0 as NSString).abbreviatingWithTildeInPath).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            Text("Runs: claude \(draft.cliArgs.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
            if draft.transport != .stdio && draft.headers.allSatisfy({ $0.key.isEmpty }) {
                Text("Servers that use OAuth (GitHub, Linear, Notion, Sentry…) ask you to sign in the first time Claude uses them, or run /mcp in Claude Code.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result {
                Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.ok ? .green : .red).font(.callout).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(result?.ok == true ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        working = true
                        result = await MCPManager.add(draft)
                        working = false
                        if result?.ok == true { ext.reloadMCP() }
                    }
                } label: { if working { ProgressView().controlSize(.small) } else { Text("Add server") } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid || working || result?.ok == true)
            }
        }
        .padding(20)
        .frame(width: 600, height: 620)
    }
}

struct KeyValueEditor: View {
    let title: String
    @Binding var rows: [MCPDraft.KeyValue]
    let keyHint: String
    let valueHint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button { rows.append(.init()) } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
            }
            ForEach($rows) { $r in
                HStack {
                    TextField("", text: $r.key, prompt: Text(keyHint)).frame(width: 160)
                    SecureOrPlainField(text: $r.value, hint: valueHint, secret: r.key.lowercased().contains("key") || r.key.lowercased().contains("token") || r.key.lowercased().contains("auth"))
                    Button { rows.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
        }
    }
}

struct SecureOrPlainField: View {
    @Binding var text: String
    let hint: String
    let secret: Bool
    var body: some View {
        if secret { SecureField("", text: $text, prompt: Text(hint)) } else { TextField("", text: $text, prompt: Text(hint)) }
    }
}

// MARK: - Hooks

struct HookRecipe: Identifiable {
    var id: String { name }
    let name: String
    let blurb: String
    let entry: ClaudeSettings.HookEntry

    static let all: [HookRecipe] = [
        HookRecipe(name: "Format after edits", blurb: "Run Prettier on every file Claude writes or edits.",
                   entry: .init(event: "PostToolUse", matcher: "Edit|Write|MultiEdit",
                                command: #"jq -r '.tool_input.file_path // empty' | xargs -I{} npx --no-install prettier --write "{}" 2>/dev/null || true"#, timeout: 30)),
        HookRecipe(name: "Block rm -rf", blurb: "Stop any shell command containing rm -rf before it runs.",
                   entry: .init(event: "PreToolUse", matcher: "Bash",
                                command: #"jq -r '.tool_input.command' | grep -qE 'rm\s+-(rf|fr)' && { echo 'Blocked by hook: rm -rf is not allowed' >&2; exit 2; } || exit 0"#, timeout: 10)),
        HookRecipe(name: "Protect .env files", blurb: "Refuse edits to .env and secrets files.",
                   entry: .init(event: "PreToolUse", matcher: "Edit|Write|MultiEdit",
                                command: #"jq -r '.tool_input.file_path // empty' | grep -qE '(^|/)\.env|secrets' && { echo 'Blocked: protected file' >&2; exit 2; } || exit 0"#, timeout: 10)),
        HookRecipe(name: "Say when done", blurb: "Speak “Claude is done” when a reply finishes.",
                   entry: .init(event: "Stop", matcher: "", command: "say 'Claude is done' &", timeout: 5)),
        HookRecipe(name: "Lint before commit", blurb: "Run npm run lint before any git commit Claude makes.",
                   entry: .init(event: "PreToolUse", matcher: "Bash",
                                command: #"jq -r '.tool_input.command' | grep -q 'git commit' && { npm run lint --silent >&2 || exit 2; } || exit 0"#, timeout: 120)),
        HookRecipe(name: "Log every command", blurb: "Append each shell command to ~/.claude/bash-log.txt.",
                   entry: .init(event: "PreToolUse", matcher: "Bash",
                                command: #"jq -r '"\(now|todate) \(.cwd) $ \(.tool_input.command)"' >> ~/.claude/bash-log.txt"#, timeout: 5)),
    ]
}

struct HooksEditor: View {
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var ext: ExtensionsStore
    @State private var scope: ClaudeSettings.Scope = .user
    @State private var project = ""
    @State private var hooks: [ClaudeSettings.HookEntry] = []
    @State private var draft = ClaudeSettings.HookEntry(event: "PostToolUse", matcher: "", command: "", timeout: nil)
    @State private var error: String?

    private var url: URL { ClaudeSettings.url(scope, project: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScopePicker(scope: $scope, project: $project)
            Text("Hooks run your own shell commands at points in Claude's work, e.g. after every edit. The command gets details as JSON on stdin; exit code 2 blocks the action and shows Claude your stderr.")
                .font(.callout).foregroundStyle(.secondary)

            Text("Active hooks").font(.headline)
            if hooks.isEmpty { Text("None in \((url.path as NSString).abbreviatingWithTildeInPath)").foregroundStyle(.secondary) }
            ForEach(hooks) { h in
                Card(padding: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Tag(text: h.event, color: .purple); if !h.matcher.isEmpty { Tag(text: h.matcher, color: .blue) }; if let t = h.timeout { Tag(text: "\(t)s") } }
                            Text(h.command).font(.caption.monospaced()).textSelection(.enabled).lineLimit(4)
                            if h.command.contains("--hook permission") || h.command.contains("--hook event") {
                                Text("Installed by Claudeck for approvals and alerts").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) { mutate { try ClaudeSettings.removeHook(h, from: url) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Text("Recipes").font(.headline).padding(.top, 6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                ForEach(HookRecipe.all) { r in
                    let on = hooks.contains { $0.command == r.entry.command }
                    Card(padding: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(r.name).font(.headline); Spacer(); if on { Tag(text: "on", color: .green) } }
                            Text(r.blurb).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Customize") { draft = r.entry }.buttonStyle(.borderless).font(.caption)
                                Spacer()
                                Button(on ? "Added" : "Add") { mutate { try ClaudeSettings.addHook(r.entry, to: url) } }
                                    .disabled(on).controlSize(.small)
                            }
                        }
                    }
                }
            }

            Text("Custom hook").font(.headline).padding(.top, 6)
            Card {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("When").foregroundStyle(.secondary)
                        Picker("", selection: $draft.event) { ForEach(ClaudeSettings.hookEvents, id: \.self) { Text(eventLabel($0)).tag($0) } }.labelsHidden()
                    }
                    GridRow {
                        Text("Matching").foregroundStyle(.secondary)
                        TextField("", text: $draft.matcher, prompt: Text("Tool name or regex, e.g. Bash or Edit|Write — blank for all"))
                    }
                    GridRow {
                        Text("Run").foregroundStyle(.secondary)
                        TextField("", text: $draft.command, prompt: Text("shell command"), axis: .vertical).font(.callout.monospaced()).lineLimit(2...5)
                    }
                    GridRow {
                        Text("Timeout").foregroundStyle(.secondary)
                        HStack {
                            TextField("", value: $draft.timeout, format: .number, prompt: Text("default")).frame(width: 80)
                            Text("seconds").foregroundStyle(.secondary)
                            Spacer()
                            Button("Add hook") { mutate { try ClaudeSettings.addHook(draft, to: url) } }
                                .buttonStyle(.borderedProminent).disabled(draft.command.isEmpty)
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            Text("Changes apply to new Claude Code sessions. A backup of the original file is saved next to it as .claudeck.bak.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .onAppear(perform: load)
        .onChange(of: scope) { _, _ in load() }
        .onChange(of: project) { _, _ in load() }
    }

    private func load() { hooks = ClaudeSettings.hooks(url) }

    private func mutate(_ f: () throws -> Void) {
        do { try f(); error = nil } catch { self.error = error.localizedDescription }
        load()
        ext.reload(projects: sessions.knownProjects)
    }

    private func eventLabel(_ e: String) -> String {
        [
            "PreToolUse": "Before a tool runs (PreToolUse)", "PostToolUse": "After a tool runs (PostToolUse)",
            "PermissionRequest": "Claude asks permission (PermissionRequest)", "Notification": "Claude sends a notification",
            "UserPromptSubmit": "You send a prompt (UserPromptSubmit)", "Stop": "Claude finishes a reply (Stop)",
            "SubagentStop": "A subagent finishes", "PreCompact": "Before /compact", "SessionStart": "Session starts", "SessionEnd": "Session ends",
        ][e] ?? e
    }
}

struct ScopePicker: View {
    @EnvironmentObject var sessions: SessionStore
    @Binding var scope: ClaudeSettings.Scope
    @Binding var project: String

    var body: some View {
        HStack {
            Picker("Settings file", selection: $scope) {
                ForEach(ClaudeSettings.Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(maxWidth: 420)
            if scope != .user {
                Picker("", selection: $project) {
                    Text("Choose project…").tag("")
                    ForEach(sessions.knownProjects, id: \.self) { Text(($0 as NSString).abbreviatingWithTildeInPath).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 260)
            }
            Spacer()
            Button("Open file") {
                let u = ClaudeSettings.url(scope, project: project)
                if FileManager.default.fileExists(atPath: u.path) { NSWorkspace.shared.open(u) } else { NSWorkspace.shared.open(u.deletingLastPathComponent()) }
            }
            .disabled(scope != .user && project.isEmpty)
        }
        .onChange(of: scope) { _, s in if s != .user && project.isEmpty { project = sessions.knownProjects.first ?? "" } }
    }
}

// MARK: - Permissions

struct PermissionsEditor: View {
    @State private var scope: ClaudeSettings.Scope = .user
    @State private var project = ""
    @State private var perm = ClaudeSettings.Permissions()
    @State private var saved = ClaudeSettings.Permissions()
    @State private var error: String?

    private var url: URL { ClaudeSettings.url(scope, project: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScopePicker(scope: $scope, project: $project)
            let risks = ClaudeSettings.risks(perm, settings: ClaudeSettings.read(url))
            if !risks.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Worth a look", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.headline)
                        ForEach(risks, id: \.self) { Text("• \($0)").font(.callout) }
                        if risks.contains(where: { $0.contains(".env") }) {
                            Button("Deny reading .env files") {
                                for r in ["Read(./.env)", "Read(./.env.*)"] where !perm.deny.contains(r) { perm.deny.append(r) }
                            }.controlSize(.small)
                        }
                    }
                }
            }
            HStack {
                Text("Default mode").frame(width: 120, alignment: .leading)
                Picker("", selection: $perm.defaultMode) {
                    Text("Not set (ask each time)").tag("")
                    Text("Ask each time (default)").tag("default")
                    Text("Auto-accept edits").tag("acceptEdits")
                    Text("Plan mode").tag("plan")
                    Text("Auto (classifier decides)").tag("auto")
                    Text("Don't ask (deny if not allowed)").tag("dontAsk")
                    Text("Bypass all ⚠︎").tag("bypassPermissions")
                }.labelsHidden().frame(width: 280)
            }
            RuleList(title: "Always allow", color: .green, rules: $perm.allow,
                     suggestions: ["Bash(npm test:*)", "Bash(npm run lint)", "Bash(git status)", "Bash(git diff:*)", "WebSearch", "Read(./**)"])
            RuleList(title: "Always ask", color: .orange, rules: $perm.ask,
                     suggestions: ["Bash(git push:*)", "Bash(rm:*)", "WebFetch"])
            RuleList(title: "Never allow", color: .red, rules: $perm.deny,
                     suggestions: ["Read(./.env)", "Read(./.env.*)", "Read(./secrets/**)", "Bash(sudo:*)", "Bash(curl:*)", "Edit(./.git/**)"])
            RuleList(title: "Extra folders Claude can use", color: .blue, rules: $perm.additionalDirectories, suggestions: [], placeholder: "/path/to/folder")
            Text("Rule syntax: Tool or Tool(specifier). Bash(npm test:*) matches commands starting with “npm test”; Read(./.env) and Edit(src/**) take file globs; WebFetch(domain:github.com) limits to a site; mcp__server__tool targets MCP tools.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let error { Text(error).foregroundStyle(.red) }
                Spacer()
                Button("Revert") { perm = saved }.disabled(perm == saved)
                Button("Save") {
                    do { try ClaudeSettings.setPermissions(perm, url); saved = perm; error = nil }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).disabled(perm == saved)
            }
        }
        .onAppear(perform: load)
        .onChange(of: scope) { _, _ in load() }
        .onChange(of: project) { _, _ in load() }
    }

    private func load() { perm = ClaudeSettings.permissions(url); saved = perm }
}

struct RuleList: View {
    let title: String
    let color: Color
    @Binding var rules: [String]
    let suggestions: [String]
    var placeholder = "Rule, e.g. Bash(npm run build)"
    @State private var newRule = ""

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(color)
                FlowRow(items: rules) { r in
                    HStack(spacing: 4) {
                        Text(r).font(.callout.monospaced())
                        Button { rules.removeAll { $0 == r } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(color.opacity(0.12), in: Capsule())
                }
                HStack {
                    TextField("", text: $newRule, prompt: Text(placeholder)).onSubmit(add)
                    Button("Add", action: add).disabled(newRule.isEmpty)
                }
                let unused = suggestions.filter { !rules.contains($0) }
                if !unused.isEmpty {
                    HStack(spacing: 6) {
                        Text("Suggestions:").font(.caption).foregroundStyle(.secondary)
                        ForEach(unused, id: \.self) { s in
                            Button(s) { rules.append(s) }.buttonStyle(.link).font(.caption.monospaced())
                        }
                    }
                }
            }
        }
    }

    private func add() {
        let r = newRule.trimmingCharacters(in: .whitespaces)
        if !r.isEmpty && !rules.contains(r) { rules.append(r) }
        newRule = ""
    }
}

/// Wrapping horizontal layout for chips.
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content
    var body: some View {
        FlowLayout(spacing: 6) { ForEach(items, id: \.self) { content($0) } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: subviews.isEmpty ? 0 : y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

// MARK: - CLAUDE.md & memory

struct InstructionsEditor: View {
    @EnvironmentObject var sessions: SessionStore
    @State private var files: [InstructionFile] = []
    @State private var selected: InstructionFile?
    @State private var text = ""
    @State private var original = ""
    @State private var stale: [String: [StaleReference]] = [:]
    @State private var message: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                let groups = Dictionary(grouping: files, by: \.scope).sorted { a, b in
                    a.key.hasPrefix("Personal") ? true : b.key.hasPrefix("Personal") ? false : a.key < b.key
                }
                ForEach(groups, id: \.key) { g in
                    Text(g.key).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                    ForEach(g.value) { f in
                        Button { select(f) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: f.kind == .claudeMD ? "doc.text" : "brain").foregroundStyle(f.exists ? Color.accentColor : .secondary)
                                Text(f.kind == .claudeMD ? f.name : f.name.replacingOccurrences(of: ".md", with: ""))
                                    .lineLimit(1).foregroundStyle(f.exists ? .primary : .secondary)
                                if !f.exists { Text("create").font(.caption2).foregroundStyle(.tertiary) }
                                Spacer()
                                if let s = stale[f.path], !s.isEmpty {
                                    Text("\(s.count)").font(.caption2.weight(.bold)).padding(.horizontal, 5)
                                        .background(Color.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange)
                                        .help("References that no longer exist")
                                }
                            }
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(selected?.id == f.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 260)

            VStack(alignment: .leading, spacing: 8) {
                if let f = selected {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(f.kind == .claudeMD ? "Instructions Claude reads at the start of every session\(f.projectDir == nil ? "" : " in \(f.scope)")" : "A memory Claude saved")
                                .font(.headline)
                            Text((f.path as NSString).abbreviatingWithTildeInPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if f.kind != .claudeMD {
                            Button("Delete", role: .destructive) {
                                try? FileManager.default.trashItem(at: URL(fileURLWithPath: f.path), resultingItemURL: nil)
                                reload(); selected = nil
                            }
                        }
                        Button("Revert") { text = original }.disabled(text == original)
                        Button("Save") { save(f) }.buttonStyle(.borderedProminent).disabled(text == original)
                    }
                    if let s = stale[f.path], !s.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Possibly out of date", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout.weight(.semibold))
                            ForEach(s, id: \.self) { r in Text("Line \(r.line): \(r.reference) doesn't exist").font(.caption) }
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    TextEditor(text: $text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .scrollContentBackground(.hidden).padding(8)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                        .frame(minHeight: 420)
                    if let message { Text(message).font(.caption).foregroundStyle(.green) }
                } else {
                    ContentUnavailableView("Pick a file", systemImage: "doc.text",
                                           description: Text("CLAUDE.md files tell Claude how to work in a project. Memories are notes Claude saved about you and your work. Orange counts mark references to files that no longer exist."))
                }
            }
        }
        .task(id: sessions.isLoading) { reload() }
    }

    private func reload() {
        let projects = sessions.knownProjects, keys = sessions.projectKeys
        files = InstructionFiles.all(projects: projects, projectKeys: keys)
        let list = files
        Task.detached(priority: .utility) {
            var st: [String: [StaleReference]] = [:]
            for f in list where f.exists {
                if let t = try? String(contentsOfFile: f.path, encoding: .utf8) { st[f.path] = InstructionFiles.staleReferences(in: t, file: f) }
            }
            await MainActor.run { stale = st }
        }
    }

    private func select(_ f: InstructionFile) {
        selected = f
        message = nil
        original = (try? String(contentsOfFile: f.path, encoding: .utf8)) ?? (f.kind == .claudeMD ? "# \(f.scope)\n\n## How to work in this project\n\n- \n" : "")
        if !f.exists { original = "" ; text = "# \(f.scope)\n\n## How to work in this project\n\n- " } else { text = original }
    }

    private func save(_ f: InstructionFile) {
        do {
            try FileManager.default.createDirectory(atPath: (f.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: f.path, atomically: true, encoding: .utf8)
            original = text
            message = "Saved. New sessions will use it."
            reload()
            selected = files.first { $0.path == f.path }
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Creator

struct CreatorSheet: View {
    @EnvironmentObject var ext: ExtensionsStore
    @EnvironmentObject var sessions: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State var kind: Creator.Kind
    @State private var name = ""
    @State private var description = ""
    @State private var body_ = ""
    @State private var tools = ""
    @State private var model = ""
    @State private var project = ""
    @State private var error: String?

    init(kind: Creator.Kind) { _kind = State(initialValue: kind) }

    private var slug: String { name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { if !($1 == "-" && $0.last == "-") { $0.append($1) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $kind) { ForEach(Creator.Kind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            Text(help).font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name, prompt: Text(kind == .command ? "review-pr" : kind == .agent ? "test-writer" : "release-notes"))
                if !slug.isEmpty { Text(kind == .command ? "Use it as /\(slug)" : "Saved as \(slug)").font(.caption).foregroundStyle(.secondary) }
                TextField(kind == .command ? "What it does" : "When Claude should use it", text: $description, prompt: Text(descHint), axis: .vertical).lineLimit(2...4)
                if kind == .agent {
                    TextField("Tools (optional)", text: $tools, prompt: Text("Read, Grep, Glob, Bash — blank for all"))
                    ModelPicker(model: $model)
                }
                Picker("Available in", selection: $project) {
                    Text("All my projects").tag("")
                    ForEach(sessions.knownProjects, id: \.self) { Text("Only \(($0 as NSString).lastPathComponent)").tag($0) }
                }
                TextField("Instructions", text: $body_, prompt: Text(bodyHint), axis: .vertical).lineLimit(6...14)
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    do {
                        let content = Creator.template(kind: kind, name: slug, description: description, body: body_, tools: tools, model: model)
                        let url = try Creator.create(kind: kind, name: slug, projectDir: project.isEmpty ? nil : project, content: content)
                        ext.reload(projects: sessions.knownProjects)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction).disabled(slug.isEmpty || description.isEmpty)
            }
        }
        .padding(20).frame(width: 600, height: 640)
    }

    private var help: String {
        switch kind {
        case .skill: return "A skill is a set of instructions (plus optional scripts) Claude loads automatically when a task matches its description."
        case .agent: return "A subagent is a specialist Claude can hand work to, with its own instructions, tools and model."
        case .command: return "A slash command is a saved prompt you trigger by typing /name in Claude Code. $ARGUMENTS is replaced with what you type after it."
        }
    }
    private var descHint: String {
        switch kind {
        case .skill: return "Use when the user asks for release notes or a changelog"
        case .agent: return "Writes and runs unit tests for changed code. Use after implementing a feature."
        case .command: return "Review the current PR for bugs"
        }
    }
    private var bodyHint: String {
        switch kind {
        case .skill: return "1. Read the git log since the last tag\n2. Group changes by type\n3. …"
        case .agent: return "You are a meticulous test engineer. When invoked…"
        case .command: return "Review $ARGUMENTS for correctness, security and readability…"
        }
    }
}

