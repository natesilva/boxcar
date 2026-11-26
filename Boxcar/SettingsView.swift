import AppKit
import ContainerCore
import ContainerUI
import DockerRuntime
import SwiftUI

struct SettingsView: View {
    let store: ContainerStore
    @Bindable var updater: Updater

    @AppStorage(DockerSettings.sourceKey) private var source = DockerCommandSource.automatic
    @AppStorage(DockerSettings.customPathKey) private var customPath = ""

    private static let releasesURL = URL(string: "https://github.com/natesilva/boxcar/releases")

    private var locator: DockerCLILocator {
        let selection: DockerCLISelection = source == .automatic ? .automatic : .custom(path: customPath)
        return DockerCLILocator(selection: { selection })
    }

    var body: some View {
        Form {
            Section("Docker command") {
                Picker("Docker command", selection: $source) {
                    Text("Locate automatically").tag(DockerCommandSource.automatic)
                    Text("Use this command:").tag(DockerCommandSource.custom)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                HStack {
                    TextField("Path to docker", text: $customPath)
                        .labelsHidden()
                        .onSubmit(refreshContainers)
                    Button("Choose…", action: chooseCommand)
                }
                .disabled(source == .automatic)

                status
            }
            Section {
                OpenAtLoginToggle()
            }
            Section {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                HStack {
                    Button("Check for Updates…", action: updater.checkForUpdates)
                        .disabled(!updater.canCheckForUpdates)
                    Spacer()
                    if let releasesURL = Self.releasesURL {
                        Link("What’s New", destination: releasesURL)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
        .bringsWindowToFront()
        .onChange(of: source, refreshContainers)
    }

    @ViewBuilder
    private var status: some View {
        if let url = locator.locate() {
            Text("Using \(url.abbreviatedPath)")
                .foregroundStyle(.secondary)
        } else if source == .custom {
            Text("There is no executable file at this path.")
                .foregroundStyle(.red)
        } else {
            Text("The docker command was not found.")
                .foregroundStyle(.red)
        }
    }

    private func chooseCommand() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        customPath = url.path
        refreshContainers()
    }

    private func refreshContainers() {
        Task { await store.refresh() }
    }
}

private extension URL {
    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
