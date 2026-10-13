import SwiftUI
import WebKit

/// Renders message HTML with scripts disabled, links opened in the browser,
/// `cid:` images served from the message itself, and optional remote blocking.
struct MessageWebView: NSViewRepresentable {
    let document: String
    let key: String
    let inline: [String: Attachment]
    let blockRemote: Bool
    var onMailto: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.cid, forURLScheme: "letterbox-cid")
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = true
        view.allowsBackForwardNavigationGestures = false
        RemoteContentBlocker.prepare()
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let c = context.coordinator
        c.onMailto = onMailto
        c.cid.parts = inline
        let loadKey = "\(key)|\(blockRemote)"
        guard c.loadedKey != loadKey else { return }
        c.loadedKey = loadKey
        let controller = view.configuration.userContentController
        controller.removeAllContentRuleLists()
        if blockRemote, let rules = RemoteContentBlocker.rules { controller.add(rules) }
        view.loadHTMLString(document, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let cid = CIDSchemeHandler()
        var loadedKey: String?
        var onMailto: ((URL) -> Void)?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            if action.navigationType == .linkActivated || (action.targetFrame?.isMainFrame ?? true) && url.scheme != "about" {
                if url.scheme == "mailto" {
                    onMailto?(url)
                } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
    }
}

final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {
    var parts: [String: Attachment] = [:]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let raw = url.absoluteString.replacingOccurrences(of: "letterbox-cid:", with: "")
        let key = (raw.removingPercentEncoding ?? raw).lowercased()
        guard let part = parts[key] else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: part.mimeType, expectedContentLength: part.data.count, textEncodingName: nil))
        task.didReceive(part.data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

enum RemoteContentBlocker {
    nonisolated(unsafe) static var rules: WKContentRuleList?
    private nonisolated(unsafe) static var started = false

    static func prepare() {
        guard !started else { return }
        started = true
        let json = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "letterbox.block-remote", encodedContentRuleList: json) { list, _ in
            rules = list
        }
    }
}

enum MessageHTML {
    private static let cidPattern = try! NSRegularExpression(pattern: "(src\\s*=\\s*[\"']?)cid:", options: .caseInsensitive)
    private static let headTag = try! NSRegularExpression(pattern: "<head[^>]*>", options: .caseInsensitive)
    private static let urlPattern = try! NSRegularExpression(pattern: "\\b(https?://[^\\s<>\"']+[^\\s<>\"'.,;:!?)\\]])", options: .caseInsensitive)
    private static let emailPattern = try! NSRegularExpression(pattern: "\\b([A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,})\\b", options: .caseInsensitive)

    @MainActor private static var documents: [String: (doc: String, remote: Bool)] = [:]

    @MainActor static func cachedDocument(for message: ParsedMessage, key: String) -> String {
        entry(message, key).doc
    }

    @MainActor static func cachedHasRemote(_ message: ParsedMessage, key: String) -> Bool {
        entry(message, key).remote
    }

    @MainActor private static func entry(_ message: ParsedMessage, _ key: String) -> (doc: String, remote: Bool) {
        if let hit = documents[key] { return hit }
        if documents.count > 30 { documents.removeAll() }
        let value = (document(for: message), hasRemoteContent(message))
        documents[key] = value
        return value
    }

    static func document(for message: ParsedMessage) -> String {
        if let html = message.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return htmlDocument(html)
        }
        return textDocument(message.text ?? "")
    }

    static func hasRemoteContent(_ message: ParsedMessage) -> Bool {
        guard let html = message.html else { return false }
        return html.range(of: "src=[\"']?https?:", options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: "url\\(['\"]?https?:", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let htmlHead = """
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; frame-src 'none'">
    <style>
      :root { color-scheme: light only; }
      html { -webkit-text-size-adjust: 100%; background: #ffffff; }
      body { margin: 0; padding: 20px 26px 32px; font: 14px/1.5 -apple-system, system-ui, "Helvetica Neue", sans-serif; color: #1d1d1f; overflow-wrap: anywhere; }
      img { max-width: 100%; height: auto; }
      pre { white-space: pre-wrap; }
      blockquote[type=cite] { margin: 6px 0; padding-left: 12px; border-left: 3px solid #d0d0d6; color: #555; }
      a { color: #0a64d6; }
    </style>
    """

    private static func htmlDocument(_ html: String) -> String {
        let ns = html as NSString
        var body = cidPattern.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: ns.length), withTemplate: "$1letterbox-cid:")
        let bns = body as NSString
        if let m = headTag.firstMatch(in: body, range: NSRange(location: 0, length: bns.length)) {
            let insertAt = m.range.location + m.range.length
            body = bns.replacingCharacters(in: NSRange(location: insertAt, length: 0), with: htmlHead)
        } else {
            body = "<!doctype html><html><head>\(htmlHead)</head><body>\(body)</body></html>"
        }
        return body
    }

    private static func textDocument(_ text: String) -> String {
        var html = ""
        var depth = 0
        var inSignature = false
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(rawLine)
            var level = 0
            while line.hasPrefix(">") {
                level += 1
                line = line.dropFirst()
                if line.hasPrefix(" ") { line = line.dropFirst() }
            }
            while depth < level { html += "<blockquote>"; depth += 1 }
            while depth > level { html += "</blockquote>"; depth -= 1 }
            if line == "-- " && level == 0 && !inSignature {
                inSignature = true
                html += "<div class=\"sig\">"
            }
            html += linkify(HTMLText.escape(String(line))) + "\n"
        }
        while depth > 0 { html += "</blockquote>"; depth -= 1 }
        if inSignature { html += "</div>" }

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'">
        <style>
          :root { color-scheme: light dark; }
          body { margin: 0; padding: 20px 26px 32px; font: 14px/1.55 -apple-system, system-ui, sans-serif; white-space: pre-wrap; overflow-wrap: anywhere; color: #1d1d1f; }
          blockquote { margin: 2px 0; padding-left: 12px; border-left: 3px solid rgba(127,127,140,.35); color: #6e6e73; }
          .sig { color: #8e8e93; }
          a { color: #0a64d6; text-decoration: none; }
          a:hover { text-decoration: underline; }
          @media (prefers-color-scheme: dark) {
            body { color: #ececf0; }
            blockquote { color: #a1a1a8; }
            a { color: #5aa8ff; }
          }
        </style></head><body>\(html)</body></html>
        """
    }

    private static func linkify(_ s: String) -> String {
        let ns = s as NSString
        var out = urlPattern.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "<a href=\"$1\">$1</a>")
        if !out.contains("<a ") {
            let ons = out as NSString
            out = emailPattern.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: ons.length), withTemplate: "<a href=\"mailto:$1\">$1</a>")
        }
        return out
    }
}
