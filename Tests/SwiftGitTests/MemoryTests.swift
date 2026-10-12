import AppKit
import Darwin
import SwiftTreeSitter
import Testing
@testable import SwiftGitKit

/// Memory per open repository, measured in-process on the repositories the
/// app has open (read from its saved tab list). Opt-in: runs only when
/// .dev/measure-real-repos exists; the other suites are skipped then so they
/// don't distort the numbers. Only reads the repositories.
@MainActor
@Suite("Memory", .serialized)
struct MemoryTests {
    nonisolated static var marker: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".dev/measure-real-repos")
    }
    nonisolated static var measuring: Bool { FileManager.default.fileExists(atPath: marker.path) }

    /// Physical footprint after asking malloc to return free pages.
    static func footprint() -> Int {
        malloc_zone_pressure_relief(nil, 0)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    static func mb(_ bytes: Int) -> String { String(format: "%+.1f MB", Double(bytes) / 1_048_576) }
    static func total(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

    @Test func memoryPerRealRepository() async throws {
        guard Self.measuring else { return }
        let paths = UserDefaults(suiteName: "hu.pepitaponi.SwiftGit")?.stringArray(forKey: "openRepositories") ?? []
        UI.setUpApp()
        var report = ["Repositories from the app's tab list: \(paths.count)", "Process at start: \(Self.total(Self.footprint()))"]
        // Warm up shared code paths (AppKit, fonts) with a small fixture first.
        do {
            let repo = try await Repository.open(try Fixture.makeRepo())
            let wc = RepoWindowController(repository: repo)
            await repo.refreshAll()
            await repo.reloadGraph()
            try? await Task.sleep(nanoseconds: 500_000_000)
            wc.window?.close()
        }
        // Reference: what an empty window of the same size costs.
        do {
            let before = Self.footprint()
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
            w.isReleasedWhenClosed = false
            w.contentView = NSView()
            w.toolbar = NSToolbar(identifier: "MemoryTest")
            w.displayIfNeeded()
            w.contentView?.display()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let shown = Self.footprint()
            w.close()
            try? await Task.sleep(nanoseconds: 300_000_000)
            report.append("Empty 1400×900 window: \(Self.mb(shown - before)) (after close \(Self.mb(Self.footprint() - before)))")
        }
        // Where does a tab's window cost go? Unloaded content vs toolbar vs window.
        do {
            var parts: [String] = []
            var last = Self.footprint()
            func step(_ n: String) { let now = Self.footprint(); parts.append("\(n) \(Self.mb(now - last))"); last = now }
            let repo = try await Repository.open(try Fixture.makeRepo())
            await repo.refreshAll()
            await repo.reloadGraph()
            step("model")
            var wc: RepoWindowController? = RepoWindowController(repository: repo)
            step("controller")
            if let w = wc?.window { w.setContentSize(NSSize(width: 1400, height: 900)); await UI.settle(w) }
            step("drawn")
            wc?.testRoot.unloadContent()
            try? await Task.sleep(nanoseconds: 300_000_000)
            step("content unloaded")
            wc?.window?.toolbar = nil
            try? await Task.sleep(nanoseconds: 300_000_000)
            step("toolbar removed")
            wc?.window?.close()
            wc = nil
            try? await Task.sleep(nanoseconds: 500_000_000)
            step("closed")
            report.append("Fixture tab: " + parts.joined(separator: ", "))
        }
        // Compiled highlight queries are kept for the app's lifetime: what does each cost?
        var langs: [String] = []
        for ext in ["swift", "ts", "tsx", "js", "py", "go", "rs", "c", "cpp", "java", "json", "sh", "rb", "css", "html", "cs", "adb"] {
            let before = Self.footprint()
            _ = SyntaxHighlighter.shared.isSupported(path: "x.\(ext)")
            langs.append("\(ext) \(Self.mb(Self.footprint() - before))")
        }
        report.append("Highlight queries: " + langs.joined(separator: ", "))
        let baseline = Self.footprint()
        report.append("Baseline after warm-up: \(Self.total(baseline))")
        var windows: [RepoWindowController] = []
        for path in paths.prefix(8) {
            var steps: [String] = []
            var last = Self.footprint()
            let start = last
            func step(_ name: String) {
                let now = Self.footprint()
                steps.append("\(name) \(Self.mb(now - last))")
                last = now
            }
            guard let repo = try? await Repository.open(URL(fileURLWithPath: path)) else { continue }
            await repo.refreshAll()
            step("status+refs")
            await repo.reloadGraph()
            step("graph")
            let wc = RepoWindowController(repository: repo)
            step("controllers")
            wc.window?.setContentSize(NSSize(width: 1400, height: 900))
            if let w = wc.window { await UI.settle(w) }
            step("layout+draw")
            if let history = wc.testRoot.main?.content.history, let head = repo.headHash {
                history.select(hash: head, scroll: true)
                await UI.wait("detail", timeout: 20) { history.detail.testFileCount > 0 || repo.graph.count == 0 }
                await UI.wait("diff", timeout: 20) { history.detail.diffVC.testRowCount > 0 || history.detail.testFileCount == 0 }
                try? await Task.sleep(nanoseconds: 1_500_000_000)   // syntax highlighting, summaries, merge checks
                step("commit+diff")
            }
            report.append("\((path as NSString).lastPathComponent): \(repo.graph.count) commits, \(repo.refs.count) refs — "
                          + steps.joined(separator: ", ") + " = \(Self.mb(Self.footprint() - start))")
            windows.append(wc)
        }
        let all = Self.footprint()
        report.append("All tabs open: \(Self.total(all)) (\(Self.mb(all - baseline)) over baseline, "
                      + "\(Self.mb((all - baseline) / max(1, windows.count))) per tab)")
        weak var history: HistoryViewController? = windows.first?.testRoot.main?.content.history
        weak var diff: DiffViewController? = history?.detail.diffVC
        weak var sidebar: SidebarViewController? = windows.first?.testRoot.main?.sidebar
        for wc in windows { wc.testRoot.unloadContent(); wc.repository.dropCaches() }
        try? await Task.sleep(nanoseconds: 500_000_000)
        report.append("After unloading: history VC \(history == nil ? "freed" : "STILL ALIVE"), "
                      + "diff VC \(diff == nil ? "freed" : "STILL ALIVE"), sidebar \(sidebar == nil ? "freed" : "STILL ALIVE")")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let bg = Self.footprint()
        report.append("All as background tabs (views unloaded): \(Self.total(bg)) (\(Self.mb(bg - baseline)) over baseline)")
        weak var firstController = windows.first
        weak var firstRepo = windows.first?.repository
        for wc in windows { wc.window?.close() }
        windows.removeAll()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        report.append("All tabs closed: \(Self.total(Self.footprint())); window controller \(firstController == nil ? "freed" : "STILL ALIVE"), "
                      + "repository \(firstRepo == nil ? "freed" : "STILL ALIVE")")
        let text = report.joined(separator: "\n")
        print("DIAG memory\n" + text)
        try? text.write(to: UI.snapshotDir.appendingPathComponent("memory.txt"), atomically: true, encoding: .utf8)
    }

    /// Heap census of the running SwiftGit app (if any), by size, for attribution.
    @Test func heapOfRunningApp() throws {
        guard Self.measuring else { return }
        func run(_ exe: String, _ args: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            guard (try? p.run()) != nil else { return "" }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        let pid = run("/usr/bin/pgrep", ["-x", "SwiftGit"]).split(separator: "\n").first.map(String.init) ?? ""
        guard !pid.isEmpty else { return }
        let heap = run("/usr/bin/heap", ["-sortBySize", "-s", pid])
        let lines = heap.split(separator: "\n", omittingEmptySubsequences: false).prefix(120).joined(separator: "\n")
        try? lines.write(to: UI.snapshotDir.appendingPathComponent("app-heap.txt"), atomically: true, encoding: .utf8)
    }
}


/// Where the memory for syntax highlighting goes (diagnostic, prints only).
@MainActor
@Suite("Highlight query cost", .serialized, .disabled(if: !MemoryTests.measuring))
struct HighlightQueryCost {
    static func inUse() -> Int {
        var s = malloc_statistics_t()
        malloc_zone_statistics(nil, &s)
        return Int(s.size_in_use)
    }

    @Test func compileCostPerLanguage() throws {
        let h = SyntaxHighlighter()
        var lines: [String] = []
        for id in ["swift", "typescript", "tsx", "javascript", "python", "go", "rust", "c", "cpp", "java",
                   "json", "bash", "ruby", "css", "html", "csharp", "ada"] {
            guard let def = h.definition(id), let ptr = def.0 else { continue }
            let text = def.1.compactMap { h.queryText($0.0, $0.1) }.joined(separator: "\n")
            let language = Language(language: ptr)
            let fpBefore = MemoryTests.footprint()
            let before = Self.inUse()
            let start = Date()
            var query: Query? = try Query(language: language, data: Data(text.utf8))
            let ms = Date().timeIntervalSince(start) * 1000
            let compiled = Self.inUse()
            let fpCompiled = MemoryTests.footprint()
            let patterns = query?.patternCount ?? 0
            query = nil
            let freed = Self.inUse()
            lines.append(String(format: "%@: .scm %d B, %d patterns, compile %.0f ms, query keeps %.2f MB, footprint %+.1f MB, after release %+.2f MB",
                                id, text.utf8.count, patterns, ms,
                                Double(compiled - before) / 1_048_576,
                                Double(fpCompiled - fpBefore) / 1_048_576,
                                Double(freed - before) / 1_048_576))
        }
        let out = lines.joined(separator: "\n")
        print("DIAG queries\n" + out)
        try out.write(to: UI.snapshotDir.appendingPathComponent("query-cost.txt"), atomically: true, encoding: .utf8)
    }
}
