import AppKit
import ContainerCore
import ContainerUI
import DockerRuntime
import SwiftUI

@main struct MyApp: App {
    @State private var store: ContainerStore

    init() {
        let containerStore = ContainerStore(runtimes: [DockerCLIRuntime()])
        store = containerStore
        Task { await containerStore.start() }
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { containerStore.shutdown() }
        }
    }

    var body: some Scene {
        MenuBarExtra("MyApp", systemImage: "rectangle.stack") {
            ShellMenu {
                ContainerMenuContent(store: store)
            }
        }
        .menuBarExtraStyle(.menu)

        ContainerLogsWindow(store: store)
    }
}
