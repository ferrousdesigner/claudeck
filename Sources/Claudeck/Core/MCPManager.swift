import Foundation

struct MCPDraft: Equatable {
    enum Transport: String, CaseIterable, Identifiable { case stdio, http, sse; var id: String { rawValue } }
    var name = ""
    var transport: Transport = .stdio
    var commandOrURL = ""
    var args = ""                       // space-separated, stdio only
    var env: [KeyValue] = []            // stdio env vars
    var headers: [KeyValue] = []        // http/sse headers
    var scope = "user"                  // local | user | project
    var projectDir: String?

    struct KeyValue: Identifiable, Equatable { let id = UUID(); var key = ""; var value = "" }

    /// Arguments for `claude mcp add`. `-e` and `-H` take multiple values, so they must come
    /// after the positional name (otherwise they swallow it).
    var cliArgs: [String] {
        var a = ["mcp", "add", "--scope", scope, "--transport", transport.rawValue, name]
        if transport == .stdio {
            for kv in env where !kv.key.isEmpty { a += ["-e", "\(kv.key)=\(kv.value)"] }
            a.append("--")
            a.append(commandOrURL)
            a += Self.splitArgs(args)
        } else {
            a.append(commandOrURL)
            for kv in headers where !kv.key.isEmpty { a += ["-H", "\(kv.key): \(kv.value)"] }
        }
        return a
    }

    var isValid: Bool {
        !name.isEmpty && !name.contains(" ") && !commandOrURL.isEmpty
            && (transport == .stdio || commandOrURL.hasPrefix("http"))
            && (scope == "user" || projectDir != nil)
    }

    /// Splits on spaces, keeping "quoted strings" together.
    static func splitArgs(_ s: String) -> [String] {
        var out: [String] = []; var cur = ""; var quote: Character?
        for c in s {
            if let q = quote { if c == q { quote = nil } else { cur.append(c) } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == " " { if !cur.isEmpty { out.append(cur); cur = "" } }
            else { cur.append(c) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

/// Ready-made MCP servers people commonly add. `needs` lists env vars/headers the user must fill in.
struct MCPPreset: Identifiable {
    var id: String { name }
    let name: String
    let blurb: String
    let icon: String
    let draft: MCPDraft

    static func stdio(_ name: String, _ blurb: String, _ icon: String, _ cmd: String, _ args: String, env: [String] = []) -> MCPPreset {
        var d = MCPDraft(); d.name = name; d.transport = .stdio; d.commandOrURL = cmd; d.args = args
        d.env = env.map { MCPDraft.KeyValue(key: $0, value: "") }
        return MCPPreset(name: name, blurb: blurb, icon: icon, draft: d)
    }

    static func http(_ name: String, _ blurb: String, _ icon: String, _ url: String, headers: [String] = []) -> MCPPreset {
        var d = MCPDraft(); d.name = name; d.transport = .http; d.commandOrURL = url
        d.headers = headers.map { MCPDraft.KeyValue(key: $0, value: "") }
        return MCPPreset(name: name, blurb: blurb, icon: icon, draft: d)
    }

    static let gallery: [MCPPreset] = [
        .http("github", "Issues, PRs, code search and Actions on GitHub (sign in with OAuth after adding)", "chevron.left.forwardslash.chevron.right", "https://api.githubcopilot.com/mcp/"),
        .http("sentry", "Look up errors and stack traces from Sentry", "ant", "https://mcp.sentry.dev/mcp"),
        .http("linear", "Read and update Linear issues", "list.bullet.rectangle", "https://mcp.linear.app/mcp"),
        .http("notion", "Search and edit Notion pages", "doc.richtext", "https://mcp.notion.com/mcp"),
        .http("figma", "Pull frames and design tokens from the Figma desktop app", "paintpalette", "http://127.0.0.1:3845/mcp"),
        .http("stripe", "Payments, customers and invoices in Stripe", "creditcard", "https://mcp.stripe.com"),
        .stdio("playwright", "Drive a real browser: click, type, screenshot", "safari", "npx", "-y @playwright/mcp@latest"),
        .stdio("postgres", "Query a Postgres database (read-only)", "cylinder.split.1x2", "npx", "-y @modelcontextprotocol/server-postgres postgresql://localhost/mydb"),
        .stdio("filesystem", "Give Claude access to extra folders", "folder", "npx", "-y @modelcontextprotocol/server-filesystem ~/Documents"),
        .stdio("memory", "A persistent knowledge graph Claude can read and write", "brain", "npx", "-y @modelcontextprotocol/server-memory"),
        .stdio("context7", "Up-to-date docs for thousands of libraries", "books.vertical", "npx", "-y @upstash/context7-mcp"),
        .stdio("firebase", "Firestore, Auth and Hosting in your Firebase projects", "flame", "npx", "-y firebase-tools@latest experimental:mcp"),
    ]
}

enum MCPManager {
    static func add(_ d: MCPDraft) async -> (ok: Bool, message: String) {
        let cwd = d.projectDir.map { URL(fileURLWithPath: $0) } ?? Paths.appSupport
        let r = await CLI.run(d.cliArgs, cwd: cwd)
        let msg = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.status == 0, msg.isEmpty ? (r.status == 0 ? "Added \(d.name)" : "Failed (exit \(r.status))") : msg)
    }

    static func remove(_ name: String, scope: String?, projectDir: String?) async -> (ok: Bool, message: String) {
        var args = ["mcp", "remove", name]
        if let scope { args += ["--scope", scope] }
        let r = await CLI.run(args, cwd: projectDir.map { URL(fileURLWithPath: $0) } ?? Paths.appSupport)
        return (r.status == 0, (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Servers defined in Claude Desktop's config, as (name, JSON) pairs ready for `claude mcp add-json`.
    static func claudeDesktopServers() -> [(String, String)] {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude_desktop_config.json")
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let servers = o["mcpServers"] as? [String: Any] else { return [] }
        return servers.compactMap { name, cfg in
            guard let data = try? JSONSerialization.data(withJSONObject: cfg), let json = String(data: data, encoding: .utf8) else { return nil }
            return (name, json)
        }.sorted { $0.0 < $1.0 }
    }

    static func addJSON(name: String, json: String, scope: String = "user") async -> (ok: Bool, message: String) {
        let r = await CLI.run(["mcp", "add-json", "--scope", scope, name, json])
        return (r.status == 0, (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func details(_ name: String) async -> String {
        let r = await CLI.run(["mcp", "get", name])
        return (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
