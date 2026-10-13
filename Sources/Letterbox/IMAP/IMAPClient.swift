import Foundation

struct IMAPError: LocalizedError {
    let message: String
    var isAuthFailure = false
    var errorDescription: String? { message }
}

struct RemoteFolder {
    let path: String
    let delimiter: String?
    let attributes: Set<String> // lowercased, e.g. "\\sent"
}

struct SelectInfo {
    var exists = 0
    var uidValidity: UInt32 = 0
    var uidNext: UInt32 = 0
}

struct FetchedSummary {
    var uid: UInt32 = 0
    var flags: Set<String> = []
    var date = Date()
    var size = 0
    var subject = ""
    var from: [MailAddress] = []
    var to: [MailAddress] = []
    var cc: [MailAddress] = []
    var replyTo: [MailAddress] = []
    var messageID: String?
    var inReplyTo: String?
    var references: String?
    var deliveredTo: [String] = []
    var hasAttachments = false
}

/// A single authenticated IMAP connection. All public calls are serialized and
/// transparently reconnect once if the socket has gone stale.
final class IMAPClient: @unchecked Sendable {
    let host: String
    let port: UInt16
    let security: ConnectionSecurity
    private let username: String
    private let password: String

    private var stream: MailSocket?
    private var tagCounter = 0
    private(set) var capabilities: Set<String> = []
    private var selected: String?
    private let mutex = AsyncMutex()

