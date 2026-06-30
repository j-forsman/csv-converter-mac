import Cocoa
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private struct FileSnapshot: Equatable {
        let byteSize: Int64
        let modifiedAt: TimeInterval
    }

    private enum DefaultsKey {
        static let launchAtLoginPreference = "launchAtLoginPreference"
        static let watchedFolderBookmark = "watchedFolderBookmark"
    }

    private enum NotificationUserInfoKey {
        static let outputPath = "outputPath"
    }

    private let scanInterval: TimeInterval = 2
    private let requiredStableDuration: TimeInterval = 3
    private let fileManager = FileManager.default
    private let conversionQueue = OperationQueue()
    private let logQueue = DispatchQueue(label: "com.csvconverter.log", qos: .utility)

    private var statusItem: NSStatusItem?
    private var _cachedWatchedFolderURL: URL?
    private var scanTimer: Timer?
    private var knownSnapshots: [String: FileSnapshot] = [:]
    private var pendingSnapshots: [String: FileSnapshot] = [:]
    private var pendingSince: [String: Date] = [:]
    private var queuedPaths = Set<String>()
    private var isWatching = true
    private var lastActivity = "Ready"

    func applicationDidFinishLaunching(_ notification: Notification) {
        conversionQueue.name = "CSV Converter Conversion Queue"
        conversionQueue.maxConcurrentOperationCount = 1
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        buildStatusItem()
        configureLaunchAtLoginIfNeeded()
        if hasWatchedFolderBookmark {
            startWatchingCurrentFolder()
            log("App started. Watching folder: \(watchedFolderURL.lastPathComponent)")
        } else {
            isWatching = false
            lastActivity = "Choose folder"
            updateStatusMenu()
            log("App started. Waiting for watched folder access.")

            DispatchQueue.main.async { [weak self] in
                self?.chooseFolder()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        scanTimer?.invalidate()
        conversionQueue.cancelAllOperations()
        log("App stopped.")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let outputPath = response.notification.request.content.userInfo[NotificationUserInfoKey.outputPath] as? String else {
            completionHandler()
            return
        }

        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL

        DispatchQueue.main.async {
            let folderURL = self.watchedFolderURL
            let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing { folderURL.stopAccessingSecurityScopedResource() }
            }

            guard self.fileManager.fileExists(atPath: outputURL.path) else {
                self.log("Notification clicked, but output file no longer exists.")
                completionHandler()
                return
            }

            self.log("Notification clicked. Opening converted file.")
            NSWorkspace.shared.open(outputURL)
            completionHandler()
        }
    }

    // MARK: - Folder Watching

    private var watchedFolderURL: URL {
        if let cached = _cachedWatchedFolderURL {
            return cached
        }
        if let bookmark = UserDefaults.standard.data(forKey: DefaultsKey.watchedFolderBookmark),
           let url = resolveBookmarkedFolder(from: bookmark) {
            _cachedWatchedFolderURL = url
            return url
        }
        return defaultDownloadsURL
    }

    private var defaultDownloadsURL: URL {
        if let userHome = NSHomeDirectoryForUser(NSUserName()) {
            return URL(fileURLWithPath: userHome)
                .appendingPathComponent("Downloads", isDirectory: true)
                .standardizedFileURL
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .standardizedFileURL
    }

    private var hasWatchedFolderBookmark: Bool {
        UserDefaults.standard.data(forKey: DefaultsKey.watchedFolderBookmark) != nil
    }

    private func startWatchingCurrentFolder() {
        scanTimer?.invalidate()
        knownSnapshots = snapshotsInWatchedFolder()
        pendingSnapshots.removeAll()
        pendingSince.removeAll()
        queuedPaths.removeAll()

        scanTimer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            self?.scanWatchedFolder(convertExistingFiles: false)
        }
        scanTimer?.tolerance = 1

        setWatching(true)
        updateStatusMenu()
    }

    private func scanWatchedFolder(convertExistingFiles: Bool) {
        guard isWatching else { return }
        guard hasWatchedFolderBookmark else {
            lastActivity = "Choose folder"
            updateStatusMenu()
            log("Scan skipped. Choose a watched folder first.")
            return
        }

        let currentSnapshots = snapshotsInWatchedFolder()
        let currentPaths = Set(currentSnapshots.keys)
        knownSnapshots = knownSnapshots.filter { currentPaths.contains($0.key) }
        pendingSnapshots = pendingSnapshots.filter { currentPaths.contains($0.key) }
        pendingSince = pendingSince.filter { currentPaths.contains($0.key) }

        for (path, snapshot) in currentSnapshots {
            if !convertExistingFiles, knownSnapshots[path] == snapshot {
                continue
            }

            if convertExistingFiles {
                pendingSnapshots.removeValue(forKey: path)
                pendingSince.removeValue(forKey: path)
                knownSnapshots[path] = snapshot
                enqueueConversion(for: path)
            } else if pendingSnapshots[path] == snapshot {
                guard let firstStableSeen = pendingSince[path] else {
                    pendingSince[path] = Date()
                    continue
                }
                if Date().timeIntervalSince(firstStableSeen) >= requiredStableDuration {
                    pendingSnapshots.removeValue(forKey: path)
                    pendingSince.removeValue(forKey: path)
                    knownSnapshots[path] = snapshot
                    enqueueConversion(for: path)
                }
            } else if pendingSnapshots[path] != snapshot {
                pendingSnapshots[path] = snapshot
                pendingSince[path] = Date()
            }
        }
    }

    private func snapshotsInWatchedFolder() -> [String: FileSnapshot] {
        let folderURL = watchedFolderURL
        let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        guard isReadableDirectory(folderURL) else {
            lastActivity = "Cannot read watched folder"
            log("Cannot read watched folder. Choose the folder again from the menu bar icon.")
            return [:]
        }

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
            )

            return urls.reduce(into: [:]) { result, url in
                guard url.pathExtension.lowercased() == "csv",
                      let snapshot = snapshot(for: url) else { return }
                result[url.standardizedFileURL.path] = snapshot
            }
        } catch {
            lastActivity = "Scan failed"
            log("Failed to scan watched folder: \(error.localizedDescription)")
            return [:]
        }
    }

    private func snapshot(for url: URL) -> FileSnapshot? {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true,
                  let byteSize = values.fileSize,
                  let modifiedAt = values.contentModificationDate else { return nil }
            return FileSnapshot(byteSize: Int64(byteSize), modifiedAt: modifiedAt.timeIntervalSince1970)
        } catch {
            log("Failed to read CSV file metadata: \(error.localizedDescription)")
            return nil
        }
    }

    private func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.isReadableFile(atPath: url.path)
    }

    // MARK: - Conversion

    private func enqueueConversion(for path: String) {
        guard !queuedPaths.contains(path) else { return }
        queuedPaths.insert(path)
        lastActivity = "Queued \(URL(fileURLWithPath: path).lastPathComponent)"
        updateStatusMenu()
        log("Queued conversion.")

        let folderURL = watchedFolderURL
        conversionQueue.addOperation { [weak self] in
            self?.runConversion(path: path, folderURL: folderURL)
        }
    }

    private func runConversion(path: String, folderURL: URL) {
        guard URL(fileURLWithPath: path).pathExtension.lowercased() == "csv" else {
            finishConversion(path: path)
            return
        }

        log("Starting conversion.")

        let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let outputURL = try CSVXLSXConverter.convert(csvURL: URL(fileURLWithPath: path))
            log("Finished conversion.")
            notify(title: "CSV Converter",
                   body: "Converted \(URL(fileURLWithPath: path).lastPathComponent)",
                   outputURL: outputURL)
        } catch {
            log("Conversion failed: \(error.localizedDescription)")
            notify(title: "CSV Converter", body: "Conversion failed for \(URL(fileURLWithPath: path).lastPathComponent)")
        }

        finishConversion(path: path)
    }

    private func finishConversion(path: String) {
        DispatchQueue.main.async {
            self.queuedPaths.remove(path)
            self.lastActivity = self.queuedPaths.isEmpty ? "Idle" : "Converting..."
            self.updateStatusMenu()
        }
    }

    // MARK: - Status Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: "CSV Converter")
        updateStatusMenu()
    }

    private func updateStatusMenu() {
        let menu = NSMenu()

        let title = NSMenuItem(title: "CSV Converter", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let folder = NSMenuItem(title: "Folder: \(watchedFolderURL.lastPathComponent)", action: nil, keyEquivalent: "")
        folder.isEnabled = false
        menu.addItem(folder)

        let status = NSMenuItem(title: "Status: \(isWatching ? lastActivity : "Paused")", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: isWatching ? "Pause Watching" : "Resume Watching",
                                action: #selector(toggleWatching),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Choose Folder...",
                                action: #selector(chooseFolder),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Scan Folder Now",
                                action: #selector(scanFolderNow),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Watched Folder",
                                action: #selector(openWatchedFolder),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        let launchAtLogin = NSMenuItem(title: "Open at Login",
                                       action: #selector(toggleLaunchAtLogin),
                                       keyEquivalent: "")
        launchAtLogin.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchAtLogin)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open App Log",
                                action: #selector(openAppLog),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private var shouldLaunchAtLogin: Bool {
        if UserDefaults.standard.object(forKey: DefaultsKey.launchAtLoginPreference) == nil {
            UserDefaults.standard.set(true, forKey: DefaultsKey.launchAtLoginPreference)
        }
        return UserDefaults.standard.bool(forKey: DefaultsKey.launchAtLoginPreference)
    }

    private func configureLaunchAtLoginIfNeeded() {
        if shouldLaunchAtLogin {
            enableLaunchAtLoginIfPossible()
        } else if isLaunchAtLoginEnabled {
            disableLaunchAtLogin()
        }
        updateStatusMenu()
    }

    private func enableLaunchAtLoginIfPossible() {
        guard !isLaunchAtLoginEnabled else { return }

        do {
            try SMAppService.mainApp.register()
            log("Enabled launch at login.")
        } catch {
            log("Failed to enable launch at login: \(error.localizedDescription)")
        }
    }

    private func disableLaunchAtLogin() {
        guard isLaunchAtLoginEnabled else { return }

        do {
            try SMAppService.mainApp.unregister()
            log("Disabled launch at login.")
        } catch {
            log("Failed to disable launch at login: \(error.localizedDescription)")
        }
    }

    @objc private func toggleWatching() {
        setWatching(!isWatching)
    }

    @objc private func toggleLaunchAtLogin() {
        let enable = !isLaunchAtLoginEnabled
        UserDefaults.standard.set(enable, forKey: DefaultsKey.launchAtLoginPreference)

        if enable {
            enableLaunchAtLoginIfPossible()
        } else {
            disableLaunchAtLogin()
        }

        updateStatusMenu()
    }

    private func setWatching(_ enabled: Bool) {
        isWatching = enabled
        lastActivity = enabled ? "Watching" : "Paused"
        updateStatusMenu()
        log(enabled ? "Watching resumed." : "Watching paused.")
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = hasWatchedFolderBookmark ? watchedFolderURL : defaultDownloadsURL
        panel.message = "Choose the folder CSV Converter should watch."

        guard panel.runModal() == .OK,
              let selectedURL = panel.url?.standardizedFileURL else {
            if !hasWatchedFolderBookmark {
                lastActivity = "Choose folder"
                updateStatusMenu()
            }
            log("Folder selection cancelled.")
            return
        }

        _cachedWatchedFolderURL = nil
        do {
            let bookmark = try selectedURL.bookmarkData(options: [.withSecurityScope],
                                                        includingResourceValuesForKeys: nil,
                                                        relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: DefaultsKey.watchedFolderBookmark)
        } catch {
            log("Failed to save selected folder access: \(error.localizedDescription)")
        }

        log("Changed watched folder.")
        startWatchingCurrentFolder()
    }

    @objc private func scanFolderNow() {
        guard hasWatchedFolderBookmark else {
            chooseFolder()
            return
        }

        log("Manual scan requested.")
        scanWatchedFolder(convertExistingFiles: true)
    }

    @objc private func openWatchedFolder() {
        let folderURL = watchedFolderURL
        let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { folderURL.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.open(folderURL)
    }

    @objc private func openAppLog() {
        ensureLogFileExists()
        NSWorkspace.shared.open(appLogURL)
    }

    // MARK: - Logging and Notifications

    private var appSupportDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CSV Converter Mac", isDirectory: true)
    }

    private var appLogURL: URL {
        appSupportDirectory.appendingPathComponent("watcher.log")
    }

    private func log(_ message: String) {
        NSLog("%@", message)
        logQueue.async { [self] in
            ensureLogFileExists()
            let line = "[\(Date())] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: appLogURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    private func ensureLogFileExists() {
        try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: appLogURL.path) {
            try? "CSV Converter Mac watcher log\n".write(to: appLogURL, atomically: true, encoding: .utf8)
        }
    }

    private func notify(title: String, body: String, outputURL: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let outputURL {
            content.userInfo = [NotificationUserInfoKey.outputPath: outputURL.path]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                     content: content,
                                                                     trigger: nil))
    }

    private func resolveBookmarkedFolder(from bookmark: Data) -> URL? {
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmark,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            if isStale {
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                let refreshedBookmark = try url.bookmarkData(options: [.withSecurityScope],
                                                             includingResourceValuesForKeys: nil,
                                                             relativeTo: nil)
                UserDefaults.standard.set(refreshedBookmark, forKey: DefaultsKey.watchedFolderBookmark)
            }
            // Return the raw URL — calling standardizedFileURL creates a new URL object
        // that loses the security scope granted by the bookmark resolver.
        return url
        } catch {
            log("Failed to restore selected folder access: \(error.localizedDescription)")
            UserDefaults.standard.removeObject(forKey: DefaultsKey.watchedFolderBookmark)
            return nil
        }
    }

}
