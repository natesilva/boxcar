import AppKit
import SwiftUI

/// The app is a menu bar app and has no Dock icon. While a window of the app is open,
/// the app gets a Dock icon and an entry in the Cmd-Tab list, so that the person can
/// switch back to the window after another app comes to the front.
@MainActor
final class DockPresence {
    static let shared = DockPresence()

    private var openWindowCount = 0

    func windowDidAppear() {
        openWindowCount += 1
        NSApp.setActivationPolicy(.regular)
    }

    func windowDidDisappear() {
        openWindowCount = max(openWindowCount - 1, 0)
        if openWindowCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct DockPresenceModifier: ViewModifier {
    /// SwiftUI can call `onAppear` more than once for one window, so each window counts itself only once.
    @State private var isCounted = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !isCounted else {
                    return
                }
                isCounted = true
                DockPresence.shared.windowDidAppear()
            }
            .onDisappear {
                guard isCounted else {
                    return
                }
                isCounted = false
                DockPresence.shared.windowDidDisappear()
            }
    }
}

extension View {
    /// Shows the app in the Dock and the Cmd-Tab list while this view is on screen.
    func showsAppInDockWhileVisible() -> some View {
        modifier(DockPresenceModifier())
    }
}
