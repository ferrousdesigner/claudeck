import Foundation
import AppKit

struct GitStatus: Hashable {
    var isRepo = false
    var branch: String?
    var changedFiles = 0
    var ahead = 0
    var behind = 0
    var lastCommit: String?
    var lastCommitDate: Date?
}

struct ProjectHealth: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var sessions: [SessionSummary]
    var git = GitStatus()
    var hasClaudeMD = false
    var nextSteps: [String] = []

    var name: String { (path as NSString).lastPathComponent }
    var tokens: TokenUsage { sessions.reduce(TokenUsage()) { $0 + $1.tokens } }
    var cost: Double { sessions.reduce(0) { $0 + $1.cost } }
    var lastActive: Date? { sessions.compactMap(\.end).max() }
}

enum Projects {
    static func git(_ dir: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func gitStatus(_ dir: String) -> GitStatus {
        var g = GitStatus()
        guard FileManager.default.fileExists(atPath: dir), git(dir, ["rev-parse", "--is-inside-work-tree"]) == "true" else { return g }
        g.isRepo = true
        g.branch = git(dir, ["rev-parse", "--abbrev-ref", "HEAD"])
        g.changedFiles = git(dir, ["status", "--porcelain"])?.split(separator: "\n").count ?? 0
        if let ab = git(dir, ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])?.split(separator: "\t"), ab.count == 2 {
            g.ahead = Int(ab[0]) ?? 0; g.behind = Int(ab[1]) ?? 0
        }
        if let log = git(dir, ["log", "-1", "--format=%s%x1f%cI"])?.components(separatedBy: "\u{1f}"), log.count == 2 {
            g.lastCommit = log[0]; g.lastCommitDate = ISO.parse(log[1])
        }
        return g
    }

    /// Pulls bullet points from the "Open threads / next steps" part of cached summaries.
    static func nextSteps(from sessions: [SessionSummary]) -> [String] {
        var out: [String] = []
        for s in sessions.prefix(5) {
            guard let text = Summarizer.cached(for: s)?.text,
                  let r = text.range(of: "Open threads", options: .caseInsensitive) else { continue }
            let after = text[r.upperBound...]
            for line in after.split(separator: "\n").dropFirst() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("**") { break }
                if t.hasPrefix("- ") || t.hasPrefix("* ") { out.append(String(t.dropFirst(2))) }
            }
        }
        return Array(out.prefix(6))
    }

    static func health(_ sessions: [SessionSummary]) -> [ProjectHealth] {
        let groups = Dictionary(grouping: sessions.filter { $0.cwd != nil }, by: { $0.cwd! })
        return groups.map { path, ss in
            let sorted = ss.sorted { ($0.end ?? .distantPast) > ($1.end ?? .distantPast) }
            return ProjectHealth(path: path, sessions: sorted, git: gitStatus(path),
                                 hasClaudeMD: FileManager.default.fileExists(atPath: path + "/CLAUDE.md")
                                    || FileManager.default.fileExists(atPath: path + "/.claude/CLAUDE.md"),
                                 nextSteps: nextSteps(from: sorted))
        }
        .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }
}

/// Opening sessions and folders in other tools.
enum Handoff {
    /// Opens Terminal.app running `claude --resume <id>` in the session's folder (no automation permission needed).
    static func resumeInTerminal(_ s: SessionSummary) {
        runInTerminal("cd \(shellQuote(s.cwd ?? Paths.home.path)) && \(Paths.claudeBinary ?? "claude") --resume \(s.id)", name: "resume-\(s.shortID)")
    }

    static func newSessionInTerminal(_ dir: String) {
        runInTerminal("cd \(shellQuote(dir)) && \(Paths.claudeBinary ?? "claude")", name: "claude-\((dir as NSString).lastPathComponent)")
    }

    static func runInTerminal(_ command: String, name: String) {
        let url = Paths.appSupport.appendingPathComponent("\(name).command")
        let script = "#!/bin/zsh -l\n\(command)\n"
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    static var editors: [(name: String, bundle: String)] {
        [("Visual Studio Code", "com.microsoft.VSCode"), ("Cursor", "com.todesktop.230313mzl4w4u92"),
         ("Zed", "dev.zed.Zed"), ("Xcode", "com.apple.dt.Xcode")]
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.1) != nil }
    }

    static func open(_ dir: String, inEditor bundle: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: dir)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Runs the same prompt in several git worktrees at once so results can be compared side by side.
enum Worktrees {
    struct Created { let path: String; let branch: String }

    static func create(repo: String, count: Int, slug: String) throws -> [Created] {
        guard Projects.git(repo, ["rev-parse", "--is-inside-work-tree"]) == "true",
              let top = Projects.git(repo, ["rev-parse", "--show-toplevel"]) else {
            throw NSError(domain: "Worktrees", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(repo) isn't a git repository."])
        }
        let base = (top as NSString).deletingLastPathComponent + "/.claudeck-worktrees/" + (top as NSString).lastPathComponent
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
        let clean = String(slug.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(24))
        var out: [Created] = []
        for i in 1...count {
            let branch = "deck/\(clean)-\(stamp)-\(i)"
            let path = "\(base)/\(clean)-\(stamp)-\(i)"
            guard Projects.git(top, ["worktree", "add", "-b", branch, path]) != nil else {
                throw NSError(domain: "Worktrees", code: 2, userInfo: [NSLocalizedDescriptionKey: "git worktree add failed for \(path)"])
            }
            out.append(Created(path: path, branch: branch))
        }
        return out
    }

    static func diffStat(_ path: String) -> String {
        let tracked = Projects.git(path, ["diff", "--stat", "HEAD"]) ?? ""
        let untracked = Projects.git(path, ["ls-files", "--others", "--exclude-standard"]) ?? ""
        let u = untracked.isEmpty ? "" : "\nNew files:\n" + untracked
        let s = (tracked + u).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "No changes" : s
    }

    static func remove(_ path: String) -> Bool {
        guard let top = Projects.git(path, ["rev-parse", "--git-common-dir"]) else { return false }
        let repo = (top as NSString).deletingLastPathComponent
        return Projects.git(repo, ["worktree", "remove", "--force", path]) != nil
    }
}
