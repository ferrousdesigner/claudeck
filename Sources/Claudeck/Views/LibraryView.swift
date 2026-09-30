import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var state: AppState
    @State private var editing: PromptTemplate?
    @State private var editingSchedule: Schedule?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompts & Schedules").font(.largeTitle.weight(.bold))
                        Text("Save prompts you use often, then run them in one click or on a schedule. Use {{name}} for blanks you fill in each time.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { editing = PromptTemplate(name: "", prompt: "") } label: { Label("New prompt", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(library.templates) { t in
                        Card(padding: 14) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: t.icon).foregroundStyle(Color.deckAccent)
                                    Text(t.name).font(.headline).lineLimit(1)
                                    Spacer()
                                    Menu {
                                        Button("Edit") { editing = t }
                                        Button("Schedule…") { editingSchedule = Schedule(templateID: t.id) }
                                        Button("Duplicate") { var c = t; c.id = UUID(); c.name += " copy"; library.templates.append(c) }
                                        Divider()
                                        Button("Delete", role: .destructive) {
                                            library.templates.removeAll { $0.id == t.id }
                                            library.schedules.removeAll { $0.templateID == t.id }
                                        }
                                    } label: { Image(systemName: "ellipsis.circle") }
                                        .menuStyle(.borderlessButton).fixedSize()
                                }
                                Text(t.prompt).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                                HStack(spacing: 6) {
                                    if !t.cwd.isEmpty { Tag(text: (t.cwd as NSString).lastPathComponent) }
                                    Tag(text: permLabel(t.permissionMode))
                                    if !t.model.isEmpty { Tag(text: t.model) }
                                    Spacer()
                                    Button { state.compose(cwd: t.cwd.isEmpty ? nil : t.cwd, template: t) } label: { Label("Run", systemImage: "play.fill") }
                                        .buttonStyle(.borderedProminent).tint(.deckAccent).controlSize(.small)
                                }
                            }
                        }
                    }
                }

                HStack {
                    Label("Schedules", systemImage: "alarm").font(.title2.weight(.semibold))
                    Spacer()
                    Menu {
                        ForEach(library.templates) { t in Button(t.name) { editingSchedule = Schedule(templateID: t.id) } }
                    } label: { Label("Add schedule", systemImage: "plus") }.fixedSize()
                }
                .padding(.top, 8)
                Text("Schedules run while Claudeck is open — it keeps running in the menu bar when you close the window. Turn on “Open at login” in Settings so they never miss.")
                    .font(.callout).foregroundStyle(.secondary)
                if library.schedules.isEmpty {
                    Card { Text("No schedules yet. Try “Standup summary” every weekday at 9:00.").foregroundStyle(.secondary) }
                }
                ForEach($library.schedules) { $s in
                    Card(padding: 12) {
                        HStack(spacing: 12) {
                            Toggle("", isOn: $s.enabled).toggleStyle(.switch).labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.template(s.templateID)?.name ?? "Deleted prompt").font(.headline)
                                Text("\(s.summary) · in \((library.template(s.templateID)?.cwd ?? "") .isEmpty ? "home folder" : (library.template(s.templateID)!.cwd as NSString).lastPathComponent)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let next = s.nextFire(after: Date()) { Text("Next \(next.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                                Text("Last run \(Fmt.ago(s.lastRun))").font(.caption2).foregroundStyle(.secondary)
                            }
                            Button("Edit") { editingSchedule = s }
                            Button("Run now") {
                                if let t = library.template(s.templateID) { library.run(t, label: "⏰ \(t.name)"); s.lastRun = Date(); state.tab = .status }
                            }
                            Button(role: .destructive) { library.schedules.removeAll { $0.id == s.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .padding(24)
        }
        .fabClearance()
        .sheet(item: $editing) { t in TemplateEditor(template: t) }
        .sheet(item: $editingSchedule) { s in ScheduleEditor(schedule: s) }
    }

    private func permLabel(_ m: String) -> String {
        ["default": "ask-only", "acceptEdits": "auto-edit", "plan": "plan only", "bypassPermissions": "bypass ⚠︎"][m] ?? m
    }
}

struct TemplateEditor: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var sessions: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State var template: PromptTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(library.template(template.id) == nil ? "New prompt" : "Edit prompt").font(.title2.weight(.semibold))
            TextField("Name", text: $template.name).textFieldStyle(.roundedBorder)
            TextEditor(text: $template.prompt)
                .font(.body).frame(minHeight: 150).scrollContentBackground(.hidden).padding(6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            if !template.variables.isEmpty {
                Text("Blanks: \(template.variables.map { "{{\($0)}}" }.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Folder").foregroundStyle(.secondary)
                    Picker("", selection: $template.cwd) {
                        Text("Ask each time").tag("")
                        ForEach(sessions.knownProjects, id: \.self) { Text(($0 as NSString).abbreviatingWithTildeInPath).tag($0) }
                        if !template.cwd.isEmpty && !sessions.knownProjects.contains(template.cwd) { Text(template.cwd).tag(template.cwd) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Permissions").foregroundStyle(.secondary)
                    PermissionPicker(mode: $template.permissionMode)
                }
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    ModelPicker(model: $template.model)
                }
                GridRow {
                    Text("Icon").foregroundStyle(.secondary)
                    Picker("", selection: $template.icon) {
                        ForEach(["text.bubble", "checklist", "testtube.2", "hammer", "map", "person.3", "shippingbox", "doc.text", "ladybug", "sparkles", "bolt", "paintbrush"], id: \.self) {
                            Image(systemName: $0).tag($0)
                        }
                    }.labelsHidden().frame(width: 80)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let i = library.templates.firstIndex(where: { $0.id == template.id }) { library.templates[i] = template }
                    else { library.templates.append(template) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(template.name.isEmpty || template.prompt.isEmpty)
            }
        }
        .padding(20).frame(width: 560)
    }
}

struct ScheduleEditor: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State var schedule: Schedule

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schedule “\(library.template(schedule.templateID)?.name ?? "")”").font(.title2.weight(.semibold))
            Picker("Prompt", selection: $schedule.templateID) {
                ForEach(library.templates) { Text($0.name).tag($0.id) }
            }
            Picker("Run", selection: $schedule.kind) {
                ForEach(Schedule.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if schedule.kind == .daily {
                HStack {
                    Text("Time")
                    DatePicker("", selection: Binding(
                        get: { Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date())! },
                        set: { schedule.hour = Calendar.current.component(.hour, from: $0); schedule.minute = Calendar.current.component(.minute, from: $0) }
                    ), displayedComponents: .hourAndMinute).labelsHidden()
                }
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { d in
                        let on = schedule.weekdays.contains(d)
                        Button(Calendar.current.veryShortWeekdaySymbols[d - 1]) {
                            if on { schedule.weekdays.remove(d) } else { schedule.weekdays.insert(d) }
                        }
                        .buttonStyle(.bordered).tint(on ? .accentColor : .secondary)
                    }
                }
            } else {
                Stepper("Every \(schedule.intervalMinutes) minutes", value: $schedule.intervalMinutes, in: 5...1440, step: 5)
            }
            if library.template(schedule.templateID)?.cwd.isEmpty ?? true {
                Label("This prompt has no folder set, so it will run in your home folder. Set one by editing the prompt.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !(library.template(schedule.templateID)?.variables.isEmpty ?? true) {
                Label("Blanks like {{…}} stay empty on scheduled runs.", systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let i = library.schedules.firstIndex(where: { $0.id == schedule.id }) { library.schedules[i] = schedule }
                    else { library.schedules.append(schedule) }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460)
    }
}

struct PermissionPicker: View {
    @Binding var mode: String
    var body: some View {
        Picker("", selection: $mode) {
            Text("Ask-only (read, no edits)").tag("default")
            Text("Auto-accept file edits").tag("acceptEdits")
            Text("Plan mode (no changes)").tag("plan")
            Text("Bypass all permissions ⚠︎").tag("bypassPermissions")
        }.labelsHidden()
    }
}

struct ModelPicker: View {
    @Binding var model: String
    var body: some View {
        Picker("", selection: $model) {
            Text("Default").tag("")
            Text("Opus").tag("opus")
            Text("Sonnet").tag("sonnet")
            Text("Haiku").tag("haiku")
        }.labelsHidden()
    }
}
