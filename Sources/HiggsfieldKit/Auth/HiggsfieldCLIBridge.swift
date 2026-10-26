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
    ///
    /// `npm install -g @higgsfield/cli` installs `higgsfield`/`higgs` as a Node
    /// shim (`#!/usr/bin/env node`) that launches the native binary at
    /// `<package>/vendor/hf`. Apps started from Finder often can't find `node`,
    /// so the shim is resolved to that native binary whenever it exists.
    public static func locate(environment: [String: String], fileManager: FileManager = .default) -> URL? {
        if let explicit = environment["HIGGSFIELD_CLI_PATH"], fileManager.isExecutableFile(atPath: explicit) {
            return nativeBinary(for: URL(fileURLWithPath: explicit), fileManager: fileManager)
        }
        for dir in searchDirectories(environment: environment, fileManager: fileManager) {
            for name in ["hf", "higgsfield", "higgs"] {
                let path = (dir as NSString).appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: path) {
                    return nativeBinary(for: URL(fileURLWithPath: path), fileManager: fileManager)
                }
            }
        }
        return nil
    }

    static func searchDirectories(environment: [String: String], fileManager: FileManager = .default) -> [String] {
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
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    /// Maps an npm shim to the package's native `vendor/hf` binary.
    static func nativeBinary(for url: URL, fileManager: FileManager = .default) -> URL {
        let resolved = URL(fileURLWithPath: resolveSymlinks(url.path, fileManager: fileManager))
        guard resolved.pathExtension == "js" else { return url }
        // <package>/bin/higgsfield.js → <package>/vendor/hf
        let vendor = resolved.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor").appendingPathComponent("hf")
        return fileManager.isExecutableFile(atPath: vendor.path) ? vendor : url
    }

    /// Follows a chain of (possibly relative) symlinks, as npm creates them.
    static func resolveSymlinks(_ path: String, fileManager: FileManager = .default) -> String {
        var current = path
        for _ in 0..<16 {
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: current) else { break }
            let next = destination.hasPrefix("/")
                ? destination
                : ((current as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
            current = (next as NSString).standardizingPath
        }
        return current
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
        // If a shim is still used, let `/usr/bin/env node` find Node.
        env["PATH"] = Self.searchDirectories(environment: environment).joined(separator: ":")
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
            // Drain both pipes while the process runs so a chatty CLI can't
            // block on a full pipe buffer.
            let outBuffer = PipeBuffer(out), errBuffer = PipeBuffer(err)
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            process.terminationHandler = { p in
                timer.cancel()
                let stdout = String(decoding: outBuffer.finish(), as: UTF8.self)
                let stderr = String(decoding: errBuffer.finish(), as: UTF8.self)
                continuation.resume(returning: Result(status: p.terminationStatus, stdout: stdout, stderr: stderr))
            }
            do {
                try process.run()
                // Close this process's copies of the write ends so the readers see
                // end of file as soon as the CLI exits.
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            } catch {
                // Let the reader threads see end of file and exit.
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                continuation.resume(throwing: HiggsfieldError.cliUnavailable("Couldn’t launch the Higgsfield CLI: \(error.localizedDescription)"))
            }
        }
    }
}

/// Reads a pipe to the end on its own thread, so a chatty CLI never blocks on
/// a full pipe buffer, and `finish()` returns only once every byte is in.
///
/// An earlier version used `readabilityHandler`; a chunk could still be in
/// that handler when the process ended, so `finish()` sometimes returned an
/// empty token (seen once on 2026-10-26: "`hf auth token` failed (exit 0)").
private final class PipeBuffer: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()

    init(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        Thread.detachNewThread { [self] in
            data = handle.readDataToEndOfFile()
            done.signal()
        }
    }

    /// Waits for end of file (the process has exited and closed its end) and
    /// returns everything it wrote.
    func finish() -> Data {
        done.wait()
        return data
    }
}
