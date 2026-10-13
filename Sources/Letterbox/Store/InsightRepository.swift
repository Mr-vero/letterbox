import Foundation

extension MailRepository {
    func allInsights() -> [String: Insight] {
        var out: [String: Insight] = [:]
        _ = db.reader.query("""
        SELECT i.folder, i.uid, priority, category, summary, reason, action, due, needs_reply, done
        FROM insights i JOIN messages m ON m.folder = i.folder AND m.uid = i.uid
        """) { r in
            out[MessageSummary.makeID(r.text(0), UInt32(r.int(1)))] = Insight(
                priority: r.int(2), category: r.text(3), summary: r.text(4), reason: r.text(5),
                action: r.text(6), due: r.text(7), needsReply: r.bool(8), done: r.bool(9))
        }
        return out
    }

    func saveInsight(_ i: Insight, folder: String, uid: UInt32) {
        db.writer.run("""
        INSERT INTO insights(folder, uid, priority, category, summary, reason, action, due, needs_reply, done, analyzed)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(folder, uid) DO UPDATE SET priority=excluded.priority, category=excluded.category, summary=excluded.summary,
            reason=excluded.reason, action=excluded.action, due=excluded.due, needs_reply=excluded.needs_reply, analyzed=excluded.analyzed
        """, [.text(folder), .of(uid), .of(i.priority), .text(i.category), .text(i.summary), .text(i.reason), .text(i.action),
              .text(i.due), .of(i.needsReply), .of(i.done), .double(Date().timeIntervalSince1970)])
    }

    func setInsightDone(_ done: Bool, folder: String, uid: UInt32) {
        db.writer.run("UPDATE insights SET done = ? WHERE folder = ? AND uid = ?", [.of(done), .text(folder), .of(uid)])
    }

    /// Recent inbox messages Claude hasn't looked at yet, newest first.
    func messagesNeedingTriage(folder: String, since: Date, limit: Int) -> [MessageSummary] {
        let ids = db.reader.query("""
        SELECT m.uid FROM messages m LEFT JOIN insights i ON i.folder = m.folder AND i.uid = m.uid
        WHERE m.folder = ? AND i.uid IS NULL AND m.date >= ? ORDER BY m.date DESC LIMIT ?
        """, [.text(folder), .double(since.timeIntervalSince1970), .of(limit)]) { UInt32($0.int(0)) }
        return ids.compactMap { message(folder: folder, uid: $0) }
    }

    func recentMessages(folder: String, since: Date, limit: Int) -> [MessageSummary] {
        db.reader.query("SELECT \(Self.messageColumns) FROM messages WHERE folder = ? AND date >= ? ORDER BY date DESC LIMIT ?",
                        [.text(folder), .double(since.timeIntervalSince1970), .of(limit)], Self.message)
    }
}

extension MailRepository {
    func threadInsights() -> [String: Insight] {
        var out: [String: Insight] = [:]
        _ = db.reader.query("""
        SELECT thread, latest, priority, category, summary, reason, action, due, due_date, status, needs_reply, timeline, done FROM thread_insights
        """) { r in
            let timeline = (try? JSONDecoder().decode([TimelineEvent].self, from: Data(r.text(11).utf8))) ?? []
            out[r.text(0)] = Insight(priority: r.int(2), category: r.text(3), summary: r.text(4), reason: r.text(5), action: r.text(6),
                                     due: r.text(7), needsReply: r.bool(10), done: r.bool(12), status: r.text(9), dueDate: r.text(8),
                                     timeline: timeline, latestID: r.text(1))
        }
        return out
    }

    func saveThreadInsight(_ i: Insight, thread: String) {
        let timeline = String(decoding: (try? JSONEncoder().encode(i.timeline)) ?? Data("[]".utf8), as: UTF8.self)
        db.writer.run("""
        INSERT INTO thread_insights(thread, latest, priority, category, summary, reason, action, due, due_date, status, needs_reply, timeline, done, analyzed)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(thread) DO UPDATE SET latest=excluded.latest, priority=excluded.priority, category=excluded.category,
            summary=excluded.summary, reason=excluded.reason, action=excluded.action, due=excluded.due, due_date=excluded.due_date,
            status=excluded.status, needs_reply=excluded.needs_reply, timeline=excluded.timeline, analyzed=excluded.analyzed,
            done = CASE WHEN thread_insights.latest = excluded.latest THEN thread_insights.done ELSE 0 END
        """, [.text(thread), .text(i.latestID), .of(i.priority), .text(i.category), .text(i.summary), .text(i.reason), .text(i.action),
              .text(i.due), .text(i.dueDate), .text(i.status), .of(i.needsReply), .text(timeline), .of(i.done),
              .double(Date().timeIntervalSince1970)])
    }

    func setThreadDone(_ done: Bool, thread: String) {
        db.writer.run("UPDATE thread_insights SET done = ? WHERE thread = ?", [.of(done), .text(thread)])
    }

    /// Messages from the given folders, newest first, for threading.
    func threadPool(folders: [String], since: Date, limit: Int = 5000) -> [MessageSummary] {
        guard !folders.isEmpty else { return [] }
        let placeholders = folders.map { _ in "?" }.joined(separator: ",")
        return db.reader.query("SELECT \(Self.messageColumns) FROM messages WHERE folder IN (\(placeholders)) AND date >= ? ORDER BY date DESC LIMIT ?",
                               folders.map { .text($0) } + [.double(since.timeIntervalSince1970), .of(limit)], Self.message)
    }
}
