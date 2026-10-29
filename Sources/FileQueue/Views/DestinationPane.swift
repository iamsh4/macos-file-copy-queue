import SwiftUI
import UniformTypeIdentifiers

struct VolumeInfo: Equatable {
    var exists: Bool
    var name: String?
    var isLocal = true
    var isRemovable = false
    var total: Int64?
    var available: Int64?

    var usedFraction: Double? {
        guard let total, let available, total > 0 else { return nil }
        return Double(total - available) / Double(total)
    }

    static func load(_ url: URL) async -> VolumeInfo {
        await Task.detached(priority: .userInitiated) {
            guard FileOps.isFolder(url) else { return VolumeInfo(exists: false) }
            let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsLocalKey, .volumeIsRemovableKey,
                                             .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
            let v = try? url.resourceValues(forKeys: keys)
            return VolumeInfo(exists: true,
                              name: v?.volumeName,
                              isLocal: v?.volumeIsLocal ?? true,
                              isRemovable: v?.volumeIsRemovable ?? false,
                              total: v?.volumeTotalCapacity.map(Int64.init),
                              available: FileOps.availableCapacity(url))
        }.value
    }
}

struct DestinationPane: View {
    @Environment(QueueManager.self) private var queue
    @State private var pathText = ""
    @State private var pathError: String?
    @State private var targeted = false
    @State private var volume: VolumeInfo?
    @State private var refreshTick = 0
    @FocusState private var pathFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("DESTINATION")
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                card
                pathField

                HStack {
                    Button("Choose…", systemImage: "folder") { queue.chooseDestination() }
                    if let dest = queue.destination {
                        Button("Reveal", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(dest) }
                        Spacer()
                        Button {
                            queue.toggleFavorite(dest)
                        } label: {
                            Image(systemName: queue.isFavorite(dest) ? "star.fill" : "star")
                                .foregroundStyle(queue.isFavorite(dest) ? .yellow : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(queue.isFavorite(dest) ? "Remove from favorites" : "Add to favorites")
                    }
                }
                .controlSize(.regular)

                Label("Drop a folder anywhere on this side to change the destination.", systemImage: "hand.point.up.left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if !queue.favorites.isEmpty {
                    DestinationList(title: "Favorites", urls: queue.favorites, removable: false)
                }
                let recents = queue.recents.filter { !queue.favorites.contains($0) }
                if !recents.isEmpty {
                    DestinationList(title: "Recent", urls: recents, removable: true)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.06))
                    .padding(4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        // The whole pane accepts a folder (a dropped file selects its enclosing folder).
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task { @MainActor in
                guard let url = await loadFileURLs(from: providers).first else { return }
                queue.destination = (FileOps.isFolder(url) ? url : url.deletingLastPathComponent()).standardizedFileURL
            }
            return true
        }
        .task(id: "\(queue.destination?.path ?? "")#\(refreshTick)#\(queue.finishedItems.count)") {
            if let dest = queue.destination { volume = await VolumeInfo.load(dest) } else { volume = nil }
        }
        .onChange(of: queue.destination, initial: true) {
            pathText = queue.destination.map(Fmt.path) ?? ""
            pathError = nil
        }
        .onAppear {
            // Don't let the path field grab focus when the window opens.
            DispatchQueue.main.async { pathFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in refreshTick += 1 }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refreshTick += 1 }
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 10) {
            if let dest = queue.destination {
                FileIcon(url: dest, size: 76)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                Text(dest.lastPathComponent.isEmpty ? "/" : dest.lastPathComponent)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                volumeDetails
            } else {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.tint)
                    .padding(.bottom, 2)
                Text("Drop a destination folder here")
                    .font(.headline)
                Text("or type a path below")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(targeted ? 0 : 0.06), radius: 4, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.primary.opacity(0.08),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [7, 5] : []))
        )
        .animation(.easeOut(duration: 0.15), value: targeted)
    }

    @ViewBuilder
    private var volumeDetails: some View {
        if let volume {
            if !volume.exists {
                Label("Not available. Is the volume mounted?", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: volume.isLocal ? (volume.isRemovable ? "externaldrive" : "internaldrive") : "network")
                    Text(volume.name ?? "Volume")
                    Text("·")
                    Text(volume.isLocal ? (volume.isRemovable ? "External" : "Local") : "Network")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let used = volume.usedFraction, let available = volume.available, let total = volume.total {
                    VStack(spacing: 4) {
                        ProgressView(value: used)
                            .progressViewStyle(.linear)
                            .tint(used > 0.9 ? .red : used > 0.75 ? .orange : .accentColor)
                        Text("\(Fmt.bytes(available)) free of \(Fmt.bytes(total))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: Path field

    private var pathField: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("/Volumes/NAS/Folder", text: $pathText)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .focused($pathFocused)
                    .onSubmit(applyPath)
                if pathFocused {
                    Button("Go", action: applyPath)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(pathError != nil ? Color.red : (pathFocused ? Color.accentColor : Color.primary.opacity(0.12)),
                              lineWidth: pathFocused || pathError != nil ? 1.5 : 1))

            if let pathError {
                Text(pathError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func applyPath() {
        let trimmed = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var path = (trimmed as NSString).expandingTildeInPath
        if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        if FileOps.isFolder(url) {
            pathError = nil
            queue.destination = url
            pathFocused = false
        } else if FileOps.exists(url) {
            pathError = "That's a file, not a folder."
        } else {
            pathError = "No folder exists at that path."
        }
    }
}

private struct DestinationList: View {
    @Environment(QueueManager.self) private var queue
    let title: String
    let urls: [URL]
    let removable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(urls, id: \.self) { url in
                DestinationRow(url: url, selected: url == queue.destination) {
                    queue.destination = url
                }
                .contextMenu {
                    Button(queue.isFavorite(url) ? "Remove from Favorites" : "Add to Favorites") { queue.toggleFavorite(url) }
                    Button("Open in Finder") { NSWorkspace.shared.open(url) }
                    if removable {
                        Button("Remove from Recents") { queue.removeRecent(url) }
                    }
                }
            }
        }
    }
}

private struct DestinationRow: View {
    let url: URL
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                FileIcon(url: url, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(url.lastPathComponent)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(Fmt.path(url.deletingLastPathComponent()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.path)
    }
}
