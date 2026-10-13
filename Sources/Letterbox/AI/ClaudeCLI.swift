import Foundation

struct ClaudeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs the local `claude` CLI in non-interactive print mode with all tools disabled,
/// so it acts purely as a language model over the text we hand it.
final class ClaudeCLI: @unchecked Sendable {
    let executable: URL
    var model: String

    init(executable: URL, model: String) {
        self.executable = executable
        self.model = model
    }

    /// Finds the CLI in the usual install locations, then via a login shell.
    static func locate(preferred: String? = nil) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [preferred].compactMap { $0 }.filter { !$0.isEmpty }
        candidates += ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude"]
        for c in candidates where fm.isExecutableFile(atPath: c) { return URL(fileURLWithPath: c) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty || !fm.isExecutableFile(atPath: out) ? nil : URL(fileURLWithPath: out)
    }

    private static let workDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("letterbox-claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func baseArguments(system: String) -> [String] {
        ["-p", "--tools", "", "--no-session-persistence", "--strict-mcp-config",
         "--setting-sources", "", "--model", model, "--system-prompt", system]
    }

    private func makeProcess(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        p.currentDirectoryURL = Self.workDir
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["CLAUDE_CODE_ENTRYPOINT"] = "letterbox"
        p.environment = env
        return p
    }

    /// One-shot call returning schema-validated JSON decoded into `T`.
    func structured<T: Decodable>(_ type: T.Type, prompt: String, system: String, schema: String) async throws -> T {
        let args = baseArguments(system: system) + ["--output-format", "json", "--json-schema", schema]
        let data = try await run(args, input: prompt)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError(message: "Claude returned an unreadable response.")
        }
        if obj["is_error"] as? Bool == true {
            throw ClaudeError(message: (obj["result"] as? String) ?? "Claude reported an error.")
        }
        let payload: Any
        if let s = obj["structured_output"] {
            payload = s
        } else if let r = obj["result"] as? String, let d = r.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: d) {
            payload = parsed
        } else {
            throw ClaudeError(message: "Claude didn’t return structured data.")
        }
        let json = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(T.self, from: json)
    }

    /// Streams text deltas as Claude writes.
    func stream(prompt: String, system: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let args = baseArguments(system: system) + ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
            let p = makeProcess(args)
            let input = Pipe(), output = Pipe(), errors = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = errors
            var buffer = Data()
            var sawText = false
            var failure: String?

            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 10) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if obj["type"] as? String == "stream_event",
                       let event = obj["event"] as? [String: Any],
                       let delta = event["delta"] as? [String: Any],
                       delta["type"] as? String == "text_delta",
                       let text = delta["text"] as? String {
                        sawText = true
                        continuation.yield(text)
                    } else if obj["type"] as? String == "result", obj["is_error"] as? Bool == true {
                        failure = (obj["result"] as? String) ?? "Claude reported an error."
                    }
                }
            }
            p.terminationHandler = { proc in
                output.fileHandleForReading.readabilityHandler = nil
                if let failure {
                    continuation.finish(throwing: ClaudeError(message: failure))
                } else if proc.terminationStatus != 0 && !sawText {
                    let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    continuation.finish(throwing: ClaudeError(message: Self.clean(err) ?? "Claude exited with status \(proc.terminationStatus)."))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in if p.isRunning { p.terminate() } }
            do {
                try p.run()
                input.fileHandleForWriting.write(Data(prompt.utf8))
                try? input.fileHandleForWriting.close()
            } catch {
                continuation.finish(throwing: ClaudeError(message: "Couldn’t start Claude: \(error.localizedDescription)"))
            }
        }
    }

    private func run(_ args: [String], input: String) async throws -> Data {
        let p = makeProcess(args)
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let collected = DataBox()
                outPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if !d.isEmpty { collected.append(d) }
                }
                p.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    collected.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    if proc.terminationStatus == 0 || !collected.data.isEmpty {
                        cont.resume(returning: collected.data)
                    } else {
                        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        cont.resume(throwing: ClaudeError(message: Self.clean(err) ?? "Claude exited with status \(proc.terminationStatus)."))
                    }
                }
                do {
                    try p.run()
                    inPipe.fileHandleForWriting.write(Data(input.utf8))
                    try? inPipe.fileHandleForWriting.close()
                } catch {
                    cont.resume(throwing: ClaudeError(message: "Couldn’t start Claude: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(300))
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ d: Data) { lock.lock(); storage.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}
