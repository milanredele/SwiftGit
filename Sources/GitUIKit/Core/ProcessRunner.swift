import Foundation

/// Locates command line tools and builds the environment for child processes.
/// GUI apps start with a minimal PATH, so the user's login-shell PATH is
/// resolved once in the background (Homebrew git/gh, node for hooks, …).
enum Tooling {
    private static let lock = NSLock()
    private static var _path: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    private static var cache: [String: String] = [:]

    static var path: [String] {
        lock.lock(); defer { lock.unlock() }
        return _path
    }

    static func loadLoginShellPath() {
        DispatchQueue.global(qos: .utility).async {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = ["-ilc", "printf '__GITUI_PATH__%s__END__' \"$PATH\""]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if p.isRunning { p.terminate() }
            }
            let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            let s = String(decoding: data, as: UTF8.self)
            guard let r1 = s.range(of: "__GITUI_PATH__"),
                  let r2 = s.range(of: "__END__", range: r1.upperBound..<s.endIndex) else { return }
            let parts = s[r1.upperBound..<r2.lowerBound].split(separator: ":").map(String.init)
            lock.lock()
            var merged: [String] = []
            for d in parts + _path where !d.isEmpty && !merged.contains(d) { merged.append(d) }
            _path = merged
            cache.removeAll()
            lock.unlock()
        }
    }

    static func find(_ tool: String) -> String? {
        lock.lock()
        if let c = cache[tool] { lock.unlock(); return c }
        let dirs = _path
        lock.unlock()
        for dir in dirs {
            let p = dir + "/" + tool
            if FileManager.default.isExecutableFile(atPath: p) {
                lock.lock(); cache[tool] = p; lock.unlock()
                return p
            }
        }
        return nil
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path.joined(separator: ":")
        env["GIT_TERMINAL_PROMPT"] = "0"     // never hang waiting for a password prompt
        env["GIT_EDITOR"] = "true"           // never open an editor (merge, rebase --continue)
        env["GIT_OPTIONAL_LOCKS"] = "0"      // status must not write the index (FSEvents loop)
        env["GIT_PAGER"] = "cat"
        env["PAGER"] = "cat"
        env["GH_PAGER"] = "cat"
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        return env
    }
}

struct RunResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: String

    var ok: Bool { status == 0 }
    var output: String { String(decoding: stdout, as: UTF8.self) }
    var errorMessage: String {
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return e }
        let o = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return o.isEmpty ? "Command failed with exit code \(status)" : o
    }
}

/// Lets the UI interrupt a running command (SIGINT, like Ctrl-C).
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var isCancelled = false

    func attach(_ p: Process) {
        lock.lock(); process = p; let c = isCancelled; lock.unlock()
        if c { p.interrupt() }
    }

    func cancel() {
        lock.lock(); isCancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { p.interrupt() }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

enum ProcessRunner {
    /// Runs a command off the main thread. If `onStdout` is given, stdout is
    /// streamed to it chunk by chunk and not accumulated in the result.
    static func run(executable: String,
                    arguments: [String],
                    cwd: URL?,
                    stdin: Data? = nil,
                    cancel: CancelToken? = nil,
                    onStdout: (@Sendable (Data) -> Void)? = nil,
                    onStderrLine: (@Sendable (String) -> Void)? = nil) async -> RunResult {
        await withCheckedContinuation { (cont: CheckedContinuation<RunResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = runBlocking(executable: executable, arguments: arguments, cwd: cwd, stdin: stdin,
                                    cancel: cancel, onStdout: onStdout, onStderrLine: onStderrLine)
                cont.resume(returning: r)
            }
        }
    }

    static func runBlocking(executable: String,
                            arguments: [String],
                            cwd: URL?,
                            stdin: Data?,
                            cancel: CancelToken?,
                            onStdout: (@Sendable (Data) -> Void)?,
                            onStderrLine: (@Sendable (String) -> Void)?) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let cwd { p.currentDirectoryURL = cwd }
        p.environment = Tooling.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { p.standardInput = inPipe } else { p.standardInput = FileHandle.nullDevice }

        do {
            try p.run()
        } catch {
            return RunResult(status: -1, stdout: Data(),
                             stderr: "Could not launch \(executable): \(error.localizedDescription)")
        }
        cancel?.attach(p)

        if let inPipe, let stdin {
            DispatchQueue.global().async {
                let fh = inPipe.fileHandleForWriting
                try? fh.write(contentsOf: stdin)
                try? fh.close()
            }
        }

        let out = DataBox()
        let err = DataBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            let fh = outPipe.fileHandleForReading
            while true {
                guard let chunk = try? fh.read(upToCount: 65536), !chunk.isEmpty else { break }
                if let onStdout { onStdout(chunk) } else { out.data.append(chunk) }
            }
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            let fh = errPipe.fileHandleForReading
            var pending = Data()
            while true {
                guard let chunk = try? fh.read(upToCount: 16384), !chunk.isEmpty else { break }
                err.data.append(chunk)
                if let onStderrLine {
                    pending.append(chunk)
                    // progress output uses \r, regular output \n
                    while let idx = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                        let line = String(decoding: pending[pending.startIndex..<idx], as: UTF8.self)
                        pending.removeSubrange(pending.startIndex...idx)
                        let t = line.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { onStderrLine(t) }
                    }
                }
            }
            group.leave()
        }

        group.wait()
        p.waitUntilExit()
        return RunResult(status: p.terminationStatus, stdout: out.data,
                         stderr: String(decoding: err.data, as: UTF8.self))
    }
}
