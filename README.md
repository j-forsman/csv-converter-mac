# CSV Converter Mac

A macOS menu bar app that watches a folder and automatically converts CSV files to XLSX as they arrive. The app has no window; everything lives in the menu bar.

## How it works

1. On first launch, the app asks you to choose a folder to watch. The picker starts in Downloads.
2. The app scans the watched folder every 2 seconds.
3. When a CSV file appears and has been stable for 3 seconds, it is queued for conversion.
4. The XLSX file is written to the same folder as `{filename} converted.xlsx`.
5. A notification appears when conversion finishes. Click it to open the generated XLSX file in Excel or your default spreadsheet app.

If a converted file already exists, the app appends `2`, `3`, and so on. The watched folder and its sandbox access permission are remembered between launches.

The app also registers itself to open at login by default. You can turn this on or off from the menu bar.

## Requirements

- macOS 14 or later
- Xcode, if building from source
- No runtime dependencies; CSV parsing, XLSX generation, and ZIP writing are built into the app.

## Install

Double-click `Tools/install-latest-app.command` to build the app and install it to `/Applications`.

You can also run it from Xcode, but installing to `/Applications` is the best way to test login startup behavior.

## Menu bar

Click the table icon in the menu bar to:

- Pause / resume watching
- Change the watched folder
- Trigger an immediate scan of the folder
- Open the watched folder in Finder
- Toggle opening at login
- Open the app log
- Quit the app

## Supported CSV formats

- Delimiters: comma, semicolon, tab (auto-detected)
- Encodings: UTF-8 (with or without BOM), UTF-16, Windows-1252
- Line endings: CRLF, LF, CR
- Quoted fields with embedded commas, newlines, or double-quote escaping (`""`)

## Limits

- Maximum input file size: 25 MB
- Maximum XLSX rows: 1,048,576
- Maximum XLSX columns: 16,384

These limits match the XLSX worksheet limits and keep conversion safe for a menu bar utility.

## Build

```bash
xcodebuild -project "CSV Converter Mac.xcodeproj" \
           -scheme "CSV Converter Mac" \
           -configuration Debug build
```

For a sandbox-friendly local build directory:

```bash
xcodebuild -project "CSV Converter Mac.xcodeproj" \
           -scheme "CSV Converter Mac" \
           -configuration Debug \
           -derivedDataPath /tmp/csv-converter-mac-derived \
           build
```

## Manual verification

The app does not currently have an automated test suite. To verify a build:

1. Install and launch the app.
2. Choose a watched folder.
3. Drop a CSV file into that folder.
4. Confirm that an XLSX file appears in the same folder.
5. Inspect the generated worksheet XML if needed:

```bash
unzip -p "example converted.xlsx" xl/worksheets/sheet1.xml
```
