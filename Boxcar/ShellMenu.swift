import AppKit
import SwiftUI

struct ShellMenu<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.openSettings) private var openSettings

    private let updater = Updater.shared

    var body: some View {
        content
        Divider()
        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
        Button("About Boxcar") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel()
        }
        Button("Quit Boxcar") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
