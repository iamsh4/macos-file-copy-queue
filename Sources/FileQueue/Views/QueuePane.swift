import SwiftUI
import UniformTypeIdentifiers

enum DropZone: Equatable {
    case copy, move, noDestination

    var operation: TransferOperation? {
        switch self {
        case .copy: .copy
        case .move: .move
        case .noDestination: nil
        }
    }
}

struct QueuePane: View {
    @Environment(QueueManager.self) private var queue
    @State private var selection = Set<UUID>()
    @State private var dropZone: DropZone?
    @AppStorage("showSpeedGraph") private var showSpeedGraph = true

    var body: some View {
        VStack(spacing: 0) {
            if queue.isPaused {
                PausedBanner(reason: queue.pauseReason) { queue.isPaused = false }
            }
            GeometryReader { geo in
                ZStack {
                    if queue.items.isEmpty {
                        EmptyQueueView(destination: queue.destination)
                    } else {
                        queueList
                    }
                    if let dropZone {
                        DropOverlay(zone: dropZone, destination: queue.destination)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .onDrop(of: [.fileURL], delegate: QueueDropDelegate(height: geo.size.height, zone: $dropZone, queue: queue))
            }
            if showSpeedGraph {
                SpeedGraph()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            QueueFooter()
        }
    }

    private var queueList: some View {
        List(selection: $selection) {
            if !queue.activeItems.isEmpty {
                Section("In Progress") {
                    ForEach(queue.activeItems) { item in
                        TransferRow(item: item).tag(item.id).contextMenu { menu(for: item) }
                    }
                }
            }
            if !queue.pendingItems.isEmpty {
                Section("Up Next") {
                    ForEach(queue.pendingItems) { item in
                        TransferRow(item: item).tag(item.id).contextMenu { menu(for: item) }
                    }
                    .onMove { queue.movePending(from: $0, to: $1) }
                }
            }
            if !queue.finishedItems.isEmpty {
                Section("Finished") {
                    ForEach(queue.finishedItems) { item in
                        TransferRow(item: item).tag(item.id).contextMenu { menu(for: item) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onDeleteCommand { queue.remove(selection) }
        .animation(.default, value: queue.items.map(\.status))
    }

    /// Context-menu actions apply to the whole selection when the clicked row is part of it.
    @ViewBuilder
    private func menu(for item: TransferItem) -> some View {
        let ids = selection.contains(item.id) ? selection : [item.id]
        let targets = queue.items.filter { ids.contains($0.id) }

        if targets.contains(where: { $0.status == .pending }) {
            Button("Move to Top") { ids.forEach(queue.moveToTop) }
            Menu("Change To") {
                Button("Copy") { queue.setOperation(.copy, for: ids) }
                Button("Move") { queue.setOperation(.move, for: ids) }
            }
        }
        if targets.contains(where: { $0.status.isRetryable }) {
            Button("Retry") { queue.retry(ids) }
        }
        if targets.contains(where: { $0.status.isActive && $0.isCancellable }) {
            Button("Cancel Transfer") { targets.filter(\.status.isActive).forEach { queue.cancel($0.id) } }
        }
        Divider()
        if let final = item.finalURL, FileOps.exists(final) {
            Button("Show Copy in Finder") { NSWorkspace.shared.activateFileViewerSelecting([final]) }
        }
        if FileOps.exists(item.source) {
            Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.source]) }
        }
        Button("Open Destination Folder") { NSWorkspace.shared.open(item.destinationFolder) }
        Button("Copy Destination Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.destinationFolder.path, forType: .string)
        }
        if targets.contains(where: { !$0.status.isActive }) {
            Divider()
            Button("Remove from Queue", role: .destructive) { queue.remove(ids) }
        }
    }
}

// MARK: - Drop handling

struct QueueDropDelegate: DropDelegate {
    let height: CGFloat
    @Binding var zone: DropZone?
    let queue: QueueManager

    private func zone(for info: DropInfo) -> DropZone {
        guard queue.destination != nil else { return .noDestination }
        return info.location.y < height / 2 ? .copy : .move
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.15)) { zone = zone(for: info) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let z = zone(for: info)
        if z != zone { withAnimation(.spring(duration: 0.22)) { zone = z } }
        switch z {
        case .copy: return DropProposal(operation: .copy)
        case .move: return DropProposal(operation: .move)
        case .noDestination: return DropProposal(operation: .forbidden)
        }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.15)) { zone = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let z = zone(for: info)
        withAnimation(.easeOut(duration: 0.2)) { zone = nil }
        guard let op = z.operation else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            let urls = await loadFileURLs(from: providers)
            withAnimation { _ = queue.enqueue(urls, operation: op) }
        }
        return true
    }
}

struct DropOverlay: View {
    let zone: DropZone
    let destination: URL?

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            if let destination {
                VStack(spacing: 14) {
                    DropZoneCard(operation: .copy, active: zone == .copy, destination: destination)
                    DropZoneCard(operation: .move, active: zone == .move, destination: destination)
                }
                .padding(22)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("Choose a destination first")
                        .font(.title3.weight(.semibold))
                    Text("Drop a folder on the right, or type its path.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct DropZoneCard: View {
    let operation: TransferOperation
    let active: Bool
    let destination: URL

    var body: some View {
        let tint = operation.tint
        VStack(spacing: 8) {
            Image(systemName: operation == .copy ? "plus.square.on.square" : "arrow.right.square")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(active ? tint : .secondary)
                .symbolEffect(.bounce, value: active)
            Text("Queue \(operation.title)")
                .font(.title2.weight(.bold))
                .foregroundStyle(active ? .primary : .secondary)
            Text("to “\(destination.lastPathComponent)”")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(operation == .copy ? "Originals stay where they are" : "Originals are removed only after a complete, verified copy")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(active ? tint.opacity(0.16) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(active ? tint : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: active ? 2.5 : 1.5, dash: active ? [] : [8, 6]))
        )
        .scaleEffect(active ? 1 : 0.97)
        .animation(.spring(duration: 0.25), value: active)
    }
}

// MARK: - Empty state, banner, footer

struct EmptyQueueView: View {
    let destination: URL?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Drop files here to queue them")
                .font(.title2.weight(.semibold))
            VStack(spacing: 4) {
                Label("Upper half copies", systemImage: "plus.square.on.square")
                Label("Lower half moves", systemImage: "arrow.right.square")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Text(destination.map { "Items transfer one at a time to “\($0.lastPathComponent)”." }
                 ?? "Set a destination folder on the right to get started.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [9, 7]))
                .padding(18)
        )
    }
}

struct PausedBanner: View {
    let reason: String?
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .font(.title3)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("Queue paused").font(.callout.weight(.semibold))
                Text(reason ?? "No new transfers start until you resume.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resume", action: resume)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct QueueFooter: View {
    @Environment(QueueManager.self) private var queue
    @AppStorage("showSpeedGraph") private var showSpeedGraph = true

    var body: some View {
        let o = queue.overall
        HStack(spacing: 12) {
            if o.remainingItems > 0 {
                ProgressView(value: o.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 160)
                    .tint(queue.isPaused ? .secondary : .accentColor)
                Text(summary(o))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(queue.items.isEmpty ? "Ready" : "All transfers finished")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if o.remainingItems > 0 && !queue.activeItems.isEmpty {
                Label(o.bytesPerSecond > 0 ? Fmt.rate(o.bytesPerSecond) : "–", systemImage: "speedometer")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                    .help("Current transfer speed")
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSpeedGraph.toggle() }
            } label: {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundStyle(showSpeedGraph ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(showSpeedGraph ? "Hide speed graph" : "Show speed graph")
            if o.remainingItems > 0 {
                Button(queue.isPaused ? "Resume" : "Pause", systemImage: queue.isPaused ? "play.fill" : "pause.fill") {
                    queue.isPaused.toggle()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { if !showSpeedGraph { Divider() } }
    }

    private func summary(_ o: OverallProgress) -> String {
        var parts = ["\(o.remainingItems) remaining"]
        if o.totalBytes > 0 {
            parts.append("\(Fmt.bytes(o.doneBytes)) of \(Fmt.bytes(o.totalBytes))\(o.unmeasuredItems > 0 ? "+" : "")")
        }
        if let eta = o.eta, o.unmeasuredItems == 0 { parts.append("about \(Fmt.duration(eta)) left") }
        return parts.joined(separator: " · ")
    }
}
