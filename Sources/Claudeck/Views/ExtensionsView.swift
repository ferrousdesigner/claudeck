import SwiftUI
import AppKit

struct ExtensionsView: View {
    enum Section: String, CaseIterable {
        case skills = "Skills", plugins = "Plugins", mcp = "MCP", agents = "Agents & commands", hooks = "Hooks",
             permissions = "Permissions", memory = "CLAUDE.md & memory", settings = "settings.json"
    }

    @EnvironmentObject var ext: ExtensionsStore
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var state: AppState
    @State private var creating: Creator.Kind?
    @State private var addingMCP: MCPDraft?
    @State private var mcpDetails: (String, String)?
    @State private var pluginDetails: (String, String)?
    private var section: Section { state.extensionsSection }
    @State private var search = ""
    @State private var installedOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Extensions").font(.largeTitle.weight(.bold))
                Spacer()
                if ext.loading { ProgressView().controlSize(.small) }
                Menu {
                    ForEach(Creator.Kind.allCases) { k in Button("New \(k.rawValue.lowercased())…") { creating = k } }
                    Button("Add MCP server…") { addingMCP = MCPDraft() }
                } label: { Label("Create", systemImage: "plus") }.fixedSize()
                Button { ext.reload(projects: sessions.knownProjects) } label: { Label("Reload", systemImage: "arrow.clockwise") }
            }
            .padding([.horizontal, .top], 24)

            HStack {
                Picker("", selection: $state.extensionsSection) {
                    ForEach(Section.allCases, id: \.self) { s in Text("\(s.rawValue) \(count(s))").tag(s) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(.horizontal, 24).padding(.vertical, 12)

            if [.skills, .plugins, .mcp, .agents].contains(section) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter \(section.rawValue.lowercased())", text: $search).textFieldStyle(.plain)
                    if section == .plugins { Toggle("Installed only", isOn: $installedOnly).controlSize(.small) }
                }
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24)
            }

            if let err = ext.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.callout).lineLimit(3)
                    Spacer()
                    Button("Dismiss") { ext.lastError = nil }
                }
                .padding(10).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24).padding(.top, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    switch section {
                    case .skills: skillsList
                    case .plugins: pluginsList
                    case .mcp: mcpList
                    case .agents: agentsList
                    case .hooks: HooksEditor()
                    case .permissions: PermissionsEditor()
                    case .memory: InstructionsEditor()
                    case .settings: settingsSection
                    }
                }
                .padding(24)
            }
            .fabClearance()
        }
        .task(id: sessions.isLoading) { if !sessions.isLoading { ext.reload(projects: sessions.knownProjects) } }
        .sheet(item: $creating) { k in CreatorSheet(kind: k) }
        .sheet(item: Binding(get: { addingMCP.map { IdentifiedDraft(draft: $0) } }, set: { addingMCP = $0?.draft })) { d in
            MCPAddSheet(draft: d.draft)
        }
        .sheet(item: Binding(get: { mcpDetails.map { TextSheetItem(title: $0.0, text: $0.1) } }, set: { _ in mcpDetails = nil })) { TextSheet(item: $0) }
        .sheet(item: Binding(get: { pluginDetails.map { TextSheetItem(title: $0.0, text: $0.1) } }, set: { _ in pluginDetails = nil })) { TextSheet(item: $0) }
    }

    private func count(_ s: Section) -> String {
        let n: Int
        switch s {
        case .skills: n = ext.skills.count
        case .plugins: n = ext.plugins.filter(\.installed).count
        case .mcp: n = ext.mcpServers.count
        case .agents: n = ext.agentsAndCommands.count
        case .hooks: n = ext.hooks.count
        default: n = 0
        }
        return n > 0 ? "(\(n))" : ""
    }

    private func matches(_ parts: String...) -> Bool {
        search.isEmpty || parts.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    // MARK: Skills

    @ViewBuilder private var skillsList: some View {
        let items = ext.skills.filter { matches($0.name, $0.description, $0.source) }
        if items.isEmpty { empty("No skills found", "Skills live in ~/.claude/skills, <project>/.claude/skills and inside plugins.") }
        let groups = Dictionary(grouping: items, by: \.source).sorted { $0.key < $1.key }
        ForEach(groups, id: \.key) { g in
            Text(g.key).font(.headline).padding(.top, 6)
            ForEach(g.value) { s in
                ItemCard(icon: "wand.and.stars", title: s.name, subtitle: s.description, tag: nil, path: s.path)
            }
        }
        Text("Built-in skills and slash commands (like /init, /code-review, /simplify) ship inside Claude Code itself, so they don't appear here.")
            .font(.caption).foregroundStyle(.tertiary).padding(.top, 8)
    }

    // MARK: Plugins

    @ViewBuilder private var pluginsList: some View {
        let items = ext.plugins.filter { (!installedOnly || $0.installed) && matches($0.name, $0.description, $0.category ?? "", $0.author ?? "") }
        if items.isEmpty { empty("No plugins", "Add a marketplace with `claude plugin marketplace add`.") }
        ForEach(items) { p in
            Card(padding: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "shippingbox").font(.title2).foregroundStyle(p.installed ? Color.accentColor : .secondary).frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(p.name).font(.headline)
                            if let c = p.category { Tag(text: c) }
                            if p.installed { Tag(text: p.enabled ? "enabled" : "disabled", color: p.enabled ? .green : .secondary) }
                        }
                        Text(p.description).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        Text("\(p.author.map { "by \($0) · " } ?? "")\(p.marketplace)").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Details") {
                        if p.installed {
                            Task {
                                let r = await CLI.run(["plugin", "details", p.id])
                                pluginDetails = (p.name, (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                        } else {
                            pluginDetails = (p.name, p.offlineDetails)
                        }
                    }.buttonStyle(.borderless)
                    if ext.busyPlugin == p.id {
                        ProgressView().controlSize(.small)
                    } else if p.installed {
                        Button(p.enabled ? "Disable" : "Enable") { ext.pluginAction(p.enabled ? "disable" : "enable", p) }
                        Button("Uninstall", role: .destructive) { ext.pluginAction("uninstall", p) }
                    } else {
                        Button("Install") { ext.pluginAction("install", p) }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    // MARK: MCP

    @ViewBuilder private var mcpList: some View {
        HStack {
            Text("Servers configured for Claude Code").font(.headline)
            Spacer()
            Button { addingMCP = MCPDraft() } label: { Label("Add server", systemImage: "plus") }.buttonStyle(.borderedProminent)
            if ext.loadingMCP { ProgressView().controlSize(.small); Text("Checking health…").font(.caption).foregroundStyle(.secondary) }
            Button("Re-check") { ext.reloadMCP() }.disabled(ext.loadingMCP)
        }
        if !ext.loadingMCP && ext.mcpServers.isEmpty { empty("No MCP servers", "Add one with `claude mcp add`.") }
        ForEach(ext.mcpServers.filter { matches($0.name, $0.target) }) { m in
            Card(padding: 12) {
                HStack(spacing: 12) {
                    Circle().fill(m.ok ? Color.green : .red).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name).font(.headline)
                        Text(m.target).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                    }
                    Spacer()
                    Text(m.status).font(.callout).foregroundStyle(m.ok ? .green : .red)
                    Button("Details") { Task { mcpDetails = (m.name, await MCPManager.details(m.name)) } }.buttonStyle(.borderless)
                    if !m.name.hasPrefix("claude.ai") {
                        Button(role: .destructive) {
                            Task {
                                let r = await MCPManager.remove(m.name, scope: nil, projectDir: nil)
                                if !r.ok { ext.lastError = r.message }
                                ext.reloadMCP()
                            }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove")
                    }
                }
            }
        }
        Text("Popular servers").font(.headline).padding(.top, 12)
        Text("One click fills in the form; you review it before anything is added.").font(.caption).foregroundStyle(.secondary)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
            ForEach(MCPPreset.gallery) { p in
                let added = ext.mcpServers.contains { $0.name == p.name }
                Button { addingMCP = p.draft } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: p.icon).font(.title3).foregroundStyle(.tint).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(p.name).font(.headline); if added { Tag(text: "added", color: .green) } }
                            Text(p.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.6)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(added)
            }
        }
        let desktop = MCPManager.claudeDesktopServers()
        if !desktop.isEmpty {
            Button("Import \(desktop.count) server\(desktop.count == 1 ? "" : "s") from Claude Desktop") {
                Task {
                    var msgs: [String] = []
                    for (name, json) in desktop where !ext.mcpServers.contains(where: { $0.name == name }) {
                        let r = await MCPManager.addJSON(name: name, json: json)
                        if !r.ok { msgs.append("\(name): \(r.message)") }
                    }
                    ext.lastError = msgs.isEmpty ? nil : msgs.joined(separator: "\n")
                    ext.reloadMCP()
                }
            }.buttonStyle(.link).padding(.top, 4)
        }
    }

    // MARK: Agents & commands

    @ViewBuilder private var agentsList: some View {
        let items = ext.agentsAndCommands.filter { matches($0.name, $0.description, $0.source) }
        if items.isEmpty { empty("No custom agents or commands", "Add them as Markdown files in ~/.claude/agents or ~/.claude/commands.") }
        ForEach(items) { a in
            ItemCard(icon: a.kind == "agent" ? "person.crop.circle.badge.checkmark" : "command", title: a.name,
                     subtitle: a.description, tag: a.source, path: a.path)
        }
    }

    // MARK: Settings

    @ViewBuilder private var settingsSection: some View {
        HStack {
            Text("~/.claude/settings.json").font(.headline)
            Spacer()
            Button("Open") { NSWorkspace.shared.open(Paths.settingsFile) }
        }
        Card(padding: 12) {
            Text(ext.settingsText).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "tray", description: Text(detail)).frame(maxWidth: .infinity)
    }
}

struct ItemCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let tag: String?
    let path: String
    @State private var expanded = false

    var body: some View {
        Card(padding: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(title).font(.headline); if let tag { Tag(text: tag) } }
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
                            .onTapGesture { expanded.toggle() }
                    }
                    Text((path as NSString).abbreviatingWithTildeInPath).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless).help("Open file")
            }
        }
    }
}

struct Tag: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }
}


struct IdentifiedDraft: Identifiable { let id = UUID(); let draft: MCPDraft }
struct TextSheetItem: Identifiable { let id = UUID(); let title: String; let text: String }

struct TextSheet: View {
    let item: TextSheetItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(item.title).font(.headline); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding()
            Divider()
            ScrollView { Text(item.text).font(.callout.monospaced()).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading) }
        }
        .frame(width: 640, height: 480)
    }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
