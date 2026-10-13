import Foundation

struct MessageQuery {
    var item: SidebarItem
    var search: String = ""
    var unreadOnly = false
    var excludedFolders: [String] = []
    var limit = 2500
}

/// Typed access to the cache. Reads go through the reader handle, writes through the writer.
final class MailRepository: @unchecked Sendable {
    let db: Database

    init(db: Database) { self.db = db }

    static let messageColumns = """
    folder, uid, message_id, subject, from_name, from_addr, to_list, cc_list, reply_to, delivered_to,
    date, seen, flagged, answered, size, has_att, snippet, in_reply_to, refs
    """

    static func message(_ r: SQLRow) -> MessageSummary {
        MessageSummary(
            folder: r.text(0), uid: UInt32(r.int(1)), messageID: r.text(2), subject: r.text(3),
            fromName: r.text(4), fromEmail: r.text(5),
            to: AddressCoding.decode(r.text(6)), cc: AddressCoding.decode(r.text(7)), replyTo: AddressCoding.decode(r.text(8)),
            deliveredTo: r.text(9).split(separator: " ").map(String.init),
            date: Date(timeIntervalSince1970: r.double(10)),
            seen: r.bool(11), flagged: r.bool(12), answered: r.bool(13), size: r.int(14), hasAttachments: r.bool(15),
            snippet: r.text(16), inReplyTo: r.text(17), references: r.text(18))
    }

    // MARK: Folders

    func folders() -> [Folder] {
        db.reader.query("SELECT path, name, delimiter, role, total, unread FROM folders WHERE selectable = 1") { r in
            Folder(path: r.text(0), name: r.text(1), delimiter: r.text(2), role: FolderRole(rawValue: r.text(3)) ?? .custom,
                   total: r.int(4), unread: r.int(5))
        }
        .sorted { ($0.role.order, $0.displayName.lowercased()) < ($1.role.order, $1.displayName.lowercased()) }
    }

    func replaceFolders(_ remote: [RemoteFolder]) {
        db.writer.transaction {
            let paths = Set(remote.map(\.path))
            let existing = db.writer.query("SELECT path FROM folders") { $0.text(0) }
            for gone in existing where !paths.contains(gone) {
                db.writer.run("DELETE FROM folders WHERE path = ?", [.text(gone)])
                db.writer.run("DELETE FROM messages WHERE folder = ?", [.text(gone)])
                db.writer.run("DELETE FROM bodies WHERE folder = ?", [.text(gone)])
            }
            for f in remote {
                let virtual = f.attributes.contains("\\flagged") || f.attributes.contains("\\important")
                let selectable = !virtual && !f.attributes.contains("\\noselect") && !f.attributes.contains("\\nonexistent")
                var name = ModifiedUTF7.decode(f.path)
                if let d = f.delimiter, !d.isEmpty {
                    name = name.components(separatedBy: d).joined(separator: " / ")
                }
                db.writer.run("""
                INSERT INTO folders(path, name, delimiter, role, selectable) VALUES(?,?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET name=excluded.name, delimiter=excluded.delimiter, role=excluded.role, selectable=excluded.selectable
                """, [.text(f.path), .text(name), .of(f.delimiter), .text(FolderRole.detect(path: f.path, attributes: f.attributes).rawValue), .of(selectable)])
            }
        }
    }

    func folderState(_ path: String) -> (uidValidity: UInt32, uidNext: UInt32) {
        db.writer.query("SELECT uidvalidity, uidnext FROM folders WHERE path = ?", [.text(path)]) {
            (UInt32($0.int(0)), UInt32($0.int(1)))
        }.first ?? (0, 0)
    }

    func updateFolderState(_ path: String, uidValidity: UInt32, uidNext: UInt32, total: Int) {
        db.writer.run("UPDATE folders SET uidvalidity = ?, uidnext = ?, total = ? WHERE path = ?",
                      [.of(uidValidity), .of(uidNext), .of(total), .text(path)])
    }

