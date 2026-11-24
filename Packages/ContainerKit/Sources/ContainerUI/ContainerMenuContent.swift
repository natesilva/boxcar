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
            Text("Loading…")
        }
        ForEach(store.sections) { section in
            Section(section.source.name) {
                if let errorMessage = section.errorMessage {
                    Text(errorMessage)
                } else if section.containers.isEmpty {
                    Text("No containers")
                } else {
                    ForEach(section.containers) { container in
                        ContainerMenuItem(store: store, container: container)
                    }
                }
            }
        }
        if let lastActionError = store.lastActionError {
            Divider()
            Text(lastActionError)
        }
        Divider()
        Button("Refresh") {
            Task { await store.refresh() }
        }
        .keyboardShortcut("r")
    }
}

struct ContainerMenuItem: View {
    let store: ContainerStore
    let container: ContainerInfo

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
                .disabled(!container.state.allows(action) || store.pendingActions.contains(container.ref))
            }
            Divider()
            Button("View Logs…") {
                // A menu bar app is not active by default, so new windows would open behind other apps.
                NSApp.activate()
                openWindow(value: container.ref)
            }
        } label: {
            Label(container.name, systemImage: container.state.symbolName)
        }
    }
}

extension ContainerAction {
    var title: LocalizedStringKey {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
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
