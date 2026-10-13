import Foundation

struct MIMEHeaders {
    var fields: [(name: String, value: String)] = []

    subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func all(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    func decoded(_ name: String) -> String? {
        self[name].map(EncodedWords.decode)
    }
}

enum MIME {
    // MARK: Headers

    static func parseHeaders(_ bytes: ArraySlice<UInt8>) -> MIMEHeaders {
        var headers = MIMEHeaders()
        var current: (String, String)?
        var lineStart = bytes.startIndex
        var i = bytes.startIndex

        func flush(_ line: ArraySlice<UInt8>) {
            var l = line
            if l.last == 13 { l = l.dropLast() }
            guard !l.isEmpty else { return }
            let text = decodeHeaderBytes(l)
            if l.first == 32 || l.first == 9 {
                if current != nil {
                    current!.1 += " " + text.trimmingCharacters(in: .whitespaces)
                }
                return
            }
            if let c = current { headers.fields.append(c) }
            if let colon = text.firstIndex(of: ":") {
                let name = text[..<colon].trimmingCharacters(in: .whitespaces)
                let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                current = (name, value)
            } else {
                current = nil
            }
        }

        while i < bytes.endIndex {
            if bytes[i] == 10 {
                flush(bytes[lineStart..<i])
                lineStart = i + 1
            }
            i += 1
        }
        if lineStart < bytes.endIndex { flush(bytes[lineStart..<bytes.endIndex]) }
        if let c = current { headers.fields.append(c) }
        return headers
    }

