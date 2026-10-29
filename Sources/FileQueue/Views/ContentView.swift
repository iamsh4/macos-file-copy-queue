import SwiftUI

struct ContentView: View {
    @Environment(QueueManager.self) private var queue

    var body: some View {
        HSplitView {
            QueuePane()
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            DestinationPane()
                .frame(minWidth: 290, idealWidth: 330, maxWidth: 460, maxHeight: .infinity)
        }
        .navigationTitle("FileQueue")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Items to Copy…", systemImage: TransferOperation.copy.symbol) { queue.presentAddPanel(.copy) }
                    Button("Items to Move…", systemImage: TransferOperation.move.symbol) { queue.presentAddPanel(.move) }
                    Divider()
                    Button("Paste as Copy") { queue.pasteFromClipboard(.copy) }
                    Button("Paste as Move") { queue.pasteFromClipboard(.move) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add items to the queue")

                Button {
                    queue.isPaused.toggle()
                } label: {
                    Label(queue.isPaused ? "Resume" : "Pause", systemImage: queue.isPaused ? "play.fill" : "pause.fill")
                }
                .help(queue.isPaused ? "Resume the queue" : "Pause after the current transfer")

                Button {
                    withAnimation { queue.clearFinished() }
                } label: {
                    Label("Clear Finished", systemImage: "checkmark.rectangle.stack")
                }
                .help("Clear finished items")
                .disabled(queue.finishedItems.isEmpty)

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
    }

    private var subtitle: String {
        let o = queue.overall
        if queue.isPaused && o.remainingItems > 0 { return "Paused · \(o.remainingItems) remaining" }
        if o.remainingItems == 0 { return "Idle" }
        return "\(o.remainingItems) remaining"
    }
}
