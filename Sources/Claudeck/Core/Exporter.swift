import Foundation
import AppKit
import WebKit

/// Converts memory docs (Markdown) to HTML, Word (.docx) and PDF.
enum Exporter {
    static func html(fromMarkdown md: String, title: String) -> String {
        var body = ""
        var inList = false, inCode = false, inTable = false
        func closeBlocks() {
            if inList { body += "</ul>\n"; inList = false }
            if inTable { body += "</table>\n"; inTable = false }
        }
        for raw in md.components(separatedBy: "\n") {
            let line = raw
            if line.hasPrefix("```") {
                closeBlocks()
                body += inCode ? "</code></pre>\n" : "<pre><code>"
                inCode.toggle(); continue
            }
            if inCode { body += escape(line) + "\n"; continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") {
                if t.replacingOccurrences(of: "|", with: "").allSatisfy({ $0 == "-" || $0 == " " || $0 == ":" }) { continue }
                if !inTable { closeBlocks(); body += "<table>\n"; inTable = true }
                let cells = t.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                body += "<tr>" + cells.map { "<td>\(inline($0.trimmingCharacters(in: .whitespaces)))</td>" }.joined() + "</tr>\n"
                continue
            }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                if inTable { body += "</table>\n"; inTable = false }
                if !inList { body += "<ul>\n"; inList = true }
                let item = t.hasPrefix("- ") || t.hasPrefix("* ") ? String(t.dropFirst(2)) : String(t[t.range(of: ". ")!.upperBound...])
                body += "<li>\(inline(item))</li>\n"; continue
            }
            closeBlocks()
            if t.isEmpty { continue }
            if let level = t.firstIndex(where: { $0 != "#" }).map({ t.distance(from: t.startIndex, to: $0) }), level > 0, level <= 6, t.hasPrefix("#") {
                body += "<h\(level)>\(inline(t.dropFirst(level).trimmingCharacters(in: .whitespaces)))</h\(level)>\n"
            } else {
                body += "<p>\(inline(t))</p>\n"
            }
        }
        closeBlocks()
        if inCode { body += "</code></pre>" }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body{font:14px -apple-system,Helvetica,Arial,sans-serif;line-height:1.5;color:#1d1d1f;max-width:760px;margin:32px auto;padding:0 24px}
        h1{font-size:24px}h2{font-size:18px;margin-top:28px;border-bottom:1px solid #ddd;padding-bottom:4px}h3{font-size:15px;margin-top:20px}
        code{font:12px Menlo,monospace;background:#f2f2f2;padding:1px 4px;border-radius:3px}
        pre{background:#f6f6f6;padding:10px;border-radius:6px;overflow:auto}pre code{background:none;padding:0}
        table{border-collapse:collapse;margin:12px 0}td{border:1px solid #ddd;padding:4px 8px;vertical-align:top}
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inline(_ s: String) -> String {
        var h = escape(s)
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
            (#"(?<![*\w])\*([^*]+)\*(?!\*)"#, "<em>$1</em>"),
            (#"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (p, r) in rules { h = h.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        return h
    }

    /// Word document via macOS's built-in `textutil`.
    static func docx(markdown: String, title: String, to out: URL) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".html")
        try html(fromMarkdown: markdown, title: title).write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        p.arguments = ["-convert", "docx", "-output", out.path, tmp.path]
        p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "Exporter", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "textutil failed"]) }
    }

    /// PDF rendered through WebKit.
    @MainActor
    static func pdf(markdown: String, title: String, to out: URL) async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1100))
        let loader = PDFLoader()
        web.navigationDelegate = loader
        web.loadHTMLString(html(fromMarkdown: markdown, title: title), baseURL: nil)
        await loader.waitUntilLoaded()
        let config = WKPDFConfiguration()
        let data = try await web.pdf(configuration: config)
        try data.write(to: out)
    }

    /// Asks where to save, then writes the chosen format.
    @MainActor
    static func exportWithPanel(markdown: String, title: String, defaultName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: ["Word document (.docx)", "PDF (.pdf)", "Markdown (.md)", "Web page (.html)"])
        let exts = ["docx", "pdf", "md", "html"]
        format.target = panel
        panel.accessoryView = format
        panel.nameFieldStringValue = defaultName + ".docx"
        let handler = FormatChange(panel: panel, popup: format, exts: exts)
        format.action = #selector(FormatChange.changed)
        format.target = handler
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = exts[format.indexOfSelectedItem]
        let dest = url.pathExtension == ext ? url : url.deletingPathExtension().appendingPathExtension(ext)
        Task {
            do {
                switch ext {
                case "docx": try docx(markdown: markdown, title: title, to: dest)
                case "pdf": try await pdf(markdown: markdown, title: title, to: dest)
                case "html": try html(fromMarkdown: markdown, title: title).write(to: dest, atomically: true, encoding: .utf8)
                default: try markdown.write(to: dest, atomically: true, encoding: .utf8)
                }
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                NSAlert(error: error).runModal()
            }
            _ = handler
        }
    }
}

private final class FormatChange: NSObject {
    let panel: NSSavePanel; let popup: NSPopUpButton; let exts: [String]
    init(panel: NSSavePanel, popup: NSPopUpButton, exts: [String]) { self.panel = panel; self.popup = popup; self.exts = exts }
    @objc func changed() {
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + exts[popup.indexOfSelectedItem]
    }
}

private final class PDFLoader: NSObject, WKNavigationDelegate {
    private var cont: CheckedContinuation<Void, Never>?
    private var done = false
    func waitUntilLoaded() async {
        if done { return }
        await withCheckedContinuation { c in cont = c }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true; cont?.resume(); cont = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done = true; cont?.resume(); cont = nil }
}
