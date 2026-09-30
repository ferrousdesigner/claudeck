import Foundation

/// CLAUDE.md files and Claude's saved memories, with a check for references that no longer exist.
struct InstructionFile: Identifiable, Hashable {
    enum Kind: String { case claudeMD = "CLAUDE.md", memory = "Memory", memoryIndex = "Memory index" }
    var id: String { path }
    let path: String
    let kind: Kind
    let scope: String        // "Personal" or project name
    let projectDir: String?
    var exists: Bool

    var name: String { (path as NSString).lastPathComponent }
}

struct StaleReference: Hashable {
    let reference: String
    let line: Int
}

enum InstructionFiles {
    static func all(projects: [String], projectKeys: [String: String]) -> [InstructionFile] {
        let fm = FileManager.default
        var out: [InstructionFile] = []
        let userMD = Paths.claudeDir.appendingPathComponent("CLAUDE.md").path
        out.append(InstructionFile(path: userMD, kind: .claudeMD, scope: "Personal (all projects)", projectDir: nil, exists: fm.fileExists(atPath: userMD)))
        for p in projects {
            let name = (p as NSString).lastPathComponent
            let candidates = [p + "/CLAUDE.md", p + "/.claude/CLAUDE.md", p + "/CLAUDE.local.md"]
            let existing = candidates.filter { fm.fileExists(atPath: $0) }
            if existing.isEmpty {
                out.append(InstructionFile(path: candidates[0], kind: .claudeMD, scope: name, projectDir: p, exists: false))
            } else {
                out += existing.map { InstructionFile(path: $0, kind: .claudeMD, scope: name, projectDir: p, exists: true) }
            }
        }
        // Auto-memory folders: ~/.claude/projects/<key>/memory/*.md
        let dirs = (try? fm.contentsOfDirectory(atPath: Paths.projectsDir.path)) ?? []
        for key in dirs {
            let mem = Paths.projectsDir.appendingPathComponent(key).appendingPathComponent("memory")
            guard let files = try? fm.contentsOfDirectory(atPath: mem.path) else { continue }
            let cwd = projectKeys[key] ?? decode(key)
            let scope = cwd.map { ($0 as NSString).lastPathComponent } ?? key
            for f in files.sorted() where f.hasSuffix(".md") {
                out.append(InstructionFile(path: mem.appendingPathComponent(f).path, kind: f == "MEMORY.md" ? .memoryIndex : .memory,
                                           scope: scope, projectDir: cwd, exists: true))
            }
        }
        return out
    }

    /// "-Users-me-Projects-app" → "/Users/me/Projects/app" when that folder exists (dashes in names make this a best guess).
    static func decode(_ key: String) -> String? {
        let guess = key.replacingOccurrences(of: "-", with: "/")
        return FileManager.default.fileExists(atPath: guess) ? guess : nil
    }

    /// Finds `backticked` file paths and absolute paths that don't exist on disk.
    static func staleReferences(in text: String, file: InstructionFile) -> [StaleReference] {
        let fm = FileManager.default
        var out: [StaleReference] = []
        let base = file.projectDir ?? Paths.home.path
        let memDir = (file.path as NSString).deletingLastPathComponent
        for (n, line) in text.components(separatedBy: "\n").enumerated() {
            var refs: [String] = []
            refs += matches(#"`([~/.]?[\w.\-]+(?:/[\w.\-]+)+/?)`"#, in: line)
            refs += matches(#"(?<![\w`(])(/Users/[^\s`'"),]+)"#, in: line)
            for r in refs {
                var cleaned = r
                while let last = cleaned.last, ".,:;".contains(last) { cleaned.removeLast() }   // trailing punctuation only
                cleaned = cleaned.replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)   // file.ts:42
                if cleaned.contains("*") || cleaned.contains("<") || cleaned.hasPrefix("http") { continue }
                let expanded = (cleaned as NSString).expandingTildeInPath
                // Only judge things that are clearly filesystem paths: absolute paths under real roots,
                // or relative paths ending in a file with an extension. Skips git refs, URLs, API routes.
                let fsRoots = ["/Users/", "/Applications/", "/opt/", "/usr/local/", "/Library/", "/private/", "/Volumes/"]
                if expanded.hasPrefix("/") && !fsRoots.contains(where: { expanded.hasPrefix($0) }) { continue }
                if !expanded.hasPrefix("/") && (expanded as NSString).pathExtension.isEmpty { continue }
                if expanded.hasPrefix("/") {
                    if !fm.fileExists(atPath: expanded) { out.append(StaleReference(reference: cleaned, line: n + 1)) }
                    continue
                }
                // Relative paths: only judge them when we know the project folder, and accept a match
                // in the project or its parent (memories often mention sibling repos).
                guard file.projectDir != nil else { continue }
                if fm.fileExists(atPath: (base as NSString).appendingPathComponent(expanded))
                    || fm.fileExists(atPath: ((base as NSString).deletingLastPathComponent as NSString).appendingPathComponent(expanded)) { continue }
                // Memories often cite partial paths (e.g. admin/doctor/doctor.service.ts inside some sub-repo's src/),
                // so accept any file in the project tree that ends with the reference.
                let rel = expanded.hasPrefix("./") ? String(expanded.dropFirst(2)) : expanded
                let index = fileIndex(base)
                if index.isEmpty { continue }
                if !index.contains(where: { $0 == rel || $0.hasSuffix("/" + rel) }) {
                    out.append(StaleReference(reference: cleaned, line: n + 1))
                }
            }
        }
        return out
    }

    nonisolated(unsafe) private static var indexCache: [String: [String]] = [:]

    /// Relative paths of files under `base`, skipping dependency and build folders. Capped for huge trees.
    static func fileIndex(_ base: String) -> [String] {
        if let c = indexCache[base] { return c }
        var out: [String] = []
        // Never crawl the whole home folder or system roots; those "projects" only get exact-path checks.
        let home = Paths.home.path
        if base == home || base == "/" || base == "/Users" { indexCache[base] = []; return [] }
        let skip: Set<String> = ["node_modules", ".git", "build", "dist", ".next", "Pods", "DerivedData", ".build", "vendor", "__pycache__", ".venv"]
        if let e = FileManager.default.enumerator(atPath: base) {
            while let rel = e.nextObject() as? String {
                let last = (rel as NSString).lastPathComponent
                if skip.contains(last) { e.skipDescendants(); continue }
                if (e.fileAttributes?[.type] as? FileAttributeType) == .typeRegular { out.append(rel) }
                if out.count > 300_000 { break }
            }
        }
        indexCache[base] = out
        return out
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }
}

/// Scaffolds new skills, subagents and slash commands.
enum Creator {
    enum Kind: String, CaseIterable, Identifiable {
        case skill = "Skill", agent = "Subagent", command = "Slash command"
        var id: String { rawValue }
    }

