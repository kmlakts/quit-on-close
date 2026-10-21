import AppKit
import ApplicationServices
import Observation

/// Tracks whether the app has been granted Accessibility access.
@MainActor @Observable
final class Permissions {
    private(set) var isTrusted = AXIsProcessTrusted()

    /// Shows the system prompt that sends the user to System Settings.
    func request() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
    }

    /// Returns once access has been granted.
    func waitUntilTrusted() async {
        while !AXIsProcessTrusted() {
            try? await Task.sleep(for: .seconds(1))
        }
        isTrusted = true
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
