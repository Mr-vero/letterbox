import Foundation

struct MailAddress: Hashable, Codable {
    var name: String
    var email: String

    var display: String { name.isEmpty ? email : name }

    /// Parses a comma-separated list like `Jane <jane@x.com>, bob@y.com`.
    static func parseList(_ input: String) -> [MailAddress] {
        var out: [MailAddress] = []
        var cur = ""
        var inQuotes = false
        var inAngle = false
        for ch in input {
            if ch == "\"" { inQuotes.toggle() }
            if ch == "<" { inAngle = true }
            if ch == ">" { inAngle = false }
            if (ch == "," || ch == ";") && !inQuotes && !inAngle {
                if let a = parseSingle(cur) { out.append(a) }
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        if let a = parseSingle(cur) { out.append(a) }
        return out
    }

    static func parseSingle(_ raw: String) -> MailAddress? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let email = s[s.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces)
            let name = s[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
            return email.contains("@") ? MailAddress(name: EncodedWords.decode(name), email: email) : nil
        }
        return s.contains("@") ? MailAddress(name: "", email: s) : nil
    }
}

struct OutgoingAttachment: Identifiable, Hashable {
    let id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
}

struct OutgoingMessage {
    var from: MailAddress
    var to: [MailAddress]
    var cc: [MailAddress] = []
    var bcc: [MailAddress] = []
    var subject: String
    var body: String
    var inReplyTo: String?
    var references: String?
    var attachments: [OutgoingAttachment] = []

    var allRecipients: [String] { (to + cc + bcc).map(\.email) }
}

enum MessageBuilder {
    static func build(_ m: OutgoingMessage) -> (bytes: [UInt8], messageID: String) {
        let domain = m.from.email.split(separator: "@").last.map(String.init) ?? "letterbox.local"
        let messageID = "<\(UUID().uuidString.lowercased())@\(domain)>"
        var h: [String] = []
        h.append("Date: \(MailDate.rfc2822(Date()))")
        h.append("From: \(format(m.from))")
        if !m.to.isEmpty { h.append(addressHeader("To", m.to)) }
        if !m.cc.isEmpty { h.append(addressHeader("Cc", m.cc)) }
        h.append("Subject: \(encodeHeader(m.subject))")
        h.append("Message-ID: \(messageID)")
        if let r = m.inReplyTo, !r.isEmpty { h.append("In-Reply-To: \(r)") }
        if let r = m.references, !r.isEmpty { h.append("References: \(fold(r))") }
        h.append("MIME-Version: 1.0")
        h.append("X-Mailer: Letterbox for Mac")

        let textBody = normalize(m.body)
        var out = h.joined(separator: "\r\n") + "\r\n"

        if m.attachments.isEmpty {
            out += "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
            out += quotedPrintable(textBody)
        } else {
            let boundary = "=_lb_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            out += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
            out += "This is a multi-part message in MIME format.\r\n"
            out += "--\(boundary)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
            out += quotedPrintable(textBody) + "\r\n"
            for a in m.attachments {
                let name = encodeParam(a.filename)
                out += "--\(boundary)\r\n"
                out += "Content-Type: \(a.mimeType); name=\(name)\r\n"
                out += "Content-Disposition: attachment; filename=\(name)\r\n"
                out += "Content-Transfer-Encoding: base64\r\n\r\n"
                out += a.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
                out += "\r\n"
            }
            out += "--\(boundary)--\r\n"
        }
        return (Array(out.utf8), messageID)
    }

    static func format(_ a: MailAddress) -> String {
        guard !a.name.isEmpty else { return a.email }
        let name: String
        if a.name.unicodeScalars.allSatisfy({ $0.isASCII }) {
            let specials = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
            name = a.name.rangeOfCharacter(from: specials) != nil
                ? "\"\(a.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
                : a.name
        } else {
            name = encodeHeader(a.name)
        }
        return "\(name) <\(a.email)>"
    }

    private static func addressHeader(_ name: String, _ list: [MailAddress]) -> String {
        "\(name): " + list.map(format).joined(separator: ",\r\n ")
    }

    private static func fold(_ s: String) -> String {
        s.split(separator: " ").joined(separator: "\r\n ")
    }

    static func encodeHeader(_ s: String) -> String {
        guard !s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) else { return s }
        // Encode in chunks of whole characters, max ~45 bytes each, so lines stay short.
        var words: [String] = []
        var chunk = ""
        for ch in s {
            if (chunk + String(ch)).utf8.count > 45 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    private static func encodeParam(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return "\"\(s.replacingOccurrences(of: "\"", with: "'"))\""
        }
        return "\"\(encodeHeader(s).replacingOccurrences(of: "\r\n ", with: " "))\""
    }

    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func quotedPrintable(_ text: String) -> String {
        var out = ""
        let hex = Array("0123456789ABCDEF")
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { out += "\r\n" }
            let bytes = Array(line.utf8)
            var lineLen = 0
            for (i, b) in bytes.enumerated() {
                let isLast = i == bytes.count - 1
                var token: String
                if (b >= 33 && b <= 126 && b != 61) || ((b == 32 || b == 9) && !isLast) {
                    token = String(UnicodeScalar(b))
                } else {
                    token = "=" + String(hex[Int(b >> 4)]) + String(hex[Int(b & 0xF)])
                }
                // Dot at line start is safe for SMTP (we dot-stuff), but avoid "From " munging.
                if lineLen == 0 && token == "." { token = "=2E" }
                if lineLen + token.count > 75 {
                    out += "=\r\n"
                    lineLen = 0
                }
                out += token
                lineLen += token.count
            }
        }
        return out
    }
}
