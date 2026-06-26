# CSV Converter Mac

A macOS menu bar app that watches a folder and automatically converts CSV files to XLSX as they arrive.

## How it works

1. On first launch the app asks you to choose a folder to watch (defaults to Downloads).
2. When a CSV file appears and has been stable for 3 seconds, it is converted to XLSX in the same folder.
3. A notification pops up when done — click it to open the file in Excel (or the default XLSX app).

The watched folder and its access permission are remembered between launches.

## Requirements

- macOS 13 or later
- No external dependencies — the app converts CSV to XLSX entirely on its own.

## Install

Double-click `Tools/install-latest-app.command` to build and install the app to `/Applications`. You will need Xcode installed.

## Menu bar

Click the table icon in the menu bar to:

- Pause / resume watching
- Change the watched folder
- Trigger an immediate scan of the folder
- Open the watched folder in Finder
- Open the app log

## Supported CSV formats

- Delimiters: comma, semicolon, tab (auto-detected)
- Encodings: UTF-8 (with or without BOM), UTF-16, Windows-1252
- Line endings: CRLF, LF, CR
- Quoted fields with embedded commas, newlines, or double-quote escaping (`""`)

## Build

```bash
xcodebuild -project "CSV Converter Mac.xcodeproj" \
           -scheme "CSV Converter Mac" \
           -configuration Debug build
```
