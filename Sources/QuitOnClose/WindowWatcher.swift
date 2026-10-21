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
    /// Apps that had a window on screen at the last refresh.
    private var visiblePIDs: Set<pid_t> = []
    private var pollTask: Task<Void, Never>?
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

        // Refresh visible windows whenever they may have changed, so windows the user left on another
        // Space are still known when an app's last visible window closes.
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisibleWindows() }
            })
        }

        for app in NSWorkspace.shared.runningApplications {
            track(pid: app.processIdentifier)
        }

        // Apps that hide their window on close (common with menu bar apps) send no close event,
        // so also poll for an app's last visible window disappearing. One poll costs well under a millisecond.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshVisibleWindows()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refreshVisibleWindows() {
        let visible = WindowServer.visibleWindows()
        for (pid, windows) in visible {
            seenWindows[pid, default: []].formUnion(windows)
        }
        for pid in visiblePIDs where visible[pid] == nil && trackers[pid] != nil {
            scheduleQuitCheck(pid: pid)
        }
        visiblePIDs = Set(visible.keys)
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
                refreshVisibleWindows()
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
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, !app.isHidden,
              app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier,
              !Self.protectedBundleIDs.contains(bundleID),
              settings.allowsQuitting(bundleID) else { return }

        // Accessibility sees minimized windows but only on the current Space. Windows the app has shown
        // elsewhere (other Spaces, full screen) are caught by the window server. Any doubt keeps it open.
        guard let windows = tracker.windows(), windows.isEmpty else { return }
        guard let existing = WindowServer.windows(pid: pid) else { return }
        let seen = (seenWindows[pid] ?? []).intersection(existing.map(\.id))
        seenWindows[pid] = seen
        let currentSpaces = WindowServer.currentSpaces()
        guard !existing.contains(where: { seen.contains($0.id) && WindowServer.isOpen($0, currentSpaces: currentSpaces) }) else { return }

        print("Quitting \(app.localizedName ?? bundleID): last window closed")
        app.terminate()
    }
}

/// Window-server queries that don't depend on Accessibility.
/// Apps also own invisible windows that never appear on screen (placeholders, menu bar strips),
/// so only windows that have actually been visible are meaningful.
enum WindowServer {
    struct Window {
        let id: CGWindowID
        let pid: pid_t
        let isOnScreen: Bool
    }

    /// Normal windows currently visible on screen, by owning process.
    static func visibleWindows() -> [pid_t: Set<CGWindowID>] {
        var result: [pid_t: Set<CGWindowID>] = [:]
        for window in normalWindows([.optionOnScreenOnly, .excludeDesktopElements]) ?? [] {
            result[window.pid, default: []].insert(window.id)
        }
        return result
    }

    /// All normal windows the process owns, visible or not, or nil if the window server couldn't answer.
    static func windows(pid: pid_t) -> [Window]? {
        normalWindows([.optionAll, .excludeDesktopElements])?.filter { $0.pid == pid }
    }

    /// Whether a window the user has seen should still count as open.
    /// Off screen but on another Space means it's elsewhere; off screen on the current Space (or on no
    /// Space) means the app hid it — what menu bar apps do instead of closing. Unknown means open.
    static func isOpen(_ window: Window, currentSpaces: Set<Int>?) -> Bool {
        if window.isOnScreen { return true }
        guard let currentSpaces, let spaces = SkyLight.spaces(of: window.id) else { return true }
        return !spaces.isEmpty && spaces.isDisjoint(with: currentSpaces)
    }

    /// The Space currently shown on each display, or nil if unknown.
    static func currentSpaces() -> Set<Int>? {
        SkyLight.currentSpaces()
    }

    private static func normalWindows(_ options: CGWindowListOption) -> [Window]? {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init),
                  let id = (info[kCGWindowNumber as String] as? Int).map(CGWindowID.init),
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 100, bounds.height >= 100 else { return nil }
            return Window(id: id, pid: pid, isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }
}

/// Undocumented window-server calls that report which Space a window is on (also used by yabai and AltTab).
/// Looked up at runtime: if a future macOS removes them, Space checks are skipped and windows count as open.
private enum SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    nonisolated(unsafe) private static let handle = dlopen(nil, RTLD_NOW)
    private static let mainConnectionID = symbol("CGSMainConnectionID", as: MainConnectionID.self)
    private static let copySpacesForWindows = symbol("CGSCopySpacesForWindows", as: CopySpacesForWindows.self)
    private static let copyManagedDisplaySpaces = symbol("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: type) }
    }

    static func spaces(of window: CGWindowID) -> Set<Int>? {
        guard let mainConnectionID, let copySpacesForWindows,
              let spaces = copySpacesForWindows(mainConnectionID(), 0x7, [window] as CFArray)?.takeRetainedValue() as? [Int]
        else { return nil }
        return Set(spaces)
    }

    static func currentSpaces() -> Set<Int>? {
        guard let mainConnectionID, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(mainConnectionID())?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        let current = displays.compactMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int }
        return current.isEmpty ? nil : Set(current)
    }
}
