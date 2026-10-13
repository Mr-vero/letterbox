import Foundation

struct Attachment: Identifiable, Hashable {
    let id = UUID()
    let filename: String
    let mimeType: String
    let data: Data
    let contentID: String?

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    var symbol: String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.hasPrefix("video/") { return "film" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        switch ext {
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "rar", "7z": return "doc.zipper"
        case "ics": return "calendar"
        case "xls", "xlsx", "csv", "numbers": return "tablecells"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle"
        case "eml": return "envelope"
        default: return "doc"
        }
    }
}

struct ParsedMessage {
    var headers = MIMEHeaders()
    var html: String?
    var text: String?
    var attachments: [Attachment] = []
    var inline: [String: Attachment] = [:]

    var snippet: String {
        let source = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? html.map(HTMLText.plainText) ?? ""
        let lines = source
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") }
        return HTMLText.squash(lines.joined(separator: " ")).prefix(220).description
    }

    /// Best plain-text rendering, used for quoting in replies.
    var quotableText: String {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return html.map(HTMLText.plainText) ?? ""
    }
}

enum MessageParser {
    static func parse(_ raw: [UInt8]) -> ParsedMessage {
        let root = MIMEPart(raw[...])
        var result = ParsedMessage(headers: root.headers)
        walk(root, into: &result)
        return result
    }

    private static func walk(_ part: MIMEPart, into result: inout ParsedMessage) {
        let type = part.mimeType
        if type.hasPrefix("multipart/") {
            if type == "multipart/alternative" {
                // Prefer the richest alternative, but keep plain text for quoting/snippets.
                for child in part.children where child.mimeType == "text/plain" && result.text == nil && !child.isAttachment {
                    result.text = child.textContent
                }
                if let rich = part.children.last(where: { $0.mimeType == "text/html" || $0.mimeType.hasPrefix("multipart/") }) {
                    walk(rich, into: &result)
                } else if let any = part.children.last {
                    walk(any, into: &result)
                }
            } else {
                for child in part.children { walk(child, into: &result) }
            }
            return
        }

        let isText = type == "text/plain" || type == "text/html"
        if isText && !part.isAttachment {
            let content = part.textContent
            if type == "text/html" {
                if result.html == nil { result.html = content } else { result.html! += content }
            } else if result.text == nil {
                result.text = content
            } else if result.html == nil {
                result.text! += "\n" + content
            }
            return
        }

        if type == "application/pgp-signature" || type == "application/pkcs7-signature" { return }

        let data = Data(part.decodedBody)
        let name = part.filename ?? defaultName(for: type)
        let attachment = Attachment(filename: name, mimeType: type, data: data, contentID: part.contentID)
        if let cid = part.contentID, type.hasPrefix("image/"), part.disposition != "attachment" {
            result.inline[cid] = attachment
            if part.filename == nil { return }
            if part.disposition == "inline" { return }
            return
        }
        result.attachments.append(attachment)
    }

    private static func defaultName(for type: String) -> String {
        switch type {
        case "message/rfc822": return "Attached Message.eml"
        case "text/calendar": return "invite.ics"
        default:
            let ext = type.split(separator: "/").last.map(String.init) ?? "bin"
            return "Attachment.\(ext)"
        }
    }
}

final class MIMEPart {
    let headers: MIMEHeaders
    let mimeType: String
    let params: [String: String]
    let rawBody: ArraySlice<UInt8>
    private(set) var children: [MIMEPart] = []

    init(_ bytes: ArraySlice<UInt8>, defaultType: String = "text/plain") {
        if let (headerEnd, bodyStart) = MIME.headerBoundary(bytes) {
            headers = MIME.parseHeaders(bytes[bytes.startIndex..<headerEnd])
            rawBody = bytes[bodyStart..<bytes.endIndex]
        } else {
            headers = MIME.parseHeaders(bytes)
            rawBody = []
        }
        let ct = MIME.parseParameterized(headers["Content-Type"] ?? defaultType)
        mimeType = ct.value.isEmpty ? defaultType : ct.value
        params = ct.params

        if mimeType.hasPrefix("multipart/"), let boundary = params["boundary"], !boundary.isEmpty {
            let childDefault = mimeType == "multipart/digest" ? "message/rfc822" : "text/plain"
            children = MIMEPart.split(rawBody, boundary: boundary).map { MIMEPart($0, defaultType: childDefault) }
        }
    }

    lazy var dispositionInfo = MIME.parseParameterized(headers["Content-Disposition"] ?? "")
    var disposition: String { dispositionInfo.value }

    var filename: String? {
        let name = dispositionInfo.params["filename"] ?? params["name"]
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }

