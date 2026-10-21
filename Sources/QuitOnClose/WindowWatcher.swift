import AppKit
import ApplicationServices

/// Watches running apps for closed windows and quits an app once it has none left.
@MainActor
final class WindowWatcher {
    /// Apps that are never quit, whatever the user's rules say.
    private static let protectedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.Spotlight",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "com.apple.loginwindow",
    ]

    private let settings: Settings
    private var trackers: [pid_t: AppTracker] = [:]
    private var pendingQuits: [pid_t: Task<Void, Never>] = [:]
    /// Windows each app has had visible on screen — on whichever Space was active at the time.
    private var seenWindows: [pid_t: Set<CGWindowID>] = [:]
    private var observers: [NSObjectProtocol] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(settings: Settings) {
        self.settings = settings
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let pid = Self.pid(from: note) else { return }
            MainActor.assumeIsolated { self?.track(pid: pid) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let pid = Self.pid(from: note) else { return }
            MainActor.assumeIsolated { self?.untrack(pid: pid) }
        })

        // Sample visible windows whenever the visible set may have changed, so windows the user
        // left on another Space are still known when an app's last visible window closes.
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recordVisibleWindows() }
            })
        }

        for app in NSWorkspace.shared.runningApplications {
            track(pid: app.processIdentifier)
        }
        recordVisibleWindows()
    }

    private func recordVisibleWindows() {
        for (pid, windows) in WindowServer.visibleWindows() {
            seenWindows[pid, default: []].formUnion(windows)
        }
    }

    private nonisolated static func pid(from note: Notification) -> pid_t? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
    }

    // MARK: Tracking

    private func track(pid: pid_t, attempt: Int = 0) {
        guard pid != ownPID, trackers[pid] == nil,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.activationPolicy == .regular else { return }

        let tracker = AppTracker(pid: pid) { [weak self] event in
            self?.handle(event, pid: pid)
        }
        if tracker.start() {
            trackers[pid] = tracker
        } else if attempt < 10 {
            // Freshly launched apps often aren't ready for Accessibility yet.
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                track(pid: pid, attempt: attempt + 1)
            }
        }
    }

    private func untrack(pid: pid_t) {
        pendingQuits.removeValue(forKey: pid)?.cancel()
        trackers.removeValue(forKey: pid)?.stop()
        seenWindows[pid] = nil
    }

    private func handle(_ event: AppTracker.Event, pid: pid_t) {
        switch event {
        case .windowCreated:
            pendingQuits.removeValue(forKey: pid)?.cancel()
            Task {
                // Give the new window a moment to appear on screen.
                try? await Task.sleep(for: .milliseconds(500))
                recordVisibleWindows()
            }
        case .windowClosed:
            scheduleQuitCheck(pid: pid)
        }
    }

    // MARK: Quitting

    private func scheduleQuitCheck(pid: pid_t) {
        pendingQuits[pid]?.cancel()
        let delay = settings.closeDelay
        pendingQuits[pid] = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            pendingQuits[pid] = nil
            quitIfWindowless(pid: pid)
        }
    }

    private func quitIfWindowless(pid: pid_t) {
        guard settings.isEnabled,
              let tracker = trackers[pid],
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier,
              !Self.protectedBundleIDs.contains(bundleID),
              settings.allowsQuitting(bundleID) else { return }

        // Accessibility sees minimized windows but only on the current Space. Windows the app has shown
        // elsewhere (other Spaces, full screen) are caught by the window server. Any doubt keeps it open.
        guard let windows = tracker.windows(), windows.isEmpty else { return }
        guard let existing = WindowServer.windows(pid: pid) else { return }
        let remaining = existing.intersection(seenWindows[pid] ?? [])
        seenWindows[pid] = remaining
        guard remaining.isEmpty else { return }

        print("Quitting \(app.localizedName ?? bundleID): last window closed")
        app.terminate()
    }
}

/// Window-server queries that don't depend on Accessibility.
/// Apps also own invisible windows that never appear on screen (placeholders, menu bar strips),
/// so only windows that have actually been visible are meaningful.
enum WindowServer {
    /// Normal windows currently visible on screen, by owning process.
    static func visibleWindows() -> [pid_t: Set<CGWindowID>] {
        var result: [pid_t: Set<CGWindowID>] = [:]
        for info in windowList([.optionOnScreenOnly, .excludeDesktopElements]) ?? [] {
            if let (pid, id) = normalWindow(info) { result[pid, default: []].insert(id) }
        }
        return result
    }

    /// All normal windows the process owns, visible or not, or nil if the window server couldn't answer.
    static func windows(pid: pid_t) -> Set<CGWindowID>? {
        guard let list = windowList([.optionAll, .excludeDesktopElements]) else { return nil }
        return Set(list.compactMap { info in normalWindow(info).flatMap { $0.pid == pid ? $0.id : nil } })
    }

    private static func windowList(_ options: CGWindowListOption) -> [[String: Any]]? {
        CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    }

    private static func normalWindow(_ info: [String: Any]) -> (pid: pid_t, id: CGWindowID)? {
        guard let pid = (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init),
              let id = (info[kCGWindowNumber as String] as? Int).map(CGWindowID.init),
              info[kCGWindowLayer as String] as? Int == 0,
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo),
              bounds.width >= 100, bounds.height >= 100 else { return nil }
        return (pid, id)
    }
}
