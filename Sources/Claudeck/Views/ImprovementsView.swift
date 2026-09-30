import SwiftUI

/// Ranked, concrete suggestions for spending fewer tokens, worked out from the session history.
struct ImprovementsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var ext: ExtensionsStore
    @State private var report: AdvisorReport?
    @State private var expanded: Set<String> = []

    /// Changes when there's new usage worth re-analysing (the store republishes every few seconds).
    private var signature: String { "\(sessions.sessions.count)-\(sessions.totalTokens.total / 50_000)-\(ext.mcpServers.count)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Improvements").font(.largeTitle.weight(.bold))
                Text("Where your tokens go and what to change to use fewer, based on sessions from the last 30 days. Savings are estimates at API list prices.")
                    .font(.callout).foregroundStyle(.secondary)

                if let r = report, !sessions.isLoading {
                    header(r)
                    if r.improvements.isEmpty {
                        Card {
                            Label("Nothing stands out. Your sessions already look efficient.", systemImage: "checkmark.seal")
                                .font(.headline).foregroundStyle(.green)
                        }
                    }
                    ForEach(r.improvements) { card($0) }
                    if !r.strengths.isEmpty { strengths(r.strengths) }
                } else {
                    ProgressView("Analysing sessions…").frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(24)
        }
        .fabClearance()
        .task(id: signature) { await analyse() }
        .onAppear { if ext.mcpServers.isEmpty && !ext.loadingMCP { ext.reloadMCP() } }
    }

    private func analyse() async {
        let all = sessions.sessions
        let projects = Array(Set(all.prefix(200).compactMap(\.cwd)))
        let keys = sessions.projectKeys
        let mcp = ext.mcpServers.count
        report = await Task.detached(priority: .utility) {
            let files = InstructionFiles.all(projects: projects, projectKeys: keys)
            return CostAdvisor.analyze(sessions: all, instructionFiles: files, mcpServers: mcp)
        }.value
    }

    // MARK: - Pieces

    private func header(_ r: AdvisorReport) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            Metric(title: "Potential savings", value: Fmt.usd(r.totalSavings),
                   caption: r.cost > 0 ? "about \(Int(r.totalSavings / r.cost * 100))% of \(Fmt.usd(r.cost)) in 30 days" : "last 30 days",
                   icon: "leaf", tint: .green)
            Metric(title: "Cache hit rate", value: "\(Int(r.cacheHitRate * 100))%", caption: "context read from cache", icon: "memorychip",
                   tint: r.cacheHitRate >= 0.85 ? .teal : .orange)
            Metric(title: "Starting context", value: Fmt.tokens(r.medianStartContext), caption: "typical, before your first prompt", icon: "shippingbox",
                   tint: r.medianStartContext > 25_000 ? .orange : .deckAccent)
            Metric(title: "Context per reply", value: Fmt.tokens(r.avgContextPerReply), caption: "average across \(r.sessionCount) sessions", icon: "text.bubble",
                   tint: r.avgContextPerReply > 80_000 ? .orange : .deckAccent)
        }
    }

    private func card(_ imp: Improvement) -> some View {
        let open = expanded.contains(imp.id)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: imp.icon).foregroundStyle(tint(imp.impact)).frame(width: 20)
                    Text(imp.title).font(.headline)
                    impactPill(imp.impact)
                    Spacer()
                    if imp.savings > 0 {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("~\(Fmt.usd(imp.savings))").font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(.green)
                            Text("per month").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Text(.init(imp.finding)).font(.callout)
                Text(.init(imp.why)).font(.callout).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("How to fix").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(imp.fixes, id: \.self) { f in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark.circle").font(.caption).foregroundStyle(Color.deckAccent)
                            Text(.init(f)).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if open { details(imp) }

                HStack {
                    if !imp.sessions.isEmpty || !imp.files.isEmpty {
                        Button(open ? "Hide details" : detailsLabel(imp)) {
                            withAnimation(.snappy) { if open { expanded.remove(imp.id) } else { expanded.insert(imp.id) } }
                        }
                        .buttonStyle(.link)
                    }
                    Spacer()
                    if let d = imp.destination {
                        Button(d.label) { go(d.to) }.controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder private func details(_ imp: Improvement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(imp.sessions, id: \.id) { item in
                Button { state.openSession(item.id) } label: {
                    HStack {
                        Text(sessions.session(id: item.id)?.title ?? item.id).lineLimit(1)
                        Text(sessions.session(id: item.id)?.projectName ?? "").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(item.note).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
            ForEach(imp.files, id: \.path) { f in
                HStack {
                    Text((f.path as NSString).abbreviatingWithTildeInPath).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("~\(Fmt.tokens(f.tokens)) tokens").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }
                        .buttonStyle(.link).font(.caption)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(10)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func strengths(_ items: [String]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Already working well", systemImage: "hand.thumbsup").font(.headline).foregroundStyle(.green)
                ForEach(items, id: \.self) { Text("• " + $0).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }

    private func detailsLabel(_ imp: Improvement) -> String {
        imp.sessions.isEmpty ? "Show \(imp.files.count) file\(imp.files.count == 1 ? "" : "s")"
            : "Show \(imp.sessions.count) session\(imp.sessions.count == 1 ? "" : "s")"
    }

    private func impactPill(_ i: Improvement.Impact) -> some View {
        Text(i.label + " impact").font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(tint(i))
            .background(tint(i).opacity(0.15), in: Capsule())
    }

    private func tint(_ i: Improvement.Impact) -> Color {
        switch i { case .high: return .red; case .medium: return .orange; case .low: return .secondary }
    }

    private func go(_ d: Improvement.Destination) {
        switch d {
        case .status: state.tab = .status
        case .extensions(let s): state.extensionsSection = s; state.tab = .extensions
        }
    }
}