    var contentID: String? {
        guard var cid = headers["Content-ID"]?.trimmingCharacters(in: .whitespaces), !cid.isEmpty else { return nil }
        if cid.hasPrefix("<") { cid.removeFirst() }
        if cid.hasSuffix(">") { cid.removeLast() }
        return cid.lowercased()
    }

    var isAttachment: Bool {
        disposition == "attachment" || (disposition != "inline" && filename != nil && !mimeType.hasPrefix("text/"))
    }

    var decodedBody: [UInt8] {
        switch (headers["Content-Transfer-Encoding"] ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64": return MIME.decodeBase64(rawBody)
        case "quoted-printable": return MIME.decodeQuotedPrintable(rawBody)
        default: return Array(rawBody)
        }
    }

    var textContent: String {
        var charset = params["charset"]
        let bytes = decodedBody
        if charset == nil && mimeType == "text/html" {
            charset = HTMLText.metaCharset(in: bytes)
        }
        return MIME.string(from: bytes, charset: charset)
    }

    static func split(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let delim = Array(("--" + boundary).utf8)
        var parts: [ArraySlice<UInt8>] = []
        var partStart: Int?
        var i = body.startIndex
        var atLineStart = true

        func matches(at idx: Int) -> Bool {
            guard idx + delim.count <= body.endIndex else { return false }
            for k in 0..<delim.count where body[idx + k] != delim[k] { return false }
            let after = idx + delim.count
            if after == body.endIndex { return true }
            let c = body[after]
            return c == 13 || c == 10 || c == 45 || c == 32 || c == 9
        }

        while i < body.endIndex {
            if atLineStart && body[i] == 45 && matches(at: i) {
                let after = i + delim.count
                let closing = after + 1 < body.endIndex && body[after] == 45 && body[after + 1] == 45
                if let ps = partStart {
                    var end = i
                    if end > ps && body[end - 1] == 10 { end -= 1 }
                    if end > ps && body[end - 1] == 13 { end -= 1 }
                    parts.append(body[ps..<max(ps, end)])
                }
                if closing { return parts }
                var j = after
                while j < body.endIndex && body[j] != 10 { j += 1 }
                partStart = min(j + 1, body.endIndex)
                i = j + 1
                atLineStart = true
                continue
            }
            atLineStart = body[i] == 10
            i += 1
        }
        if let ps = partStart, ps < body.endIndex { parts.append(body[ps..<body.endIndex]) }
        return parts
    }
}

// MARK: - HTML helpers

enum HTMLText {
    private static let dropBlocks = try! NSRegularExpression(pattern: "<(style|script|head|title)[^>]*>[\\s\\S]*?</\\1\\s*>", options: [.caseInsensitive])
    private static let breaks = try! NSRegularExpression(pattern: "<(br|/p|/div|/tr|/li|/h[1-6]|/table)[^>]*>", options: [.caseInsensitive])
    private static let tags = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let comments = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->")
    private static let numeric = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
    private static let spaces = try! NSRegularExpression(pattern: "[ \\t\\u00A0]+")
    private static let blankLines = try! NSRegularExpression(pattern: "\\n\\s*\\n\\s*\\n+")
    private static let invisible: Set<Character> = ["\u{034F}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{00AD}", "\u{FEFF}", "\u{2060}", "\u{180E}"]

    static func plainText(_ html: String) -> String {
        var s = replace(comments, in: html, with: "")
        s = replace(dropBlocks, in: s, with: "")
        s = replace(breaks, in: s, with: "\n")
        s = replace(tags, in: s, with: "")
        s = decodeEntities(s)
        s = replace(spaces, in: s, with: " ")
        s = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        s = replace(blankLines, in: s, with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func squash(_ s: String) -> String {
        let cleaned = String(s.filter { !invisible.contains($0) && !$0.isNewline })
        return replace(spaces, in: cleaned, with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var s = input
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&zwnj;", ""), ("&zwj;", ""), ("&shy;", ""), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&ldquo;", "“"),
            ("&rdquo;", "”"), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&copy;", "©"),
            ("&reg;", "®"), ("&trade;", "™"), ("&euro;", "€"), ("&bull;", "•"), ("&middot;", "·"),
        ]
        for (k, v) in named { s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in numeric.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let isHex = m.range(at: 1).length > 0
            let digits = ns.substring(with: m.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                out.unicodeScalars.append(scalar)
            }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func metaCharset(in bytes: [UInt8]) -> String? {
        let head = String(decoding: bytes.prefix(2048), as: UTF8.self).lowercased()
        guard let r = head.range(of: "charset=") else { return nil }
        let rest = head[r.upperBound...].drop { $0 == "\"" || $0 == "'" }
        let cs = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return cs.isEmpty ? nil : String(cs)
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}