    func updateCounts(_ path: String, total: Int, unread: Int) {
        db.writer.run("UPDATE folders SET total = ?, unread = ? WHERE path = ?", [.of(total), .of(unread), .text(path)])
    }

    func adjustUnread(_ path: String, by delta: Int) {
        db.writer.run("UPDATE folders SET unread = MAX(0, unread + ?) WHERE path = ?", [.of(delta), .text(path)])
    }

    // MARK: Messages

    func messages(_ q: MessageQuery) -> [MessageSummary] {
        var clauses: [String] = []
        var args: [SQLValue] = []
        let terms = q.search.split(separator: " ").map { "%\($0)%" }

        if terms.isEmpty {
            switch q.item {
            case .dashboard:
                break
            case .folder(let path):
                clauses.append("folder = ?"); args.append(.text(path))
            case .flagged:
                clauses.append("flagged = 1")
            case .address(let email):
                clauses.append("recipients LIKE ?"); args.append(.text("% \(email.lowercased()) %"))
            }
        }
        if case .folder = q.item, terms.isEmpty {} else if !q.excludedFolders.isEmpty {
            clauses.append("folder NOT IN (\(q.excludedFolders.map { _ in "?" }.joined(separator: ",")))")
            args += q.excludedFolders.map { .text($0) }
        }
        for t in terms {
            clauses.append("(subject LIKE ? OR from_name LIKE ? OR from_addr LIKE ? OR snippet LIKE ? OR recipients LIKE ?)")
            args += Array(repeating: .text(t), count: 5)
        }
        if q.unreadOnly { clauses.append("seen = 0") }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return db.reader.query("SELECT \(Self.messageColumns) FROM messages \(whereSQL) ORDER BY date DESC LIMIT \(q.limit)", args, Self.message)
    }

    func message(folder: String, uid: UInt32) -> MessageSummary? {
        db.reader.query("SELECT \(Self.messageColumns) FROM messages WHERE folder = ? AND uid = ?", [.text(folder), .of(uid)], Self.message).first
    }

    func upsert(_ items: [FetchedSummary], folder: String) {
        db.writer.transaction {
            for s in items {
                let from = s.from.first
                let recipients = " " + Set((s.to + s.cc).map { $0.email.lowercased() } + s.deliveredTo).joined(separator: " ") + " "
                db.writer.run("""
                INSERT INTO messages(folder, uid, message_id, subject, from_name, from_addr, to_list, cc_list, reply_to,
                    recipients, delivered_to, date, seen, flagged, answered, size, has_att, in_reply_to, refs)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(folder, uid) DO UPDATE SET seen=excluded.seen, flagged=excluded.flagged, answered=excluded.answered
                """, [
                    .text(folder), .of(s.uid), .of(s.messageID), .text(s.subject),
                    .text(from?.name ?? ""), .text(from?.email ?? ""),
                    .text(AddressCoding.encode(s.to)), .text(AddressCoding.encode(s.cc)), .text(AddressCoding.encode(s.replyTo)),
                    .text(recipients), .text(Array(Set(s.deliveredTo)).joined(separator: " ")),
                    .double(s.date.timeIntervalSince1970),
                    .of(s.flags.contains("\\seen")), .of(s.flags.contains("\\flagged")), .of(s.flags.contains("\\answered")),
                    .of(s.size), .of(s.hasAttachments), .of(s.inReplyTo), .of(s.references),
                ])
            }
        }
    }

    func uidRange(_ folder: String) -> (min: UInt32, max: UInt32)? {
        db.writer.query("SELECT MIN(uid), MAX(uid), COUNT(*) FROM messages WHERE folder = ?", [.text(folder)]) {
            $0.int(2) > 0 ? (UInt32($0.int(0)), UInt32($0.int(1))) : nil
        }.first ?? nil
    }

