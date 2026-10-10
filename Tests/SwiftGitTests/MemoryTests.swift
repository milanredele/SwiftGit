import AppKit
import Darwin
import Testing
@testable import SwiftGitKit

/// Memory per open repository, measured in-process on the repositories the
/// app has open (read from its saved tab list). Opt-in: runs only when
/// .dev/measure-real-repos exists, and only reads the repositories.
@MainActor
@Suite("Memory", .serialized)
struct MemoryTests {
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    static func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

    @Test func memoryPerRealRepository() async throws {
        let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".dev/measure-real-repos")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        let paths = UserDefaults(suiteName: "hu.pepitaponi.SwiftGit")?.stringArray(forKey: "openRepositories") ?? []
        UI.setUpApp()
        var report = ["Repositories from the app's tab list: \(paths.count)"]
        // Warm up shared code paths (grammars, AppKit) with a small fixture first.
        do {
            let repo = try await Repository.open(try Fixture.makeRepo())
            let wc = RepoWindowController(repository: repo)
            await repo.refreshAll()
            await repo.reloadGraph()
            try? await Task.sleep(nanoseconds: 500_000_000)
            wc.window?.close()
        }
        let baseline = Self.footprint()
        report.append("Baseline after warm-up: \(Self.mb(baseline))")
        var windows: [RepoWindowController] = []
        for path in paths.prefix(8) {
            let before = Self.footprint()
            guard let repo = try? await Repository.open(URL(fileURLWithPath: path)) else { continue }
            let wc = RepoWindowController(repository: repo)
            wc.window?.setContentSize(NSSize(width: 1400, height: 900))
            await repo.refreshAll()
            await repo.reloadGraph()
            if let history = wc.testRoot.main?.content.history, let head = repo.headHash {
                history.select(hash: head, scroll: true)
                await UI.wait("detail", timeout: 20) { history.detail.testFileCount > 0 || repo.graph.count == 0 }
                await UI.wait("diff", timeout: 20) { history.detail.diffVC.testRowCount > 0 || history.detail.testFileCount == 0 }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let after = Self.footprint()
            report.append("\((path as NSString).lastPathComponent): \(repo.graph.count) commits, \(repo.refs.count) refs, "
                          + "graph \(Self.mb(repo.graph.approximateBytes)), tab +\(Self.mb(after - before))")
            windows.append(wc)
        }
        let total = Self.footprint()
        report.append("All tabs open: \(Self.mb(total)) (\(Self.mb(total - baseline)) above baseline, "
                      + "\(Self.mb((total - baseline) / max(1, windows.count))) per tab)")
        for wc in windows { wc.testRoot.unloadContent(); wc.repository.dropCaches() }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        report.append("Background tabs (views unloaded): \(Self.mb(Self.footprint()))")
        for wc in windows { wc.window?.close() }
        let text = report.joined(separator: "\n")
        print("DIAG memory\n" + text)
        try? text.write(to: UI.snapshotDir.appendingPathComponent("memory.txt"), atomically: true, encoding: .utf8)
    }
}
