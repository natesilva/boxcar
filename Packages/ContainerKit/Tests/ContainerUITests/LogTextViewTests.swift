import AppKit
import SwiftUI
import Testing
@testable import ContainerUI

/// The tests wait a fixed time for layout, so they must not run at the same time.
@Suite(.serialized) @MainActor
struct LogTextViewTests {
    @Test func tailsWhileLinesArriveAndTheWindowResizes() async throws {
        let log = try await Log()
        defer { log.close() }

        try await log.append(times: 60)
        #expect(log.distanceToEnd <= 1)

        log.window.setContentSize(NSSize(width: 700, height: 300))
        try await log.settle()
        #expect(log.distanceToEnd <= 1)
        #expect(log.isTailing)
    }

    @Test func scrollingBackStopsTailingUntilItIsTurnedOnAgain() async throws {
        let log = try await Log()
        defer { log.close() }

        // A synthetic scroll wheel event stops the run loop of the test process,
        // so the test scrolls and then posts the notification of a scroll by a person.
        log.textView.scroll(.zero)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: log.scrollView)
        try await log.expectStopped()

        log.isTailing = true
        try await log.append(times: 5)
        #expect(log.distanceToEnd <= 1)
    }

    @Test(arguments: [
        #selector(NSResponder.scrollToBeginningOfDocument(_:)),
        #selector(NSResponder.scrollPageUp(_:)),
    ])
    func aKeyboardScrollStopsTailing(command: Selector) async throws {
        let log = try await Log()
        defer { log.close() }

        log.textView.doCommand(by: command)
        try await log.expectStopped()
    }

    @Test func selectingTextStopsTailingAndKeepsTheSelection() async throws {
        let log = try await Log()
        defer { log.close() }

        let selection = NSRange(location: 0, length: 4)
        log.textView.setSelectedRange(selection)
        try await log.settle()
        try await log.append(times: 5)
        #expect(!log.isTailing)
        #expect(log.textView.selectedRange() == selection)
    }
}

/// A log view in a window, with 60 lines.
@MainActor
private final class Log {
    var isTailing = true {
        didSet { update() }
    }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 540), styleMask: .titled, backing: .buffered, defer: false)
    private(set) var scrollView = NSScrollView()
    private(set) var textView = NSTextView()
    private var lines: [LogLine] = []
    private var host: NSHostingView<LogTextView>?

    init() async throws {
        let host = NSHostingView(rootView: view)
        self.host = host
        window.isReleasedWhenClosed = false
        window.contentView = host
        try await settle()
        scrollView = try #require(host.firstScrollView)
        textView = try #require(scrollView.documentView as? NSTextView)
        append(60)
        try await settle()
    }

    var distanceToEnd: CGFloat {
        textView.frame.maxY - scrollView.contentView.bounds.maxY
    }

    func append(times: Int) async throws {
        for _ in 1...times {
            append(2)
            try await settle()
        }
    }

    func expectStopped() async throws {
        try await settle()
        #expect(!isTailing)
        let position = scrollView.contentView.bounds.minY
        try await append(times: 5)
        #expect(scrollView.contentView.bounds.minY == position)
    }

    /// The text view needs time to lay out before the next change.
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    func close() {
        window.close()
    }

    private var view: LogTextView {
        LogTextView(lines: lines, isTailing: Binding(get: { self.isTailing }, set: { self.isTailing = $0 }))
    }

    private func append(_ count: Int) {
        lines += (lines.count..<lines.count + count).map { LogLine(id: $0, text: "line \($0)") }
        update()
    }

    private func update() {
        host?.rootView = view
    }
}