    init(host: String, port: UInt16, security: ConnectionSecurity = .tls, username: String, password: String) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
        self.password = password
    }

    // MARK: Session

    func connect() async throws {
        try await serialized { if self.stream == nil { try await self.openSession() } }
    }

    func disconnect() async {
        await mutex.lock()
        if stream != nil { _ = try? await execute([.text("LOGOUT")]) }
        teardown()
        await mutex.unlock()
    }

    private func serialized<T>(_ body: () async throws -> T) async throws -> T {
        await mutex.lock()
        let result: Result<T, Error>
        do { result = .success(try await attempt(body)) } catch { result = .failure(error) }
        await mutex.unlock()
        return try result.get()
    }

    private func attempt<T>(_ body: () async throws -> T) async throws -> T {
        if stream == nil { try await openSession() }
        do {
            return try await body()
        } catch let error as IMAPError {
            throw error
        } catch {
            teardown()
            try await openSession()
            return try await body()
        }
    }

    private func teardown() {
        stream?.close()
        stream = nil
        selected = nil
    }

    private func openSession() async throws {
        let s = MailSocket(host: host, port: port)
        try await s.open(tls: security == .tls)
        stream = s
        tagCounter = 0
        let greeting = String(decoding: try await readResponse(), as: UTF8.self)
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else {
            teardown()
            throw IMAPError(message: "Unexpected server greeting: \(greeting)")
        }
        if security == .startTLS {
            _ = try await execute([.text("STARTTLS")])
            try await s.startTLS()
        }
        let preauth = try await execute([.text("CAPABILITY")])
        let loginDisabled = preauth.contains { String(decoding: $0, as: UTF8.self).uppercased().contains("LOGINDISABLED") }
        do {
            if loginDisabled {
                let token = Data(([0] + Array(username.utf8) + [0] + Array(password.utf8))).base64EncodedString()
                _ = try await execute([.text("AUTHENTICATE PLAIN \(token)")])
            } else {
                _ = try await execute([.text("LOGIN "), astring(username), .text(" "), astring(password)])
            }
        } catch let e as IMAPError {
            teardown()
            throw IMAPError(message: e.message, isAuthFailure: true)
        }
        let caps = try await execute([.text("CAPABILITY")])
        capabilities = []
        for line in caps {
            let s = String(decoding: line, as: UTF8.self)
            guard s.uppercased().hasPrefix("* CAPABILITY") else { continue }
            s.split(separator: " ").dropFirst(2).forEach { capabilities.insert($0.uppercased()) }
        }
    }

    // MARK: Commands

    func listFolders() async throws -> [RemoteFolder] {
        try await serialized {
            let cmd = self.capabilities.contains("SPECIAL-USE") ? "LIST \"\" \"*\" RETURN (SPECIAL-USE)" : "LIST \"\" \"*\""
            let lines = try await self.execute([.text(cmd)])
            var folders: [RemoteFolder] = []
            for line in lines {
                let v = IMAPParser.parse(line)
                guard v.count >= 5, v[1].text?.uppercased() == "LIST" else { continue }
                let attrs = Set(v[2].items.compactMap { $0.text?.lowercased() })
                guard let path = v[4].text else { continue }
                folders.append(RemoteFolder(path: path, delimiter: v[3].text, attributes: attrs))
            }
            return folders
        }
    }

    func status(_ path: String) async throws -> (messages: Int, unseen: Int) {
        try await serialized {
            let lines = try await self.execute([.text("STATUS "), self.quoted(path), .text(" (MESSAGES UNSEEN)")])
            var messages = 0, unseen = 0
            for line in lines {
                let v = IMAPParser.parse(line)
                guard v.count >= 4, v[1].text?.uppercased() == "STATUS" else { continue }
                let items = v[3].items
                var k = 0
                while k + 1 < items.count {
                    switch items[k].text?.uppercased() {
                    case "MESSAGES": messages = items[k + 1].int ?? 0
                    case "UNSEEN": unseen = items[k + 1].int ?? 0
                    default: break
                    }
                    k += 2
                }
            }
            return (messages, unseen)
        }
    }

    func select(_ path: String) async throws -> SelectInfo {
        try await serialized { try await self.selectLocked(path) }
    }

    private func selectLocked(_ path: String) async throws -> SelectInfo {
        selected = nil
        let lines = try await execute([.text("SELECT "), quoted(path)])
        selected = path
        var info = SelectInfo()
        for line in lines {
            let s = String(decoding: line, as: UTF8.self)
            let parts = s.split(separator: " ")
            if parts.count >= 3, parts[2].uppercased() == "EXISTS" { info.exists = Int(parts[1]) ?? 0 }
            if let n = Self.code("UIDVALIDITY", in: s) { info.uidValidity = n }
            if let n = Self.code("UIDNEXT", in: s) { info.uidNext = n }
        }
        return info
    }

    private func ensureSelected(_ path: String) async throws {
        if selected != path { _ = try await selectLocked(path) }
    }

    private static func code(_ name: String, in s: String) -> UInt32? {
        guard let r = s.range(of: "[\(name) ") else { return nil }
        return UInt32(s[r.upperBound...].prefix { $0.isNumber })
    }

    private static let summaryItems =
        "(UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (DELIVERED-TO X-ORIGINAL-TO ENVELOPE-TO X-ENVELOPE-TO X-DELIVERED-TO X-RCPT-TO REFERENCES)])"

    /// Fetches summaries by sequence-number range (`byUID == false`) or UID set.
    func fetchSummaries(in path: String, set: String, byUID: Bool) async throws -> [FetchedSummary] {
        try await serialized {
            try await self.ensureSelected(path)
            let lines = try await self.execute([.text("\(byUID ? "UID " : "")FETCH \(set) \(Self.summaryItems)")])
            return lines.compactMap(Self.parseSummary)
        }
    }

    func fetchFlags(in path: String, uidSet: String) async throws -> [UInt32: Set<String>] {
        try await serialized {
            try await self.ensureSelected(path)
            let lines = try await self.execute([.text("UID FETCH \(uidSet) (UID FLAGS)")])
            var out: [UInt32: Set<String>] = [:]
            for line in lines {
                guard let d = Self.fetchDict(line), let uid = d["UID"]?.int else { continue }
                out[UInt32(uid)] = Set(d["FLAGS"]?.items.compactMap { $0.text?.lowercased() } ?? [])
            }
            return out
        }
    }

    func searchUIDs(in path: String, criteria: String) async throws -> [UInt32] {
        try await serialized {
            try await self.ensureSelected(path)
            let lines = try await self.execute([.text("UID SEARCH \(criteria)")])
            var uids: [UInt32] = []
            for line in lines {
                let s = String(decoding: line, as: UTF8.self)
                guard s.uppercased().hasPrefix("* SEARCH") else { continue }
                uids += s.split(separator: " ").dropFirst(2).compactMap { UInt32($0) }
            }
            return uids
        }
    }

    func fetchBodies(in path: String, uids: [UInt32]) async throws -> [UInt32: [UInt8]] {
        guard !uids.isEmpty else { return [:] }
        return try await serialized {
            try await self.ensureSelected(path)
            let lines = try await self.execute([.text("UID FETCH \(Self.uidSet(uids)) (UID BODY.PEEK[])")])
            var out: [UInt32: [UInt8]] = [:]
            for line in lines {
                guard let d = Self.fetchDict(line), let uid = d["UID"]?.int, let body = d["BODY[]"]?.bytes else { continue }
                out[UInt32(uid)] = body
            }
            return out
        }
    }

    func store(in path: String, uids: [UInt32], flag: String, add: Bool) async throws {
        guard !uids.isEmpty else { return }
        try await serialized {
            try await self.ensureSelected(path)
            _ = try await self.execute([.text("UID STORE \(Self.uidSet(uids)) \(add ? "+" : "-")FLAGS.SILENT (\(flag))")])
        }
    }

    func move(in path: String, uids: [UInt32], to destination: String) async throws {
        guard !uids.isEmpty else { return }
        try await serialized {
            try await self.ensureSelected(path)
            let set = Self.uidSet(uids)
            if self.capabilities.contains("MOVE") {
                _ = try await self.execute([.text("UID MOVE \(set) "), self.quoted(destination)])
            } else {
                _ = try await self.execute([.text("UID COPY \(set) "), self.quoted(destination)])
                try await self.expungeLocked(set)
            }
        }
    }

    func deletePermanently(in path: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await serialized {
            try await self.ensureSelected(path)
            try await self.expungeLocked(Self.uidSet(uids))
        }
    }

    private func expungeLocked(_ set: String) async throws {
        _ = try await execute([.text("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")])
        if capabilities.contains("UIDPLUS") {
            _ = try await execute([.text("UID EXPUNGE \(set)")])
        } else {
            _ = try await execute([.text("EXPUNGE")])
        }
    }

    func append(to path: String, message: [UInt8], flags: [String]) async throws {
        try await serialized {
            _ = try await self.execute([.text("APPEND "), self.quoted(path), .text(" (\(flags.joined(separator: " "))) "), .literal(message)])
        }
    }

    func create(_ path: String) async throws {
        try await serialized { _ = try await self.execute([.text("CREATE "), self.quoted(path)]) }
    }

    func noop() async throws {
        try await serialized { _ = try await self.execute([.text("NOOP")]) }
    }

    // MARK: Wire protocol

    private enum Part {
        case text(String)
        case literal([UInt8])
    }

    private func quoted(_ s: String) -> Part {
        .text("\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"")
    }

    private func astring(_ s: String) -> Part {
        if s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) { return quoted(s) }
        return .literal(Array(s.utf8))
    }

    private func execute(_ parts: [Part]) async throws -> [[UInt8]] {
        guard let stream else { throw NetError.closed }
        tagCounter += 1
        let tag = "L\(tagCounter)"
        let tagPrefix = Array((tag + " ").utf8)
        var untagged: [[UInt8]] = []
        var line = tagPrefix

        for part in parts {
            switch part {
            case .text(let s):
                line += Array(s.utf8)
            case .literal(let data):
                line += Array("{\(data.count)}\r\n".utf8)
                try await stream.send(line)
                while true {
                    let resp = try await readResponse()
                    if resp.first == 0x2B { break }
                    if resp.starts(with: tagPrefix) {
                        throw IMAPError(message: Self.serverMessage(resp, dropping: tagPrefix.count))
                    }
                    untagged.append(resp)
                }
                line = data
            }
        }
        line += [13, 10]
        try await stream.send(line)

        while true {
            let resp = try await readResponse()
            if resp.starts(with: tagPrefix) {
                let rest = String(decoding: resp[tagPrefix.count...], as: UTF8.self)
                if rest.uppercased().hasPrefix("OK") { return untagged }
                throw IMAPError(message: Self.serverMessage(resp, dropping: tagPrefix.count))
            }
            if resp.first == 0x2A {
                if resp.starts(with: Array("* BYE".utf8)) { teardownAfterBye() }
                untagged.append(resp)
            }
        }
    }

    private func teardownAfterBye() {
        // The server will close the socket; the next read will fail and trigger a reconnect.
    }

    private static func serverMessage(_ resp: [UInt8], dropping n: Int) -> String {
        var s = String(decoding: resp.dropFirst(n), as: UTF8.self)
        for prefix in ["NO ", "BAD ", "no ", "bad "] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            s = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? "The server rejected the request." : s
    }

    private func readResponse() async throws -> [UInt8] {
        guard let stream else { throw NetError.closed }
        var out: [UInt8] = []
        while true {
            let line = try await stream.readLine()
            out += line
            if let n = Self.trailingLiteral(line) {
                out += [13, 10]
                out += try await stream.readBytes(n)
                continue
            }
            return out
        }
    }

    private static func trailingLiteral(_ line: [UInt8]) -> Int? {
        guard line.last == 0x7D else { return nil }
        var j = line.count - 2
        if j >= 0 && line[j] == 0x2B { j -= 1 }
        var value = 0, mult = 1, digits = 0
        while j >= 0, line[j] >= 0x30, line[j] <= 0x39 {
            value += Int(line[j] - 0x30) * mult
            mult *= 10
            digits += 1
            j -= 1
        }
        guard digits > 0, j >= 0, line[j] == 0x7B else { return nil }
        return value
    }

    // MARK: Parsing

    static func uidSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var ranges: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1] == sorted[j] + 1 { j += 1 }
            ranges.append(i == j ? "\(sorted[i])" : "\(sorted[i]):\(sorted[j])")
            i = j + 1
        }
        return ranges.joined(separator: ",")
    }

    private static func fetchDict(_ line: [UInt8]) -> [String: IMAPValue]? {
        let v = IMAPParser.parse(line)
        guard v.count >= 4, v[2].text?.uppercased() == "FETCH" else { return nil }
        let items = v[3].items
        var dict: [String: IMAPValue] = [:]
        var k = 0
        while k + 1 < items.count {
            let key = items[k].text?.uppercased() ?? ""
            dict[key.hasPrefix("BODY[HEADER") ? "HEADERFIELDS" : key] = items[k + 1]
            k += 2
        }
        return dict
    }

    private static func parseSummary(_ line: [UInt8]) -> FetchedSummary? {
        guard let d = fetchDict(line), let uid = d["UID"]?.int else { return nil }
        var s = FetchedSummary()
        s.uid = UInt32(uid)
        s.flags = Set(d["FLAGS"]?.items.compactMap { $0.text?.lowercased() } ?? [])
        s.size = d["RFC822.SIZE"]?.int ?? 0

        let env = d["ENVELOPE"]?.items ?? []
        func field(_ i: Int) -> IMAPValue { i < env.count ? env[i] : .null }
        let envDate = field(0).text.flatMap(MailDate.parseRFC2822)
        let received = d["INTERNALDATE"]?.text.flatMap(MailDate.parseInternal)
        s.date = received ?? envDate ?? Date()
        s.subject = field(1).text.map(EncodedWords.decode) ?? ""
        s.from = addresses(field(2))
        s.replyTo = addresses(field(4))
        s.to = addresses(field(5))
        s.cc = addresses(field(6))
        s.inReplyTo = field(8).text
        s.messageID = field(9).text

        if let raw = d["HEADERFIELDS"]?.bytes {
            let headers = MIME.parseHeaders(raw[...])
            s.references = headers["References"]
            for name in ["Delivered-To", "X-Original-To", "Envelope-To", "X-Envelope-To", "X-Delivered-To", "X-Rcpt-To"] {
                for value in headers.all(name) {
                    s.deliveredTo += MailAddress.parseList(value).map { $0.email.lowercased() }
                }
            }
        }
        if let bs = d["BODYSTRUCTURE"] { s.hasAttachments = hasAttachment(bs) }
        return s
    }

    private static func addresses(_ v: IMAPValue) -> [MailAddress] {
        v.items.compactMap { a in
            let f = a.items
            guard f.count >= 4, let mailbox = f[2].text, let host = f[3].text else { return nil }
            let name = f[0].text.map(EncodedWords.decode) ?? ""
            return MailAddress(name: name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")), email: "\(mailbox)@\(host)")
        }
    }

    private static func hasAttachment(_ v: IMAPValue) -> Bool {
        let items = v.items
        guard let first = items.first else { return false }
        if first.isList {
            return items.contains { $0.isList && $0.items.first.map { $0.isList || $0.text != nil } == true && hasAttachment($0) }
        }
        let type = first.text?.lowercased() ?? ""
        let subtype = items.count > 1 ? items[1].text?.lowercased() ?? "" : ""
        for item in items where item.isList {
            if item.items.first?.text?.lowercased() == "attachment" { return true }
        }
        if type == "application" && !subtype.contains("signature") { return true }
        return false
    }
}
