import Foundation
import Combine

/// One prompt sent from the dashboard to the local `claude` CLI (headless, stream-json).
@MainActor
final class PromptRun: ObservableObject, Identifiable {
    enum State: Equatable { case running, done, failed(String), cancelled }

    struct Event: Identifiable, Hashable {
        enum Kind { case text, tool, result, error, info }
        let id: Int
        let kind: Kind
        let text: String
    }

    let id = UUID()
    let prompt: String
    let cwd: String
    let resumeId: String?
    var label: String?
    var groupID: UUID?          // set when the run is one of several parallel worktree runs
    let startedAt = Date()
    @Published var state: State = .running
    @Published var events: [Event] = []
    @Published var sessionId: String?
    @Published var tokens = TokenUsage()
    @Published var costUSD: Double?
    @Published var finishedAt: Date?

    fileprivate var process: Process?

    init(prompt: String, cwd: String, resumeId: String?) {
        self.prompt = prompt; self.cwd = cwd; self.resumeId = resumeId
    }

    var title: String { label ?? String(prompt.replacingOccurrences(of: "\n", with: " ").prefix(80)) }
    var finalText: String? { events.last(where: { $0.kind == .result })?.text ?? events.last(where: { $0.kind == .text })?.text }

    fileprivate func add(_ kind: Event.Kind, _ text: String) {
        events.append(Event(id: events.count, kind: kind, text: text))
    }

    func cancel() {
        process?.terminate()
        state = .cancelled
        finishedAt = Date()
    }
}

struct PromptOptions {
    var cwd: String
    var resumeId: String?
    var model: String?          // nil = CLI default
    var permissionMode: String  // default | acceptEdits | plan | bypassPermissions
}

@MainActor
final class ClaudeRunner: ObservableObject {
    @Published private(set) var runs: [PromptRun] = []
    private var forwarders: [UUID: AnyCancellable] = [:]

    var activeCount: Int { runs.filter { $0.state == .running }.count }

    @discardableResult
    func send(_ prompt: String, options: PromptOptions, label: String? = nil, groupID: UUID? = nil) -> PromptRun {
        let run = PromptRun(prompt: prompt, cwd: options.cwd, resumeId: options.resumeId)
        run.label = label
        run.groupID = groupID
        runs.insert(run, at: 0)
        // Re-publish when a run changes so counts like `activeCount` stay current.
        forwarders[run.id] = run.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        Notifier.shared.watch(run)

        guard let bin = Paths.claudeBinary else {
            run.add(.error, "Couldn't find the `claude` CLI. Install Claude Code or add it to your PATH.")
            run.state = .failed("claude not found")
            return run
        }

        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                    "--permission-mode", options.permissionMode]
        if let r = options.resumeId { args += ["--resume", r] }
        if let m = options.model { args += ["--model", m] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: options.cwd)
        p.environment = Paths.childEnvironment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        run.process = p

        let reader = LineReader { [weak run] line in
            Task { @MainActor in run.map { Self.handle(line: line, run: $0) } }
        }
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { reader.feed(d) }
        }
        let errBuffer = LockedData()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { errBuffer.append(d) }
        }
        p.terminationHandler = { [weak run] proc in
            let status = proc.terminationStatus
            let stderr = String(data: errBuffer.value, encoding: .utf8) ?? ""
            Task { @MainActor in
                guard let run else { return }
                reader.flush()
                if run.state == .running {
                    if status == 0 { run.state = .done } else {
                        if !stderr.isEmpty { run.add(.error, stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        run.state = .failed("exit \(status)")
                    }
                }
                run.finishedAt = Date()
            }
        }
        do { try p.run() } catch {
            run.add(.error, error.localizedDescription)
            run.state = .failed(error.localizedDescription)
        }
        return run
    }

    func clearFinished() {
        for r in runs where r.state != .running { forwarders[r.id] = nil }
        runs.removeAll { $0.state != .running }
    }

    private static func handle(line: String, run: PromptRun) {
        guard let data = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { run.add(.info, line) }
            return
        }
        if let sid = o["session_id"] as? String { run.sessionId = sid }
        switch o["type"] as? String {
        case "system":
            if o["subtype"] as? String == "init" {
                let model = o["model"] as? String ?? ""
                run.add(.info, "Session started\(model.isEmpty ? "" : " · \(model)")")
            }
        case "assistant":
            guard let msg = o["message"] as? [String: Any] else { return }
            for b in msg["content"] as? [[String: Any]] ?? [] {
                switch b["type"] as? String {
                case "text": if let t = b["text"] as? String, !t.isEmpty { run.add(.text, t) }
                case "tool_use": run.add(.tool, SessionParser.describeToolUse(b))
                default: break
                }
            }
        case "result":
            if let u = o["usage"] as? [String: Any] { run.tokens = TokenUsage(json: u) }
            run.costUSD = o["total_cost_usd"] as? Double
            let isError = (o["is_error"] as? Bool) == true
            // The result repeats Claude's final message; only show it if it adds something.
            if let r = o["result"] as? String, !r.isEmpty, isError || run.events.last(where: { $0.kind == .text })?.text != r {
                run.add(isError ? .error : .result, r)
            }
            run.state = isError ? .failed(o["subtype"] as? String ?? "error") : .done
            run.finishedAt = Date()
        default: break
        }
    }
}

/// Splits a byte stream into UTF-8 lines.
final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void
    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func feed(_ d: Data) {
        lock.lock()
        buffer.append(d)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8) { lines.append(s) }
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let rest = buffer; buffer = Data()
        lock.unlock()
        if !rest.isEmpty, let s = String(data: rest, encoding: .utf8) { onLine(s) }
    }
}

final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Runs a one-shot `claude -p` and returns stdout. Used for summaries and CLI listings.
enum CLI {
    static func run(_ args: [String], stdin: String? = nil, cwd: URL = Paths.appSupport) async -> (status: Int32, out: String, err: String) {
        guard let bin = Paths.claudeBinary else { return (127, "", "claude CLI not found") }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = args
                p.currentDirectoryURL = cwd
                p.environment = Paths.childEnvironment
                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out; p.standardError = err
                p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
                do { try p.run() } catch { cont.resume(returning: (126, "", error.localizedDescription)); return }
                // Drain stderr and feed stdin off-thread so large outputs can't deadlock the pipes.
                let errBuf = LockedData()
                let group = DispatchGroup()
                DispatchQueue.global().async(group: group) { errBuf.append(err.fileHandleForReading.readDataToEndOfFile()) }
                if let stdin {
                    DispatchQueue.global().async(group: group) {
                        inp.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data())
                        try? inp.fileHandleForWriting.close()
                    }
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                group.wait()
                cont.resume(returning: (p.terminationStatus,
                                        String(data: outData, encoding: .utf8) ?? "",
                                        String(data: errBuf.value, encoding: .utf8) ?? ""))
            }
        }
    }
}
