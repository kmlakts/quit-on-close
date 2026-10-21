import Observation
import ServiceManagement

/// Launch-at-login state, backed by the system's login items.
@MainActor @Observable
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    private(set) var error: String?

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}
