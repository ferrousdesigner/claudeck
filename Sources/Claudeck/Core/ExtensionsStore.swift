import Foundation
import Combine

@MainActor
final class ExtensionsStore: ObservableObject {
    @Published var skills: [SkillInfo] = []
    @Published var plugins: [PluginInfo] = []
    @Published var mcpServers: [MCPServerInfo] = []
    @Published var agentsAndCommands: [AgentOrCommand] = []
    @Published var hooks: [(event: String, detail: String)] = []
    @Published var settingsText = ""
    @Published var loadingMCP = false
    @Published var loading = false
    @Published var busyPlugin: String?
    @Published var lastError: String?

    func reload(projects: [String]) {
        loading = true
        Task.detached(priority: .userInitiated) {
            let skills = Scanner.skills(projects: projects)
            let agents = Scanner.agentsAndCommands(projects: projects)
            let (hooks, settings) = Scanner.settings()
            let available = Scanner.marketplacePlugins()
            await MainActor.run {
                self.skills = skills
                self.agentsAndCommands = agents
                self.hooks = hooks
                self.settingsText = settings
                self.plugins = available
                self.loading = false
            }
            await self.refreshInstalledPlugins()
        }
        reloadMCP()
    }

    func reloadMCP() {
        loadingMCP = true
        Task {
            let res = await CLI.run(["mcp", "list"])
            self.mcpServers = Scanner.parseMCP(res.out)
            self.loadingMCP = false
        }
    }

    func refreshInstalledPlugins() async {
        let res = await CLI.run(["plugin", "list", "--json"])
        let enabledMap = Scanner.enabledPluginsFromSettings()
        var installed: [String: Bool] = [:] // id or name -> enabled
        if let data = res.out.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for p in arr {
                let id = (p["id"] as? String) ?? (p["name"] as? String) ?? ""
                let enabled = (p["enabled"] as? Bool) ?? enabledMap[id] ?? true
                installed[id] = enabled
                if let name = id.split(separator: "@").first { installed[String(name)] = enabled }
            }
        }
        for (k, v) in enabledMap where installed[k] == nil { installed[k] = v }
        var list = plugins
        for i in list.indices {
            if let e = installed[list[i].id] ?? installed[list[i].name] {
                list[i].installed = true; list[i].enabled = e
            } else {
                list[i].installed = false; list[i].enabled = false
            }
        }
        // Installed plugins from marketplaces we don't have locally.
        for (id, e) in installed where id.contains("@") && !list.contains(where: { $0.id == id }) {
            let parts = id.split(separator: "@", maxSplits: 1).map(String.init)
            list.append(PluginInfo(name: parts[0], description: "", category: nil, author: nil, marketplace: parts[1], installed: true, enabled: e))
        }
        plugins = list.sorted { ($0.installed ? 0 : 1, $0.name) < ($1.installed ? 0 : 1, $1.name) }
    }

    func pluginAction(_ action: String, _ plugin: PluginInfo) {
        busyPlugin = plugin.id
        Task {
            let res = await CLI.run(["plugin", action, plugin.id])
            if res.status != 0 { self.lastError = (res.err.isEmpty ? res.out : res.err).trimmingCharacters(in: .whitespacesAndNewlines) }
            await self.refreshInstalledPlugins()
            self.busyPlugin = nil
        }
    }
}

enum Scanner {
    static let fm = FileManager.default

    // MARK: Skills

    static func skills(projects: [String]) -> [SkillInfo] {
        var out: [SkillInfo] = []
        let skillsRoot = Paths.claudeDir.appendingPathComponent("skills")
        for file in findFiles(named: "SKILL.md", under: skillsRoot, maxDepth: 4) {
            let source = file.path.contains("/skills/synced/") ? "Synced from claude.ai" : "Personal"
            if let s = skill(at: file, source: source) { out.append(s) }
        }
        let cache = Paths.pluginsDir.appendingPathComponent("cache")
        for file in findFiles(named: "SKILL.md", under: cache, maxDepth: 7) {
            if let s = skill(at: file, source: "Plugin: \(pluginName(fromPath: file.path))") { out.append(s) }
        }
        for p in projects {
            let root = URL(fileURLWithPath: p).appendingPathComponent(".claude/skills")
            for file in findFiles(named: "SKILL.md", under: root, maxDepth: 3) {
                if let s = skill(at: file, source: "Project: \((p as NSString).lastPathComponent)") { out.append(s) }
            }
        }
        return out.sorted { ($0.source, $0.name.lowercased()) < ($1.source, $1.name.lowercased()) }
    }

