import ApplicationServices
import Foundation

/// Accessibility observer for one app: reports when its windows open and close.
@MainActor
final class AppTracker {
    enum Event {
        case windowCreated
        case windowClosed
    }

    let pid: pid_t
    private let appElement: AXUIElement
    private let onEvent: (Event) -> Void
    private var observer: AXObserver?

    init(pid: pid_t, onEvent: @escaping (Event) -> Void) {
        self.pid = pid
        self.appElement = AXUIElementCreateApplication(pid)
        self.onEvent = onEvent
        // Never let an unresponsive app stall us for long.
        AXUIElementSetMessagingTimeout(appElement, 1.0)
    }

    /// Starts observing. Returns false if the app isn't reachable yet.
    func start() -> Bool {
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { return false }

        let result = AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        guard result == .success || result == .notificationAlreadyRegistered else { return false }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = observer

        for window in windows() ?? [] {
            watchForClose(window)
        }
        return true
    }

    func stop() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }

    /// The app's windows (including minimized ones), or nil if Accessibility couldn't answer.
    func windows() -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    /// Whether the window is minimized. Unknown counts as minimized, which keeps the app open.
    static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else { return true }
        return value as? Bool ?? true
    }

    private var refcon: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private func watchForClose(_ window: AXUIElement) {
        guard let observer else { return }
        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
    }

    fileprivate func handle(_ notification: String, element: AXUIElement) {
        guard observer != nil else { return }
        switch notification {
        case kAXWindowCreatedNotification:
            watchForClose(element)
            onEvent(.windowCreated)
        case kAXUIElementDestroyedNotification:
            onEvent(.windowClosed)
        default:
            break
        }
    }
}

/// Runs on the main run loop, where the observer's source is installed.
private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let tracker = Unmanaged<AppTracker>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    // Safe: the observer's source is on the main run loop, so this never leaves the main thread.
    nonisolated(unsafe) let element = element
    MainActor.assumeIsolated {
        tracker.handle(name, element: element)
    }
}
