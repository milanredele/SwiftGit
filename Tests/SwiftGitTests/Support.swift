import AppKit
import Foundation
import Testing
@testable import SwiftGitKit

/// Test-run safety net: unbuffered output (so a log shows where a run stopped)
/// and a watchdog that ends a hung run instead of blocking the dev loop.
enum Watchdog {
    /// Ends the run when no test has made progress for this long (a hang), or
    /// after `totalLimit` in any case. Progress-based, because CI machines run
    /// the suite several times slower than a developer Mac.
    static let idleLimit: TimeInterval = 120
    static let totalLimit: TimeInterval = 900
    nonisolated(unsafe) private static var lastBeat = Date()
    private static let lock = NSLock()

    /// Called by fixtures and waits: the run is still moving.
    static func beat() {
        lock.lock(); lastBeat = Date(); lock.unlock()
    }

    private static var idle: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastBeat)
    }

    static let start: Void = {
        beat()
        let started = Date()
        setvbuf(stdout, nil, _IONBF, 0)
        // On a Swift runtime trap, print the stack of the crashing thread (debug aid).
        for sig in [SIGTRAP, SIGSEGV, SIGBUS] {
            signal(sig) { s in
                let trace = Thread.callStackSymbols.joined(separator: "\n")
                fputs("CRASH (signal \(s)) stack:\n" + trace + "\n", stdout)
                exit(43)
            }
        }
        Thread.detachNewThread {
            while idle < idleLimit && Date().timeIntervalSince(started) < totalLimit { sleep(5) }
            let msg = "WATCHDOG: no test progress for \(Int(idle)) s (run time \(Int(Date().timeIntervalSince(started))) s), exiting (see the last 'started' lines above).\n"
            fputs(msg, stdout)
            fputs(msg, stderr)
            // Record every thread's stack (macOS `sample`) to see what is stuck.
            let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".dev/snapshots/hang-sample.txt")   // uploaded with the CI snapshots
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            p.arguments = [String(getpid()), "2", "-file", out.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            exit(42)
        }
    }()
}

/// Builds throwaway repositories with a known history and working-tree state.
enum Fixture {
    @discardableResult
    static func git(_ args: [String], in dir: URL, input: String? = nil, env extra: [String: String] = [:]) throws -> String {
        Watchdog.beat()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "user.name=Test User", "-c", "user.email=test@example.com",
                       "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_AUTHOR_DATE"] = "2026-01-01T12:00:00"
        env["GIT_COMMITTER_DATE"] = "2026-01-01T12:00:00"
        env.merge(extra) { _, new in new }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        try p.run()
        if let input {
            try inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw FixtureError(message: "git \(args.joined(separator: " ")): \(String(decoding: errData, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    struct FixtureError: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    static func write(_ dir: URL, _ name: String, _ text: String) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func lines(_ n: Int, prefix: String = "line") -> String {
        (1...n).map { "\(prefix) \($0)" }.joined(separator: "\n") + "\n"
    }

    /// main: 3 commits + merge of `feature` (2 commits). Working tree: modified a.txt
    /// (unstaged), modified b.swift (staged), untracked new.txt.
    static func makeRepo() throws -> URL {
        _ = Watchdog.start
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitui-fixture-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git(["init", "-q"], in: dir)

        try write(dir, "a.txt", lines(40))
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "Initial commit"], in: dir)

