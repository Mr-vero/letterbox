import Foundation

/// Owns the IMAP connections and keeps the local cache in step with the server.
/// One connection does background sync; a second serves user actions so that
/// opening a message never waits behind a long sync.
final class SyncEngine: @unchecked Sendable {
    let account: Account
    private let password: String
    let repo: MailRepository
    private let background: IMAPClient
    private let interactive: IMAPClient

    init(account: Account, password: String, repo: MailRepository) {
        self.account = account
        self.password = password
        self.repo = repo
        background = IMAPClient(host: account.imapHost, port: account.imapPort, security: account.imapSecurity, username: account.loginName, password: password)
        interactive = IMAPClient(host: account.imapHost, port: account.imapPort, security: account.imapSecurity, username: account.loginName, password: password)
    }

    func connect() async throws {
        try await interactive.connect()
    }

    func shutdown() async {
        await background.disconnect()
        await interactive.disconnect()
    }

    // MARK: Folder sync

    func refreshFolders() async throws {
        let remote = try await background.listFolders()
        repo.replaceFolders(remote)
        for folder in repo.folders() {
            if let status = try? await background.status(folder.path) {
                repo.updateCounts(folder.path, total: status.messages, unread: status.unseen)
            }
        }
    }

    /// Returns true if anything changed locally.
    @discardableResult
    func syncFolder(_ path: String, initialWindow: Int, progress: @escaping (Int, Int) async -> Void) async throws -> Bool {
        let info = try await background.select(path)
        let state = repo.folderState(path)
        var changed = false

        if state.uidValidity != 0 && state.uidValidity != info.uidValidity {
            repo.clearFolder(path)
            changed = true
        }

        if let range = repo.uidRange(path) {
            if info.uidNext == 0 || info.uidNext > range.max + 1 {
                let fresh = try await background.fetchSummaries(in: path, set: "\(range.max + 1):*", byUID: true)
                    .filter { $0.uid > range.max }
                if !fresh.isEmpty {
                    repo.upsert(fresh, folder: path)
                    changed = true
                    await progress(fresh.count, fresh.count)
                }
            }
            let remote = try await background.fetchFlags(in: path, uidSet: "\(range.min):\(range.max)")
            let local = repo.cachedUIDs(path, from: range.min)
            var updates: [UInt32: Set<String>] = [:]
            var removed: [UInt32] = []
            for (uid, l) in local where uid <= range.max {
                guard let f = remote[uid] else { removed.append(uid); continue }
                if l.seen != f.contains("\\seen") || l.flagged != f.contains("\\flagged") || l.answered != f.contains("\\answered") {
                    updates[uid] = f
                }
            }
            if !updates.isEmpty || !removed.isEmpty {
                repo.applyFlags(path, flags: updates, removed: removed)
                changed = true
            }
        } else if info.exists > 0 {
            // First sync: newest first, small first page so the list paints quickly.
            var upper = info.exists
            let lower = max(1, info.exists - initialWindow + 1)
            var pageSize = 60
            let total = info.exists - lower + 1
            while upper >= lower {
                let lo = max(lower, upper - pageSize + 1)
                let page = try await background.fetchSummaries(in: path, set: "\(lo):\(upper)", byUID: false)
                repo.upsert(page, folder: path)
                await progress(info.exists - lo + 1, total)
                upper = lo - 1
                pageSize = 250
            }
            changed = true
        }

        repo.updateFolderState(path, uidValidity: info.uidValidity, uidNext: info.uidNext, total: info.exists)
        let unseen = (try? await background.searchUIDs(in: path, criteria: "UNSEEN").count) ?? repo.unreadCount(path)
        repo.updateCounts(path, total: info.exists, unread: unseen)
        return changed
    }

    /// Downloads recent message bodies so they open instantly and get previews.
    func prefetchBodies(in path: String, limit: Int, onBatch: @escaping () async -> Void) async throws {
        let uids = repo.messagesNeedingBodies(folder: path, limit: limit, maxSize: 400_000)
        guard !uids.isEmpty else { return }
        for chunk in stride(from: 0, to: uids.count, by: 10).map({ Array(uids[$0..<min($0 + 10, uids.count)]) }) {
            let bodies = try await background.fetchBodies(in: path, uids: chunk)
            for (uid, raw) in bodies {
                let parsed = MessageParser.parse(raw)
                repo.saveBody(raw, folder: path, uid: uid, snippet: parsed.snippet, hasAttachments: !parsed.attachments.isEmpty)
            }
            await onBatch()
        }
        repo.pruneBodies()
    }

    // MARK: User actions

    func loadBody(folder: String, uid: UInt32) async throws -> (ParsedMessage, snippet: String) {
        if let raw = repo.body(folder: folder, uid: uid) {
            let parsed = MessageParser.parse(raw)
            return (parsed, parsed.snippet)
        }
        guard let raw = try await interactive.fetchBodies(in: folder, uids: [uid])[uid] else {
            throw IMAPError(message: "This message is no longer on the server.")
        }
        let parsed = MessageParser.parse(raw)
        let snippet = parsed.snippet
        repo.saveBody(raw, folder: folder, uid: uid, snippet: snippet, hasAttachments: !parsed.attachments.isEmpty)
        return (parsed, snippet)
    }

    func setFlag(_ flag: String, _ on: Bool, folder: String, uids: [UInt32]) async throws {
        try await interactive.store(in: folder, uids: uids, flag: flag, add: on)
    }

    func move(folder: String, uids: [UInt32], to destination: String) async throws {
        try await interactive.move(in: folder, uids: uids, to: destination)
    }

    func deletePermanently(folder: String, uids: [UInt32]) async throws {
        try await interactive.deletePermanently(in: folder, uids: uids)
    }

    func createFolder(_ path: String) async throws {
        try await interactive.create(path)
    }

    func append(to folder: String, message: [UInt8], flags: [String]) async throws {
        try await interactive.append(to: folder, message: message, flags: flags)
    }

    func smtp() -> SMTPClient {
        SMTPClient(host: account.smtpHost, port: account.smtpPort, security: account.smtpSecurity, username: account.loginName, password: password)
    }
}
