import SwiftUI
import Charts

struct UsageView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    @State private var days = 30
    @State private var includeCacheReads = true
    @State private var sort = "Cost"
    @State private var showCost = true

    struct DayPoint: Identifiable {
        var id: String { day + kind }
        let date: Date
        let day: String
        let kind: String
        let value: Int
    }

    private var points: [DayPoint] {
        let cal = Calendar.current
        return (0..<days).reversed().flatMap { offset -> [DayPoint] in
            guard let d = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: Date())) else { return [] }
            let key = Fmt.day.string(from: d)
            let t = sessions.tokens(onDay: key)
            if showCost { return [DayPoint(date: d, day: key, kind: "Cost", value: Int(sessions.cost(onDay: key) * 100))] }
            var out = [
                DayPoint(date: d, day: key, kind: "Input", value: t.input),
                DayPoint(date: d, day: key, kind: "Output", value: t.output),
                DayPoint(date: d, day: key, kind: "Cache write", value: t.cacheCreate),
            ]
            if includeCacheReads { out.append(DayPoint(date: d, day: key, kind: "Cache read", value: t.cacheRead)) }
            return out
        }
    }

    private var byModel: [(String, TokenUsage)] {
        var m: [String: TokenUsage] = [:]
        for s in sessions.sessions { for (k, v) in s.tokensByModel { m[k, default: .init()] += v } }
        return m.sorted { $0.value.total > $1.value.total }
    }

    private var byProject: [(String, TokenUsage, Int)] {
        var m: [String: (TokenUsage, Int)] = [:]
        for s in sessions.sessions {
            let k = s.projectName
            m[k] = ((m[k]?.0 ?? .init()) + s.tokens, (m[k]?.1 ?? 0) + 1)
        }
        return m.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.1.total > $1.1.total }
    }

    private var sortedSessions: [SessionSummary] {
        switch sort {
        case "Recent": return sessions.sessions
        case "Output": return sessions.sessions.sorted { $0.tokens.output > $1.tokens.output }
        case "Cost": return sessions.sessions.sorted { $0.cost > $1.cost }
        default: return sessions.sessions.sorted { $0.tokens.total > $1.tokens.total }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Cost & tokens").font(.largeTitle.weight(.bold))
                Text("Costs are Anthropic API list prices for the tokens used. On a Pro/Max plan you're not billed per token, so read it as how much work you've pushed through.")
                    .font(.callout).foregroundStyle(.secondary)
                let total = sessions.totalTokens
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    Metric(title: "Today", value: Fmt.usd(sessions.cost(days: 1)), caption: "\(Fmt.tokens(sessions.tokens(days: 1).total)) tokens", icon: "sun.max", tint: .deckAccent)
                    Metric(title: "Last 7 days", value: Fmt.usd(sessions.cost(days: 7)), caption: "\(Fmt.tokens(sessions.tokens(days: 7).total)) tokens", icon: "calendar", tint: .deckAccent)
                    Metric(title: "Last 30 days", value: Fmt.usd(sessions.cost(days: 30)), caption: "\(Fmt.tokens(sessions.tokens(days: 30).total)) tokens", icon: "calendar.badge.clock", tint: .deckAccent)
                    Metric(title: "All time", value: Fmt.usd(sessions.sessions.reduce(0) { $0 + $1.cost }), caption: "\(sessions.sessions.count) sessions", icon: "sum", tint: .deckAccent)
                }
                BudgetBars()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    Metric(title: "All tokens", value: Fmt.tokens(total.total), caption: "\(sessions.sessions.count) sessions", icon: "number")
                    Metric(title: "Output", value: Fmt.tokens(total.output), icon: "text.cursor", tint: .purple)
                    Metric(title: "Input + cache write", value: Fmt.tokens(total.input + total.cacheCreate), icon: "arrow.down.doc", tint: .orange)
                    Metric(title: "Cache reads", value: Fmt.tokens(total.cacheRead),
                           caption: total.total > 0 ? String(format: "%.0f%% of all tokens", Double(total.cacheRead) / Double(total.total) * 100) : nil,
                           icon: "memorychip", tint: .teal)
                }

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Per day").font(.headline)
                            Spacer()
                            Picker("", selection: $showCost) { Text("$").tag(true); Text("Tokens").tag(false) }.pickerStyle(.segmented).frame(width: 120).labelsHidden()
                            if !showCost { Toggle("Include cache reads", isOn: $includeCacheReads).controlSize(.small) }
                            Picker("", selection: $days) {
                                Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                            }.pickerStyle(.segmented).frame(width: 220)
                        }
                        Chart(points) { p in
                            BarMark(x: .value("Day", p.date, unit: .day), y: .value("Tokens", p.value))
                                .foregroundStyle(by: .value("Type", p.kind))
                        }
                        .chartForegroundStyleScale(["Input": Color.blue, "Output": Color.purple, "Cache write": Color.orange, "Cache read": Color.teal, "Cost": Color.deckAccent])
                        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Int.self) { Text(showCost ? Fmt.usd(Double(n) / 100) : Fmt.tokens(n)) } } } }
                        .chartLegend(showCost ? .hidden : .automatic)
                        .frame(height: 240)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("By model").font(.headline)
                            ForEach(byModel, id: \.0) { m in
                                HStack { Text(m.0).font(.callout.monospaced()); Spacer(); Text("\(Fmt.tokens(m.1.total)) · \(Fmt.usd(Pricing.cost(m.1, model: m.0)))").monospacedDigit() }
                                ProgressView(value: Double(m.1.total), total: Double(max(byModel.first?.1.total ?? 1, 1)))
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("By project").font(.headline)
                            ForEach(byProject.prefix(8), id: \.0) { p in
                                HStack { Text(p.0); Text("\(p.2) sessions").font(.caption).foregroundStyle(.secondary); Spacer(); Text(Fmt.tokens(p.1.total)).monospacedDigit()
                                    Text(Fmt.usd(sessions.sessions.filter { $0.projectName == p.0 }.reduce(0) { $0 + $1.cost })).monospacedDigit().foregroundStyle(.secondary) }
                                ProgressView(value: Double(p.1.total), total: Double(max(byProject.first?.1.total ?? 1, 1)))
                            }
                        }
                    }
                }

                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Per session").font(.headline)
                            Spacer()
                            Picker("Sort", selection: $sort) { Text("Cost").tag("Cost"); Text("Tokens").tag("Tokens"); Text("Output").tag("Output"); Text("Recent").tag("Recent") }
                                .pickerStyle(.segmented).frame(width: 280)
                        }
                        .padding(16)
                        Divider()
                        HStack {
                            Text("Session").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Input").frame(width: 70, alignment: .trailing)
                            Text("Output").frame(width: 70, alignment: .trailing)
                            Text("Cache W").frame(width: 70, alignment: .trailing)
                            Text("Cache R").frame(width: 70, alignment: .trailing)
                            Text("Total").frame(width: 80, alignment: .trailing)
                            Text("Cost").frame(width: 70, alignment: .trailing)
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        ForEach(sortedSessions) { s in
                            Button { state.openSession(s.id) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.title).lineLimit(1)
                                        Text("\(s.projectName) · \(Fmt.ago(s.end))").font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Text(Fmt.tokens(s.tokens.input)).frame(width: 70, alignment: .trailing)
                                    Text(Fmt.tokens(s.tokens.output)).frame(width: 70, alignment: .trailing)
                                    Text(Fmt.tokens(s.tokens.cacheCreate)).frame(width: 70, alignment: .trailing)
                                    Text(Fmt.tokens(s.tokens.cacheRead)).frame(width: 70, alignment: .trailing)
                                    Text(Fmt.tokens(s.tokens.total)).fontWeight(.semibold).frame(width: 80, alignment: .trailing)
                                    Text(Fmt.usd(s.cost)).fontWeight(.semibold).foregroundStyle(Color.deckAccent).frame(width: 70, alignment: .trailing)
                                }
                                .monospacedDigit()
                                .padding(.horizontal, 16).padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            .padding(24)
        }
        .fabClearance()
    }
}
