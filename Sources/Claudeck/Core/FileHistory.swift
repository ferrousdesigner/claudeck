import Foundation

/// Files Claude edited in a session, from the backups Claude Code keeps in ~/.claude/file-history/<session>/.
struct ChangedFile: Identifiable, Hashable {
    var id: String { path }
    let path: String
    /// Backup of the file as it was before Claude's first edit, nil if Claude created the file.
    let originalBackup: URL?
    let firstEdit: Date?

    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    var wasCreated: Bool { originalBackup == nil }
}

enum FileHistory {
    static func changes(for s: SessionSummary) -> [ChangedFile] {
        guard let data = try? Data(contentsOf: s.path, options: .mappedIfSafe) else { return [] }
        let backupsDir = Paths.claudeDir.appendingPathComponent("file-history").appendingPathComponent(s.id)
        var earliest: [String: (version: Int, backup: String?, time: Date?)] = [:]
        let marker = Array(#""file-history-snapshot""#.utf8)
        var lineStart = data.startIndex
        for i in data.indices where data[i] == 0x0A {
            defer { lineStart = data.index(after: i) }
            let line = data[lineStart..<i]
            guard line.count > 60, line.prefix(60).withUnsafeBytes({ raw in
                raw.firstRange(of: marker) != nil
            }) else { continue }
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let snap = o["snapshot"] as? [String: Any],
                  let tracked = snap["trackedFileBackups"] as? [String: [String: Any]] else { continue }
            for (rel, info) in tracked {
                let parent = info["realParentDir"] as? String
                let abs = rel.hasPrefix("/") ? rel
                    : parent.map { ($0 as NSString).appendingPathComponent((rel as NSString).lastPathComponent) }
                    ?? ((s.cwd ?? "") as NSString).appendingPathComponent(rel)
                let version = info["version"] as? Int ?? 0
                if let cur = earliest[abs], cur.version <= version { continue }
                earliest[abs] = (version, info["backupFileName"] as? String, ISO.parse(info["backupTime"] as? String))
            }
        }
        return earliest.map { path, e in
            ChangedFile(path: path, originalBackup: e.backup.map { backupsDir.appendingPathComponent($0) }, firstEdit: e.time)
        }
        .sorted { $0.path < $1.path }
    }

    /// Unified diff between the pre-session version and the file on disk now.
    static func diff(_ f: ChangedFile) -> String {
        let before = f.originalBackup?.path ?? "/dev/null"
        let after = f.exists ? f.path : "/dev/null"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        p.arguments = ["-u", "--label", "before session", "--label", "now", before, after]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: out, encoding: .utf8) ?? "(binary file)"
        return text.isEmpty ? "No differences: the file is back to how it was before the session." : text
    }

    static func stats(_ diff: String) -> (added: Int, removed: Int) {
        var a = 0, r = 0
        for line in diff.split(separator: "\n") {
            if line.hasPrefix("+") && !line.hasPrefix("+++") { a += 1 }
            if line.hasPrefix("-") && !line.hasPrefix("---") { r += 1 }
        }
        return (a, r)
    }

    /// Puts the file back the way it was before the session. Files Claude created are moved to the Trash.
    static func restore(_ f: ChangedFile) throws {
        let fm = FileManager.default
        if let b = f.originalBackup {
            let data = try Data(contentsOf: b)
            try fm.createDirectory(at: URL(fileURLWithPath: f.path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: f.path), options: .atomic)
        } else if f.exists {
            try fm.trashItem(at: URL(fileURLWithPath: f.path), resultingItemURL: nil)
        }
    }
}

private extension UnsafeRawBufferPointer {
    func firstRange(of needle: [UInt8]) -> Range<Int>? {
        guard count >= needle.count else { return nil }
        for i in 0...(count - needle.count) {
            var j = 0
            while j < needle.count && self[i + j] == needle[j] { j += 1 }
            if j == needle.count { return i..<(i + needle.count) }
        }
        return nil
    }
}
