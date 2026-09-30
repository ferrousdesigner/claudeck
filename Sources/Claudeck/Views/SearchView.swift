import SwiftUI

struct SearchView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    @AppStorage("lastSearch") private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var roleFilter = "All"
    @FocusState private var focused: Bool

    private var filtered: [SearchHit] {
        switch roleFilter {
        case "You": return hits.filter { $0.role == .user }
        case "Claude": return hits.filter { $0.role == .assistant }
        case "Tools": return hits.filter { $0.role == .tool }
        default: return hits
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Search every session").font(.largeTitle.weight(.bold))
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("e.g. firebase auth bug, “worktree”, a file name…", text: $query)
                        .textFieldStyle(.plain).font(.title3).focused($focused)
                        .onSubmit { Task { await run() } }
                    if searching { ProgressView().controlSize(.small) }
                }
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
                HStack {
                    Picker("", selection: $roleFilter) {
                        ForEach(["All", "You", "Claude", "Tools"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented).frame(width: 280).labelsHidden()
                    Spacer()
                    Text(sessions.search.isIndexing ? "Indexing…" : "\(sessions.search.indexedCount) sessions indexed · \(filtered.count) matches")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)

            if hits.isEmpty && !query.isEmpty && (sessions.search.isIndexing || sessions.search.indexedCount == 0) {
                ProgressView("Indexing your sessions…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hits.isEmpty && !query.isEmpty && !searching {
                ContentUnavailableView.search(text: query)
            } else if hits.isEmpty {
                ContentUnavailableView("Find anything you and Claude ever discussed", systemImage: "text.magnifyingglass",
                                       description: Text("Searches your prompts, Claude's replies and the commands it ran, across every project. All words must match."))
            } else {
                List {
                    let grouped = Dictionary(grouping: filtered, by: \.sessionID)
                    let order = grouped.keys.sorted { (grouped[$0]?.first?.timestamp ?? .distantPast) > (grouped[$1]?.first?.timestamp ?? .distantPast) }
                    ForEach(order, id: \.self) { sid in
                        let s = sessions.session(id: sid)
                        Section {
                            ForEach(grouped[sid] ?? []) { h in
                                Button { state.openSession(sid) } label: { HitRow(hit: h, query: query) }.buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Text(s?.title ?? sid).font(.headline)
                                Text(s?.projectName ?? "").foregroundStyle(.secondary)
                                Spacer()
                                Text(Fmt.ago(s?.end)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .fabClearance()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: "\(query)|\(sessions.search.indexedCount)|\(sessions.search.isIndexing)") {
            try? await Task.sleep(for: .milliseconds(300))   // debounce typing
            await run()
        }
        .onAppear {
            focused = true
            if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count { query = CommandLine.arguments[i + 1] }
        }
    }

    private func run() async {
        searching = true
        hits = await sessions.search.search(query)
        searching = false
    }
}

struct HitRow: View {
    let hit: SearchHit
    let query: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hit.role == .user ? "person.fill" : hit.role == .tool ? "hammer" : "sparkle")
                .foregroundStyle(hit.role == .user ? Color.accentColor : hit.role == .tool ? .secondary : .deckAccent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted).lineLimit(3)
                if let t = hit.timestamp { Text(t.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var highlighted: AttributedString {
        var a = AttributedString(hit.snippet)
        for word in query.split(separator: " ") {
            var searchRange = a.startIndex..<a.endIndex
            while let r = a[searchRange].range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive]) {
                a[r].backgroundColor = .yellow.opacity(0.35)
                a[r].font = .body.bold()
                searchRange = r.upperBound..<a.endIndex
            }
        }
        return a
    }
}
