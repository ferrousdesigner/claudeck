import Foundation
import Combine

struct SearchHit: Identifiable, Hashable {
    let id = UUID()
    let sessionID: String
    let role: TranscriptRole
    let snippet: String
    let matchRange: Range<String.Index>?
    let timestamp: Date?
}

/// Full-text search over every prompt and reply in every session.
@MainActor
final class SearchIndex: ObservableObject {
    @Published private(set) var indexedCount = 0
    @Published private(set) var isIndexing = false

    private let store = SearchStorage()

    /// Re-indexes sessions whose transcript changed since last time.
    func update(_ sessions: [SessionSummary]) {
        guard !isIndexing else { return }
        isIndexing = true
        let store = store
        Task.detached(priority: .utility) {
            let n = store.update(sessions)
            await MainActor.run { self.indexedCount = n; self.isIndexing = false }
        }
    }

    func search(_ query: String, limit: Int = 300) async -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let store = store
        return await Task.detached(priority: .userInitiated) { store.search(q, limit: limit) }.value
    }
}

final class SearchStorage: @unchecked Sendable {
    private struct Doc { var modified: Date; var entries: [TranscriptEntry] }
    private var docs: [String: Doc] = [:]
    private let lock = NSLock()

    func update(_ sessions: [SessionSummary]) -> Int {
        for s in sessions {
            lock.lock(); let current = docs[s.id]; lock.unlock()
            if let current, current.modified >= s.fileModified { continue }
            let entries = SessionParser.transcript(url: s.path).filter { $0.role != .system }
            lock.lock(); docs[s.id] = Doc(modified: s.fileModified, entries: entries); lock.unlock()
        }
        lock.lock(); defer { lock.unlock() }
        return docs.count
    }

    func search(_ q: String, limit: Int) -> [SearchHit] {
        lock.lock(); let snapshot = docs; lock.unlock()
        // All words must appear in the entry (in any order).
        let words = q.lowercased().split(separator: " ").map(String.init)
        var hits: [SearchHit] = []
        for (id, doc) in snapshot {
            for e in doc.entries {
                guard words.allSatisfy({ e.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) else { continue }
                let (snippet, range) = Self.snippet(e.text, around: words[0])
                hits.append(SearchHit(sessionID: id, role: e.role, snippet: snippet, matchRange: range, timestamp: e.timestamp))
            }
        }
        hits.sort { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        return Array(hits.prefix(limit))
    }

    static func snippet(_ text: String, around word: String) -> (String, Range<String.Index>?) {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let r = flat.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else { return (String(flat.prefix(200)), nil) }
        let start = flat.index(r.lowerBound, offsetBy: -80, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: 140, limitedBy: flat.endIndex) ?? flat.endIndex
        let prefix = start > flat.startIndex ? "…" : ""
        let s = prefix + flat[start..<end] + (end < flat.endIndex ? "…" : "")
        return (s, s.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]))
    }
}
