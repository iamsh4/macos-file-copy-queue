import SwiftUI

struct SettingsView: View {
    @AppStorage(PrefKey.engine) private var engine = TransferEngineKind.builtIn
    @AppStorage(PrefKey.conflict) private var conflict = ConflictPolicy.keepBoth
    @AppStorage(PrefKey.maxConcurrent) private var maxConcurrent = 1
    @AppStorage(PrefKey.verify) private var verify = true
    @AppStorage(PrefKey.trashMovedSources) private var trashMovedSources = false
    @AppStorage(PrefKey.notify) private var notify = true
    @AppStorage(PrefKey.preventSleep) private var preventSleep = true
    @AppStorage(PrefKey.defaultOperation) private var defaultOperation = TransferOperation.copy

    var body: some View {
        Form {
            Section {
                Picker("Transfer engine", selection: $engine) {
                    Text("Built-in").tag(TransferEngineKind.builtIn)
                    Text("Finder").tag(TransferEngineKind.finder)
                }
                .pickerStyle(.segmented)
                Text(engine == .builtIn
                     ? "Uses macOS's copyfile, which preserves the same metadata as Finder (extended attributes, tags, permissions, resource forks, dates). Shows live speed and can be cancelled."
                     : "Asks Finder to copy each item, exactly as if you dragged it yourself. Finder shows its own progress window. Progress here is estimated, and a running item can't be cancelled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(value: $maxConcurrent, in: 1...4) {
                    LabeledContent("Simultaneous transfers", value: "\(maxConcurrent)")
                }
                Picker("If an item already exists", selection: $conflict) {
                    ForEach(ConflictPolicy.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Verify size and file count before finishing", isOn: $verify)
            } header: {
                Text("Transfers")
            } footer: {
                Text("One transfer at a time is usually fastest for a NAS: a single sequential stream avoids disk seeking and SMB contention.")
            }

            Section("Moves") {
                Toggle("Put originals in the Trash instead of deleting them", isOn: $trashMovedSources)
                Text("Like Finder, a move between volumes copies the item and then removes the original. FileQueue removes it only after the copy has finished and been verified. Most network volumes don't have a Trash, so originals there are deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Picker("Dock icon and Services drops", selection: $defaultOperation) {
                    Text("Copy").tag(TransferOperation.copy)
                    Text("Move").tag(TransferOperation.move)
                }
                Toggle("Prevent idle sleep while transferring", isOn: $preventSleep)
                Toggle("Notify when the queue finishes or an item fails", isOn: $notify)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
