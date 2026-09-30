import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let claudeDir = home.appendingPathComponent(".claude")
    static let projectsDir = claudeDir.appendingPathComponent("projects")
    static let liveSessionsDir = claudeDir.appendingPathComponent("sessions")
    static let settingsFile = claudeDir.appendingPathComponent("settings.json")
    static let pluginsDir = claudeDir.appendingPathComponent("plugins")

    /// Working directory used for the dashboard's own helper calls (summaries),
    /// so they never show up mixed into real project sessions.
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent("Claudeck")
        moveLegacy(base.appendingPathComponent(legacyName), to: u)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// The app was called "Claude Deck" before 1.1. Its helper runs used this folder as their cwd,
    /// so sessions recorded there are still hidden from the session list.
    static let legacyName = "Claude Deck"
    static var legacyAppSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(legacyName)
    }

    static let defaultMemoryDir: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent("Claudeck")
        moveLegacy(base.appendingPathComponent(legacyName), to: u)
        return u
    }()

    /// Moves a folder from before the rename to its new name, unless the new one already exists.
    private static func moveLegacy(_ old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }

    static var memoryDir: URL {
        if let custom = UserDefaults.standard.string(forKey: "memoryFolder"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return defaultMemoryDir
    }

    static var sessionDocsDir: URL { memoryDir.appendingPathComponent("Sessions") }
    static var summariesDir: URL { memoryDir.appendingPathComponent(".summaries") }

    /// Locate the `claude` binary. GUI apps get a minimal PATH, so check the usual spots.
    static let claudeBinary: String? = {
        let candidates = [
            home.appendingPathComponent(".local/bin/claude").path,
            home.appendingPathComponent(".claude/local/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home.appendingPathComponent(".npm-global/bin/claude").path,
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        // Fall back to the login shell's PATH.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }()

    /// Environment for child `claude` processes with a sensible PATH.
    static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        env["PATH"] = (extra + existing).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        env["HOME"] = home.path
        return env
    }
}
