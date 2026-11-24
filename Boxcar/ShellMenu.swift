import AppKit
import SwiftUI

struct ShellMenu<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
        Divider()
        OpenAtLoginToggle()
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
