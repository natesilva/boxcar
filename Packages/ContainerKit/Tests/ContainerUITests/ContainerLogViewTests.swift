import AppKit
import ContainerCore
import SwiftUI
import Testing
@testable import ContainerUI

extension LogTextViewTests {
    @Test func keepsMoreLinesWhileTailingIsStopped() async throws {
        let runtime = StreamingRuntime()
        let source = ContainerSource(runtimeID: runtime.id, name: "test")
        let view = ContainerLogView(store: ContainerStore(runtimes: [runtime]), ref: ContainerRef(source: source, containerID: "web"))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 540), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let textView = try #require(host.firstScrollView?.documentView as? NSTextView)

        var written = 0
        func write(_ count: Int, expectingLineCount expected: Int) async throws {
            (written + 1...written + count).forEach { runtime.lines.continuation.yield("line \($0)") }
            written += count
            // The lines can arrive in several updates, so the test waits for the last one.
            for _ in 1...100 where !textView.string.hasSuffix("line \(written)\n") {
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(textView.string.hasSuffix("line \(written)\n"))
            #expect(textView.string.split(separator: "\n").count == expected)
        }

        try await write(10_500, expectingLineCount: 10_000)

        textView.doCommand(by: #selector(NSResponder.scrollPageUp(_:)))
        try await Task.sleep(for: .milliseconds(200))
        func firstVisibleLine() throws -> String {
            let top = try #require(textView.enclosingScrollView).contentView.bounds.minY
            let index = textView.characterIndexForInsertion(at: NSPoint(x: 40, y: top + 40))
            let text = textView.string as NSString
            return text.substring(with: text.lineRange(for: NSRange(location: index, length: 0)))
        }

        let line = try firstVisibleLine()
        try await write(500, expectingLineCount: 10_500)
        try await write(9_500, expectingLineCount: 20_000)
        #expect(try firstVisibleLine() == line)
    }
}

private struct StreamingRuntime: ContainerRuntime {
    let id = "streaming"
    let displayName = "Streaming"
    let lines = AsyncThrowingStream<String, any Error>.makeStream()

    func sources() async throws -> [ContainerSource] { [] }
    func containers(in source: ContainerSource) async throws -> [ContainerInfo] { [] }
    func perform(_ action: ContainerAction, on ref: ContainerRef) async throws {}
    func perform(_ action: ContainerAction, on group: ContainerGroupRef) async throws {}

    func changes(in source: ContainerSource) async -> AsyncThrowingStream<Void, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func logs(for ref: ContainerRef, after lastLine: String?) async -> AsyncThrowingStream<String, any Error> {
        lines.stream
    }
}
