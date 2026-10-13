import Foundation

struct SMTPError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal SMTP submission client supporting implicit TLS and STARTTLS.
struct SMTPClient {
    let host: String
    let port: UInt16
    var security: ConnectionSecurity = .tls
    let username: String
    let password: String

    func send(_ message: [UInt8], from: String, to recipients: [String]) async throws {
        guard !recipients.isEmpty else { throw SMTPError(message: "Add at least one recipient.") }
        let stream = MailSocket(host: host, port: port, readTimeout: 90)
        defer { stream.close() }
        try await stream.open(tls: security == .tls)

        _ = try await expect(stream, 220)
        try await stream.send("EHLO letterbox.local\r\n")
        var ehlo = try await expect(stream, 250)
        if security == .startTLS {
            try await stream.send("STARTTLS\r\n")
            _ = try await expect(stream, 220, context: "The server refused STARTTLS")
            try await stream.startTLS()
            try await stream.send("EHLO letterbox.local\r\n")
            ehlo = try await expect(stream, 250)
        }
        let auth = ehlo.first { $0.uppercased().hasPrefix("AUTH") }?.uppercased() ?? "AUTH PLAIN LOGIN"

        if auth.contains("PLAIN") {
            let token = Data(([0] + Array(username.utf8) + [0] + Array(password.utf8))).base64EncodedString()
            try await stream.send("AUTH PLAIN \(token)\r\n")
            _ = try await expect(stream, 235, context: "Sign-in to the outgoing server failed")
        } else {
            try await stream.send("AUTH LOGIN\r\n")
            _ = try await expect(stream, 334)
            try await stream.send(Data(username.utf8).base64EncodedString() + "\r\n")
            _ = try await expect(stream, 334)
            try await stream.send(Data(password.utf8).base64EncodedString() + "\r\n")
            _ = try await expect(stream, 235, context: "Sign-in to the outgoing server failed")
        }

        try await stream.send("MAIL FROM:<\(from)>\r\n")
        _ = try await expect(stream, 250, context: "The server refused the sender \(from)")
        for r in recipients {
            try await stream.send("RCPT TO:<\(r)>\r\n")
            _ = try await expect(stream, [250, 251], context: "The server refused the recipient \(r)")
        }
        try await stream.send("DATA\r\n")
        _ = try await expect(stream, 354)
        try await stream.send(dotStuff(message) + Array("\r\n.\r\n".utf8))
        _ = try await expect(stream, 250, context: "The server didn’t accept the message")
        try? await stream.send("QUIT\r\n")
    }

    private func dotStuff(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 64)
        var atLineStart = true
        for b in bytes {
            if atLineStart && b == 46 { out.append(46) }
            out.append(b)
            atLineStart = b == 10
        }
        while out.last == 10 || out.last == 13 { out.removeLast() }
        return out
    }

    private func expect(_ stream: MailSocket, _ code: Int, context: String? = nil) async throws -> [String] {
        try await expect(stream, [code], context: context)
    }

    /// Reads a (possibly multi-line) reply and returns the text of each line.
    private func expect(_ stream: MailSocket, _ codes: [Int], context: String? = nil) async throws -> [String] {
        var lines: [String] = []
        var code = 0
        while true {
            let line = String(decoding: try await stream.readLine(), as: UTF8.self)
            code = Int(line.prefix(3)) ?? 0
            lines.append(String(line.dropFirst(4)))
            if line.count < 4 || line[line.index(line.startIndex, offsetBy: 3)] != "-" { break }
        }
        guard codes.contains(code) else {
            let detail = lines.joined(separator: " ")
            throw SMTPError(message: [context, detail].compactMap { $0 }.joined(separator: ": "))
        }
        return lines
    }
}