    private static func skill(at url: URL, source: String) -> SkillInfo? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fm = frontmatter(text)
        let name = fm["name"] ?? url.deletingLastPathComponent().lastPathComponent
        return SkillInfo(name: name, description: fm["description"] ?? "", source: source, path: url.path)
    }

    private static func pluginName(fromPath path: String) -> String {
        // .../plugins/cache/<marketplace>/<plugin>/<version>/skills/...
        let comps = path.components(separatedBy: "/")
        if let i = comps.firstIndex(of: "cache"), comps.count > i + 2 { return comps[i + 2] }
        return "plugin"
    }

    // MARK: Agents & commands

    static func agentsAndCommands(projects: [String]) -> [AgentOrCommand] {
        var out: [AgentOrCommand] = []
        func collect(_ dir: URL, kind: String, source: String) {
            for f in findFiles(withExtension: "md", under: dir, maxDepth: 3) {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let meta = frontmatter(text)
                let name = meta["name"] ?? f.deletingPathExtension().lastPathComponent
                let desc = meta["description"] ?? firstLine(afterFrontmatter: text)
                out.append(AgentOrCommand(kind: kind, name: kind == "command" ? "/\(name)" : name, description: desc, source: source, path: f.path))
            }
        }
        collect(Paths.claudeDir.appendingPathComponent("agents"), kind: "agent", source: "Personal")
        collect(Paths.claudeDir.appendingPathComponent("commands"), kind: "command", source: "Personal")
        for p in projects {
            let base = URL(fileURLWithPath: p).appendingPathComponent(".claude")
            let label = "Project: \((p as NSString).lastPathComponent)"
            collect(base.appendingPathComponent("agents"), kind: "agent", source: label)
            collect(base.appendingPathComponent("commands"), kind: "command", source: label)
        }
        let cache = Paths.pluginsDir.appendingPathComponent("cache")
        if let e = fm.enumerator(at: cache, includingPropertiesForKeys: nil) {
            for case let u as URL in e where ["agents", "commands"].contains(u.lastPathComponent) {
                e.skipDescendants()
                collect(u, kind: u.lastPathComponent == "agents" ? "agent" : "command", source: "Plugin: \(pluginName(fromPath: u.path))")
            }
        }
        return out
    }

    // MARK: Plugins

    static func marketplacePlugins() -> [PluginInfo] {
        let known = Paths.pluginsDir.appendingPathComponent("known_marketplaces.json")
        guard let d = try? Data(contentsOf: known),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]] else { return [] }
        var out: [PluginInfo] = []
        for (mkt, info) in m {
            guard let loc = info["installLocation"] as? String else { continue }
            let manifest = URL(fileURLWithPath: loc).appendingPathComponent(".claude-plugin/marketplace.json")
            guard let md = try? Data(contentsOf: manifest),
                  let mo = try? JSONSerialization.jsonObject(with: md) as? [String: Any],
                  let plugins = mo["plugins"] as? [[String: Any]] else { continue }
            for p in plugins {
                guard let name = p["name"] as? String else { continue }
                var local: String?
                if let src = p["source"] as? String, src.hasPrefix("./") { local = (loc as NSString).appendingPathComponent(String(src.dropFirst(2))) }
                let src = p["source"] as? [String: Any]
                let home = p["homepage"] as? String ?? (src?["url"] as? String) ?? (src?["repo"] as? String).map { "https://github.com/\($0)" }
                out.append(PluginInfo(name: name, description: p["description"] as? String ?? "",
                                      category: p["category"] as? String,
                                      author: (p["author"] as? [String: Any])?["name"] as? String,
                                      marketplace: mkt, installed: false, enabled: false, localPath: local, homepage: home))
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    static func enabledPluginsFromSettings() -> [String: Bool] {
        guard let d = try? Data(contentsOf: Paths.settingsFile),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o["enabledPlugins"] as? [String: Bool] ?? [:]
    }

    // MARK: MCP

    static func parseMCP(_ out: String) -> [MCPServerInfo] {
        out.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            guard let colon = line.range(of: ": "), let dash = line.range(of: " - ", options: .backwards),
                  colon.upperBound <= dash.lowerBound else { return nil }
            let name = String(line[..<colon.lowerBound])
            if name.hasPrefix("Checking") { return nil }
            return MCPServerInfo(name: name, target: String(line[colon.upperBound..<dash.lowerBound]),
                                 status: String(line[dash.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: Settings / hooks

    static func settings() -> ([(event: String, detail: String)], String) {
        guard let d = try? Data(contentsOf: Paths.settingsFile),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return ([], "No ~/.claude/settings.json") }
        var hooks: [(String, String)] = []
        if let h = o["hooks"] as? [String: Any] {
            for (event, value) in h.sorted(by: { $0.key < $1.key }) {
                let pretty = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
                hooks.append((event, pretty))
            }
        }
        let pretty = (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (hooks, pretty)
    }

    // MARK: Helpers

    static func frontmatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---") else { return [:] }
        let lines = text.components(separatedBy: "\n")
        var out: [String: String] = [:]
        var key: String?
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[i]
            if let c = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let k = String(line[..<c]).trimmingCharacters(in: .whitespaces)
                var v = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                if v == ">" || v == "|" || v == ">-" || v == "|-" { v = "" }
                if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                    v = String(v.dropFirst().dropLast())
                }
                out[k] = v; key = k
            } else if let k = key {
                let cont = line.trimmingCharacters(in: .whitespaces)
                if !cont.isEmpty { out[k] = ((out[k] ?? "") + " " + cont).trimmingCharacters(in: .whitespaces) }
            }
            i += 1
        }
        return out
    }

    private static func firstLine(afterFrontmatter text: String) -> String {
        var body = text
        if text.hasPrefix("---"), let r = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            body = String(text[r.upperBound...])
        }
        return body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }.map { String($0.prefix(200)) } ?? ""
    }

    static func findFiles(named name: String, under root: URL, maxDepth: Int) -> [URL] {
        findFiles(under: root, maxDepth: maxDepth) { $0.lastPathComponent == name }
    }

    static func findFiles(withExtension ext: String, under root: URL, maxDepth: Int) -> [URL] {
        findFiles(under: root, maxDepth: maxDepth) { $0.pathExtension == ext }
    }

    private static func findFiles(under root: URL, maxDepth: Int, match: (URL) -> Bool) -> [URL] {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in e {
            if e.level > maxDepth { e.skipDescendants(); continue }
            if ["node_modules", ".git"].contains(u.lastPathComponent) { e.skipDescendants(); continue }
            if match(u) { out.append(u) }
        }
        return out
    }
}
