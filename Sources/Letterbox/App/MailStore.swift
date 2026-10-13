import AppKit
import Observation
import SwiftUI

enum BodyState {
    case loading
    case loaded(ParsedMessage)
    case failed(String)
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let symbol: String
}

@Observable @MainActor
final class ComposeDraft: Identifiable {
    let id = UUID()
    var fromEmail: String
    var to = ""
    var cc = ""
    var bcc = ""
    var showCcBcc = false
    var subject = ""
    var body = ""
    var attachments: [OutgoingAttachment] = []
    var inReplyTo: String?
    var references: String?
    var replyingTo: String?
    var isReply = false
    var isSending = false
    var error: String?

    /// Quoted original (reply/forward), kept apart from the editable body.
    var quote = ""
    var showQuote = false
    /// Plain text of the message being answered, for Claude.
    var context = ""
    var contextFrom = ""
    var contextSubject = ""
    var contextDate = Date()

    var aiInstruction = ""
    var aiTone: ReplyTone?
    var aiBusy = false
    var aiError: String?
    var autoGenerate = false
    @ObservationIgnored var aiTask: Task<Void, Never>?
    /// Bumps whenever the body is replaced programmatically so the editor reloads.
    var bodyRevision = 0

    init(fromEmail: String) { self.fromEmail = fromEmail }

    var isEmpty: Bool {
        to.isEmpty && cc.isEmpty && subject.isEmpty && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    var fullBody: String { quote.isEmpty ? body : body + "\n\n" + quote }
}

@Observable @MainActor
final class MailStore {
    // MARK: Account & data
    var account: Account?
    var folders: [Folder] = []
    var addresses: [Alias] = []
    var hiddenAliases: [Alias] = []
    var messages: [MessageSummary] = []
    var flaggedCount = 0

    // MARK: UI state
    var sidebarSelection: SidebarItem? = .dashboard {
        didSet {
            guard oldValue != sidebarSelection else { return }
            selection = []
            reloadMessages()
        }
    }
    var selection: Set<String> = [] {
        didSet { if oldValue != selection { selectionDidChange() } }
    }
    var searchText = "" {
        didSet { if oldValue != searchText { scheduleSearch() } }
    }
    var unreadOnly = false {
        didSet { reloadMessages() }
    }
    var bodyState: BodyState?
    var openedID: String?
    var confirmDeletion: [String]?

    var isSyncing = false
    var syncProgress: String?
    var lastSync: Date?
    var syncError: String?
    var toast: Toast?
    var pendingCompose: UUID?
    var drafts: [UUID: ComposeDraft] = [:]