    func cachedUIDs(_ folder: String, from minUID: UInt32) -> [UInt32: (seen: Bool, flagged: Bool, answered: Bool)] {
        var out: [UInt32: (Bool, Bool, Bool)] = [:]
        _ = db.writer.query("SELECT uid, seen, flagged, answered FROM messages WHERE folder = ? AND uid >= ?", [.text(folder), .of(minUID)]) { r in
            out[UInt32(r.int(0))] = (r.bool(1), r.bool(2), r.bool(3))
        }
        return out
    }

    func applyFlags(_ folder: String, flags: [UInt32: Set<String>], removed: [UInt32]) {
        db.writer.transaction {
            for (uid, f) in flags {
                db.writer.run("UPDATE messages SET seen = ?, flagged = ?, answered = ? WHERE folder = ? AND uid = ?",
                              [.of(f.contains("\\seen")), .of(f.contains("\\flagged")), .of(f.contains("\\answered")), .text(folder), .of(uid)])
            }
            for uid in removed {
                db.writer.run("DELETE FROM messages WHERE folder = ? AND uid = ?", [.text(folder), .of(uid)])
                db.writer.run("DELETE FROM bodies WHERE folder = ? AND uid = ?", [.text(folder), .of(uid)])
            }
        }
    }

    func setFlag(_ column: String, _ value: Bool, folder: String, uids: [UInt32]) {
        db.writer.transaction {
            for uid in uids {
                db.writer.run("UPDATE messages SET \(column) = ? WHERE folder = ? AND uid = ?", [.of(value), .text(folder), .of(uid)])
            }
        }
    }

    func delete(folder: String, uids: [UInt32]) {
        db.writer.transaction {
            for uid in uids {
                db.writer.run("DELETE FROM messages WHERE folder = ? AND uid = ?", [.text(folder), .of(uid)])
                db.writer.run("DELETE FROM bodies WHERE folder = ? AND uid = ?", [.text(folder), .of(uid)])
            }
        }
    }

    func clearFolder(_ folder: String) {
        db.writer.transaction {
            db.writer.run("DELETE FROM messages WHERE folder = ?", [.text(folder)])
            db.writer.run("DELETE FROM bodies WHERE folder = ?", [.text(folder)])
        }
    }

    func unreadCount(_ folder: String) -> Int {
        db.reader.query("SELECT COUNT(*) FROM messages WHERE folder = ? AND seen = 0", [.text(folder)]) { $0.int(0) }.first ?? 0
    }

    // MARK: Bodies

    func body(folder: String, uid: UInt32) -> [UInt8]? {
        db.reader.query("SELECT raw FROM bodies WHERE folder = ? AND uid = ?", [.text(folder), .of(uid)]) { $0.blob(0) }.first
    }

    func saveBody(_ raw: [UInt8], folder: String, uid: UInt32, snippet: String, hasAttachments: Bool) {
        db.writer.transaction {
            db.writer.run("INSERT OR REPLACE INTO bodies(folder, uid, raw, fetched) VALUES(?,?,?,?)",
                          [.text(folder), .of(uid), .blob(raw), .double(Date().timeIntervalSince1970)])
            db.writer.run("UPDATE messages SET snippet = ?, has_att = (has_att OR ?) WHERE folder = ? AND uid = ?",
                          [.text(snippet), .of(hasAttachments), .text(folder), .of(uid)])
        }
    }

    func messagesNeedingBodies(folder: String, limit: Int, maxSize: Int) -> [UInt32] {
        db.writer.query("""
        SELECT m.uid FROM messages m LEFT JOIN bodies b ON b.folder = m.folder AND b.uid = m.uid
        WHERE m.folder = ? AND b.uid IS NULL AND m.size <= ? ORDER BY m.date DESC LIMIT ?
        """, [.text(folder), .of(maxSize), .of(limit)]) { UInt32($0.int(0)) }
    }

