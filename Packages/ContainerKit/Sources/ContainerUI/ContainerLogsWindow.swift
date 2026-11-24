import AppKit
import AsyncAlgorithms
import ContainerCore
import SwiftUI

/// One window per container. Opening the logs of a container that already
/// has a window brings that window to the front.
public struct ContainerLogsWindow: Scene {
    let store: ContainerStore

    public init(store: ContainerStore) {
        self.store = store
    }

    public var body: some Scene {
        WindowGroup(LocalizedStringResource("Logs", bundle: #bundle, comment: "Name of the container log window group."), for: ContainerRef.self) { $ref in
            if let ref {
                ContainerLogView(store: store, ref: ref)
            }
        }
        .defaultSize(width: 900, height: 540)
        .restorationBehavior(.disabled)
    }
}

enum StreamEnd: Equatable {
    case finished
    case failed(String)
}

struct LogLine: Identifiable {
    let id: Int
    let text: String
}

struct ContainerLogView: View {
    let store: ContainerStore
    let ref: ContainerRef

    @State private var lines: [LogLine] = []
    @State private var nextLineID = 0
    @State private var connection = 0
    @State private var streamEnd: StreamEnd?
    @State private var lastRawLine: String?

    /// The window keeps at most this many lines, so a noisy container
    /// cannot make the window use unlimited memory.
    private static let maxLines = 10_000

    private static let resumeDelay: Duration = .seconds(1)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Text(line.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .bottom) {
            if let streamEnd {
                HStack {
                    switch streamEnd {
                    case .finished:
                        Text("The log stream ended.", bundle: #bundle, comment: "Shown at the bottom of the log window when the log stream stops.")
                    case .failed(let message):
                        Text(message)
                    }
                    Spacer()
                    Button(LocalizedStringResource("Reconnect", bundle: #bundle, comment: "Button that restarts the log stream.")) {
                        connection += 1
                    }
                }
                .padding()
                .background(.bar)
            }
        }
        .navigationTitle(Text("\(containerName) (\(ref.source.name))", bundle: #bundle, comment: "Log window title. The first value is the container name. The second value is the Docker context."))
        .toolbar {
            Button(LocalizedStringResource("Copy All", bundle: #bundle, comment: "Toolbar button that copies all log lines."), systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
            }
            Button(LocalizedStringResource("Clear", bundle: #bundle, comment: "Toolbar button that removes all log lines from the window."), systemImage: "trash") {
                lines.removeAll()
            }
        }
        .task(id: connection) {
            await follow()
        }
        .task(id: shouldResume) {
            await resumeAfterRestart()
        }
    }

    private var containerName: String {
        store.container(for: ref)?.name ?? ref.containerID
    }

    /// A stream that ended while the container ran is the stream of an earlier run.
    private var shouldResume: Bool {
        streamEnd == .finished && store.container(for: ref)?.state == .running
    }

    /// The store can report the new state of a container a moment after the stream ends,
    /// so the window waits before it checks again. A stream that ends again at once
    /// is therefore tried at most once per delay.
    private func resumeAfterRestart() async {
        guard shouldResume else {
            return
        }
        try? await Task.sleep(for: Self.resumeDelay)
        if !Task.isCancelled && shouldResume {
            connection += 1
        }
    }

    /// The window keeps its lines when it follows the log again, so that the
    /// output before a stop stays visible. A new stream starts after the last line.
    private func follow() async {
        var needsNotice = !lines.isEmpty
        streamEnd = nil
        do {
            // Adding each line in its own update makes the scroll view lay out and
            // scroll once per line, so the initial tail would visibly scroll past.
            // The window adds all lines that arrive within one interval together.
            let batches = await store.logs(for: ref, after: lastRawLine).chunks(ofCount: Self.maxLines, or: .repeating(every: .milliseconds(100)))
            for try await batch in batches where !batch.isEmpty {
                if needsNotice && connection > 0 {
                    appendNotice()
                }
                needsNotice = false
                append(batch)
            }
            streamEnd = .finished
        } catch is CancellationError {
        } catch {
            streamEnd = .failed(error.localizedDescription)
        }
    }

    /// Separates the lines of an earlier stream from the lines of a later one.
    private func appendNotice() {
        let text = String(localized: "Log stream resumed", bundle: #bundle, comment: "Line in the log window that separates the lines before a restart of the log stream from the lines after it.")
        lines.append(LogLine(id: nextLineID, text: text))
        nextLineID += 1
    }

    private func append(_ batch: [String]) {
        lines += batch.enumerated().map { offset, text in
            LogLine(id: nextLineID + offset, text: text.removingANSIEscapeSequences())
        }
        nextLineID += batch.count
        lastRawLine = batch.last
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }
}

extension String {
    /// Many containers color their output with ANSI escape sequences.
    /// The log window shows plain text, so it removes them.
    func removingANSIEscapeSequences() -> String {
        replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "")
    }
}
