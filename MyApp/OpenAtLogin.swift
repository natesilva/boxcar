import OSLog
import ServiceManagement
import SwiftUI

/// Registers the app as a login item with `SMAppService`. The user can also
/// change the setting in System Settings › General › Login Items, so the
/// model reads the status again each time the menu shows the toggle.
@MainActor
@Observable
final class OpenAtLogin {
    private let service = SMAppService.mainApp
    private var status: SMAppService.Status
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MyApp", category: "OpenAtLogin")

    init() {
        status = service.status
    }

    var isEnabled: Bool {
        get { status == .enabled }
        set { setEnabled(newValue) }
    }

    func refresh() {
        status = service.status
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            logger.error("Could not change the login item: \(error.localizedDescription)")
        }
        refresh()
        // The user turned off the login item in System Settings before.
        // Only the user can turn it on again there.
        if status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

struct OpenAtLoginToggle: View {
    @State private var openAtLogin = OpenAtLogin()

    var body: some View {
        Toggle("Open at Login", isOn: $openAtLogin.isEnabled)
            .onAppear { openAtLogin.refresh() }
    }
}
