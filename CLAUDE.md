# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & run

```bash
# Build (debug)
xcodebuild -project "CSV Converter Mac.xcodeproj" -scheme "CSV Converter Mac" -configuration Debug build

# Run the built binary directly (captures NSLog to stdout)
"/path/from/DerivedData/Build/Products/Debug/CSV Converter Mac.app/Contents/MacOS/CSV Converter Mac" &

# Build and install to /Applications (for end-user testing)
./Tools/install-latest-app.command
```

The app has no test suite. Verify behaviour by running the app, dropping a CSV into the watched folder, and inspecting the output XLSX with `unzip -p file.xlsx xl/worksheets/sheet1.xml`.

## Architecture

The app is a macOS menu-bar-only agent (`LSUIElement = true`). There is no window — the entire UI is the NSStatusItem menu. `SwiftUI` is present only as the app entry point; all logic lives in `AppDelegate`.

**`AppDelegate.swift`** — owns everything:
- Folder watching via a repeating `Timer` (`scanInterval = 2 s`). Files must remain byte-for-byte stable for `requiredStableDuration = 3 s` before they are queued.
- Security-scoped bookmark stored in `UserDefaults` under key `watchedFolderBookmark`. The resolved URL must **not** be passed through `.standardizedFileURL` — that strips the security scope. Always call `startAccessingSecurityScopedResource()` on the URL returned directly by `URL(resolvingBookmarkData:options:.withSecurityScope:)`. When refreshing a stale bookmark, call `startAccessingSecurityScopedResource()` on the resolved URL **before** calling `bookmarkData(options:)`, since the sandbox may block the stat needed to build the new bookmark.
- `watchedFolderURL` caches the resolved URL in `_cachedWatchedFolderURL`. Clear the cache (`_cachedWatchedFolderURL = nil`) any time the bookmark changes (e.g. in `chooseFolder`). `watchedFolderURL` must only be called from the main thread — `enqueueConversion` captures it there and passes it to `runConversion` on the background queue.
- All logging goes through `log()`, which dispatches file I/O to `logQueue` (a serial `DispatchQueue`) to prevent concurrent `FileHandle` writes between the main thread and the background conversion queue.
- Conversion runs on a serial `OperationQueue` (max 1 concurrent). `runConversion` takes the folder URL as a parameter (captured on the main thread in `enqueueConversion`) so it never calls `watchedFolderURL` from the background thread.
- Notification clicks are handled in `userNotificationCenter(_:didReceive:)`. The security scope must be started (via `watchedFolderURL`) before calling `fileManager.fileExists` or opening the file, since the sandbox blocks access without it.

**`CSVXLSXConverter.swift`** — pure conversion logic, no I/O side effects except the write:
- `CSVParser` — RFC 4180 parser. **Critical:** Swift's `String.makeIterator()` yields `\r\n` as a single `Character` (one Unicode grapheme cluster), so CRLF files must be normalised to `\n` before parsing. This is done at the top of `parse(_:delimiter:)`.
- `XLSXWorkbook` — builds a valid OOXML `.xlsx` (ZIP) entirely in memory with no external dependencies. Cells use `t="inlineStr"` with `xml:space="preserve"`. Styles require **two** fills (`none` + `gray125`) per the OOXML spec.
- `ZipArchive` — hand-rolled ZIP writer (stored, no compression). Writes to a temp file then `moveItem` to the final path atomically.

## Sandbox

The app is sandboxed (`com.apple.security.app-sandbox`) with only `com.apple.security.files.user-selected.read-write`. All folder access is gated through security-scoped bookmarks. The sandbox prevents writing to `~/Library/Application Support/` in debug (ad-hoc) builds, so `watcher.log` is only written in properly signed releases.
