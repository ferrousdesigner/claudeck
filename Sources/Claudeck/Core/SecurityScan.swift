import Foundation

struct SecretFinding: Identifiable, Hashable {
    let id = UUID()
    let sessionID: String
    let kind: String
    let masked: String
    let context: String
    let timestamp: Date?
}

/// Looks through session transcripts for secrets that ended up in Claude's context
/// (API keys, tokens, private keys) and for reads of .env / credential files.
enum SecurityScan {
    static let patterns: [(String, String)] = [
        ("Anthropic API key", #"sk-ant-[A-Za-z0-9_\-]{20,}"#),
        ("OpenAI API key", #"sk-(?:proj-)?[A-Za-z0-9]{32,}"#),
        ("AWS access key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("GitHub token", #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b|github_pat_[A-Za-z0-9_]{40,}"#),
        ("Slack token", #"\bxox[baprs]-[A-Za-z0-9\-]{10,}"#),
        ("Stripe secret key", #"\b(?:sk|rk)_live_[A-Za-z0-9]{20,}"#),
        ("Google API key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        ("Private key", #"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"#),
        ("JWT", #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#),
        ("Password assignment", #"(?i)\b(?:password|passwd|pwd|secret)\s*[:=]\s*["']?[^\s"'\\]{8,}"#),
        ("Database URL with password", #"\b(?:postgres|postgresql|mysql|mongodb(?:\+srv)?|redis)://[^:\s/]+:[^@\s]{4,}@"#),
    ]

    static let sensitiveFileRead = #""name":"(?:Read|Bash)"[^\n]{0,300}?(?:\.env\b|\.env\.|id_rsa|\.pem\b|credentials\.json|\.npmrc|\.netrc|\.aws/credentials)"#

    private static let compiled: [(String, NSRegularExpression)] = patterns.compactMap { k, p in
        (try? NSRegularExpression(pattern: p)).map { (k, $0) }
    }
    private static let fileRead = try! NSRegularExpression(pattern: sensitiveFileRead)

    static func scan(_ sessions: [SessionSummary], progress: ((Double) -> Void)? = nil) -> [SecretFinding] {
        var out: [SecretFinding] = []
        for (n, s) in sessions.enumerated() {
            progress?(Double(n) / Double(max(sessions.count, 1)))
            guard let text = try? String(contentsOf: s.path, encoding: .utf8) else { continue }
            var seen = Set<String>()
            text.enumerateLines { line, _ in
                // Skip base64 image payloads, which produce false positives and are slow.
                if line.count > 400_000 { return }
                let ns = line as NSString
                let range = NSRange(location: 0, length: ns.length)
                var ts: Date?
                if let r = line.range(of: #""timestamp":""#), let end = line[r.upperBound...].firstIndex(of: "\"") {
                    ts = ISO.parse(String(line[r.upperBound..<end]))
                }
                for (kind, re) in compiled {
                    for m in re.matches(in: line, range: range) {
                        let value = ns.substring(with: m.range)
                        guard seen.insert(kind + value).inserted else { continue }
                        out.append(SecretFinding(sessionID: s.id, kind: kind, masked: mask(value),
                                                 context: context(ns, m.range), timestamp: ts))
                    }
                }
                for m in fileRead.matches(in: line, range: range) {
                    let v = ns.substring(with: m.range)
                    let file = v.range(of: #"[\w./~\-]*(?:\.env[\w.]*|id_rsa|\.pem|credentials\.json|\.npmrc|\.netrc|\.aws/credentials)"#, options: .regularExpression)
                        .map { String(v[$0]) } ?? "sensitive file"
                    guard seen.insert("file" + file).inserted else { continue }
                    out.append(SecretFinding(sessionID: s.id, kind: "Read a sensitive file", masked: file,
                                             context: "Claude opened \(file), so its contents were sent to the model.", timestamp: ts))
                }
            }
        }
        progress?(1)
        return out
    }

    static func mask(_ v: String) -> String {
        guard v.count > 10 else { return String(repeating: "•", count: v.count) }
        return String(v.prefix(6)) + String(repeating: "•", count: min(v.count - 10, 16)) + String(v.suffix(4))
    }

    private static func context(_ ns: NSString, _ r: NSRange) -> String {
        let start = max(0, r.location - 50), end = min(ns.length, r.location + r.length + 30)
        var c = ns.substring(with: NSRange(location: start, length: end - start))
        c = c.replacingOccurrences(of: ns.substring(with: r), with: mask(ns.substring(with: r)))
        return c.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\\"", with: "\"")
    }
}
