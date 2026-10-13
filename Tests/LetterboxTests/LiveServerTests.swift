import XCTest
@testable import Letterbox

/// Unauthenticated probes of real providers. Run with LETTERBOX_LIVE=1.
final class LiveServerTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LETTERBOX_LIVE"] == "1")
    }

    private func imapGreeting(_ host: String) async throws -> String {
        let s = MailSocket(host: host, port: 993, readTimeout: 15)
        try await s.open(tls: true)
        defer { s.close() }
        let greeting = String(decoding: try await s.readLine(), as: UTF8.self)
        try await s.send("a1 CAPABILITY\r\n")
        var caps = ""
        while true {
            let line = String(decoding: try await s.readLine(), as: UTF8.self)
            if line.hasPrefix("* CAPABILITY") { caps = line }
            if line.hasPrefix("a1 ") { break }
        }
        return greeting + "\n  " + caps
    }

    func testImplicitTLSIMAP() async throws {
        for host in ["imap.mail.com", "imap.gmail.com", "imap.mail.me.com", "imap.fastmail.com"] {
            let g = try await imapGreeting(host)
            print("IMAP \(host): \(g.prefix(160))")
            XCTAssertTrue(g.hasPrefix("* OK"), host)
        }
    }

    private func smtpLines(_ s: MailSocket) async throws -> [String] {
        var lines: [String] = []
        while true {
            let line = String(decoding: try await s.readLine(), as: UTF8.self)
            lines.append(line)
            if line.count < 4 || line[line.index(line.startIndex, offsetBy: 3)] != "-" { return lines }
        }
    }

    func testSTARTTLSSMTP() async throws {
        for host in ["smtp.gmail.com", "smtp.mail.me.com", "smtp.mail.com"] {
            let s = MailSocket(host: host, port: 587, readTimeout: 15)
            try await s.open(tls: false)
            _ = try await smtpLines(s)
            try await s.send("EHLO letterbox.local\r\n")
            let before = try await smtpLines(s)
            XCTAssertTrue(before.contains { $0.uppercased().contains("STARTTLS") }, host)
            try await s.send("STARTTLS\r\n")
            let ready = try await smtpLines(s)
            XCTAssertTrue(ready.first?.hasPrefix("220") == true, host)
            try await s.startTLS()
            try await s.send("EHLO letterbox.local\r\n")
            let after = try await smtpLines(s)
            print("SMTP \(host) after TLS:", after.filter { $0.contains("AUTH") })
            XCTAssertTrue(after.contains { $0.contains("AUTH") }, host)
            try await s.send("QUIT\r\n")
            s.close()
        }
    }

    func testImplicitTLSSMTP() async throws {
        let s = MailSocket(host: "smtp.mail.com", port: 465, readTimeout: 15)
        try await s.open(tls: true)
        let greeting = String(decoding: try await s.readLine(), as: UTF8.self)
        XCTAssertTrue(greeting.hasPrefix("220"))
        s.close()
    }
}