    static func decodeHeaderBytes(_ bytes: ArraySlice<UInt8>) -> String {
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        return String(bytes: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Returns (headerRange end, body start) for the first blank line.
    static func headerBoundary(_ b: ArraySlice<UInt8>) -> (Int, Int)? {
        let s = b.startIndex
        if b.starts(with: [13, 10]) { return (s, s + 2) }
        if b.first == 10 { return (s, s + 1) }
        var i = s
        while i < b.endIndex {
            if b[i] == 10 {
                let n = i + 1
                if n < b.endIndex && b[n] == 10 { return (i, n + 1) }
                if n + 1 < b.endIndex && b[n] == 13 && b[n + 1] == 10 { return (i, n + 2) }
            }
            i += 1
        }
        return nil
    }

    // MARK: Parameterized values (Content-Type, Content-Disposition)

    static func parseParameterized(_ s: String) -> (value: String, params: [String: String]) {
        var parts: [String] = []
        var cur = ""
        var inQuotes = false
        var escaped = false
        for ch in s {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" && inQuotes { escaped = true; continue }
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch == ";" && !inQuotes { parts.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        parts.append(cur)

        let value = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var params: [String: String] = [:]
        var extended: [String: [(Int, String, Bool)]] = [:]

        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key.contains("*") {
                let comps = key.split(separator: "*", omittingEmptySubsequences: false)
                let base = String(comps[0])
                let encoded = key.hasSuffix("*")
                let index = comps.count > 1 ? Int(comps[1]) ?? 0 : 0
                extended[base, default: []].append((index, val, encoded))
            } else {
                params[key] = EncodedWords.decode(val)
            }
        }

        for (base, segments) in extended {
            var charset = "utf-8"
            var bytes: [UInt8] = []
            for (n, seg) in segments.sorted(by: { $0.0 < $1.0 }).enumerated() {
                var text = seg.1
                if seg.2 {
                    if n == 0, let first = text.firstIndex(of: "'"),
                       let second = text[text.index(after: first)...].firstIndex(of: "'") {
                        charset = String(text[..<first])
                        text = String(text[text.index(after: second)...])
                    }
                    bytes += percentDecode(text)
                } else {
                    bytes += Array(text.utf8)
                }
            }
            params[base] = string(from: bytes, charset: charset)
        }
        return (value, params)
    }

    private static func percentDecode(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        while i < u.count {
            if u[i] == 37, i + 2 < u.count, let h = hex(u[i + 1]), let l = hex(u[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else {
                out.append(u[i])
                i += 1
            }
        }
        return out
    }

    // MARK: Transfer encodings

    static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }

    static func decodeQuotedPrintable<C: Collection>(_ b: C) -> [UInt8] where C.Element == UInt8 {
        let bytes = Array(b)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if c == 61 { // '='
                if i + 1 < bytes.count && bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count && bytes[i + 1] == 13 && bytes[i + 2] == 10 { i += 3; continue }
                if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                    out.append(h << 4 | l)
                    i += 3
                    continue
                }
                // Lenient: "=" followed by trailing whitespace then a line break is a soft break.
                var j = i + 1
                while j < bytes.count && (bytes[j] == 32 || bytes[j] == 9) { j += 1 }
                if j < bytes.count && (bytes[j] == 13 || bytes[j] == 10) {
                    i = j + (bytes[j] == 13 && j + 1 < bytes.count && bytes[j + 1] == 10 ? 2 : 1)
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private static let base64Table: [UInt8] = {
        var t = [UInt8](repeating: 255, count: 256)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        for (i, c) in alphabet.enumerated() { t[Int(c)] = UInt8(i) }
        t[Int(UInt8(ascii: "-"))] = 62
        t[Int(UInt8(ascii: "_"))] = 63
        return t
    }()

    static func decodeBase64<C: Collection>(_ b: C) -> [UInt8] where C.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(b.count * 3 / 4)
        var acc: UInt32 = 0
        var bits = 0
        for c in b {
            if c == 61 { break } // '=' padding
            let v = base64Table[Int(c)]
            if v == 255 { continue }
            acc = (acc << 6) | UInt32(v)
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> UInt32(bits)) & 0xFF))
            }
        }
        return out
    }

    // MARK: Charsets

    static func encoding(for charset: String) -> String.Encoding {
        let cs = charset.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        switch cs {
        case "", "utf-8", "utf8", "us-ascii", "ascii", "unicode-1-1-utf-8": return .utf8
        case "iso-8859-1", "latin1", "latin-1", "windows-1252", "cp1252": return .windowsCP1252
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if cf != kCFStringEncodingInvalidId {
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            }
            return .utf8
        }
    }

    static func string<C: Collection>(from bytes: C, charset: String?) -> String where C.Element == UInt8 {
        let data = Data(bytes)
        let enc = encoding(for: charset ?? "utf-8")
        if let s = String(data: data, encoding: enc) { return s }
        if enc != .utf8, let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }
}

// MARK: - RFC 2047 encoded words

enum EncodedWords {
    private static let regex = try! NSRegularExpression(pattern: "=\\?([^?\\s]+)\\?([bBqQ])\\?([^?]*)\\?=")

    static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var out = ""
        var cursor = 0
        var pendingBytes: [UInt8] = []
        var pendingCharset: String?

        func flushPending() {
            if let cs = pendingCharset {
                out += MIME.string(from: pendingBytes, charset: cs)
            }
            pendingBytes = []
            pendingCharset = nil
        }

        for m in matches {
            let gap = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let gapIsWhitespace = gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            var charset = ns.substring(with: m.range(at: 1))
            if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) }
            let mode = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))

            if !(pendingCharset != nil && gapIsWhitespace) {
                flushPending()
                out += gap
            } else if pendingCharset?.lowercased() != charset.lowercased() {
                flushPending()
            }

            let bytes: [UInt8]
            if mode == "B" {
                bytes = MIME.decodeBase64(Array(text.utf8))
            } else {
                let underscored = Array(text.utf8).map { $0 == 95 ? 32 : $0 }
                bytes = MIME.decodeQuotedPrintable(underscored)
            }
            pendingCharset = charset
            pendingBytes += bytes
            cursor = m.range.location + m.range.length
        }
        flushPending()
        out += ns.substring(from: cursor)
        return out
    }
}
