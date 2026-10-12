# SwiftGit

A lightweight, native macOS git client built with plain AppKit on top of the
`git` and `gh` command line tools.

- **Native:** AppKit only (no Electron, WebKit or SwiftUI). The app is ~25 MB on
  disk, almost all of it compiled syntax grammars, which macOS maps from disk
  rather than loading into memory.
- **Light on resources:** no polling (FSEvents only), zero idle CPU, and a target
  of ≤ 5 MB of memory per open repository tab.
- **Uses your git:** every operation runs the real `git` binary, so hooks,
  credential helpers, SSH agent, signing and `.gitconfig` behave exactly as in
  your terminal. GitHub features go through `gh`, which already holds your login.

## Features

- Multiple repositories as native macOS window tabs; background tabs release
  their views and rebuild them instantly when you switch back.
- Sidebar with local branches (ahead/behind counts), remotes, tags and stashes.
- Commit graph with lazy loading of commit details for the visible rows only.
- Checkout, create / rename / delete branches, merge, rebase (with continue /
  skip / abort banner), cherry-pick, revert, reset, tags, stash / pop / apply.
- Fetch, pull (merge or rebase), push (sets upstream automatically), force push
  with lease, progress and cancel.
- Changes view: stage / unstage / discard files, commit and amend.
- **Side-by-side diff** by default with vertical scrolling locked between the
  panes (horizontal too, hold ⌥ to scroll one side), word-level highlights,
  expandable context, an overview strip of all changes, unified mode, and
  staging / unstaging / discarding of individual hunks or selected lines.
- Syntax highlighting in diffs via [tree-sitter](https://tree-sitter.github.io/):
  Swift, JavaScript, TypeScript/TSX, Python, Go, Rust, C, C++, Java, JSON (up to
  8 MB), Bash, Ruby, CSS, HTML/SVG, C# and Ada. Both file versions are parsed in
  the background and only the colors for the visible diff lines are kept.
- More languages through bundled TextMate grammars, run by a small built-in
  interpreter on the [Oniguruma](https://github.com/kkos/oniguruma) regex
  library: YAML, Markdown, Dockerfile, Makefile, SQL, PHP, Objective-C, Lua,
  Perl, INI/properties, diff/patch, Groovy/Gradle, PowerShell, XML, R, Dart,
  log files, batch, SCSS and Less.
- Very long lines (minified JSON, generated code) draw only their visible part.
- **GitHub pull requests** with base/head selection, PR templates, draft flag
  and a searchable reviewer picker (people and teams). The title and
  description default to the branch's earliest commit message. If the
  [Claude Code](https://claude.com/claude-code) CLI (`claude`) is installed,
  a **Generate** button writes them from all of the branch's commit messages
  using the small Haiku model, keeping the commits' conventions (e.g. a
  `feat:` / `fix(scope):` prefix). If the branch already has an open (draft)
  pull request, the sheet updates that one instead, and a branch that was
  rebased after pushing is force pushed (with lease) first.
- Push explains rejections: after a rebase or amend it shows how the local and
  remote branch diverged and offers a force push (with lease) or a pull.
- The active `gh` account (and your organization, when it owns the repository)
  is shown in the toolbar; its menu switches between logged-in accounts.
- **Undo** the last operation (⌥⌘Z or the toolbar): commit, amend, merge,
  rebase, pull, cherry-pick, revert, reset, checkout, branch create / rename /
  delete.
- **Recoverable discards:** discarded files, hunks and lines (and hard resets)
  are kept for 14 days under Repository › Recover Discarded Changes…
  (a hidden reflog, not the stash list; expired automatically).
- **Conflicts:** each conflicted file says what happened and offers Keep /
  Take one side, Merge Tool, Edit File and Mark Resolved.
- **Edit commits** (simple interactive rebase): keep, reword, squash, fixup,
  drop and reorder the commits from a chosen one up to HEAD.
- **Search** the history (⌘F) by message, author or hash, and show a file's
  history (`file:path`, or right-click a file).
- Pull requests are shown next to their branches in the sidebar (number,
  draft, checks, review state).
- Quiet fetch when a tab gets focus; pulls blocked by local changes offer
  "Stash and Pull". Settings (⌘,) for pull mode, auto-stash, fetching and
  the Claude model.
- Opens your configured `git difftool` / `git mergetool` when you want them.

## Requirements

- macOS 14 Sonoma or later (Apple Silicon or Intel)
- `git` (Xcode Command Line Tools or Homebrew)
- [`gh`](https://cli.github.com) logged in (`gh auth login`) for pull requests

## Install

Download `SwiftGit-<version>.zip` from the
[Releases](../../releases) page, unzip it and move `SwiftGit.app` to
`/Applications`.

Release builds are ad-hoc signed (not notarized), so on first launch macOS will
refuse to open the app. Either right-click it and choose **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/SwiftGit.app
```

## Build from source

Requires Xcode 16 or later (Swift 6 toolchain).

```sh
scripts/build-app.sh release      # → build/SwiftGit.app
open build/SwiftGit.app
```

`UNIVERSAL=1 scripts/build-app.sh release` builds an arm64 + x86_64 binary.
`swift build` / `swift run SwiftGit` also work for quick iterations.

## Tests

```sh
swift test
```

The suite uses swift-testing and runs headless:

- **Core tests** create throwaway repositories with a known history and check
  status/ref parsing, the commit graph, diff rows and partial (line) staging
  through `git apply`.
- **UI tests** build the real window controllers in an offscreen window, drive
  them in-process, assert on what is actually rendered (pixel sampling, hit
  testing) and write PNG snapshots plus a view-tree dump to `.dev/snapshots/`.
  No screen recording or accessibility permission is needed.

## Project layout

```
Sources/SwiftGit/          executable (main.swift only)
Sources/COniguruma/        vendored Oniguruma regex library (C)
Sources/SwiftGitKit/
  Core/                    git/gh runners, parsers, commit graph, diff model
  Core/TextMate/           TextMate grammar interpreter
  Resources/Grammars/      bundled TextMate grammars (compressed) + licenses
  UI/                      AppKit windows, sidebar, history, changes, diff, PR sheet
  App/                     app delegate and menus
Tests/SwiftGitTests/       core + offscreen UI tests
scripts/build-app.sh       builds and bundles SwiftGit.app
scripts/dev-loop.sh        local helper that runs build/test/commit actions on request
.github/workflows/         CI: test, build universal app, publish release on main
```

## License

BSD 2-Clause, see [LICENSE](LICENSE). Third-party components (Oniguruma,
tree-sitter and its grammars, SwiftTreeSitter, TextMate grammars) are listed
with their licenses in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Releases

Every push to `main` runs the tests on a macOS 26 GitHub runner, builds a
universal app and publishes a GitHub release `v0.1.<run number>` with the zipped
app and its SHA-256. Pull requests run the same build and tests without
publishing. Test snapshots are attached to each run as an artifact.