        var a = (1...40).map { "line \($0)" }
        a[4] = "line 5 changed"
        a[14] = "line 15 changed"
        try write(dir, "a.txt", a.joined(separator: "\n") + "\n")
        try write(dir, "src/b.swift", "struct B {\n    let value = 1\n    func run() {\n        print(value)\n    }\n}\n")
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "Second commit", "-m", "Adds b.swift"], in: dir)

        try git(["switch", "-q", "-c", "feature"], in: dir)
        try write(dir, "src/b.swift", "struct B {\n    let value = 2\n    func run() {\n        print(\"value:\", value)\n    }\n}\n")
        try git(["commit", "-q", "-am", "Feature: change B"], in: dir)
        try write(dir, "docs/notes.md", "# Notes\n\nSome notes.\n")
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "Feature: notes"], in: dir)

        try git(["switch", "-q", "main"], in: dir)
        try write(dir, "c.md", "hello\n")
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "Main work"], in: dir)
        try git(["merge", "-q", "--no-ff", "feature", "-m", "Merge feature"], in: dir)
        try git(["tag", "v1.0"], in: dir)

        // Working tree state
        a[2] = "line 3 modified in working tree"
        a.insert("inserted line", at: 20)
        a[30] = "line 30 modified"
        try write(dir, "a.txt", a.joined(separator: "\n") + "\n")
        try write(dir, "src/b.swift", "struct B {\n    let value = 3\n    func run() {\n        print(\"value:\", value)\n    }\n}\n")
        try git(["add", "src/b.swift"], in: dir)
        try write(dir, "new.txt", "brand new\n")
        return dir.resolvingSymlinksInPath()
    }
}

@MainActor
enum UI {
    static var snapshotDir: URL {
        // <package>/Tests/SwiftGitTests/Support.swift → <package>/.dev/snapshots
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".dev/snapshots", isDirectory: true)
    }

    static func setUpApp() {
        _ = Watchdog.start
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    /// Waits (servicing the main actor) until `condition` holds.
    static func wait(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let start = Date()
        Watchdog.beat()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                Issue.record("Timed out waiting for \(what)")
                return
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    static func settle(_ window: NSWindow) async {
        Watchdog.beat()
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// Renders the window content offscreen to .dev/snapshots/<name>.png and
    /// writes a view-tree dump to <name>.txt.
    static func snapshot(_ window: NSWindow, _ name: String) {
        guard let view = window.contentView else { return }
        // cacheDisplay doesn't draw the window background: use the light appearance
        // so text stays readable in snapshots when the Mac is in dark mode.
        if window.appearance == nil {
            window.appearance = NSAppearance(named: .aqua)
            view.layoutSubtreeIfNeeded()
            view.needsDisplay = true
        }
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: snapshotDir.appendingPathComponent("\(name).png"))
            }
        }
        var out = ""
        dump(view, depth: 0, into: &out)
        try? out.write(to: snapshotDir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }

    /// Renders one view on its own and returns the distinct colors found in a sample grid.
    static func sampleColors(_ view: NSView) -> Set<String> {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        var colors = Set<String>()
        let stepX = max(1, rep.pixelsWide / 40), stepY = max(1, rep.pixelsHigh / 40)
        for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    colors.insert(String(format: "%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)))
                }
            }
        }
        return colors
    }

    static func find<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let t = root as? T { return t }
        for s in root.subviews { if let t = find(type, in: s) { return t } }
        return nil
    }

    static func dump(_ v: NSView, depth: Int, into out: inout String) {
        let f = v.frame
        var line = String(repeating: "  ", count: depth)
            + "\(type(of: v)) [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))]"
        if v.isHidden { line += " HIDDEN" }
        if let tf = v as? NSTextField, !tf.stringValue.isEmpty { line += " \"\(tf.stringValue.prefix(60))\"" }
        if let b = v as? NSButton, !b.title.isEmpty { line += " button:\"\(b.title)\"" }
        if let t = v as? NSTableView { line += " rows=\(t.numberOfRows)" }
        if let pane = v as? DiffPaneView {
            line += " pane(rows=\(pane.rows.count) diff=\(pane.diff != nil) visible=\(pane.visibleRect.integral) layer=\(pane.layer != nil) needsDisplay=\(pane.needsDisplay))"
        }
        if let tv = v as? NSTextView { line += " text=\"\(tv.string.prefix(40).replacingOccurrences(of: "\n", with: "⏎"))\"" }
        out += line + "\n"
        if depth > 40 { return }
        for s in v.subviews { dump(s, depth: depth + 1, into: &out) }
    }
}
