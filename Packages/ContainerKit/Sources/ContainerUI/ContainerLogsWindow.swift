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
        WindowGroup("Logs", for: ContainerRef.self) { $ref in
            if let ref {
                ContainerLogView(store: store, ref: ref)
            }
        }
        .defaultSize(width: 900, height: 540)
        .restorationBehavior(.disabled)
    }
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
    @State private var endMessage: String?

    /// The window keeps at most this many lines, so a noisy container
    /// cannot make the window use unlimited memory.
    private static let maxLines = 10_000

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
            if let endMessage {
                HStack {
                    Text(endMessage)
                    Spacer()
                    Button("Reconnect") {
                        connection += 1
                    }
                }
                .padding()
                .background(.bar)
            }
        }
        .navigationTitle(title)
        .toolbar {
            Button("Copy All", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
            }
            Button("Clear", systemImage: "trash") {
                lines.removeAll()
            }
        }
        .task(id: connection) {
            await follow()
        }
    }

    private var title: String {
        let name = store.container(for: ref)?.name ?? ref.containerID
        return "\(name) (\(ref.source.name))"
    }

    private func follow() async {
        lines.removeAll()
        endMessage = nil
        do {
            // Adding each line in its own update makes the scroll view lay out and
            // scroll once per line, so the initial tail would visibly scroll past.
            // The window adds all lines that arrive within one interval together.
            let batches = await store.logs(for: ref).chunks(ofCount: Self.maxLines, or: .repeating(every: .milliseconds(100)))
            for try await batch in batches {
                append(batch)
            }
            endMessage = String(localized: "The log stream ended.")
        } catch is CancellationError {
        } catch {
            endMessage = error.localizedDescription
        }
    }

    private func append(_ batch: [String]) {
        lines += batch.enumerated().map { offset, text in
            LogLine(id: nextLineID + offset, text: text.removingANSIEscapeSequences())
        }
        nextLineID += batch.count
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
