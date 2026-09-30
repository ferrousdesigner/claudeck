import Foundation
import Combine

/// A saved, reusable prompt. `{{name}}` placeholders are filled in when it runs.
struct PromptTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var prompt: String
    var cwd: String = ""
    var model: String = ""
    var permissionMode: String = "acceptEdits"
    var icon: String = "text.bubble"

    var variables: [String] {
        var out: [String] = []
        var rest = prompt[...]
        while let a = rest.range(of: "{{"), let b = rest.range(of: "}}", range: a.upperBound..<rest.endIndex) {
            let v = rest[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespaces)
            if !v.isEmpty && !out.contains(v) { out.append(v) }
            rest = rest[b.upperBound...]
        }
        return out
    }

    func filled(_ values: [String: String]) -> String {
        var p = prompt
        for (k, v) in values {
            p = p.replacingOccurrences(of: "{{\(k)}}", with: v).replacingOccurrences(of: "{{ \(k) }}", with: v)
        }
        return p
    }
}

/// Runs a template automatically: daily at a time on chosen weekdays, or every N minutes.
struct Schedule: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable { case daily = "At a time", interval = "Every N minutes" }
    var id = UUID()
    var templateID: UUID
    var kind: Kind = .daily
    var hour = 9
    var minute = 0
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]   // Calendar weekday numbers, 1 = Sunday
    var intervalMinutes = 60
    var enabled = true
    var lastRun: Date?

    /// Next time this schedule should fire after `from`.
    func nextFire(after from: Date) -> Date? {
        guard enabled else { return nil }
        let cal = Calendar.current
        switch kind {
        case .interval:
            let base = lastRun ?? from.addingTimeInterval(-Double(intervalMinutes) * 60)
            return max(base.addingTimeInterval(Double(max(intervalMinutes, 5)) * 60), from)
        case .daily:
            guard !weekdays.isEmpty else { return nil }
            for dayOffset in 0..<8 {
                guard let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: from)),
                      let t = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
                if t > from && weekdays.contains(cal.component(.weekday, from: t)) { return t }
            }
            return nil
        }
    }

    func isDue(now: Date) -> Bool {
        guard enabled else { return false }
        switch kind {
        case .interval:
            guard let last = lastRun else { return true }
            return now.timeIntervalSince(last) >= Double(max(intervalMinutes, 5)) * 60
        case .daily:
            let cal = Calendar.current
            guard weekdays.contains(cal.component(.weekday, from: now)),
                  let today = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now), now >= today,
                  now.timeIntervalSince(today) < 60 * 60 else { return false }   // catch up within an hour
            return lastRun.map { $0 < today } ?? true
        }
    }

    var summary: String {
        switch kind {
        case .interval: return "Every \(intervalMinutes) min"
        case .daily:
            let names = Calendar.current.shortWeekdaySymbols
            let days = weekdays.count == 7 ? "Every day" : weekdays == [2, 3, 4, 5, 6] ? "Weekdays" : weekdays.sorted().map { names[$0 - 1] }.joined(separator: ", ")
            return "\(days) at \(String(format: "%02d:%02d", hour, minute))"
        }
    }
}

@MainActor
final class Library: ObservableObject {
    @Published var templates: [PromptTemplate] = [] { didSet { save() } }
    @Published var schedules: [Schedule] = [] { didSet { save() } }

    private var url: URL { Paths.appSupport.appendingPathComponent("library.json") }
    private var loaded = false
    private var timer: Timer?
    weak var runner: ClaudeRunner?

    private struct Stored: Codable { var templates: [PromptTemplate]; var schedules: [Schedule] }

    init() {
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Stored.self, from: d) {
            templates = s.templates; schedules = s.schedules
        } else {
            templates = Self.starters
        }
        loaded = true
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func save() {
        guard loaded, let d = try? JSONEncoder().encode(Stored(templates: templates, schedules: schedules)) else { return }
        try? d.write(to: url, options: .atomic)
    }

    func template(_ id: UUID) -> PromptTemplate? { templates.first { $0.id == id } }

    @discardableResult
    func run(_ t: PromptTemplate, values: [String: String] = [:], cwd: String? = nil, label: String? = nil) -> PromptRun? {
        guard let runner else { return nil }
        let dir = cwd ?? (t.cwd.isEmpty ? Paths.home.path : t.cwd)
        return runner.send(t.filled(values), options: PromptOptions(cwd: dir, resumeId: nil, model: t.model.isEmpty ? nil : t.model,
                                                                   permissionMode: t.permissionMode), label: label ?? t.name)
    }

    /// Fires due schedules. Runs only while Claudeck is open (it stays alive in the menu bar).
    func tick(now: Date = Date()) {
        for i in schedules.indices where schedules[i].isDue(now: now) {
            guard let t = template(schedules[i].templateID) else { continue }
            schedules[i].lastRun = now
            if let run = run(t, label: "⏰ \(t.name)") { Notifier.shared.watch(run) }
        }
    }

    static let starters: [PromptTemplate] = [
        PromptTemplate(name: "Review my changes", prompt: "Review the uncommitted changes in this repo for bugs, security issues and anything that looks unfinished. Be specific, cite file:line.", permissionMode: "plan", icon: "checklist"),
        PromptTemplate(name: "Run tests and fix", prompt: "Run the test suite. If anything fails, find the root cause and fix it, then re-run until green. Summarize what you changed.", icon: "testtube.2"),
        PromptTemplate(name: "Write tests for…", prompt: "Write thorough tests for {{file or feature}}, matching the existing test style. Run them.", icon: "plus.rectangle.on.rectangle"),
        PromptTemplate(name: "Explain this codebase", prompt: "Give me a concise tour of this codebase: what it does, how it's structured, the main entry points, and anything surprising.", permissionMode: "plan", icon: "map"),
        PromptTemplate(name: "Standup summary", prompt: "Look at git log for the last 24 hours across this repo and write a 5-bullet standup update: what got done, what's in progress, blockers.", permissionMode: "plan", icon: "person.3"),
        PromptTemplate(name: "Dependency check", prompt: "Check this project's dependencies for outdated or vulnerable packages. List them by severity with the upgrade command. Don't change anything.", permissionMode: "plan", icon: "shippingbox"),
    ]
}
