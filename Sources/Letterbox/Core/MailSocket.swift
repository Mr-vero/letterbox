import Foundation

enum ConnectionSecurity: String, Codable, CaseIterable, Identifiable {
    case tls = "SSL/TLS"
    case startTLS = "STARTTLS"
    case none = "None"

    var id: String { rawValue }
}

/// A buffered socket for IMAP/SMTP that supports implicit TLS, STARTTLS upgrades,
/// and plain connections (local bridges). Blocking I/O runs on a private serial
/// queue; callers serialize commands (see `AsyncMutex`).
final class MailSocket: @unchecked Sendable {
    let host: String
    let port: UInt16
    private let readTimeout: TimeInterval
    private let queue = DispatchQueue(label: "letterbox.socket", qos: .userInitiated)
    private let watchdog = DispatchQueue(label: "letterbox.socket.watchdog")
    private var input: InputStream?
    private var output: OutputStream?
    private var buffer: [UInt8] = []
    private var start = 0

    /// Self-signed certificates are accepted only for local bridges (e.g. Proton Mail Bridge).
    private var isLocal: Bool { ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()) }

    init(host: String, port: UInt16, readTimeout: TimeInterval = 60) {
        self.host = host
        self.port = port
        self.readTimeout = readTimeout
    }

    deinit { closeStreams() }

    func open(tls: Bool) async throws {
        try await run {
            var r: InputStream?
            var w: OutputStream?
            Stream.getStreamsToHost(withName: self.host, port: Int(self.port), inputStream: &r, outputStream: &w)
            guard let r, let w else { throw NetError.connectionFailed("Couldn’t create a connection to \(self.host).") }
            if tls { self.applyTLS(r, w) }
            r.open()
            w.open()
            let deadline = Date().addingTimeInterval(20)
            while r.streamStatus == .opening || w.streamStatus == .opening {
                if Date() > deadline { r.close(); w.close(); throw NetError.connectionFailed("Timed out connecting to \(self.host):\(self.port).") }
                usleep(5_000)
            }
            if let e = r.streamError ?? w.streamError, r.streamStatus == .error || w.streamStatus == .error {
                throw NetError.connectionFailed(e.localizedDescription)
            }
            self.input = r
            self.output = w
        }
    }

    /// Upgrades an established plain connection to TLS (after a STARTTLS exchange).
    func startTLS() async throws {
        try await run {
            guard let r = self.input, let w = self.output else { throw NetError.closed }
            guard self.start == self.buffer.count else { throw NetError.connectionFailed("Unexpected data before TLS negotiation.") }
            self.applyTLS(r, w)
        }
    }

    private func applyTLS(_ r: InputStream, _ w: OutputStream) {
        r.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        w.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        var settings: [String: Any] = [kCFStreamSSLPeerName as String: host]
        if isLocal { settings[kCFStreamSSLValidatesCertificateChain as String] = false }
        let key = CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings)
        CFReadStreamSetProperty(r as CFReadStream, key, settings as CFDictionary)
        CFWriteStreamSetProperty(w as CFWriteStream, key, settings as CFDictionary)
    }

    func send(_ bytes: [UInt8]) async throws {
        try await run {
            guard let w = self.output else { throw NetError.closed }
            var offset = 0
            try bytes.withUnsafeBufferPointer { p in
                while offset < bytes.count {
                    let n = w.write(p.baseAddress! + offset, maxLength: bytes.count - offset)
                    if n <= 0 { throw w.streamError.map { NetError.connectionFailed($0.localizedDescription) } ?? NetError.closed }
                    offset += n
                }
            }
        }
    }

    func send(_ string: String) async throws {
        try await send(Array(string.utf8))
    }

    /// Reads one line, stripping the trailing CRLF.
    func readLine() async throws -> [UInt8] {
        try await run {
            var scan = self.start
            while true {
                var i = scan
                while i + 1 < self.buffer.count {
                    if self.buffer[i] == 13 && self.buffer[i + 1] == 10 {
                        let line = Array(self.buffer[self.start..<i])
                        self.start = i + 2
                        self.compact()
                        return line
                    }
                    i += 1
                }
                scan = max(self.start, self.buffer.count - 1)
                try self.fill()
            }
        }
    }

    func readBytes(_ count: Int) async throws -> [UInt8] {
        try await run {
            while self.buffer.count - self.start < count { try self.fill() }
            let out = Array(self.buffer[self.start..<(self.start + count)])
            self.start += count
            self.compact()
            return out
        }
    }

    func close() {
        queue.async { self.closeStreams() }
    }

    // MARK: Internals (run on `queue`)

    private func closeStreams() {
        input?.close()
        output?.close()
        input = nil
        output = nil
    }

    private func compact() {
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 1 << 16 {
            buffer.removeFirst(start)
            start = 0
        }
    }

    private func fill() throws {
        guard let r = input else { throw NetError.closed }
        let timeout = DispatchWorkItem { [weak r] in r?.close() }
        watchdog.asyncAfter(deadline: .now() + readTimeout, execute: timeout)
        defer { timeout.cancel() }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = r.read(&chunk, maxLength: chunk.count)
        if n > 0 {
            buffer.append(contentsOf: chunk[0..<n])
        } else if n == 0 {
            throw NetError.closed
        } else {
            throw r.streamError.map { NetError.connectionFailed($0.localizedDescription) } ?? NetError.closed
        }
    }

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }
}
