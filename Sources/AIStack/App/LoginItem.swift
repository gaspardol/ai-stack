import Foundation
import ServiceManagement

/// Starts AI Stack at login through a launch agent that also relaunches it after a crash.
enum LoginItem {
    private static let agent = SMAppService.agent(plistName: "com.gaspardoliviers.aistack.agent.plist")

    static var isEnabled: Bool { agent.status == .enabled }
    static var needsApproval: Bool { agent.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try agent.register()
                // Older builds used a plain login item; keep only one so we don't launch twice.
                if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
            } else {
                try agent.unregister()
            }
        } catch {
            Log.error("Login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)", "app")
        }
    }
}
