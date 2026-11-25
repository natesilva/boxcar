import AppKit
import SwiftUI

/// A menu bar app is not active when the person chooses a menu item. A window that opens at that
/// moment can appear behind the windows of other apps. This view waits until its window exists,
/// then orders the window to the front and activates the app.
private struct BringsWindowToFront: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowObservingView {
        WindowObservingView()
    }

    func updateNSView(_ nsView: WindowObservingView, context: Context) {}
}

private final class WindowObservingView: NSView {
    override func viewDidMoveToWindow() {
        guard let window else {
            return
        }
        Task { @MainActor in
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }
}

extension View {
    /// Orders the window of this view to the front and activates the app when the window opens.
    public func bringsWindowToFront() -> some View {
        background(BringsWindowToFront())
    }
}
