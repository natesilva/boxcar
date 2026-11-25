import AppKit
import SwiftUI

struct ShellMenu<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        content
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
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
