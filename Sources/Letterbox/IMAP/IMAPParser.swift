import Foundation

/// A generic IMAP response token tree.
indirect enum IMAPValue {
    case atom(String)
    case string([UInt8])
    case list([IMAPValue])
    case null

    var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let b): return MIME.decodeHeaderBytes(b[...])
        default: return nil
        }
    }

    var bytes: [UInt8]? {
        switch self {
        case .string(let b): return b
        case .atom(let s): return Array(s.utf8)
        default: return nil
        }
    }

    var items: [IMAPValue] {
        if case .list(let l) = self { return l }
        return []
    }

    var isList: Bool {
        if case .list = self { return true }
        return false
    }

    var int: Int? { text.flatMap { Int($0) } }
}

struct IMAPParser {
    private let b: [UInt8]
    private var i = 0

    init(_ bytes: [UInt8]) { b = bytes }

    static func parse(_ bytes: [UInt8]) -> [IMAPValue] {
        var p = IMAPParser(bytes)
        var out: [IMAPValue] = []
        while let v = p.next() { out.append(v) }
        return out
    }

    private mutating func skipSpace() {
        while i < b.count, b[i] == 32 || b[i] == 13 || b[i] == 10 { i += 1 }
    }

    mutating func next() -> IMAPValue? {
        skipSpace()
        guard i < b.count else { return nil }
        switch b[i] {
        case 0x28: // (
            i += 1
            var items: [IMAPValue] = []
            while true {
                skipSpace()
                guard i < b.count else { break }
                if b[i] == 0x29 { i += 1; break }
                guard let v = next() else { break }
                items.append(v)
            }
            return .list(items)
        case 0x29: // stray )
            i += 1
            return next()
        case 0x22: // "
            i += 1
            var out: [UInt8] = []
            while i < b.count {
                let c = b[i]
                if c == 0x5C, i + 1 < b.count { out.append(b[i + 1]); i += 2; continue }
                if c == 0x22 { i += 1; break }
                out.append(c)
                i += 1
            }
            return .string(out)
        case 0x7B: // {n}
            var j = i + 1
            var n = 0
            while j < b.count, b[j] >= 0x30, b[j] <= 0x39 { n = n * 10 + Int(b[j] - 0x30); j += 1 }
            if j < b.count, b[j] == 0x2B { j += 1 }
            if j < b.count, b[j] == 0x7D { j += 1 }
            if j < b.count, b[j] == 13 { j += 1 }
            if j < b.count, b[j] == 10 { j += 1 }
            let end = min(b.count, j + n)
            let data = Array(b[j..<end])
            i = end
            return .string(data)
        default:
            let start = i
            var depth = 0
            while i < b.count {
                let c = b[i]
                if depth == 0 && (c == 32 || c == 0x28 || c == 0x29 || c == 13 || c == 10) { break }
                if c == 0x5B { depth += 1 } else if c == 0x5D { depth = max(0, depth - 1) }
                i += 1
            }
            if i == start { i += 1; return next() }
            let s = String(decoding: b[start..<i], as: UTF8.self)
            return s.uppercased() == "NIL" ? .null : .atom(s)
        }
    }
}

enum ModifiedUTF7 {
    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let end = s[i...].firstIndex(of: "-") {
                let inner = s[s.index(after: i)..<end]
                if inner.isEmpty {
                    out += "&"
                } else {
                    var b64 = inner.replacingOccurrences(of: ",", with: "/")
                    while b64.count % 4 != 0 { b64 += "=" }
                    if let d = Data(base64Encoded: b64), let decoded = String(data: d, encoding: .utf16BigEndian) {
                        out += decoded
                    }
                }
                i = s.index(after: end)
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }
}
