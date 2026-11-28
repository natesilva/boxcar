import AppKit
import SwiftUI

/// Shows log lines in one `NSTextView`. SwiftUI's text selection works only inside one
/// `Text` view, so a list of `Text` views cannot select more than one line.
struct LogTextView: NSViewRepresentable {
    let lines: [LogLine]
    /// Whether the view keeps the end of the log visible. The view sets the value to
    /// `false` when the person scrolls away from the end or selects text.
    @Binding var isTailing: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isTailing: $isTailing)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textLayoutManager?.delegate = context.coordinator.layoutDelegate
        context.coordinator.observe(textView, in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        context.coordinator.isTailing = $isTailing
        context.coordinator.show(lines, in: textView)
    }

    /// Keeps track of the lines that the text view shows, so that an update changes only
    /// the lines that were added or removed. Replacing all text of a log with 10,000 lines
    /// for each batch of new lines would make the window slow.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private static let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]

        private static let noticeAttributes: [NSAttributedString.Key: Any] = {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacingBefore = 4
            style.paragraphSpacing = 4
            return [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
                .logNotice: true,
            ]
        }()

        /// The keyboard commands that move toward the start of the log. The text view
        /// animates some of them, so the scroll position does not show the result at once.
        private static let backwardCommands: Set<Selector> = [
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveToBeginningOfParagraph(_:)),
            #selector(NSResponder.moveToBeginningOfDocument(_:)),
            #selector(NSResponder.pageUp(_:)),
            #selector(NSResponder.scrollPageUp(_:)),
            #selector(NSResponder.scrollToBeginningOfDocument(_:)),
        ]

        /// The text layout manager keeps only a weak reference to its delegate.
        let layoutDelegate = NoticeLayoutDelegate()

        /// The ID of the first line in the text view. The IDs of the lines are consecutive.
        private var firstID = 0
        /// The length in UTF-16 units of each line in the text view, including its line break.
        private var lengths: [Int] = []

        var isTailing: Binding<Bool>
        private weak var textView: NSTextView?
        private var isEditing = false
        private var isLiveScrolling = false

        init(isTailing: Binding<Bool>) {
            self.isTailing = isTailing
        }

        /// Only an action of the person stops the tailing. TextKit changes the height of
        /// the text view and the scroll position without such an action, so the view
        /// scrolls to the end again after each of these changes.
        func observe(_ textView: NSTextView, in scrollView: NSScrollView) {
            self.textView = textView
            textView.delegate = self
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(layoutDidChange), name: NSView.frameDidChangeNotification, object: textView)
            center.addObserver(self, selector: #selector(layoutDidChange), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
            center.addObserver(self, selector: #selector(layoutDidChange), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            center.addObserver(self, selector: #selector(liveScrollWillStart), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            center.addObserver(self, selector: #selector(liveScrollDidMove), name: NSScrollView.didLiveScrollNotification, object: scrollView)
            center.addObserver(self, selector: #selector(liveScrollDidEnd), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        }

        func show(_ lines: [LogLine], in textView: NSTextView) {
            guard let storage = textView.textStorage else {
                return
            }

            // The text view removes the selection if one edit removes lines and adds lines,
            // so these are separate edits.
            isEditing = true
            if let first = lines.first, canReuse(for: lines, firstID: first.id) {
                let removedCount = first.id - firstID
                storage.deleteCharacters(in: NSRange(location: 0, length: lengths.prefix(removedCount).reduce(0, +)))
                lengths.removeFirst(removedCount)
                firstID = first.id
                append(lines[lengths.count...], to: storage)
            } else {
                storage.deleteCharacters(in: NSRange(location: 0, length: storage.length))
                lengths = []
                firstID = lines.first?.id ?? 0
                append(lines[...], to: storage)
            }
            isEditing = false

            scrollToEndLater()
        }

        /// The text view can keep its text if the lines continue the lines that it shows:
        /// the new first line is one of them, or the line directly after them.
        private func canReuse(for lines: [LogLine], firstID newFirstID: Int) -> Bool {
            guard newFirstID >= firstID, newFirstID - firstID <= lengths.count else {
                return false
            }
            return lines.count >= lengths.count - (newFirstID - firstID)
        }

        private func append(_ newLines: ArraySlice<LogLine>, to storage: NSTextStorage) {
            let text = NSMutableAttributedString()
            for line in newLines {
                let lineText = NSAttributedString(string: line.text + "\n", attributes: line.isNotice ? Self.noticeAttributes : Self.attributes)
                lengths.append(lineText.length)
                text.append(lineText)
            }
            storage.append(text)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if Self.backwardCommands.contains(commandSelector) {
                isTailing.wrappedValue = false
            }
            return false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if !isEditing, let textView, textView.selectedRange().length > 0 {
                isTailing.wrappedValue = false
            }
        }

        @objc private func layoutDidChange() {
            scrollToEndLater()
        }

        @objc private func liveScrollWillStart() {
            isLiveScrolling = true
        }

        @objc private func liveScrollDidMove() {
            guard isTailing.wrappedValue, let textView, let clipView = textView.enclosingScrollView?.contentView else {
                return
            }
            if clipView.bounds.maxY < textView.frame.maxY - 1 {
                isTailing.wrappedValue = false
            }
        }

        @objc private func liveScrollDidEnd() {
            isLiveScrolling = false
            scrollToEndLater()
        }

        /// The scroll waits for the next turn of the main queue, because a scroll during
        /// a layout pass is not safe.
        private func scrollToEndLater() {
            DispatchQueue.main.async {
                guard self.isTailing.wrappedValue, !self.isLiveScrolling, let textView = self.textView else {
                    return
                }
                textView.scrollToVisible(NSRect(x: 0, y: textView.bounds.maxY - 1, width: 1, height: 1))
            }
        }
    }
}

extension NSAttributedString.Key {
    /// Marks a paragraph that the window added itself. The text view draws it as a band.
    static let logNotice = NSAttributedString.Key("logNotice")
}

final class NoticeLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph,
           paragraph.attributedString.length > 0,
           paragraph.attributedString.attribute(.logNotice, at: 0, effectiveRange: nil) != nil {
            return NoticeLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// Draws a gray band behind a notice paragraph. The band is as wide as the text container.
final class NoticeLayoutFragment: NSTextLayoutFragment {
    private var bandBounds: CGRect {
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        return CGRect(x: -layoutFragmentFrame.origin.x, y: 0, width: width, height: layoutFragmentFrame.height)
    }

    /// TextKit clips the drawing of a fragment to its rendering surface, so the surface must include the band.
    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(bandBounds)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        NSAppearance.currentDrawing().performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.quaternaryLabelColor.cgColor)
        }
        context.fill(bandBounds.offsetBy(dx: point.x, dy: point.y))
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}
