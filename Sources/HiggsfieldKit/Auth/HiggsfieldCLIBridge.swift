import Foundation

/// Locates and runs the official Higgsfield CLI (`hf` / `higgsfield`, from
/// `npm install -g @higgsfield/cli`). Only documented subcommands are used:
/// `hf auth token` and `hf auth login`.
public struct HiggsfieldCLIBridge: Sendable {
    public var executableURL: URL?
    public var environment: [String: String]

    public init(executableURL: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        self.executableURL = executableURL ?? Self.locate(environment: environment)
    }

    /// Search order: `HIGGSFIELD_CLI_PATH`, then `PATH`, then the usual
    /// Homebrew/npm global locations (GUI apps do not inherit a login shell's PATH).
    public static func locate(environment: [String: String], fileManager: FileManager = .default) -> URL? {
        if let explicit = environment["HIGGSFIELD_CLI_PATH"], fileManager.isExecutableFile(atPath: explicit) {
            return URL(fileURLWithPath: explicit)
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "\(home)/.npm-global/bin", "\(home)/.local/bin", "\(home)/.volta/bin",
            "\(home)/.bun/bin", "\(home)/Library/pnpm",
        ]
        if let nvm = try? fileManager.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node") {
            dirs += nvm.sorted().reversed().map { "\(home)/.nvm/versions/node/\($0)/bin" }
        }
        for dir in dirs {
            for name in ["hf", "higgsfield", "higgs"] {
                let path = (dir as NSString).appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    public var isInstalled: Bool { executableURL != nil }

    /// Runs `hf auth token`. The CLI refreshes an expired session itself.
    public func accessToken() async throws -> String {
        let result = try await run(["auth", "token"], timeout: 30)
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !token.isEmpty, !token.contains(" ") else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.localizedCaseInsensitiveContains("not authenticated") || detail.contains("auth login") {
                throw HiggsfieldError.notSignedIn
            }
            throw HiggsfieldError.cliUnavailable(detail.isEmpty ? "`hf auth token` failed (exit \(result.status))." : detail)
        }
        return token
    }

    /// Runs `hf auth login`, which opens the browser for Higgsfield's own sign-in page.
    public func login(timeout: TimeInterval = 300) async throws {
        let result = try await run(["auth", "login"], timeout: timeout)
        guard result.status == 0 else {
            throw HiggsfieldError.cliUnavailable(result.stderr.isEmpty ? "`hf auth login` failed." : result.stderr)
        }
    }

    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    func run(_ arguments: [String], timeout: TimeInterval) async throws -> Result {
        guard let executableURL else {
            throw HiggsfieldError.cliUnavailable(
                "The Higgsfield CLI isn’t installed. Install it with `npm install -g @higgsfield/cli`, then run `hf auth login`."
            )
        }
        var env = environment
        env["HIGGSFIELD_DISABLE_TELEMETRY"] = env["HIGGSFIELD_DISABLE_TELEMETRY"] ?? "1"
        let processEnvironment = env
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = processEnvironment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            process.terminationHandler = { p in
                timer.cancel()
                let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: Result(status: p.terminationStatus, stdout: stdout, stderr: stderr))
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            } catch {
                continuation.resume(throwing: HiggsfieldError.cliUnavailable("Couldn’t launch the Higgsfield CLI: \(error.localizedDescription)"))
            }
        }
    }
}
