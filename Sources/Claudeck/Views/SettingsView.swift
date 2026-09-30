import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var bridge: PermissionBridge
    @AppStorage("memoryFolder") private var memoryFolder = ""
    @AppStorage("summaryModel") private var summaryModel = "haiku"
    @AppStorage("budgetDaily") private var daily = 0.0
    @AppStorage("budgetWeekly") private var weekly = 0.0
    @AppStorage("budgetMonthly") private var monthly = 0.0
    @AppStorage("notify") private var notify = true
    @AppStorage("notifyIdle") private var notifyIdle = true
    @AppStorage("stayInMenuBar") private var stayInMenuBar = true
    @AppStorage("approvalWait") private var approvalWait = 30.0
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var error: String?

    var body: some View {
        TabView {
            Form {
                Section("App") {
                    Toggle("Open at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in
                            do { try LaunchAtLogin.set(on) } catch { self.error = error.localizedDescription; launchAtLogin = LaunchAtLogin.isEnabled }
                        }
                    Toggle("Keep running in the menu bar when the window is closed", isOn: $stayInMenuBar)
                }
                Section("Memory docs") {
                    HStack {
                        Text((Paths.memoryDir.path as NSString).abbreviatingWithTildeInPath).font(.callout.monospaced())
                        Spacer()
                        Button("Change…") {
                            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                            if p.runModal() == .OK, let u = p.url { memoryFolder = u.path }
                        }
                        Button("Reveal") { NSWorkspace.shared.open(Paths.memoryDir) }
                    }
                    Picker("Model for summaries & digests", selection: $summaryModel) {
                        Text("Haiku (fast, cheap)").tag("haiku")
                        Text("Sonnet").tag("sonnet")
                        Text("Opus").tag("opus")
                    }
                }
                Section("Claude Code CLI") {
                    Text(Paths.claudeBinary ?? "Not found").font(.callout.monospaced())
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Section {
                    Toggle("Show notifications", isOn: $notify)
                    Toggle("When a session finishes and waits for you", isOn: $notifyIdle).disabled(!notify)
                    Text("You're also notified when prompts sent from Claudeck finish, when a budget hits 80% or 100%, and when Claude needs permission.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Send a test notification") { Notifier.shared.post("Claudeck", "Notifications are working.") }
                }
                Section("Approve permissions from Claudeck") {
                    Toggle("Answer Claude's permission prompts here", isOn: Binding(
                        get: { bridge.installed },
                        set: { on in do { try on ? bridge.install() : bridge.uninstall() } catch { self.error = error.localizedDescription } }
                    ))
                    Stepper("Wait \(Int(approvalWait)) seconds for an answer, then ask in the terminal", value: $approvalWait, in: 10...120, step: 5)
                    Text("Adds a PermissionRequest hook to ~/.claude/settings.json (a backup is kept). When Claude needs approval you get a notification with Allow / Deny, and the request shows in the menu bar. Toggle off and on again after changing the wait so the hook's timeout matches. If Claudeck isn't open, the terminal asks as usual.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .tabItem { Label("Alerts", systemImage: "bell") }

            Form {
                Section {
                    budgetField("Daily budget", $daily)
                    budgetField("Weekly budget", $weekly)
                    budgetField("Monthly budget", $monthly)
                    Text("Costs are API list prices for the tokens used. On a Pro or Max plan you aren't charged per token, but it's still a good measure of how hard you're pushing your plan. Leave at 0 for no budget.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Budget", systemImage: "dollarsign.circle") }
        }
        .frame(width: 560, height: 420)
    }

    private func budgetField(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .currency(code: "USD")).frame(width: 110).multilineTextAlignment(.trailing)
        }
    }
}
