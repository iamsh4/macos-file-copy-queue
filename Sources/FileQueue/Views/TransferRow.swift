import SwiftUI

struct TransferRow: View {
    @Environment(QueueManager.self) private var queue
    let item: TransferItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(url: iconURL, size: 34)
                .opacity(item.status.isFinished && item.status != .completed ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    OperationBadge(operation: item.operation)
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(Fmt.path(item.destinationFolder))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if item.status.isActive {
                    ProgressView(value: item.status == .preparing ? nil : item.fraction)
                        .progressViewStyle(.linear)
                        .tint(item.operation.tint)
                        .controlSize(.small)
                }
                detail
            }

            Spacer(minLength: 8)
            accessory
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var iconURL: URL {
        if let final = item.finalURL, item.status == .completed { return final }
        return item.source
    }

    @ViewBuilder
    private var detail: some View {
        switch item.status {
        case .pending:
            Text(item.sizeKnown ? "Waiting · \(Fmt.bytes(item.totalBytes))" : "Waiting")
                .font(.caption).foregroundStyle(.tertiary)
        case .preparing:
            Text("Preparing…").font(.caption).foregroundStyle(.secondary)
        case .copying:
            Text(copyingText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        case .verifying:
            Text("Verifying copy…").font(.caption).foregroundStyle(.secondary)
        case .finishing:
            Text(item.operation == .move ? "Finishing move…" : "Finishing…").font(.caption).foregroundStyle(.secondary)
        case .completed:
            VStack(alignment: .leading, spacing: 2) {
                Text(completedText).font(.caption).foregroundStyle(.secondary)
                if let warning = item.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        case let .failed(message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        case let .skipped(reason):
            Text("Skipped: \(reason)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var copyingText: String {
        var parts = ["\(Fmt.bytes(item.copiedBytes)) of \(Fmt.bytes(item.totalBytes))"]
        if item.fileCount > 1 { parts.append("\(item.fileCount) files") }
        if item.bytesPerSecond > 0 { parts.append(Fmt.rate(item.bytesPerSecond)) }
        if let eta = item.eta { parts.append("\(Fmt.duration(eta)) left") }
        return parts.joined(separator: " · ")
    }

    private var completedText: String {
        var text = item.operation == .move ? "Moved" : "Copied"
        if let final = item.finalURL, final.lastPathComponent != item.name { text += " as “\(final.lastPathComponent)”" }
        text += " · \(Fmt.bytes(item.totalBytes))"
        if let d = item.duration, d >= 1 {
            text += " in \(Fmt.duration(d))"
            if item.totalBytes > 0 { text += " (\(Fmt.rate(Double(item.totalBytes) / d)))" }
        }
        return text
    }

    @ViewBuilder
    private var accessory: some View {
        if hovering {
            HStack(spacing: 6) { actions }
                .buttonStyle(.borderless)
                .font(.title3)
        } else {
            statusIcon
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch item.status {
        case .pending:
            RowButton("arrow.up.to.line", "Move to top") { queue.moveToTop(item.id) }
            RowButton("xmark.circle.fill", "Remove from queue") { queue.remove([item.id]) }
        case .preparing, .copying, .verifying, .finishing:
            if item.isCancellable {
                RowButton("stop.circle.fill", "Cancel transfer") { queue.cancel(item.id) }
            } else {
                statusIcon.help("Finder transfers can't be cancelled from FileQueue")
            }
        case .completed:
            RowButton("magnifyingglass.circle.fill", "Show in Finder") {
                if let final = item.finalURL { NSWorkspace.shared.activateFileViewerSelecting([final]) }
            }
            RowButton("xmark.circle.fill", "Remove from list") { queue.remove([item.id]) }
        case .failed, .cancelled, .skipped:
            RowButton("arrow.clockwise.circle.fill", "Retry") { queue.retry([item.id]) }
            RowButton("xmark.circle.fill", "Remove from list") { queue.remove([item.id]) }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.tertiary)
        case .preparing, .verifying, .finishing:
            ProgressView().controlSize(.small)
        case .copying:
            Text(item.fraction, format: .percent.precision(.fractionLength(0)))
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(item.operation.tint)
        case .completed:
            Image(systemName: item.warning == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(item.warning == nil ? .green : .orange)
                .font(.title3)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.title3)
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary).font(.title3)
        case .skipped:
            Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.secondary).font(.title3)
        }
    }
}

private struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    init(_ symbol: String, _ help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
        }
        .foregroundStyle(.secondary)
        .help(help)
    }
}