    // MARK: Claude
    /// Claude's read on each conversation, mirrored per message id for the UI.
    var insights: [String: Insight] = [:]
    var threadInsights: [String: Insight] = [:]
    var conversations: [Conversation] = []
    @ObservationIgnored var threadOf: [String: String] = [:]
    @ObservationIgnored var conversationByID: [String: Conversation] = [:]
    @ObservationIgnored var knownMessages: [String: MessageSummary] = [:]
    var briefing: Briefing? = Briefing.load()
    var aiStatus: AIStatus = .unknown
    var deepSummaries: [String: DeepSummary] = [:]
    var summarizing: Set<String> = []
    var showPalette = false
    var searchFocusRequest = 0
    var pendingAsk: String?
    @ObservationIgnored let askSession = AskSession()
    var aiEnabled = UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(aiEnabled, forKey: "aiEnabled"); setupAI() }
    }
    var aiModel = UserDefaults.standard.string(forKey: "aiModel") ?? "sonnet" {
        didSet { UserDefaults.standard.set(aiModel, forKey: "aiModel"); claude?.model = aiModel }
    }
    var claudePath = UserDefaults.standard.string(forKey: "claudePath") ?? "" {
        didSet { UserDefaults.standard.set(claudePath, forKey: "claudePath") }
    }
    @ObservationIgnored var claude: ClaudeCLI?
    @ObservationIgnored var triageTask: Task<Void, Never>?

    // MARK: Preferences
    var blockRemoteContent = UserDefaults.standard.bool(forKey: "blockRemoteContent") {
        didSet { UserDefaults.standard.set(blockRemoteContent, forKey: "blockRemoteContent") }
    }
    var saveToSent = UserDefaults.standard.object(forKey: "saveToSent") as? Bool ?? true {
        didSet { UserDefaults.standard.set(saveToSent, forKey: "saveToSent") }
    }
    var signature = UserDefaults.standard.string(forKey: "signature") ?? "" {
        didSet { UserDefaults.standard.set(signature, forKey: "signature") }
    }

    @ObservationIgnored let repo: MailRepository
    @ObservationIgnored var engine: SyncEngine?
    @ObservationIgnored var bodyCache: [String: ParsedMessage] = [:]
    @ObservationIgnored private var bodyCacheOrder: [String] = []
    @ObservationIgnored private var bodyTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private(set) var contacts: [MailAddress] = []

    /// Demo store backed by a throwaway database; used only for offscreen snapshots.
    init(demo account: Account, database: Database) {
        repo = MailRepository(db: database)
        self.account = account
        loadFromCache()
        lastSync = Date()
    }

    init() {
        repo = MailRepository(db: Database())
        if let acct = Account.load(), let password = Keychain.password(for: acct.email) {
            account = acct
            engine = SyncEngine(account: acct, password: password, repo: repo)
            loadFromCache()
            startSync()
        }
        setupAI()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: Lookups

    func folder(_ role: FolderRole) -> Folder? { folders.first { $0.role == role } }
    var inbox: Folder? { folder(.inbox) }
    var mailboxFolders: [Folder] { folders.filter { $0.role != .custom } }
    var customFolders: [Folder] { folders.filter { $0.role == .custom } }
    var myAddresses: Set<String> { Set(([account?.email ?? ""] + addresses.map(\.email) + hiddenAliases.map(\.email)).map { $0.lowercased() }) }

    func message(_ id: String) -> MessageSummary? { messages.first { $0.id == id } ?? knownMessages[id] }
    var selectedMessages: [MessageSummary] { messages.filter { selection.contains($0.id) } }
    var openedMessage: MessageSummary? { openedID.flatMap(message) }

    var currentFolder: Folder? {
        if case .folder(let path) = sidebarSelection { return folders.first { $0.path == path } }
        return nil
    }

    var title: String {
        if !searchText.isEmpty { return "Search" }
        switch sidebarSelection {
        case .folder(let path): return folders.first { $0.path == path }?.displayName ?? "Mail"
        case .flagged: return "Flagged"
        case .dashboard: return "Dashboard"
        case .address(let email): return addresses.first { $0.email == email }?.email ?? email
        case nil: return "Letterbox"
        }
    }

    var subtitle: String {
        let unread = messages.lazy.filter { !$0.seen }.count
        if !searchText.isEmpty { return "\(messages.count) results" }
        return unread == 0 ? "\(messages.count) messages" : "\(unread) unread"
    }

    /// Which local alias received a message, if not the primary address.
    func receivingAlias(for m: MessageSummary) -> String? {
        let primary = account?.email.lowercased() ?? ""
        let recipients = m.recipientSet
        if recipients.contains(primary) { return nil }
        return addresses.first { !$0.isPrimary && recipients.contains($0.email) }?.email
    }

    private var discardedFolderPaths: [String] {
        folders.filter { $0.role == .trash || $0.role == .junk }.map(\.path)
    }

    // MARK: Sign in / out

    func signIn(account acct: Account, password: String) async throws {
        let candidate = SyncEngine(account: acct, password: password, repo: repo)
        do {
            try await candidate.connect()
        } catch let error as IMAPError where error.isAuthFailure {
            let hint = MailProvider.byID(acct.provider).help
            throw IMAPError(message: "The server didn’t accept that sign-in (\(error.message)). \(hint)", isAuthFailure: true)
        }
        repo.db.wipe()
        Keychain.setPassword(password, for: acct.email)
        acct.save()
        account = acct
        engine = candidate
        sidebarSelection = .dashboard
        loadFromCache()
        startSync()
    }

    func signOut() {
        pollTask?.cancel()
        if let engine { Task { await engine.shutdown() } }
        engine = nil
        if let account { Keychain.deletePassword(for: account.email) }
        Account.clear()
        repo.db.wipe()
        bodyCache = [:]
        bodyCacheOrder = []
        folders = []
        messages = []
        addresses = []
        hiddenAliases = []
        insights = [:]
        threadInsights = [:]
        conversations = []
        briefing = nil
        Briefing.clear()
        selection = []
        account = nil
    }

    func updateDisplayName(_ name: String) {
        account?.displayName = name
        account?.save()
        reloadAliases()
    }

    // MARK: Loading

    private func loadFromCache() {
        folders = repo.folders()
        threadInsights = repo.threadInsights()
        rebuildConversations()
        reloadAliases()
        reloadMessages()
    }

    func reloadMessages() {
        guard let item = sidebarSelection else { messages = []; return }
        var q = MessageQuery(item: item, search: searchText.trimmingCharacters(in: .whitespaces), unreadOnly: unreadOnly)
        if item == .dashboard && q.search.isEmpty {
            let inboxPath = inbox?.path ?? "INBOX"
            messages = repo.recentMessages(folder: inboxPath, since: Date().addingTimeInterval(-30 * 86400), limit: 500)
            let ids = Set(messages.map(\.id))
            let kept = selection.intersection(ids)
            if kept != selection { selection = kept }
            return
        }
        switch item {
        case .dashboard: q.excludedFolders = discardedFolderPaths
        case .flagged: q.excludedFolders = discardedFolderPaths
        case .address: q.excludedFolders = folders.filter { $0.role.isOutgoingOrDiscarded }.map(\.path)
        case .folder: q.excludedFolders = discardedFolderPaths
        }
        messages = repo.messages(q)
        let ids = Set(messages.map(\.id))
        let kept = selection.intersection(ids)
        if kept != selection { selection = kept }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            reloadMessages()
        }
    }

    private func refreshCounts() {
        folders = repo.folders()
        flaggedCount = repo.flaggedCount()
        let excluded = folders.filter { $0.role.isOutgoingOrDiscarded }.map(\.path)
        for i in addresses.indices {
            addresses[i].unread = repo.unreadCount(forAddress: addresses[i].email, excluding: excluded)
        }
    }

    private func didUpdate(folder path: String) {
        refreshCounts()
        let affected: Bool
        switch sidebarSelection {
        case .folder(let p): affected = p == path || !searchText.isEmpty
        case .flagged, .address, .dashboard: affected = true
        case nil: affected = false
        }
        if affected { reloadMessages() }
    }

    // MARK: Aliases

    func reloadAliases() {
        guard let account else { addresses = []; return }
        let stored = repo.storedAliases()
        let primary = Alias(email: account.email.lowercased(), name: account.displayName, isPrimary: true, isManual: false)
        let make = { (s: (email: String, name: String, source: String, hidden: Bool)) in
            Alias(email: s.email, name: s.name, isPrimary: false, isManual: s.source == "manual")
        }
        addresses = [primary] + stored.filter { !$0.hidden && $0.email != primary.email }.map(make).sorted { $0.email < $1.email }
        hiddenAliases = stored.filter { $0.hidden }.map(make)
        refreshCounts()
    }

    private func detectAliases() async {
        guard let account else { return }
        let sent = folder(.sent)?.path
        let excluded = folders.filter { $0.role.isOutgoingOrDiscarded }.map(\.path)
        let repo = repo
        let candidates = await Task.detached(priority: .utility) {
            AliasDetector.detect(repo.aliasEvidence(sentFolder: sent, receivedExcluding: excluded), primary: account.email)
        }.value
        for c in candidates { repo.saveAlias(email: c.email, name: c.name, source: "detected") }
        reloadAliases()
    }

    func addAlias(_ email: String, name: String = "") {
        let clean = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard clean.contains("@"), clean != account?.email.lowercased() else { return }
        repo.saveAlias(email: clean, name: name, source: "manual")
        repo.setAliasHidden(clean, hidden: false)
        reloadAliases()
    }

    func setAlias(_ email: String, hidden: Bool) {
        repo.setAliasHidden(email, hidden: hidden)
        if hidden, sidebarSelection == .address(email) { sidebarSelection = .folder("INBOX") }
        reloadAliases()
    }

    func renameAlias(_ email: String, to name: String) {
        repo.renameAlias(email, name: name)
        reloadAliases()
    }

    // MARK: Sync

    private func startSync() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.sync(full: true)
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                tick += 1
                await self?.sync(full: tick % 5 == 0)
            }
        }
    }

    func refresh() {
        Task { await sync(full: true) }
    }

    func sync(full: Bool, extra: [String] = []) async {
        guard let engine, !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
            syncProgress = nil
        }
        do {
            if full || folders.isEmpty {
                try await engine.refreshFolders()
                folders = repo.folders()
            }
            var order: [Folder] = []
            if let inbox { order.append(inbox) }
            if full {
                order += folders.filter { $0.role != .inbox }.sorted { ($0.role == .sent ? 0 : 1) < ($1.role == .sent ? 0 : 1) }
            } else {
                if let current = currentFolder, current.role != .inbox { order.append(current) }
                order += folders.filter { extra.contains($0.path) && !order.contains($0) }
            }
            for f in order {
                let window: Int
                switch f.role {
                case .inbox: window = 2000
                case .trash, .junk: window = 200
                default: window = 600
                }
                let isFirst = repo.uidRange(f.path) == nil
                let name = f.displayName
                let changed = try await engine.syncFolder(f.path, initialWindow: window) { [weak self] done, total in
                    guard let self else { return }
                    if isFirst { self.syncProgress = "Downloading \(name) — \(done) of \(total)" }
                    self.didUpdate(folder: f.path)
                }
                if changed { didUpdate(folder: f.path) }
            }
            refreshCounts()
            rebuildConversations()
            await detectAliases()
            if let inbox {
                try await engine.prefetchBodies(in: inbox.path, limit: full ? 150 : 40) { [weak self] in
                    self?.didUpdate(folder: inbox.path)
                }
            }
            if let sent = folder(.sent) {
                try await engine.prefetchBodies(in: sent.path, limit: full ? 80 : 20) {}
            }
            lastSync = Date()
            syncError = nil
            scheduleTriage()
        } catch {
            syncError = Self.friendly(error)
        }
    }

    static func friendly(_ error: Error) -> String {
        if let e = error as? IMAPError, e.isAuthFailure {
            return "Your mail server rejected the sign-in. If you use two-factor authentication, you may need an app password."
        }
        if error is NetError || (error as NSError).domain == NSPOSIXErrorDomain || (error as NSError).domain == "Network.NWError" {
            return "Can’t reach your mail server right now. Letterbox will keep trying."
        }
        return error.localizedDescription
    }

    // MARK: Reading

    private func selectionDidChange() {
        guard selection.count == 1, let id = selection.first, let m = message(id) else {
            openedID = nil
            bodyState = nil
            return
        }
        open(m)
    }

    private func open(_ m: MessageSummary) {
        openedID = m.id
        bodyTask?.cancel()
        if let cached = bodyCache[m.id] {
            bodyState = .loaded(cached)
            prefetchNeighbors(of: m)
        } else {
            bodyState = .loading
            bodyTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let (parsed, snippet): (ParsedMessage, String)
                    if let engine = self.engine {
                        (parsed, snippet) = try await engine.loadBody(folder: m.folder, uid: m.uid)
                    } else if let raw = self.repo.body(folder: m.folder, uid: m.uid) {
                        let p = MessageParser.parse(raw)
                        (parsed, snippet) = (p, p.snippet)
                    } else {
                        throw IMAPError(message: "Not connected.")
                    }
                    self.remember(parsed, for: m.id)
                    self.updateLocal(m.id) { if $0.snippet.isEmpty { $0.snippet = snippet } }
                    guard self.openedID == m.id else { return }
                    self.bodyState = .loaded(parsed)
                    self.prefetchNeighbors(of: m)
                } catch {
                    guard self.openedID == m.id, !Task.isCancelled else { return }
                    self.bodyState = .failed(Self.friendly(error))
                }
            }
        }
        if !m.seen { applyFlag([m.id], column: "seen", flag: "\\Seen", value: true) }
    }

    func retryOpen() {
        if let m = openedMessage { open(m) }
    }

    private func remember(_ parsed: ParsedMessage, for id: String) {
        if bodyCache[id] == nil { bodyCacheOrder.append(id) }
        bodyCache[id] = parsed
        while bodyCacheOrder.count > 40 {
            bodyCache[bodyCacheOrder.removeFirst()] = nil
        }
    }

    /// Warms the next and previous messages so arrow-key navigation feels instant.
    private func prefetchNeighbors(of m: MessageSummary) {
        guard let engine, let idx = messages.firstIndex(where: { $0.id == m.id }) else { return }
        let neighbors = [idx + 1, idx - 1].filter { messages.indices.contains($0) }.map { messages[$0] }
        for n in neighbors where bodyCache[n.id] == nil && n.size < 2_000_000 {
            Task { [weak self] in
                guard let (parsed, snippet) = try? await engine.loadBody(folder: n.folder, uid: n.uid) else { return }
                self?.remember(parsed, for: n.id)
                self?.updateLocal(n.id) { if $0.snippet.isEmpty { $0.snippet = snippet } }
            }
        }
    }

    private func updateLocal(_ id: String, _ change: (inout MessageSummary) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
    }

    // MARK: Flags

    func applyRead(_ ids: [String]) {
        applyFlag(ids, column: "seen", flag: "\\Seen", value: true)
    }

    func toggleRead(_ ids: [String]) {
        let targets = ids.compactMap(message)
        let makeRead = targets.contains { !$0.seen }
        applyFlag(ids, column: "seen", flag: "\\Seen", value: makeRead)
    }

    func toggleFlag(_ ids: [String]) {
        let targets = ids.compactMap(message)
        let makeFlagged = targets.contains { !$0.flagged }
        applyFlag(ids, column: "flagged", flag: "\\Flagged", value: makeFlagged)
    }

    private func applyFlag(_ ids: [String], column: String, flag: String, value: Bool) {
        let targets = ids.compactMap(message).filter { m in
            switch column {
            case "seen": return m.seen != value
            case "flagged": return m.flagged != value
            default: return m.answered != value
            }
        }
        guard !targets.isEmpty else { return }
        for (folder, group) in Dictionary(grouping: targets, by: \.folder) {
            let uids = group.map(\.uid)
            repo.setFlag(column, value, folder: folder, uids: uids)
            if column == "seen" { repo.adjustUnread(folder, by: value ? -uids.count : uids.count) }
            Task { [weak self] in
                do { try await self?.engine?.setFlag(flag, value, folder: folder, uids: uids) } catch { self?.show(error) }
            }
        }
        for m in targets {
            updateLocal(m.id) {
                switch column {
                case "seen": $0.seen = value
                case "flagged": $0.flagged = value
                default: $0.answered = value
                }
            }
        }
        refreshCounts()
    }

    // MARK: Moving

    func archive(_ ids: [String]) {
        if let archive = folder(.archive) {
            move(ids, to: archive.path, label: "Archived", symbol: "archivebox.fill")
        } else {
            Task {
                do {
                    try await engine?.createFolder("Archive")
                    try await engine?.refreshFolders()
                    folders = repo.folders()
                    if let archive = folder(.archive) { move(ids, to: archive.path, label: "Archived", symbol: "archivebox.fill") }
                } catch { show(error) }
            }
        }
    }

    func trash(_ ids: [String]) {
        let targets = ids.compactMap(message)
        guard !targets.isEmpty else { return }
        let trash = folder(.trash)
        if trash == nil || targets.allSatisfy({ $0.folder == trash?.path }) {
            confirmDeletion = ids
            return
        }
        move(ids, to: trash!.path, label: targets.count == 1 ? "Moved to Trash" : "Moved \(targets.count) messages to Trash", symbol: "trash.fill")
    }

    func markJunk(_ ids: [String]) {
        let targets = ids.compactMap(message)
        if let junk = folder(.junk), let inbox {
            if targets.allSatisfy({ $0.folder == junk.path }) {
                move(ids, to: inbox.path, label: "Moved to Inbox", symbol: "tray.fill")
            } else {
                move(ids, to: junk.path, label: "Marked as Junk", symbol: "xmark.bin.fill")
            }
        }
    }

    func moveToInbox(_ ids: [String]) {
        if let inbox { move(ids, to: inbox.path, label: "Moved to Inbox", symbol: "tray.fill") }
    }

    func move(_ ids: [String], to destination: String, label: String? = nil, symbol: String = "folder.fill") {
        let targets = ids.compactMap(message).filter { $0.folder != destination }
        guard !targets.isEmpty else { return }
        removeLocally(targets)
        let name = folders.first { $0.path == destination }?.displayName ?? destination
        showToast(label ?? "Moved to \(name)", symbol: symbol)
        for (folder, group) in Dictionary(grouping: targets, by: \.folder) {
            let uids = group.map(\.uid)
            Task { [weak self] in
                do {
                    try await self?.engine?.move(folder: folder, uids: uids, to: destination)
                } catch {
                    self?.show(error)
                    await self?.sync(full: false, extra: [folder])
                }
            }
        }
    }

    func deleteConfirmed() {
        guard let ids = confirmDeletion else { return }
        confirmDeletion = nil
        let targets = ids.compactMap(message)
        removeLocally(targets)
        showToast(targets.count == 1 ? "Message deleted" : "\(targets.count) messages deleted", symbol: "trash.fill")
        for (folder, group) in Dictionary(grouping: targets, by: \.folder) {
            let uids = group.map(\.uid)
            Task { [weak self] in
                do { try await self?.engine?.deletePermanently(folder: folder, uids: uids) } catch { self?.show(error) }
            }
        }
    }

    private func removeLocally(_ targets: [MessageSummary]) {
        let ids = Set(targets.map(\.id))
        let firstIndex = messages.firstIndex { ids.contains($0.id) }
        for (folder, group) in Dictionary(grouping: targets, by: \.folder) {
            repo.delete(folder: folder, uids: group.map(\.uid))
            let unread = group.filter { !$0.seen }.count
            if unread > 0 { repo.adjustUnread(folder, by: -unread) }
        }
        withAnimation(.snappy(duration: 0.22)) {
            messages.removeAll { ids.contains($0.id) }
        }
        if let firstIndex, !messages.isEmpty, selection.isSubset(of: ids) || selection.isEmpty {
            selection = [messages[min(firstIndex, messages.count - 1)].id]
        } else {
            selection.subtract(ids)
        }
        refreshCounts()
    }

    // MARK: Composing

    func requestCompose(_ draft: ComposeDraft) {
        if !signature.isEmpty && !draft.body.contains(signature) {
            draft.body += "\n\n-- \n\(signature)"
        }
        drafts[draft.id] = draft
        pendingCompose = draft.id
        if contacts.isEmpty { loadContacts() }
    }

    func newMessage(from email: String? = nil, to: String = "", subject: String = "", body: String = "") {
        let d = ComposeDraft(fromEmail: email ?? defaultFromAddress)
        d.to = to
        d.subject = subject
        d.body = body
        requestCompose(d)
    }

    private var defaultFromAddress: String {
        if case .address(let email) = sidebarSelection { return email }
        return account?.email ?? ""
    }

    @discardableResult
    func reply(all: Bool, to target: MessageSummary? = nil) -> ComposeDraft? {
        guard let m = target ?? openedMessage ?? selectedMessages.first else { return nil }
        let parsed = bodyCache[m.id]
        let me = myAddresses
        let d = ComposeDraft(fromEmail: replyAddress(for: m))
        let primaryTargets = m.replyTo.isEmpty ? [m.sender] : m.replyTo
        var to = primaryTargets
        var cc: [MailAddress] = []
        if all {
            to += m.to.filter { !me.contains($0.email.lowercased()) }
            cc = m.cc.filter { !me.contains($0.email.lowercased()) }
        }
        to = unique(to)
        if to.isEmpty { to = m.to }
        d.to = to.map(MessageBuilder.format).joined(separator: ", ")
        if !cc.isEmpty { d.cc = unique(cc).map(MessageBuilder.format).joined(separator: ", "); d.showCcBcc = true }
        d.subject = Self.prefixed("Re:", m.subject)
        d.inReplyTo = m.messageID
        d.references = [m.references, m.messageID].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        d.replyingTo = m.id
        d.isReply = true
        let original = parsed?.quotableText ?? m.snippet
        let quoted = original
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }
            .joined(separator: "\n")
        d.quote = "On \(RelativeDate.detailed(m.date)), \(m.senderDisplay) wrote:\n\(quoted)"
        d.context = original
        d.contextFrom = MessageBuilder.format(m.sender)
        d.contextSubject = m.displaySubject
        d.contextDate = m.date
        requestCompose(d)
        return d
    }

    func forward() {
        guard let m = openedMessage ?? selectedMessages.first else { return }
        let parsed = bodyCache[m.id]
        let d = ComposeDraft(fromEmail: replyAddress(for: m))
        d.subject = Self.prefixed("Fwd:", m.subject)
        d.isReply = true
        d.context = parsed?.quotableText ?? m.snippet
        d.contextFrom = MessageBuilder.format(m.sender)
        d.contextSubject = m.displaySubject
        d.contextDate = m.date
        d.quote = """
        ---------- Forwarded message ----------
        From: \(MessageBuilder.format(m.sender))
        Date: \(RelativeDate.detailed(m.date))
        Subject: \(m.displaySubject)
        To: \(m.to.map(MessageBuilder.format).joined(separator: ", "))

        \(parsed?.quotableText ?? m.snippet)
        """
        d.attachments = (parsed?.attachments ?? []).map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
        requestCompose(d)
    }

    func compose(mailto url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var to = comps.path
        var subject = "", body = "", cc = ""
        for item in comps.queryItems ?? [] {
            switch item.name.lowercased() {
            case "subject": subject = item.value ?? ""
            case "body": body = item.value ?? ""
            case "cc": cc = item.value ?? ""
            case "to": to += (to.isEmpty ? "" : ", ") + (item.value ?? "")
            default: break
            }
        }
        let d = ComposeDraft(fromEmail: openedMessage.map(replyAddress) ?? defaultFromAddress)
        d.to = to
        d.cc = cc
        d.showCcBcc = !cc.isEmpty
        d.subject = subject
        d.body = body
        requestCompose(d)
    }

    /// Replies go out from whichever of my addresses received the original.
    func replyAddress(for m: MessageSummary) -> String {
        let primary = account?.email.lowercased() ?? ""
        let mine = Set(addresses.map(\.email))
        let ordered = m.to.map { $0.email.lowercased() } + m.cc.map { $0.email.lowercased() } + m.deliveredTo
        if ordered.contains(primary) { return primary }
        if m.folder == folder(.sent)?.path, mine.contains(m.fromEmail.lowercased()) { return m.fromEmail.lowercased() }
        return ordered.first { mine.contains($0) } ?? primary
    }

    private func unique(_ list: [MailAddress]) -> [MailAddress] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.email.lowercased()).inserted }
    }

    private static func prefixed(_ prefix: String, _ subject: String) -> String {
        let lower = subject.lowercased()
        let existing = prefix == "Re:" ? ["re:", "aw:", "sv:"] : ["fwd:", "fw:", "wg:"]
        return existing.contains(where: lower.hasPrefix) ? subject : "\(prefix) \(subject)"
    }

    func loadContacts() {
        var seen = Set<String>()
        let sent = folder(.sent).map { repo.sentRecipients(sentFolder: $0.path) } ?? []
        contacts = (sent + repo.contacts()).filter {
            let key = $0.email.lowercased()
            return !key.contains("noreply") && !key.contains("no-reply") && seen.insert(key).inserted
        }
    }

    func send(_ d: ComposeDraft) async -> Bool {
        guard let engine, let account else { return false }
        d.error = nil
        let to = MailAddress.parseList(d.to), cc = MailAddress.parseList(d.cc), bcc = MailAddress.parseList(d.bcc)
        let typed = [d.to, d.cc, d.bcc].flatMap { $0.split(separator: ",") }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        guard !(to + cc + bcc).isEmpty else { d.error = "Add at least one recipient."; return false }
        guard typed == (to + cc + bcc).count else { d.error = "One of the addresses doesn’t look right."; return false }

        let alias = addresses.first { $0.email == d.fromEmail.lowercased() }
        let fromName = (alias?.name.isEmpty == false ? alias!.name : account.displayName)
        let outgoing = OutgoingMessage(from: MailAddress(name: fromName, email: d.fromEmail), to: to, cc: cc, bcc: bcc,
                                       subject: d.subject, body: d.fullBody, inReplyTo: d.inReplyTo, references: d.references,
                                       attachments: d.attachments)
        let (bytes, _) = MessageBuilder.build(outgoing)
        d.isSending = true
        defer { d.isSending = false }
        do {
            try await engine.smtp().send(bytes, from: d.fromEmail, to: outgoing.allRecipients)
        } catch {
            d.error = error.localizedDescription
            return false
        }
        var extra: [String] = []
        if saveToSent, account.serverSavesSent == false, let sent = folder(.sent) {
            try? await engine.append(to: sent.path, message: bytes, flags: ["\\Seen"])
            extra.append(sent.path)
        }
        if let rid = d.replyingTo, message(rid) != nil {
            applyFlag([rid], column: "answered", flag: "\\Answered", value: true)
        }
        showToast("Message sent", symbol: "paperplane.fill")
        drafts[d.id] = nil
        Task { await sync(full: false, extra: extra) }
        return true
    }

    // MARK: Attachments

    func open(_ a: Attachment) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Letterbox/\(a.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Self.safeFilename(a.filename))
        do {
            try a.data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch { show(error) }
    }

    func save(_ a: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.safeFilename(a.filename)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try a.data.write(to: url) } catch { show(error) }
    }

    private static func safeFilename(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Attachment" : cleaned
    }

    // MARK: Feedback

    func showToast(_ message: String, symbol: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = Toast(message: message, symbol: symbol) }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    func show(_ error: Error) {
        showToast(Self.friendly(error), symbol: "exclamationmark.triangle.fill")
    }
}
