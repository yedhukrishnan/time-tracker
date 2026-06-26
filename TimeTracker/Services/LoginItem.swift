import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` so the agent launches at login —
/// otherwise it isn't running when your workday starts and the nudge never fires.
enum LoginItem {

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            print("LoginItem toggle failed: \(error)")
        }
    }
}
