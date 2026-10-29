import SwiftUI

@main
struct FileQueueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var queue = QueueManager.shared

    var body: some Scene {
        Window("FileQueue", id: "main") {
            ContentView()
                .environment(queue)
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1040, height: 660)
        .windowToolbarStyle(.unified)
        .commands { QueueCommands(queue: queue) }

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            StatusMenu()
                .environment(queue)
        } label: {
            StatusLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}

struct QueueCommands: Commands {
    let queue: QueueManager

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Items to Copy…") { queue.presentAddPanel(.copy) }
                .keyboardShortcut("o")
            Button("Add Items to Move…") { queue.presentAddPanel(.move) }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Divider()
            Button("Choose Destination…") { queue.chooseDestination() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        CommandMenu("Queue") {
            Button("Paste Items as Copy") { queue.pasteFromClipboard(.copy) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Paste Items as Move") { queue.pasteFromClipboard(.move) }
                .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            Divider()
            Button(queue.isPaused ? "Resume Queue" : "Pause Queue") { queue.isPaused.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Clear Finished") { queue.clearFinished() }
                .keyboardShortcut("k")
            Divider()
            Button("Cancel All") { queue.cancelAll() }
        }
    }
}
