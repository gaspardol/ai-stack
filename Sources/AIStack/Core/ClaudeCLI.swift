import Foundation

/// How a request should be run by the Claude Code CLI.
struct ClaudeRequestConfig: Hashable {
    var model: String
    var systemPrompt: String
    var effort: String? = nil
    var disableThinking = false
    /// Keep a pre-started process ready so the next request skips CLI start-up (~1.5s).
    var keepWarm = false
}

enum ClaudeError: LocalizedError {
    case notInstalled
    case failed(String)
    case timeout
    case api(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Claude Code CLI not found. Install it (claude.com/claude-code) and run `claude` once to log in."
        case .failed(let message): return message
        case .timeout: return "Claude took too long to respond."
        case .api(let message): return message
        }
    }
}

/// Runs prompts through the `claude` CLI in print mode, so every request is billed to the
/// user's Claude subscription (the CLI's own login) rather than an API key.
///
/// Each request gets a fresh process (no conversation history accumulates). For latency-sensitive
/// configs a process is started ahead of time and sits waiting on stdin.
final class ClaudeCLI {
    static let shared = ClaudeCLI()

    private let lock = NSLock()
    private var warm: [ClaudeRequestConfig: ClaudeProcess] = [:]
    private var cachedBinary: String?

    static let workDir: URL = {
        let url = AppPaths.support.appendingPathComponent("claude-workdir", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func binaryPath() -> String? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "claude.path"), !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) { return expanded }
        }
        lock.lock()
        let cached = cachedBinary
        lock.unlock()
        if let cached, fm.isExecutableFile(atPath: cached) { return cached }

        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
        ]
        var found = candidates.first { fm.isExecutableFile(atPath: $0) }
        if found == nil, let out = Shell.run("/bin/zsh", ["-lc", "command -v claude"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), fm.isExecutableFile(atPath: out) {
            found = out
        }
        lock.lock()
        cachedBinary = found
        lock.unlock()
        return found
    }

    func complete(_ prompt: String, config: ClaudeRequestConfig, timeout: TimeInterval) async throws -> String {
        guard let binary = binaryPath() else { throw ClaudeError.notInstalled }
        lock.lock()
        let ready = warm.removeValue(forKey: config)
        lock.unlock()
        let process: ClaudeProcess
        if let ready, ready.isFresh {
            process = ready
        } else {
            ready?.terminate()
            process = try ClaudeProcess(binary: binary, config: config)
        }
        if config.keepWarm { prewarm(config) }
        return try await process.send(prompt, timeout: timeout)
    }

    func prewarm(_ config: ClaudeRequestConfig) {
        guard let binary = binaryPath() else { return }
        lock.lock()
        defer { lock.unlock() }
        if let existing = warm[config], existing.isFresh { return }
        warm[config]?.terminate()
        warm[config] = try? ClaudeProcess(binary: binary, config: config)
    }

    func invalidateWarm() {
        lock.lock()
        let all = Array(warm.values)
        warm.removeAll()
        lock.unlock()
        all.forEach { $0.terminate() }
    }

    /// `claude auth status` → (logged in, human readable summary)
    func authStatus() async -> (ok: Bool, summary: String) {
        guard let binary = binaryPath() else { return (false, "Claude Code CLI not found") }
        return await Task.detached {
            guard let out = Shell.run(binary, ["auth", "status"]),
                  let start = out.firstIndex(of: "{"), let end = out.lastIndex(of: "}"),
                  let data = String(out[start...end]).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (false, "Could not read Claude login status")
            }
            let loggedIn = json["loggedIn"] as? Bool ?? false
            guard loggedIn else { return (false, "Not logged in — run `claude` in Terminal and log in") }
            let plan = (json["subscriptionType"] as? String).map { " · \($0.capitalized) plan" } ?? ""
            let email = json["email"] as? String ?? "logged in"
            return (true, "\(email)\(plan)")
        }.value
    }
}

/// One `claude -p --input-format stream-json` process that answers exactly one prompt.
final class ClaudeProcess {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let queue = DispatchQueue(label: "aistack.claude.process")
    private var buffer = Data()
    private var stderrData = Data()
    private var continuation: CheckedContinuation<String, Error>?
    private var earlyFailure: Error?
    private var finished = false
    private let created = Date()

    var isFresh: Bool {
        let state = queue.sync { !finished && earlyFailure == nil }
        return state && process.isRunning && Date().timeIntervalSince(created) < 20 * 60
    }

    init(binary: String, config: ClaudeRequestConfig) throws {
        process.executableURL = URL(fileURLWithPath: binary)
        var args = [
            "-p", "--model", config.model,
            "--tools", "", "--strict-mcp-config", "--no-session-persistence", "--no-chrome",
            "--setting-sources", "", "--disable-slash-commands",
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--system-prompt", config.systemPrompt,
        ]
        if let effort = config.effort { args += ["--effort", effort] }
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = [env["PATH"], "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .compactMap { $0 }.joined(separator: ":")
        if config.disableThinking { env["MAX_THINKING_TOKENS"] = "0" }
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env
        process.currentDirectoryURL = ClaudeCLI.workDir
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.queue.async { self?.consume(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.queue.async {
                guard let self, self.stderrData.count < 20_000 else { return }
                self.stderrData.append(data)
            }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            // Give stdout a moment to drain before deciding the process died without answering.
            self?.queue.asyncAfter(deadline: .now() + 0.4) { self?.exited(status) }
        }
        try process.run()
    }

    func send(_ prompt: String, timeout: TimeInterval) async throws -> String {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": prompt]]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        let writer = stdinPipe.fileHandleForWriting

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                queue.async {
                    if let failure = self.earlyFailure { cont.resume(throwing: failure); return }
                    self.continuation = cont
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try writer.write(contentsOf: data)
                        } catch {
                            self.queue.async {
                                self.finish(.failure(ClaudeError.failed("Could not reach the Claude CLI: \(error.localizedDescription)")))
                            }
                        }
                    }
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        guard let self, self.continuation != nil else { return }
                        self.finish(.failure(ClaudeError.timeout))
                        self.terminate()
                    }
                }
            }
        } onCancel: {
            queue.async {
                self.finish(.failure(CancellationError()))
                self.terminate()
            }
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "result" else { continue }
            let text = object["result"] as? String ?? ""
            if (object["is_error"] as? Bool) == true {
                let detail = text.isEmpty
                    ? ((object["errors"] as? [String])?.joined(separator: "; ") ?? (object["subtype"] as? String ?? "Unknown error"))
                    : text
                finish(.failure(ClaudeError.api(detail)))
            } else {
                finish(.success(text))
            }
            try? stdinPipe.fileHandleForWriting.close()
        }
    }

    private func finish(_ result: Result<String, Error>) {
        finished = true
        guard let cont = continuation else {
            if case .failure(let error) = result, earlyFailure == nil { earlyFailure = error }
            return
        }
        continuation = nil
        cont.resume(with: result)
    }

    private func exited(_ status: Int32) {
        guard !finished || continuation != nil else { return }
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Log.error("claude exited with \(status): \(stderr.suffix(500))", "claude")
        finish(.failure(ClaudeError.failed("Claude CLI exited (code \(status)). \(stderr.suffix(300))")))
    }

    deinit { terminate() }
}

enum Shell {
    /// Runs a command synchronously and returns stdout. Call off the main thread.
    static func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = ClaudeCLI.workDir
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
