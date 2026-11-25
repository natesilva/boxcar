import AppKit
import SwiftUI

struct ShellMenu<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        content
        Divider()
        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Button("About Boxcar") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [.credits: AboutCredits.attributedString])
        }
        Button("Quit Boxcar") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
