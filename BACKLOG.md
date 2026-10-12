# Backlog

Ideas for later, roughly in order of value.

## Grammars as optional, on-demand extensions

The tree-sitter grammars are ~23 MB of the ~27 MB app binary (C# 5.2 MB,
Swift 4.2, C++ 3.4, Ruby 2.1, TSX 1.5, TypeScript 1.4, Bash 1.4, Rust 1.1,
the rest < 1 MB each). They cost almost no memory (read-only pages mapped
from disk), only download and disk size.

- Ship only a small core set (or none) in the app; build each grammar as a
  separate dynamic library (`.dylib`) plus its `highlights.scm`, published as
  release assets.
- Download a grammar the first time a diff needs it (or from Settings), verify
  its SHA-256 and code signature, store it in Application Support and load it
  with `dlopen` (`tree_sitter_<lang>` symbol).
- Settings: list installed / available grammars, remove, update with the app.
- Offline: diffs stay plain until the grammar is available.
- CI: build the grammar libraries (universal) and attach them to each release.

## Other ideas (suggested, not scheduled)

- Quick branch switcher (⌘K, fuzzy search, checkout).
- Commit message from the staged diff with Claude (like the PR Generate button).
- Drag a branch onto another in the sidebar to merge / rebase.
- Daily update check against GitHub releases ("New version available").
- Notarized releases (needs an Apple Developer account), so no `xattr` step.
- One window with a custom tab strip, if the per-tab memory (~10 MB of AppKit
  window and views, of which < 1 MB is repository data) ever needs to go down.
