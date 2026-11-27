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
            loadingText
        } else if store.sections.isEmpty {
            Text("No container engine found", bundle: #bundle, comment: "Shown in the menu when there is no Docker context to list.")
        }
        ForEach(store.sections) { section in
            // The name of the only source is not useful as a heading.
            if store.sections.count > 1 {
                Section(section.source.name) {
                    rows(for: section)
                }
            } else {
                rows(for: section)
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

extension ContainerMenuContent {
    private var loadingText: Text {
        Text("Loading…", bundle: #bundle, comment: "Shown in the menu until the container list has loaded.")
    }

    @ViewBuilder
    private func rows(for section: ContainerSection) -> some View {
        if let errorMessage = section.errorMessage {
            if let helpURL = section.helpURL {
                Button(errorMessage, systemImage: "info.circle") {
                    NSWorkspace.shared.open(helpURL)
                }
                .labelStyle(.titleAndIcon)
                .help(Text("Open instructions in the browser", bundle: #bundle, comment: "Tooltip of an error in the menu that opens a web page with help."))
            } else if let errorDetail = section.errorDetail {
                Text(errorMessage)
                    .help(Text(verbatim: errorDetail))
            } else {
                Text(errorMessage)
            }
        } else if section.isLoading {
            loadingText
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

struct ContainerGroupMenu: View {
    let store: ContainerStore
    let group: ContainerGroup

    var body: some View {
        Menu {
            ForEach(group.containers) { container in
                ContainerMenuItem(store: store, container: container, title: container.group?.memberName ?? container.name)
            }
            Divider()
            if let workingDirectory = group.workingDirectory {
                WorkingDirectoryMenuItem(directory: workingDirectory, remoteHost: group.ref.source.remoteHost)
                Divider()
            }
            ForEach(ContainerAction.allCases, id: \.self) { action in
                Button(action.groupTitle) {
                    Task { await store.perform(action, on: group) }
                }
                .disabled(!group.allows(action) || store.pendingGroupActions.contains(group.ref))
            }
        } label: {
            Label {
                Text(group.ref.name)
            } icon: {
                GroupStatusLights(counts: group.conditionCounts)
            }
            .labelStyle(.titleAndIcon)
        }
        // The menu keeps the image width of an item that it updates in place, so
        // a new identity makes it build a new item when the squares change.
        .id(group.conditionCounts)
    }
}

/// Opens the directory of a Compose project in Finder. The Mac cannot open a directory
/// on a remote host, so for that the item only shows where the directory is.
struct WorkingDirectoryMenuItem: View {
    let directory: URL
    let remoteHost: String?

    var body: some View {
        if let remoteHost {
            Button(LocalizedStringResource("\(directory.path) on \(remoteHost)", bundle: #bundle, comment: "Disabled menu item that shows the directory of a Compose project on another machine. The first value is the path. The second value is the host name."), systemImage: "folder") {}
                .labelStyle(.titleAndIcon)
                .disabled(true)
        } else {
            Button(directory.abbreviatedPath, systemImage: "folder") {
                NSWorkspace.shared.open(directory)
            }
            .labelStyle(.titleAndIcon)
            .help(Text("Show in Finder", bundle: #bundle, comment: "Tooltip of the menu item that shows the directory of a Compose project."))
        }
    }
}

/// Shows an open action and a copy action for each published port. A menu item has
/// only one action, so a container with many ports gets a submenu for each port.
/// A container can publish thousands of ports, so only the first ones are listed.
struct PortMenuItems: View {
    let ports: [PublishedPort]

    private static let maxInlinePorts = 4
    private static let maxListedPorts = 20

    var body: some View {
        if ports.count > Self.maxInlinePorts {
            ForEach(ports.prefix(Self.maxListedPorts)) { port in
                Menu {
                    actions(for: port)
                } label: {
                    Label(port.address, systemImage: "network")
                }
                .labelStyle(.titleAndIcon)
            }
            if ports.count > Self.maxListedPorts {
                Text("More ports not shown: \(ports.count - Self.maxListedPorts)", bundle: #bundle, comment: "Shown after the list of published ports of a container that has too many to list. The value is the number of ports that are not listed.")
            }
        } else {
            ForEach(ports) { port in
                actions(for: port)
            }
        }
    }

    @ViewBuilder
    private func actions(for port: PublishedPort) -> some View {
        Button(LocalizedStringResource("Open \(port.address)", bundle: #bundle, comment: "Menu item that opens a published port of a container in the browser. The value is the address, such as localhost:5173."), systemImage: "network") {
            if let url = port.url {
                NSWorkspace.shared.open(url)
            }
        }
        .labelStyle(.titleAndIcon)
        Button(LocalizedStringResource("Copy \(port.address)", bundle: #bundle, comment: "Menu item that copies the address of a published port of a container. The value is the address, such as localhost:5173."), systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(port.address, forType: .string)
        }
        .labelStyle(.titleAndIcon)
    }
}

extension URL {
    /// The path with `~` for the home directory, as Finder and Terminal show it.
    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
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
            Button(LocalizedStringResource("View Logs…", bundle: #bundle, comment: "Menu item that opens the log window of a container."), systemImage: "doc.text") {
                openWindow(value: container.ref)
                // An existing window for this container is not new, so it needs the activation here.
                NSApp.activate()
            }
            .labelStyle(.titleAndIcon)
            if !container.ports.isEmpty {
                Divider()
                PortMenuItems(ports: container.ports)
            }
            Divider()
            ForEach(ContainerAction.allCases, id: \.self) { action in
                Button(action.title) {
                    Task { await store.perform(action, on: container) }
                }
                .disabled(!container.state.allows(action) || store.isBusy(container))
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                StatusLight(condition: container.condition, isChanging: isChanging)
            }
            .labelStyle(.titleAndIcon)
        }
    }

    /// Docker has no states for starting and stopping. A pending action or a
    /// first health check that has not finished shows that the state is changing.
    private var isChanging: Bool {
        store.isBusy(container) || container.diagnostics.health == .starting
    }
}

/// A traffic light symbol in the color of a container's condition.
struct StatusLight: View {
    let condition: ContainerCondition
    let isChanging: Bool

    var body: some View {
        Image(nsImage: image)
            .accessibilityLabel(Text(condition.accessibilityLabel))
    }

    private var image: NSImage {
        NSImage.symbol(isChanging ? "circle.dotted" : "circle.fill", color: condition.color) ?? NSImage()
    }
}

/// One numbered square for each condition that a Compose project's containers are in.
/// The number is the count of containers in that condition. The squares are
/// outlines, so that a menu with many running containers is not mostly green.
struct GroupStatusLights: View {
    let counts: [ContainerCondition: Int]

    private static let spacing = 2.0

    var body: some View {
        Image(nsImage: image)
            .accessibilityLabel(Text(accessibilityLabel))
    }

    private var orderedCounts: [(condition: ContainerCondition, count: Int)] {
        ContainerCondition.allCases.compactMap { condition in
            counts[condition].map { (condition, $0) }
        }
    }

    /// A menu item has only one image, so the squares are drawn side by side into one image.
    private var image: NSImage {
        let symbols = orderedCounts.compactMap { condition, count in
            // SF Symbols has numbered squares only up to 50.
            NSImage.symbol("\(count).square", color: condition.color) ?? NSImage.symbol("square", color: condition.color)
        }
        let width = symbols.map(\.size.width).reduce(0, +) + Self.spacing * Double(max(symbols.count - 1, 0))
        let height = symbols.map(\.size.height).max() ?? 0
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x = 0.0
            for symbol in symbols {
                symbol.draw(in: NSRect(x: x, y: (height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
                x += symbol.size.width + Self.spacing
            }
            return true
        }
    }

    private var accessibilityLabel: String {
        orderedCounts
            .map { String(localized: $0.condition.countLabel($0.count)) }
            .formatted(.list(type: .and))
    }
}

extension NSImage {
    /// The menu draws SF Symbols as template images, which removes a color that
    /// `foregroundStyle` sets. A palette configuration makes the color part of the image.
    static func symbol(_ name: String, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
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

extension ContainerCondition {
    var color: NSColor {
        switch self {
        case .normal: .systemGreen
        case .warning: .systemYellow
        case .critical: .systemRed
        case .inactive: .secondaryLabelColor
        }
    }

    var accessibilityLabel: LocalizedStringResource {
        switch self {
        case .normal: LocalizedStringResource("Running", bundle: #bundle, comment: "Accessibility label of the status light of a container that runs normally.")
        case .warning: LocalizedStringResource("Needs attention", bundle: #bundle, comment: "Accessibility label of the status light of a container that is unhealthy, paused, or exited with an error.")
        case .critical: LocalizedStringResource("Failed", bundle: #bundle, comment: "Accessibility label of the status light of a container that is dead, in a restart loop, or out of memory.")
        case .inactive: LocalizedStringResource("Stopped", bundle: #bundle, comment: "Accessibility label of the status light of a container that is stopped.")
        }
    }

    func countLabel(_ count: Int) -> LocalizedStringResource {
        switch self {
        case .normal: LocalizedStringResource("Running: \(count)", bundle: #bundle, comment: "Accessibility label of a Compose project's status. The value is the number of containers that run normally.")
        case .warning: LocalizedStringResource("Needs attention: \(count)", bundle: #bundle, comment: "Accessibility label of a Compose project's status. The value is the number of containers that are unhealthy, paused, or exited with an error.")
        case .critical: LocalizedStringResource("Failed: \(count)", bundle: #bundle, comment: "Accessibility label of a Compose project's status. The value is the number of containers that are dead, in a restart loop, or out of memory.")
        case .inactive: LocalizedStringResource("Stopped: \(count)", bundle: #bundle, comment: "Accessibility label of a Compose project's status. The value is the number of stopped containers.")
        }
    }
}

