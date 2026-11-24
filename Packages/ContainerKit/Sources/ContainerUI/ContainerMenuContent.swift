import AppKit
import ContainerCore
import SwiftUI

public struct ContainerMenuContent: View {
    let store: ContainerStore

    public init(store: ContainerStore) {
        self.store = store
    }

    public var body: some View {
        if !store.hasLoaded {
            Text("Loading…", bundle: #bundle, comment: "Shown in the menu until the container list has loaded.")
        }
        ForEach(store.sections) { section in
            Section(section.source.name) {
                if let errorMessage = section.errorMessage {
                    Text(errorMessage)
                } else if section.containers.isEmpty {
                    Text("No containers", bundle: #bundle, comment: "Shown under a Docker context that has no containers.")
                } else {
                    ForEach(section.items) { item in
                        switch item {
                        case .container(let container):
                            ContainerMenuItem(store: store, container: container, title: container.name)
                        case .group(let group):
                            ContainerGroupMenu(store: store, group: group)
                        }
                    }
                }
            }
        }
        if let lastActionError = store.lastActionError {
            Divider()
            Text(lastActionError)
        }
        Divider()
        Button(LocalizedStringResource("Refresh", bundle: #bundle, comment: "Menu item that reloads the container list.")) {
            Task { await store.refresh() }
        }
        .keyboardShortcut("r")
    }
}

struct ContainerGroupMenu: View {
    let store: ContainerStore
    let group: ContainerGroup

    var body: some View {
        Menu {
            ForEach(group.containers) { container in
                ContainerMenuItem(store: store, container: container, title: container.group?.memberName ?? container.name)
            }
            Divider()
            ForEach(ContainerAction.allCases, id: \.self) { action in
                Button(action.groupTitle) {
                    Task { await store.perform(action, on: group) }
                }
                .disabled(!group.allows(action) || store.pendingGroupActions.contains(group.ref))
            }
        } label: {
            Label {
                Text(
                    "\(group.ref.name) (\(group.runningCount)/\(group.containers.count) running)",
                    bundle: #bundle,
                    comment: "Menu item for a Compose project. The values are the project name, the number of running containers, and the total number of containers."
                )
            } icon: {
                Image(systemName: group.symbolName)
            }
        }
    }
}

struct ContainerMenuItem: View {
    let store: ContainerStore
    let container: ContainerInfo
    let title: String

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Text(container.image)
            Text(container.status)
            Divider()
            ForEach(ContainerAction.allCases, id: \.self) { action in
                Button(action.title) {
                    Task { await store.perform(action, on: container) }
                }
                .disabled(!container.state.allows(action) || store.isBusy(container))
            }
            Divider()
            Button(LocalizedStringResource("View Logs…", bundle: #bundle, comment: "Menu item that opens the log window of a container.")) {
                // A menu bar app is not active by default, so new windows would open behind other apps.
                NSApp.activate()
                openWindow(value: container.ref)
            }
        } label: {
            Label(title, systemImage: container.state.symbolName)
        }
    }
}

extension ContainerAction {
    var title: LocalizedStringResource {
        switch self {
        case .start: LocalizedStringResource("Start", bundle: #bundle, comment: "Menu item that starts a container.")
        case .stop: LocalizedStringResource("Stop", bundle: #bundle, comment: "Menu item that stops a container.")
        case .restart: LocalizedStringResource("Restart", bundle: #bundle, comment: "Menu item that restarts a container.")
        }
    }

    var groupTitle: LocalizedStringResource {
        switch self {
        case .start: LocalizedStringResource("Start All", bundle: #bundle, comment: "Menu item that starts all containers of a Compose project.")
        case .stop: LocalizedStringResource("Stop All", bundle: #bundle, comment: "Menu item that stops all containers of a Compose project.")
        case .restart: LocalizedStringResource("Restart All", bundle: #bundle, comment: "Menu item that restarts all containers of a Compose project.")
        }
    }
}

extension ContainerState {
    var symbolName: String {
        switch self {
        case .running: "play.circle.fill"
        case .paused: "pause.circle"
        case .restarting: "arrow.clockwise.circle"
        case .created, .exited, .dead, .removing, .unknown: "stop.circle"
        }
    }
}

extension ContainerGroup {
    var symbolName: String {
        switch runningCount {
        case containers.count: "play.circle.fill"
        case 0: "stop.circle"
        default: "circle.lefthalf.filled"
        }
    }
}
