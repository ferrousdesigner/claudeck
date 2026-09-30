import SwiftUI
import AppKit
import ServiceManagement

enum Tab: String, CaseIterable, Identifiable {
    case status = "Status", sessions = "Sessions", search = "Search", usage = "Cost & Tokens", improvements = "Improvements", insights = "Insights",
         projects = "Projects", library = "Prompts & Schedules", security = "Security", extensions = "Extensions"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .status: return "waveform.path.ecg"
        case .sessions: return "books.vertical"
        case .search: return "magnifyingglass"
        case .usage: return "dollarsign.circle"
        case .improvements: return "lightbulb"
        case .insights: return "chart.xyaxis.line"
        case .projects: return "folder"
        case .library: return "text.book.closed"
        case .security: return "lock.shield"
        case .extensions: return "puzzlepiece.extension"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var tab: Tab = .status
    @Published var selectedSessionID: String?
    @Published var showPrompt = false
    @Published var promptResumeID: String?
    @Published var promptCwd: String?
    @Published var promptTemplate: PromptTemplate?
    @Published var extensionsSection: ExtensionsView.Section = .skills
    @Published var showWalkthrough = false
    @Published var guideTopic: String? = "start"

    init() {
        // Optional launch args: --tab <name> --session <id> --section <extensions section> --compose
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--tab"), i + 1 < args.count,
           let t = Tab.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(args[i + 1].lowercased()) }) { tab = t }
        if let i = args.firstIndex(of: "--session"), i + 1 < args.count { selectedSessionID = args[i + 1]; tab = .sessions }
        if let i = args.firstIndex(of: "--section"), i + 1 < args.count,
           let s = ExtensionsView.Section.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(args[i + 1].lowercased()) }) {
            extensionsSection = s; tab = .extensions
        }
        if args.contains("--compose") { showPrompt = true }
        // First launch shows the tour, unless launched for testing/screenshots.
        let scripted = ["--tab", "--session", "--section", "--compose", "--preview", "--search", "--scan", "--guide", "--tabhelp"].contains(where: args.contains)
        if args.contains("--walkthrough") || (!scripted && !UserDefaults.standard.bool(forKey: "didOnboard")) { showWalkthrough = true }
        if let i = args.firstIndex(of: "--guide") { guideTopic = i + 1 < args.count ? args[i + 1] : "start" }
    }

    func openGuide(_ topic: String? = nil) {
        if let topic { guideTopic = topic }
        AppDelegate.openGuideWindow?()
    }

    func openSession(_ id: String) {
        selectedSessionID = id
        tab = .sessions
        AppDelegate.showMainWindow()
    }

    func compose(resume: SessionSummary? = nil, cwd: String? = nil, template: PromptTemplate? = nil) {
        promptResumeID = resume?.id
        promptCwd = resume?.cwd ?? cwd
        promptTemplate = template
        showPrompt = true
        AppDelegate.showMainWindow()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Keep running in the menu bar after the window closes, so alerts and schedules keep working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "stayInMenuBar") as? Bool ?? true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.showMainWindow() }
        return true
    }

    @MainActor static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
    @MainActor static var openMainWindow: (() -> Void)?
    @MainActor static var openGuideWindow: (() -> Void)?
}

@main
struct ClaudeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()
    @StateObject private var sessions = SessionStore()
    @StateObject private var runner = ClaudeRunner()
    @StateObject private var extensions = ExtensionsStore()
    @StateObject private var library = Library()
    @StateObject private var bridge = PermissionBridge()

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--hook"), i + 1 < args.count { HookMode.run(args[i + 1]) }
        if args.contains("--selftest") { SelfTest.run() }
        if args.contains("--livetest") { LiveTest.run() }
        // `Claudeck --dump` prints parsed sessions and exits (handy for checking token math).
        if args.contains("--dump") {
            let (all, _) = SessionWorker().scan()
            for s in all {
                print("\(s.id)\t\(s.projectName)\tturns=\(s.userTurns)/\(s.assistantTurns)\ttools=\(s.toolCalls)\tin=\(s.tokens.input) out=\(s.tokens.output) cw=\(s.tokens.cacheCreate) cr=\(s.tokens.cacheRead)\tcost=\(Fmt.usd(s.cost))\t\(s.title)")
            }
            exit(0)
        }
    }

    var body: some Scene {
        Window("Claudeck", id: "main") {
            ContentView()
                .environmentObject(state)
                .environmentObject(sessions)
                .environmentObject(runner)
                .environmentObject(extensions)
                .environmentObject(library)
                .environmentObject(bridge)
                .frame(minWidth: 1080, minHeight: 680)
                .modifier(Bootstrap(state: state, runner: runner, library: library, bridge: bridge))
        }
        .defaultSize(width: 1360, height: 860)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Prompt to Claude…") { state.compose() }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandMenu("Go") {
                ForEach(Array(Tab.allCases.enumerated()), id: \.element) { i, t in
                    if i < 9 {
                        Button(t.rawValue) { state.tab = t }
                            .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    } else {
                        Button(t.rawValue) { state.tab = t }
                    }
                }
                Divider()
                Button("Find in All Sessions") { state.tab = .search }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Refresh") { sessions.refresh() }.keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Claudeck Guide") { state.openGuide("start") }.keyboardShortcut("?", modifiers: .command)
                Button("Help for This Screen") { state.openGuide(Guide.topic(for: state.tab)?.id) }
                Button("Take the Tour") { state.showWalkthrough = true; AppDelegate.showMainWindow() }
                Divider()
                Button("Keyboard Shortcuts") { state.openGuide("shortcuts") }
                Button("Troubleshooting") { state.openGuide("troubleshooting") }
            }
        }

        Window("Claudeck Guide", id: "guide") {
            GuideWindow()
                .environmentObject(state)
        }
        .defaultSize(width: 900, height: 640)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
                .environmentObject(sessions)
                .environmentObject(runner)
                .environmentObject(bridge)
                .environmentObject(library)
        } label: {
            MenuBarLabel(sessions: sessions, bridge: bridge, runner: runner)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(bridge)
        }
    }
}

/// One-time wiring that needs the environment (opening windows, notification routing).
struct Bootstrap: ViewModifier {
    let state: AppState
    let runner: ClaudeRunner
    let library: Library
    let bridge: PermissionBridge
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            library.runner = runner
            Notifier.shared.bridge = bridge
            Notifier.shared.setup()
            Notifier.shared.onOpenSession = { [weak state] id in state?.openSession(id) }
            AppDelegate.openMainWindow = { openWindow(id: "main") }
            AppDelegate.openGuideWindow = { NSApp.activate(ignoringOtherApps: true); openWindow(id: "guide") }
            if CommandLine.arguments.contains("--guide") { openWindow(id: "guide") }
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var sessions: SessionStore
    @ObservedObject var bridge: PermissionBridge
    @ObservedObject var runner: ClaudeRunner

    var body: some View {
        let busy = sessions.live.filter(\.isBusy).count + runner.activeCount
        HStack(spacing: 3) {
            Image(systemName: !bridge.pending.isEmpty ? "exclamationmark.bubble.fill" : busy > 0 ? "sparkles" : "sparkle")
            if !bridge.pending.isEmpty { Text("\(bridge.pending.count)") } else if busy > 0 { Text("\(busy)") }
        }
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
