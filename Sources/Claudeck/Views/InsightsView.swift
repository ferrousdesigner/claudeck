import SwiftUI
import Charts

struct InsightsView: View {
    @EnvironmentObject var sessions: SessionStore
    @State private var digestDays = 7
    @State private var generating = false
    @State private var digestError: String?
    @State private var digests: [URL] = Digest.existing()
    @State private var openDigest: URL?

    private var all: [SessionSummary] { sessions.sessions }

    private var hours: [(Int, Int)] {
        let m = all.reduce(into: [Int: Int]()) { acc, s in for (k, v) in s.hourCounts { acc[k, default: 0] += v } }
        return (0..<24).map { ($0, m[$0] ?? 0) }
    }

    private var tools: [(String, Int)] {
        all.reduce(into: [String: Int]()) { acc, s in for (k, v) in s.toolCounts { acc[k, default: 0] += v } }
            .sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) }
    }

    private var perDay: [(Date, Int)] {
        let cal = Calendar.current
        let counts = Dictionary(grouping: all.compactMap(\.start), by: { cal.startOfDay(for: $0) }).mapValues(\.count)
        return (0..<30).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: Date())) }.map { ($0, counts[$0] ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Insights").font(.largeTitle.weight(.bold))
                let prompts = all.reduce(0) { $0 + $1.userTurns }
                let toolCalls = all.reduce(0) { $0 + $1.toolCalls }
                let errors = all.reduce(0) { $0 + $1.toolErrors }
                let durations = all.compactMap { s -> TimeInterval? in guard let a = s.start, let b = s.end else { return nil }; return b.timeIntervalSince(a) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    Metric(title: "Prompts", value: "\(prompts)", caption: "\(all.count) sessions", icon: "text.bubble")
                    Metric(title: "Avg per session", value: Fmt.usd(all.isEmpty ? 0 : all.reduce(0) { $0 + $1.cost } / Double(all.count)),
                           caption: "\(Fmt.tokens(all.isEmpty ? 0 : all.reduce(0) { $0 + $1.tokens.total } / all.count)) tokens", icon: "divide")
                    Metric(title: "Tool calls", value: "\(toolCalls)", caption: String(format: "%.1f per prompt", prompts > 0 ? Double(toolCalls) / Double(prompts) : 0), icon: "hammer")
                    Metric(title: "Tool error rate", value: String(format: "%.1f%%", toolCalls > 0 ? Double(errors) / Double(toolCalls) * 100 : 0),
                           caption: "\(errors) failed calls · median session \(Fmt.duration(Date(), Date().addingTimeInterval(durations.sorted().dropFirst(durations.count / 2).first ?? 0)))",
                           icon: "exclamationmark.triangle", tint: .orange)
                }

                digestCard

                HStack(alignment: .top, spacing: 12) {
                    Card {
                        VStack(alignment: .leading) {
                            Text("When you work with Claude").font(.headline)
                            Text("Prompts by hour of day").font(.caption).foregroundStyle(.secondary)
                            Chart(hours, id: \.0) { h in
                                BarMark(x: .value("Hour", h.0), y: .value("Prompts", h.1))
                                    .foregroundStyle(Color.deckAccent.gradient)
                            }
                            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { v in AxisValueLabel { if let h = v.as(Int.self) { Text(h == 0 ? "12a" : h < 12 ? "\(h)a" : h == 12 ? "12p" : "\(h - 12)p") } } } }
                            .frame(height: 180)
                            if let peak = hours.max(by: { $0.1 < $1.1 }), peak.1 > 0 {
                                Text("Busiest hour: \(peak.0):00–\(peak.0 + 1):00").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading) {
                            Text("Sessions per day").font(.headline)
                            Text("Last 30 days").font(.caption).foregroundStyle(.secondary)
                            Chart(perDay, id: \.0) { d in
                                BarMark(x: .value("Day", d.0, unit: .day), y: .value("Sessions", d.1)).foregroundStyle(Color.accentColor.gradient)
                            }
                            .frame(height: 180)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading) {
                        Text("Most-used tools").font(.headline)
                        Chart(tools, id: \.0) { t in
                            BarMark(x: .value("Calls", t.1), y: .value("Tool", t.0))
                                .foregroundStyle(Color.purple.gradient)
                                .annotation(position: .trailing) { Text("\(t.1)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .chartYAxis { AxisMarks { AxisValueLabel() } }
                        .frame(height: CGFloat(max(tools.count, 1)) * 24)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sessions with the most failed tool calls").font(.headline)
                        ForEach(all.filter { $0.toolErrors > 0 }.sorted { $0.toolErrors > $1.toolErrors }.prefix(6)) { s in
                            HStack {
                                Text(s.title).lineLimit(1)
                                Spacer()
                                Text("\(s.toolErrors) of \(s.toolCalls) failed").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .fabClearance()
        .sheet(item: $openDigest) { url in DigestSheet(url: url) }
    }

    private var digestCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Work digest", systemImage: "doc.richtext").font(.headline)
                    Spacer()
                    Picker("", selection: $digestDays) { Text("Today").tag(1); Text("7 days").tag(7); Text("30 days").tag(30) }
                        .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                    Button {
                        Task {
                            generating = true; digestError = nil
                            do { let u = try await Digest.generate(sessions: all, days: digestDays); digests = Digest.existing(); openDigest = u }
                            catch { digestError = error.localizedDescription }
                            generating = false
                        }
                    } label: { if generating { ProgressView().controlSize(.small) } else { Label("Generate", systemImage: "sparkles") } }
                        .disabled(generating)
                }
                Text("A write-up of what you got done across all projects: highlights, per-project notes, open threads and a standup blurb.")
                    .font(.callout).foregroundStyle(.secondary)
                if let digestError { Text(digestError).foregroundStyle(.red).font(.callout) }
                ForEach(digests.prefix(5), id: \.self) { u in
                    Button { openDigest = u } label: { Label(u.deletingPathExtension().lastPathComponent, systemImage: "doc.text") }.buttonStyle(.link)
                }
            }
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct DigestSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(url.deletingPathExtension().lastPathComponent).font(.headline)
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                Button("Export…") { Exporter.exportWithPanel(markdown: text, title: "Work digest", defaultName: url.deletingPathExtension().lastPathComponent) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView { MarkdownText(text).padding(20).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .frame(width: 720, height: 620)
    }
}