    /// Keeps the body cache bounded to the most recently fetched messages.
    func pruneBodies(keep: Int = 1500) {
        db.writer.run("DELETE FROM bodies WHERE rowid NOT IN (SELECT rowid FROM bodies ORDER BY fetched DESC LIMIT ?)", [.of(keep)])
    }

    // MARK: Contacts & aliases

    func contacts(limit: Int = 800) -> [MailAddress] {
        db.reader.query("""
        SELECT from_name, from_addr, COUNT(*) c FROM messages WHERE from_addr != '' GROUP BY lower(from_addr) ORDER BY c DESC LIMIT ?
        """, [.of(limit)]) { MailAddress(name: $0.text(0), email: $0.text(1)) }
    }

    func sentRecipients(sentFolder: String) -> [MailAddress] {
        db.reader.query("SELECT to_list, cc_list FROM messages WHERE folder = ? ORDER BY date DESC LIMIT 1500", [.text(sentFolder)]) {
            AddressCoding.decode($0.text(0)) + AddressCoding.decode($0.text(1))
        }.flatMap { $0 }
    }

    struct AliasEvidence {
        var delivered: [String] = []
        var sentFrom: [MailAddress] = []
        var received: [(recipients: [MailAddress], delivered: [String])] = []
    }

    func aliasEvidence(sentFolder: String?, receivedExcluding excluded: [String]) -> AliasEvidence {
        var e = AliasEvidence()
        e.delivered = db.reader.query("SELECT delivered_to FROM messages WHERE delivered_to != ''") { $0.text(0) }
            .flatMap { $0.split(separator: " ").map(String.init) }
        if let sentFolder {
            e.sentFrom = db.reader.query("SELECT from_name, from_addr FROM messages WHERE folder = ?", [.text(sentFolder)]) {
                MailAddress(name: $0.text(0), email: $0.text(1))
            }
        }
        let placeholders = excluded.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT to_list, cc_list, delivered_to FROM messages" + (excluded.isEmpty ? "" : " WHERE folder NOT IN (\(placeholders))")
        e.received = db.reader.query(sql, excluded.map { .text($0) }) {
            (AddressCoding.decode($0.text(0)) + AddressCoding.decode($0.text(1)), $0.text(2).split(separator: " ").map(String.init))
        }
        return e
    }

    func storedAliases() -> [(email: String, name: String, source: String, hidden: Bool)] {
        db.reader.query("SELECT email, name, source, hidden FROM aliases") { ($0.text(0), $0.text(1), $0.text(2), $0.bool(3)) }
    }

    func saveAlias(email: String, name: String, source: String) {
        db.writer.run("""
        INSERT INTO aliases(email, name, source) VALUES(?,?,?)
        ON CONFLICT(email) DO UPDATE SET name = CASE WHEN aliases.name = '' THEN excluded.name ELSE aliases.name END,
            source = CASE WHEN aliases.source = 'manual' THEN 'manual' ELSE excluded.source END
        """, [.text(email.lowercased()), .text(name), .text(source)])
    }

    func setAliasHidden(_ email: String, hidden: Bool) {
        db.writer.run("UPDATE aliases SET hidden = ? WHERE email = ?", [.of(hidden), .text(email.lowercased())])
    }

    func renameAlias(_ email: String, name: String) {
        db.writer.run("UPDATE aliases SET name = ? WHERE email = ?", [.text(name), .text(email.lowercased())])
    }

    func unreadCount(forAddress email: String, excluding excluded: [String]) -> Int {
        let placeholders = excluded.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT COUNT(*) FROM messages WHERE seen = 0 AND recipients LIKE ?" + (excluded.isEmpty ? "" : " AND folder NOT IN (\(placeholders))")
        return db.reader.query(sql, [.text("% \(email.lowercased()) %")] + excluded.map { .text($0) }) { $0.int(0) }.first ?? 0
    }

    func flaggedCount() -> Int {
        db.reader.query("SELECT COUNT(*) FROM messages WHERE flagged = 1") { $0.int(0) }.first ?? 0
    }
}