    static func url(kind: Kind, name: String, projectDir: String?) -> URL {
        let root = projectDir.map { URL(fileURLWithPath: $0).appendingPathComponent(".claude") } ?? Paths.claudeDir
        switch kind {
        case .skill: return root.appendingPathComponent("skills/\(name)/SKILL.md")
        case .agent: return root.appendingPathComponent("agents/\(name).md")
        case .command: return root.appendingPathComponent("commands/\(name).md")
        }
    }

    static func template(kind: Kind, name: String, description: String, body: String, tools: String, model: String) -> String {
        let desc = description.replacingOccurrences(of: "\"", with: "\\\"")
        switch kind {
        case .skill:
            return """
            ---
            name: \(name)
            description: "\(desc)"
            ---

            # \(name)

            \(body.isEmpty ? "Describe step by step what Claude should do when this skill is used." : body)
            """
        case .agent:
            var fm = "---\nname: \(name)\ndescription: \"\(desc)\"\n"
            if !tools.isEmpty { fm += "tools: \(tools)\n" }
            if !model.isEmpty { fm += "model: \(model)\n" }
            return fm + "---\n\n" + (body.isEmpty ? "You are a specialist in … . When invoked, …" : body)
        case .command:
            return """
            ---
            description: "\(desc)"
            argument-hint: "[what to work on]"
            ---

            \(body.isEmpty ? "Do the following for $ARGUMENTS:\n\n1. …" : body)
            """
        }
    }

    static func create(kind: Kind, name: String, projectDir: String?, content: String) throws -> URL {
        let u = url(kind: kind, name: name, projectDir: projectDir)
        if FileManager.default.fileExists(atPath: u.path) {
            throw NSError(domain: "Creator", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(u.path) already exists."])
        }
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: u, atomically: true, encoding: .utf8)
        return u
    }
}

/// A "what I got done" write-up across recent sessions, generated with the local CLI.
enum Digest {
    static var dir: URL { Paths.memoryDir.appendingPathComponent("Digests") }

    static func generate(sessions: [SessionSummary], days: Int) async throws -> URL {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let recent = sessions.filter { ($0.end ?? .distantPast) >= since }.sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        guard !recent.isEmpty else { throw NSError(domain: "Digest", code: 1, userInfo: [NSLocalizedDescriptionKey: "No sessions in the last \(days) days."]) }
        var input = "Sessions from the last \(days) days:\n\n"
        for s in recent {
            input += "## \(s.title) — project \(s.projectName), \(s.start.map(Fmt.dateTime.string) ?? ""), \(Fmt.tokens(s.tokens.total)) tokens\n"
            if let sum = Summarizer.cached(for: s) { input += sum.text + "\n\n" }
            else {
                let prompts = SessionParser.transcript(url: s.path).filter { $0.role == .user }.prefix(6)
                input += prompts.map { "- asked: \($0.text.prefix(300))" }.joined(separator: "\n") + "\n"
                if let a = s.lastActivity { input += "- last: \(a.prefix(300))\n" }
                input += "\n"
            }
        }
        let system = """
        Write a concise work digest for a developer from their Claude Code sessions. Markdown. Sections: \
        **Highlights** (3-6 bullets of shipped/finished work), **By project** (one short paragraph or bullets per project), \
        **Still open** (unfinished threads and next steps), **Standup blurb** (3 sentences they can paste). Be concrete; no filler.
        """
        let r = await CLI.run(["-p", "--model", Summarizer.model, "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                               "--system-prompt", system], stdin: String(input.prefix(150_000)))
        let text = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, !text.isEmpty else {
            throw NSError(domain: "Digest", code: Int(r.status), userInfo: [NSLocalizedDescriptionKey: r.err.isEmpty ? "Digest failed" : r.err])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(Fmt.day.string(from: Date())) — last \(days) days.md"
        let url = dir.appendingPathComponent(name)
        let header = "# Work digest: last \(days) days\n\n_\(recent.count) sessions · \(Fmt.tokens(recent.reduce(0) { $0 + $1.tokens.total })) tokens · generated \(Fmt.dateTime.string(from: Date()))_\n\n"
        try (header + text).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func existing() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
