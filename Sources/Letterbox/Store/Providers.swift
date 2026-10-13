import Foundation

/// Connection presets for common providers. Anything else works through "Other".
struct MailProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let domains: [String]
    let imapHost: String
    let imapPort: UInt16
    let imapSecurity: ConnectionSecurity
    let smtpHost: String
    let smtpPort: UInt16
    let smtpSecurity: ConnectionSecurity
    var serverSavesSent = false
    let passwordLabel: String
    let help: String
    var helpURL: URL?
    var usesSeparateUsername = false

    static let gmail = MailProvider(
        id: "gmail", name: "Gmail", domains: ["gmail.com", "googlemail.com"],
        imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "smtp.gmail.com", smtpPort: 465, smtpSecurity: .tls, serverSavesSent: true,
        passwordLabel: "App password",
        help: "Google requires an app password: turn on 2-Step Verification, then create one for “Letterbox”.",
        helpURL: URL(string: "https://myaccount.google.com/apppasswords"))

    static let icloud = MailProvider(
        id: "icloud", name: "iCloud Mail", domains: ["icloud.com", "me.com", "mac.com"],
        imapHost: "imap.mail.me.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "smtp.mail.me.com", smtpPort: 587, smtpSecurity: .startTLS,
        passwordLabel: "App-specific password",
        help: "Create an app-specific password under Sign-In and Security in your Apple Account.",
        helpURL: URL(string: "https://account.apple.com/account/manage"))

    static let fastmail = MailProvider(
        id: "fastmail", name: "Fastmail", domains: ["fastmail.com", "fastmail.fm"],
        imapHost: "imap.fastmail.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "smtp.fastmail.com", smtpPort: 465, smtpSecurity: .tls,
        passwordLabel: "App password",
        help: "Create an app password with IMAP and SMTP access in Settings → Privacy & Security.",
        helpURL: URL(string: "https://app.fastmail.com/settings/security/apps"))

    static let yahoo = MailProvider(
        id: "yahoo", name: "Yahoo Mail", domains: ["yahoo.com", "ymail.com", "rocketmail.com"],
        imapHost: "imap.mail.yahoo.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "smtp.mail.yahoo.com", smtpPort: 465, smtpSecurity: .tls,
        passwordLabel: "App password",
        help: "Generate an app password in Account Security.",
        helpURL: URL(string: "https://login.yahoo.com/account/security"))

    static let mailcom = MailProvider(
        id: "mailcom", name: "mail.com", domains: Array(AliasDetector.mailComDomains),
        imapHost: "imap.mail.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "smtp.mail.com", smtpPort: 465, smtpSecurity: .tls,
        passwordLabel: "Password",
        help: "Turn on IMAP in Settings → POP3 & IMAP. With two-factor authentication, use an application-specific password from My Account → Security Options.",
        helpURL: URL(string: "https://www.mail.com"))

    static let gmx = MailProvider(
        id: "gmx", name: "GMX", domains: ["gmx.com", "gmx.us"],
        imapHost: "imap.gmx.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "mail.gmx.com", smtpPort: 465, smtpSecurity: .tls,
        passwordLabel: "Password",
        help: "Turn on IMAP in Settings → POP3 & IMAP. With two-factor authentication, use an application-specific password.")

    static let zoho = MailProvider(
        id: "zoho", name: "Zoho Mail", domains: ["zoho.com", "zohomail.com"],
        imapHost: "imap.zoho.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "smtp.zoho.com", smtpPort: 465, smtpSecurity: .tls,
        passwordLabel: "App password",
        help: "Enable IMAP access in Zoho Mail settings and create an application-specific password.",
        helpURL: URL(string: "https://accounts.zoho.com/home#security/app_password"))

    static let aol = MailProvider(
        id: "aol", name: "AOL", domains: ["aol.com"],
        imapHost: "imap.aol.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "smtp.aol.com", smtpPort: 465, smtpSecurity: .tls,
        passwordLabel: "App password",
        help: "Generate an app password in Account Security.",
        helpURL: URL(string: "https://login.aol.com/account/security"))

    static let proton = MailProvider(
        id: "proton", name: "Proton Bridge", domains: ["proton.me", "protonmail.com", "pm.me"],
        imapHost: "127.0.0.1", imapPort: 1143, imapSecurity: .startTLS,
        smtpHost: "127.0.0.1", smtpPort: 1025, smtpSecurity: .startTLS, serverSavesSent: true,
        passwordLabel: "Bridge password",
        help: "Run Proton Mail Bridge, then copy the username and password it shows for this account.",
        helpURL: URL(string: "https://proton.me/mail/bridge"), usesSeparateUsername: true)

    static let custom = MailProvider(
        id: "custom", name: "Other", domains: [],
        imapHost: "", imapPort: 993, imapSecurity: .tls,
        smtpHost: "", smtpPort: 465, smtpSecurity: .tls,
        passwordLabel: "Password",
        help: "Use the IMAP and SMTP settings from your provider. Many providers require an app password when two-factor authentication is on.")

    static let all: [MailProvider] = [gmail, icloud, fastmail, yahoo, mailcom, gmx, zoho, aol, proton, custom]

    static func byID(_ id: String) -> MailProvider { all.first { $0.id == id } ?? custom }

    static func detect(email: String) -> MailProvider? {
        guard let domain = email.split(separator: "@").last?.lowercased(), !domain.isEmpty else { return nil }
        return all.first { $0.domains.contains(domain) }
    }

    /// Reasonable guesses for an unknown domain.
    static func guess(email: String) -> (imap: String, smtp: String) {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        return domain.isEmpty ? ("", "") : ("imap.\(domain)", "smtp.\(domain)")
    }

    func apply(to account: inout Account) {
        account.provider = id
        account.imapHost = imapHost
        account.imapPort = imapPort
        account.imapSecurity = imapSecurity
        account.smtpHost = smtpHost
        account.smtpPort = smtpPort
        account.smtpSecurity = smtpSecurity
        account.serverSavesSent = serverSavesSent
    }
}
