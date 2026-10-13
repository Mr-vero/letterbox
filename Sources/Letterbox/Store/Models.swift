import Foundation

struct Account: Codable, Equatable {
    var email: String
    var displayName: String
    var provider: String = "custom"
    var username: String = ""
    var imapHost = ""
    var imapPort: UInt16 = 993
    var imapSecurity: ConnectionSecurity = .tls
    var smtpHost = ""
    var smtpPort: UInt16 = 465
    var smtpSecurity: ConnectionSecurity = .tls
    /// Some providers (e.g. Gmail) file sent mail automatically.
    var serverSavesSent = false

    var loginName: String { username.isEmpty ? email : username }
    var address: MailAddress { MailAddress(name: displayName, email: email) }

    init(email: String, displayName: String) {
        self.email = email
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decode(String.self, forKey: .email)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "custom"
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        imapHost = try c.decodeIfPresent(String.self, forKey: .imapHost) ?? ""
        imapPort = try c.decodeIfPresent(UInt16.self, forKey: .imapPort) ?? 993
        imapSecurity = try c.decodeIfPresent(ConnectionSecurity.self, forKey: .imapSecurity) ?? .tls
        smtpHost = try c.decodeIfPresent(String.self, forKey: .smtpHost) ?? ""
        smtpPort = try c.decodeIfPresent(UInt16.self, forKey: .smtpPort) ?? 465
        smtpSecurity = try c.decodeIfPresent(ConnectionSecurity.self, forKey: .smtpSecurity) ?? .tls
        serverSavesSent = try c.decodeIfPresent(Bool.self, forKey: .serverSavesSent) ?? false
    }

    static func load() -> Account? {
        migrateLegacyDefaults()
        guard let data = UserDefaults.standard.data(forKey: "account") else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "account")
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: "account") }

    /// Early builds used a different bundle identifier; carry settings over once.
    private static func migrateLegacyDefaults() {
        let d = UserDefaults.standard
        guard d.data(forKey: "account") == nil, !d.bool(forKey: "migratedLegacyDefaults"),
              let legacy = UserDefaults(suiteName: "app.letterbox.mail") else { return }
        d.set(true, forKey: "migratedLegacyDefaults")
        for key in ["account", "briefing", "aiEnabled", "aiModel", "claudePath", "blockRemoteContent", "saveToSent", "signature"] {
            if let v = legacy.object(forKey: key) { d.set(v, forKey: key) }
        }
    }
}

enum FolderRole: String {
    case inbox, drafts, sent, archive, junk, trash, custom

    var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .drafts: return "doc"
        case .sent: return "paperplane"
        case .archive: return "archivebox"
        case .junk: return "xmark.bin"
        case .trash: return "trash"
        case .custom: return "folder"
        }
    }

    var order: Int {
        switch self {
        case .inbox: return 0
        case .drafts: return 2
        case .sent: return 3
        case .archive: return 4
        case .junk: return 5
        case .trash: return 6
        case .custom: return 10
        }
    }

    /// Folders whose contents shouldn't count as "mail I received".
    var isOutgoingOrDiscarded: Bool { self == .sent || self == .drafts || self == .trash || self == .junk }

    static func detect(path: String, attributes: Set<String>) -> FolderRole {
        if path.uppercased() == "INBOX" { return .inbox }
        if attributes.contains("\\sent") { return .sent }
        if attributes.contains("\\drafts") { return .drafts }
        if attributes.contains("\\trash") { return .trash }
        if attributes.contains("\\junk") { return .junk }
        if attributes.contains("\\archive") || attributes.contains("\\all") { return .archive }
        let name = ModifiedUTF7.decode(path).lowercased()
        switch name {
        case "sent", "sent items", "sent messages", "sent mail", "outbox sent", "gesendet": return .sent
        case "drafts", "draft", "entwürfe": return .drafts
        case "trash", "deleted", "deleted items", "deleted messages", "bin", "papierkorb": return .trash
        case "spam", "junk", "junk e-mail", "junk mail", "bulk mail", "unwanted": return .junk
        case "archive", "archives", "archiv": return .archive
        default: return .custom
        }
    }
}

struct Folder: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var name: String
    var delimiter: String?
    var role: FolderRole
    var total: Int
    var unread: Int

    var displayName: String {
        switch role {
        case .inbox: return "Inbox"
        case .custom: return name
        default: return name.prefix(1).uppercased() + name.dropFirst().lowercased()
        }
    }
}

struct MessageSummary: Identifiable, Hashable {
    let folder: String
    let uid: UInt32
    var messageID: String?
    var subject: String
    var fromName: String
    var fromEmail: String
    var to: [MailAddress]
    var cc: [MailAddress]
    var replyTo: [MailAddress]
    var deliveredTo: [String]
    var date: Date
    var seen: Bool
    var flagged: Bool
    var answered: Bool
    var size: Int
    var hasAttachments: Bool
    var snippet: String
    var inReplyTo: String?
    var references: String?

    var id: String { Self.makeID(folder, uid) }
    static func makeID(_ folder: String, _ uid: UInt32) -> String { "\(folder)\u{1}\(uid)" }

    var sender: MailAddress { MailAddress(name: fromName, email: fromEmail) }
    var senderDisplay: String { fromName.isEmpty ? (fromEmail.isEmpty ? "Unknown Sender" : fromEmail) : fromName }
    var displaySubject: String { subject.trimmingCharacters(in: .whitespaces).isEmpty ? "(No Subject)" : subject }

    /// All addresses this message was delivered to, lowercased.
    var recipientSet: Set<String> {
        Set((to + cc).map { $0.email.lowercased() } + deliveredTo)
    }
}

struct Alias: Identifiable, Hashable {
    var id: String { email }
    let email: String
    var name: String
    var isPrimary: Bool
    var isManual: Bool
    var unread: Int = 0
}

enum SidebarItem: Hashable {
    case dashboard
    case folder(String)
    case flagged
    case address(String)
}

// MARK: - Compact address list encoding for the cache

enum AddressCoding {
    static func encode(_ list: [MailAddress]) -> String {
        list.map { "\($0.name)\u{1F}\($0.email)" }.joined(separator: "\u{1E}")
    }

    static func decode(_ s: String) -> [MailAddress] {
        guard !s.isEmpty else { return [] }
        return s.split(separator: "\u{1E}").map { item in
            let parts = item.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            return parts.count == 2
                ? MailAddress(name: String(parts[0]), email: String(parts[1]))
                : MailAddress(name: "", email: String(item))
        }
    }
}
