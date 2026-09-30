import SwiftUI
import AppKit

struct PromptComposer: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var runner: ClaudeRunner
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var cwd = ""
    @State private var resumeID: String?
    @State private var templateID: UUID?
    @State private var values: [String: String] = [:]
    @State private var parallel = 1
    @State private var error: String?
    @AppStorage("promptModel") private var model = ""
    @AppStorage("promptPermissionMode") private var permissionMode = "acceptEdits"
    @AppStorage("lastPromptCwd") private var lastCwd = ""
    @FocusState private var focused: Bool

    private var template: PromptTemplate? { templateID.flatMap { library.template($0) } }
    private var resumeIsLive: Bool { resumeID.flatMap { sessions.liveSession(for: $0) } != nil }
    private var isGitRepo: Bool { !cwd.isEmpty && Projects.git(cwd, ["rev-parse", "--is-inside-work-tree"]) == "true" }
    private var finalPrompt: String {
        guard let t = template else { return prompt }
        return PromptTemplate(name: t.name, prompt: prompt).filled(values)
    }
    private var variables: [String] { PromptTemplate(name: "", prompt: prompt).variables }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Color.deckAccent)
                Text("Ask Claude Code").font(.title2.weight(.semibold))
                Spacer()
                Menu {
                    Button("Blank prompt") { templateID = nil; prompt = "" }
                    Divider()
                    ForEach(library.templates) { t in Button(t.name) { apply(t) } }
                } label: { Label(template?.name ?? "Saved prompts", systemImage: "text.book.closed") }
                    .fixedSize()
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompt)
                    .font(.body).focused($focused).scrollContentBackground(.hidden).padding(8)
                if prompt.isEmpty {
                    Text("What should Claude do? e.g. “Run the tests in shoppio-web and fix anything failing”")
                        .foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                }
            }
            .frame(minHeight: 130)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))

            if !variables.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(variables, id: \.self) { v in
                        HStack {
                            Text(v).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                            TextField("Fill in \(v)", text: Binding(get: { values[v] ?? "" }, set: { values[v] = $0 })).textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Session").foregroundStyle(.secondary)
                    Picker("", selection: $resumeID) {
                        Text("New session").tag(String?.none)
                        Divider()
                        ForEach(sessions.sessions.prefix(25)) { s in
                            Text("Continue: \(s.title.prefix(50)) · \(s.projectName)").tag(Optional(s.id))
                        }
                    }
                    .labelsHidden()
                    .onChange(of: resumeID) { _, id in
                        if let c = id.flatMap({ sessions.session(id: $0)?.cwd }) { cwd = c }
                        if id != nil { parallel = 1 }
                    }
                }
                GridRow {
                    Text("Folder").foregroundStyle(.secondary)
                    HStack {
                        Picker("", selection: $cwd) {
                            if !sessions.knownProjects.contains(cwd) && !cwd.isEmpty { Text((cwd as NSString).abbreviatingWithTildeInPath).tag(cwd) }
                            ForEach(sessions.knownProjects, id: \.self) { p in Text((p as NSString).abbreviatingWithTildeInPath).tag(p) }
                        }
                        .labelsHidden().disabled(resumeID != nil)
                        Button("Choose…") { chooseFolder() }.disabled(resumeID != nil)
                    }
                }
                GridRow {
                    Text("Permissions").foregroundStyle(.secondary)
                    PermissionPicker(mode: $permissionMode)
                }
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    ModelPicker(model: $model)
                }
                GridRow {
                    Text("Parallel").foregroundStyle(.secondary)
                    HStack {
                        Stepper(parallel == 1 ? "1 run" : "\(parallel) runs in separate git worktrees", value: $parallel, in: 1...4)
                            .disabled(resumeID != nil || !isGitRepo)
                        if !isGitRepo && resumeID == nil {
                            Text("(needs a git repo)").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            if parallel > 1 {
                Label("Claude gets \(parallel) isolated copies of the repo (new branches deck/…). Compare the results on the Status tab and keep the one you like.", systemImage: "square.split.2x2")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if resumeIsLive {
                Label("This session is open in a terminal. Sending here continues it in the background as a separate run.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if permissionMode == "default" {
                Label("Headless runs can't ask you for permission, so tools that need approval (edits, most shell commands) are skipped.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }

            HStack {
                Text("⌘↩ to send · progress shows on the Status tab").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Save as prompt…") {
                    library.templates.append(PromptTemplate(name: String(prompt.prefix(30)), prompt: prompt, cwd: cwd, model: model, permissionMode: permissionMode))
                }.disabled(prompt.isEmpty || template != nil)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { send() } label: { Label("Send", systemImage: "paperplane.fill") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(finalPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cwd.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear {
            resumeID = state.promptResumeID
            cwd = state.promptCwd ?? (lastCwd.isEmpty ? (sessions.knownProjects.first ?? Paths.home.path) : lastCwd)
            if let t = state.promptTemplate { apply(t) }
            focused = true
        }
    }

    private func apply(_ t: PromptTemplate) {
        templateID = t.id
        prompt = t.prompt
        if !t.cwd.isEmpty { cwd = t.cwd }
        model = t.model
        permissionMode = t.permissionMode
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: cwd.isEmpty ? Paths.home.path : cwd)
        if panel.runModal() == .OK, let u = panel.url { cwd = u.path }
    }

    private func send() {
        let text = finalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        lastCwd = cwd
        let opts = PromptOptions(cwd: cwd, resumeId: resumeID, model: model.isEmpty ? nil : model, permissionMode: permissionMode)
        if parallel > 1 {
            do {
                let wts = try Worktrees.create(repo: cwd, count: parallel, slug: template?.name ?? String(text.prefix(20)))
                let group = UUID()
                for (i, wt) in wts.enumerated() {
                    var o = opts; o.cwd = wt.path
                    runner.send(text, options: o, label: "#\(i + 1) · \(template?.name ?? String(text.prefix(50)))", groupID: group)
                }
            } catch {
                self.error = error.localizedDescription
                return
            }
        } else {
            runner.send(text, options: opts, label: template?.name)
        }
        state.tab = .status
        dismiss()
    }
}
