import AppKit

/// Shared conflict-resolution actions (Changes lists and the diff pane).
@MainActor
enum ConflictActions {
    /// Takes one side's whole version of each file, after confirming.
    static func keep(_ side: ConflictSide, files: [FileChange], repository: Repository, window: NSWindow?) async {
        let conflicts = files.filter(\.isConflict)
        guard !conflicts.isEmpty else { return }
        let sides = await repository.conflictSides()
        let chosen = side == .ours ? sides.ours : sides.theirs
        let other = side == .ours ? sides.theirs : sides.ours
        let what = conflicts.count == 1 ? "“\(conflicts[0].path)”" : "\(conflicts.count) files"
        guard await Prompt.confirm(window, title: "Use \(chosen)’s version of \(what)?",
                                   message: "The changes \(other) made to \(conflicts.count == 1 ? "this file" : "these files") are dropped "
                                    + "and the result is staged as resolved. (Edits you already made in the file are saved to "
                                    + "Recover Discarded Changes first.)",
                                   ok: "Use \(chosen)", destructive: true) else { return }
        await repository.saveDiscarded(paths: conflicts.map(\.path), summary: "Before resolving \(what) with \(chosen)")
        await repository.resolveConflicts(conflicts, keeping: side)
    }

    /// Stages the files as resolved, warning if conflict markers are left in them.
    static func markResolved(_ files: [FileChange], repository: Repository, window: NSWindow?) async {
        let left = repository.filesWithConflictMarkers(files)
        if !left.isEmpty {
            guard await Prompt.confirm(window, title: "Conflict markers are still in \(left.count == 1 ? left[0] : "\(left.count) files")",
                                       message: "Lines starting with <<<<<<< or >>>>>>> are left. Mark as resolved anyway?",
                                       ok: "Mark Resolved", destructive: true) else { return }
        }
        await repository.markResolved(files)
    }
}
