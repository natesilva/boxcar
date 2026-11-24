import AppKit
import SwiftUI

struct ShellMenu<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
        Divider()
        Button("About MyApp") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel()
        }
        Button("Quit MyApp") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
