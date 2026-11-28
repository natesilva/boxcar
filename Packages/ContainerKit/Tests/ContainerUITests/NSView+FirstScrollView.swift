import AppKit

extension NSView {
    var firstScrollView: NSScrollView? {
        self as? NSScrollView ?? subviews.lazy.compactMap(\.firstScrollView).first
    }
}
