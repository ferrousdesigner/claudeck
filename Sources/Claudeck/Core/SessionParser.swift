import Foundation

/// Incrementally parses Claude Code session transcripts (~/.claude/projects/<key>/<id>.jsonl).
/// Keeps a byte offset per file so repeated refreshes only read newly appended lines.
final class IncrementalParse {
    var offset: UInt64 = 0
    var size: UInt64 = 0
    var seenMessageIDs: [String: TokenUsage] = [:]
    var toolNames: [String: String] = [:]   // tool_use id -> tool name, to attribute tool_result sizes
    var summary: SessionSummary

    init(summary: SessionSummary) { self.summary = summary }
}

enum SessionParser {
    private static let newline = UInt8(ascii: "\n")

    /// Reads complete lines appended since `state.offset` and folds them into the summary.
    /// `tokensOnly` is used for subagent transcripts, which only contribute token counts.
    static func advance(_ state: IncrementalParse, url: URL, tokensOnly: Bool = false) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        if size < state.offset { // file was rewritten
            let fresh = IncrementalParse(summary: SessionSummary(id: state.summary.id, path: state.summary.path, projectKey: state.summary.projectKey))
            state.offset = 0; state.seenMessageIDs = [:]; state.summary = fresh.summary
        }
        state.size = size
        if let m = attrs[.modificationDate] as? Date, !tokensOnly { state.summary.fileModified = m }
        guard size > state.offset, let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: state.offset)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return }

        // Only consume up to the last newline; a partial trailing line is picked up next time.
        guard let lastNL = data.lastIndex(of: newline) else { return }
        let usable = data[data.startIndex...lastNL]
        state.offset += UInt64(usable.count)

        var lineStart = usable.startIndex
        for i in usable.indices where usable[i] == newline {
            if i > lineStart { process(line: usable[lineStart..<i], state: state, tokensOnly: tokensOnly) }
            lineStart = usable.index(after: i)
        }
    }

    private static let assistantMarker = Array(#""type":"assistant""#.utf8)
    private static let userMarker = Array(#""type":"user""#.utf8)
    private static let titleMarker = Array(#""type":"ai-title""#.utf8)

    private static func contains(_ hay: Data.SubSequence, _ needle: [UInt8], within limit: Int = .max) -> Bool {
        // Cheap prefilter so we don't JSON-decode every attachment/snapshot line.
        hay.withUnsafeBytes { raw -> Bool in
            let n = min(raw.count, limit)
            guard n >= needle.count else { return false }
            let first = needle[0]
            var i = 0
            while i <= n - needle.count {
                if raw[i] == first {
                    var j = 1
                    while j < needle.count && raw[i + j] == needle[j] { j += 1 }
                    if j == needle.count { return true }
                }
                i += 1
            }
            return false
        }
    }

    private static func process(line: Data.SubSequence, state: IncrementalParse, tokensOnly: Bool) {
        let candidate = contains(line, assistantMarker)
            || (!tokensOnly && (contains(line, userMarker) || contains(line, titleMarker, within: 200)))
        guard candidate else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return }
        let type = obj["type"] as? String
        if tokensOnly && type != "assistant" { return }
        var s = state.summary

        if type == "ai-title" {
            if let t = obj["aiTitle"] as? String { s.aiTitle = t }
            state.summary = s
            return
        }

        let ts = ISO.parse(obj["timestamp"] as? String)
        if !tokensOnly {
            if let ts {
                if s.start == nil || ts < s.start! { s.start = ts }
                if s.end == nil || ts > s.end! { s.end = ts }
            }
            if s.cwd == nil, let c = obj["cwd"] as? String { s.cwd = c }
            if let b = obj["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { s.gitBranch = b }
        }

        guard let message = obj["message"] as? [String: Any] else { state.summary = s; return }

        if type == "assistant" {
            let content = message["content"] as? [[String: Any]] ?? []
            if !tokensOnly {
                for block in content {
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String, !t.isEmpty { s.lastActivity = String(t.prefix(300)) }
                    case "tool_use":
                        s.toolCalls += 1
                        s.toolCounts[block["name"] as? String ?? "tool", default: 0] += 1
                        if let id = block["id"] as? String { state.toolNames[id] = block["name"] as? String ?? "tool" }
                        s.lastActivity = describeToolUse(block)
                    default: break
                    }
                }
            }
            if let usageJSON = message["usage"] as? [String: Any] {
                let usage = TokenUsage(json: usageJSON)
                let mid = (message["id"] as? String) ?? (obj["uuid"] as? String) ?? UUID().uuidString
                let model = (message["model"] as? String) ?? "unknown"
                let day = ts.map { Fmt.day.string(from: $0) } ?? "unknown"
                // Streaming writes one line per content block, repeating the same usage.
                // Count each API message once (replace with the latest numbers).
                if let prev = state.seenMessageIDs[mid] {
                    s.tokens = s.tokens - prev
                    s.tokensByModel[model] = (s.tokensByModel[model] ?? .init()) - prev
                    s.tokensByDay[day] = (s.tokensByDay[day] ?? .init()) - prev
                } else if !tokensOnly, model != "<synthetic>" {
                    s.assistantTurns += 1
                }
                if model != "<synthetic>" {
                    if !tokensOnly {
                        let context = usage.input + usage.cacheCreate + usage.cacheRead
                        s.lastContextTokens = context
                        s.lastModel = model
                        if state.seenMessageIDs[mid] == nil {
                            if s.firstContextTokens == 0 { s.firstContextTokens = context }
                            else if usage.cacheCreate > 20_000 && usage.cacheCreate > usage.cacheRead {
                                // Most of an already-built context was written again: the cache expired or was invalidated.
                                s.cacheMisses += 1
                                s.cacheMissTokens += usage.cacheCreate
                            }
                        }
                        s.peakContextTokens = max(s.peakContextTokens, context)
                    }
                    s.tokens += usage
                    s.tokensByModel[model, default: .init()] += usage
                    s.tokensByDay[day, default: .init()] += usage
                    state.seenMessageIDs[mid] = usage
                }
            }
        } else if type == "user", !tokensOnly {
            if (obj["isMeta"] as? Bool) == true { state.summary = s; return }
            if let blocks = message["content"] as? [[String: Any]] {
                s.toolErrors += blocks.filter { $0["type"] as? String == "tool_result" && ($0["is_error"] as? Bool) == true }.count
                for b in blocks where b["type"] as? String == "tool_result" {
                    let name = (b["tool_use_id"] as? String).flatMap { state.toolNames[$0] } ?? "tool"
                    let chars = toolResultText(b["content"]).count
                    s.toolResultChars[name, default: 0] += chars
                    if chars > 40_000 { s.largeToolResults += 1 }
                }
            }
            if let prompt = userPromptText(message["content"]) {
                s.userTurns += 1
                if let ts { s.hourCounts[Calendar.current.component(.hour, from: ts), default: 0] += 1 }
                if s.firstPrompt == nil { s.firstPrompt = prompt }
                s.lastPrompt = prompt
                s.lastActivity = "You: " + String(prompt.prefix(200))
            }
        }
        state.summary = s
    }

    // MARK: - Text extraction shared with transcript building

    static func describeToolUse(_ block: [String: Any]) -> String {
        let name = block["name"] as? String ?? "tool"
        let input = block["input"] as? [String: Any] ?? [:]
        let detail = (input["description"] as? String)
            ?? (input["command"] as? String)
            ?? (input["file_path"] as? String)
            ?? (input["pattern"] as? String)
            ?? (input["prompt"] as? String)
            ?? (input["query"] as? String)
            ?? (input["url"] as? String)
            ?? ""
        let d = detail.replacingOccurrences(of: "\n", with: " ")
        return d.isEmpty ? "⚙︎ \(name)" : "⚙︎ \(name): \(d.prefix(200))"
    }

    /// Returns the human-typed prompt, or nil for tool results / meta messages.
    static func userPromptText(_ content: Any?) -> String? {
        var raw = ""
        if let s = content as? String {
            raw = s
        } else if let blocks = content as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            raw = blocks.compactMap { b -> String? in
                if b["type"] as? String == "text" { return b["text"] as? String }
                if b["type"] as? String == "image" { return "[image]" }
                return nil
            }.joined(separator: "\n")
        }
        return cleanPrompt(raw)
    }

    static func cleanPrompt(_ raw: String) -> String? {
        var s = raw
        if s.hasPrefix("<local-command-caveat>") || s.hasPrefix("<local-command-stdout>") || s.hasPrefix("<local-command-stderr>") { return nil }
        if s.contains("<command-name>") {
            let name = between(s, "<command-name>", "</command-name>") ?? ""
            let args = between(s, "<command-args>", "</command-args>") ?? ""
            return (name + (args.isEmpty ? "" : " " + args)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for tag in ["system-reminder", "task-notification"] {
            while let r = s.range(of: "<\(tag)>"), let e = s.range(of: "</\(tag)>", range: r.upperBound..<s.endIndex) {
                s.removeSubrange(r.lowerBound..<e.upperBound)
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
        return String(s[r1.upperBound..<r2.lowerBound])
    }

    // MARK: - Full transcript (on demand)

    static func transcript(url: URL) -> [TranscriptEntry] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var entries: [TranscriptEntry] = []
        var seenBlocks = Set<String>()
        var lineStart = data.startIndex
        for i in data.indices where data[i] == newline {
            defer { lineStart = data.index(after: i) }
            let line = data[lineStart..<i]
            guard contains(line, assistantMarker) || contains(line, userMarker) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = obj["message"] as? [String: Any] else { continue }
            let ts = ISO.parse(obj["timestamp"] as? String)
            let type = obj["type"] as? String
            if type == "user" {
                if (obj["isMeta"] as? Bool) == true { continue }
                if let p = userPromptText(message["content"]) {
                    entries.append(.init(id: entries.count, role: .user, text: p, timestamp: ts))
                } else if let blocks = message["content"] as? [[String: Any]] {
                    for b in blocks where b["type"] as? String == "tool_result" {
                        let text = toolResultText(b["content"])
                        if !text.isEmpty {
                            entries.append(.init(id: entries.count, role: .system, text: String(text.prefix(600)), timestamp: ts))
                        }
                    }
                }
            } else if type == "assistant" {
                let mid = message["id"] as? String ?? ""
                for (idx, b) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
                    let key = "\(mid)#\(obj["apiBlockIndex"] ?? idx)#\(b["type"] ?? "")#\((b["id"] as? String) ?? "")"
                    guard seenBlocks.insert(key).inserted else { continue }
                    switch b["type"] as? String {
                    case "text":
                        if let t = b["text"] as? String, !t.isEmpty {
                            entries.append(.init(id: entries.count, role: .assistant, text: t, timestamp: ts))
                        }
                    case "tool_use":
                        entries.append(.init(id: entries.count, role: .tool, text: describeToolUse(b), timestamp: ts))
                    default: break
                    }
                }
            }
        }
        return entries
    }

    private static func toolResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        return ""
    }
}
