import AppKit
import ContainerCore
import ContainerUI
import DockerRuntime
import SwiftUI

@main struct BoxcarApp: App {
    @State private var store: ContainerStore
    private let updater = Updater()

    init() {
        let locator = DockerCLILocator(selection: { DockerSettings.selection() })
        let containerStore = ContainerStore(runtimes: [DockerCLIRuntime(locator: locator)])
        store = containerStore
        Task { await containerStore.start() }
        _ = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            Task { await containerStore.refresh() }
        }
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { containerStore.shutdown() }
        }
    }

    var body: some Scene {
        MenuBarExtra("Boxcar", systemImage: "rectangle.stack") {
            ShellMenu {
                ContainerMenuContent(store: store)
            }
        }
        .menuBarExtraStyle(.menu)

        ContainerLogsWindow(store: store)

        Settings {
            SettingsView(store: store, updater: updater)
        }
    }
}
