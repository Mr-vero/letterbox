import Foundation

struct TimelineEvent: Codable, Hashable {
    var date: String      // YYYY-MM-DD
    var text: String
    var upcoming: Bool

    var day: Date? { TimelineEvent.parse(date) }

    static func parse(_ s: String) -> Date? {
        guard s.count >= 10 else { return nil }
        return isoDay.date(from: String(s.prefix(10)))
    }

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// A thread of related messages across Inbox, Sent and Archive.
struct Conversation: Identifiable, Hashable {
    let id: String
    var messages: [MessageSummary]      // oldest → newest
    var fromMe: Set<String>             // message ids written by the user

    var latest: MessageSummary { messages[messages.count - 1] }
    var subject: String { messages.first { !$0.subject.isEmpty }?.displaySubject ?? latest.displaySubject }
    var lastFromMe: Bool { fromMe.contains(latest.id) }
    var latestIncoming: MessageSummary? { messages.last { !fromMe.contains($0.id) } }
    var myLastReply: Date? { messages.last { fromMe.contains($0.id) }?.date }
    var hasIncoming: Bool { messages.contains { !fromMe.contains($0.id) } }
    var unread: Bool { messages.contains { !$0.seen && !fromMe.contains($0.id) } }
    var count: Int { messages.count }

    /// The person on the other side.
    var counterpart: MailAddress {
        if let m = latestIncoming { return m.sender }
        return latest.to.first ?? latest.sender
    }

    /// True when the user replied after the most recent incoming message.
    var repliedAfterLatestIncoming: Bool {
        guard let incoming = latestIncoming, let mine = myLastReply else { return false }
        return mine > incoming.date
    }

    func isFromMe(_ m: MessageSummary) -> Bool { fromMe.contains(m.id) }
}

enum ThreadBuilder {
    private static let prefix = try! NSRegularExpression(pattern: "^\\s*((re|aw|sv|fw|fwd|wg|tr)\\s*(\\[\\d+\\])?\\s*:\\s*)+", options: .caseInsensitive)

    static func normalizedSubject(_ s: String) -> String {
        let ns = s as NSString
        let stripped = prefix.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func isReplyish(_ s: String) -> Bool {
        let ns = s as NSString
        return prefix.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
    }

    static func ids(in header: String?) -> [String] {
        guard let header, !header.isEmpty else { return [] }
        var out: [String] = []
        var cur = ""
        var inside = false
        for ch in header {
            if ch == "<" { inside = true; cur = "" }
            else if ch == ">" { if inside && !cur.isEmpty { out.append(cur.lowercased()) }; inside = false }
            else if inside { cur.append(ch) }
        }
        if out.isEmpty, header.contains("@") { out = [header.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased()] }
        return out
    }

    static func build(_ all: [MessageSummary], me: Set<String>, sentFolder: String?) -> [Conversation] {
        // De-duplicate copies of the same message living in two folders (prefer non-sent, then newest uid).
        var seen: [String: Int] = [:]
        var msgs: [MessageSummary] = []
        for m in all {
            let key = ids(in: m.messageID).first ?? m.id
            if let i = seen[key] {
                if msgs[i].folder == sentFolder && m.folder != sentFolder { msgs[i] = m }
                continue
            }
            seen[key] = msgs.count
            msgs.append(m)
        }

        var parent = Array(0..<msgs.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        var byID: [String: Int] = [:]
        for (i, m) in msgs.enumerated() {
            for id in ids(in: m.messageID) { byID[id] = i }
        }
        // Header links: references of unknown messages still join siblings that cite them.
        var phantom: [String: Int] = [:]
        for (i, m) in msgs.enumerated() {
            for ref in ids(in: m.inReplyTo) + ids(in: m.references) {
                if let j = byID[ref] { union(i, j) }
                else if let j = phantom[ref] { union(i, j) }
                else { phantom[ref] = i }
            }
        }

        // Subject fallback for replies that lost their headers.
        let order = msgs.indices.sorted { msgs[$0].date < msgs[$1].date }
        var lastBySubject: [String: Int] = [:]
        for i in order {
            let m = msgs[i]
            let subject = normalizedSubject(m.subject)
            guard subject.count >= 4 else { continue }
            if isReplyish(m.subject), let j = lastBySubject[subject], find(i) != find(j),
               m.date.timeIntervalSince(msgs[j].date) < 45 * 86400 {
                let a = Set(([m.sender] + m.to + m.cc).map { $0.email.lowercased() })
                let b = Set(([msgs[j].sender] + msgs[j].to + msgs[j].cc).map { $0.email.lowercased() })
                if !a.intersection(b).subtracting(me).isEmpty || a.intersection(b).count >= 2 { union(i, j) }
            }
            lastBySubject[subject] = i
        }

        var groups: [Int: [MessageSummary]] = [:]
        for i in msgs.indices { groups[find(i), default: []].append(msgs[i]) }

        return groups.values.map { list in
            let sorted = list.sorted { $0.date < $1.date }
            let first = sorted[0]
            let key = ids(in: first.messageID).first ?? first.id
            let mine = Set(sorted.filter { $0.folder == sentFolder || me.contains($0.fromEmail.lowercased()) }.map(\.id))
            return Conversation(id: key, messages: sorted, fromMe: mine)
        }
        .sorted { $0.latest.date > $1.latest.date }
    }

    /// Removes quoted history so Claude sees only what each message added.
    static func newContent(_ text: String) -> String {
        var out: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") { continue }
            if t.hasPrefix("-----Original Message") || t.hasPrefix("---------- Forwarded") || t.hasPrefix("________________") { break }
            if (t.hasPrefix("On ") && t.hasSuffix("wrote:")) || (t.hasPrefix("Am ") && t.hasSuffix("schrieb:")) { break }
            if t.hasPrefix("From:") && out.count > 3 { break }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
