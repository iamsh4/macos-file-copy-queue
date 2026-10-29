import Foundation
import Observation

enum TransferStatus: Codable, Equatable {
    case pending
    case preparing
    case copying
    case verifying
    case finishing
    case completed
    case failed(String)
    case cancelled
    case skipped(String)

    var isActive: Bool {
        switch self {
        case .preparing, .copying, .verifying, .finishing: true
        default: false
        }
    }

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled, .skipped: true
        default: false
        }
    }

    var isRetryable: Bool {
        switch self {
        case .failed, .cancelled, .skipped: true
        default: false
        }
    }
}

@Observable
final class TransferItem: Identifiable {
    let id: UUID
    let source: URL
    let destinationFolder: URL
    var operation: TransferOperation
    var status: TransferStatus = .pending
    var totalBytes: Int64 = 0
    var fileCount: Int = 0
    var sizeKnown = false
    var copiedBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    var isCancellable = true
    var finalURL: URL?
    var warning: String?
    let addedAt: Date
    var startedAt: Date?
    var finishedAt: Date?

    @ObservationIgnored var lastSample: (time: TimeInterval, bytes: Int64)?

    init(id: UUID = UUID(), source: URL, destinationFolder: URL, operation: TransferOperation, addedAt: Date = Date()) {
        self.id = id
        self.source = source
        self.destinationFolder = destinationFolder
        self.operation = operation
        self.addedAt = addedAt
    }

    var name: String { source.lastPathComponent }

    var fraction: Double {
        guard totalBytes > 0 else { return status == .completed ? 1 : 0 }
        return min(1, Double(copiedBytes) / Double(totalBytes))
    }

    var eta: TimeInterval? {
        guard bytesPerSecond > 1, totalBytes > copiedBytes else { return nil }
        return Double(totalBytes - copiedBytes) / bytesPerSecond
    }

    var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    // MARK: Persistence

    struct Record: Codable {
        var id: UUID
        var source: URL
        var destinationFolder: URL
        var operation: TransferOperation
        var status: TransferStatus
        var totalBytes: Int64
        var fileCount: Int
        var sizeKnown: Bool
        var finalURL: URL?
        var warning: String?
        var addedAt: Date
        var startedAt: Date?
        var finishedAt: Date?
    }

    var record: Record {
        Record(id: id, source: source, destinationFolder: destinationFolder, operation: operation,
               status: status.isActive ? .pending : status, totalBytes: totalBytes, fileCount: fileCount,
               sizeKnown: sizeKnown, finalURL: finalURL, warning: warning, addedAt: addedAt,
               startedAt: startedAt, finishedAt: finishedAt)
    }

    convenience init(record r: Record) {
        self.init(id: r.id, source: r.source, destinationFolder: r.destinationFolder, operation: r.operation, addedAt: r.addedAt)
        status = r.status.isActive ? .pending : r.status
        totalBytes = r.totalBytes
        fileCount = r.fileCount
        sizeKnown = r.sizeKnown
        finalURL = r.finalURL
        warning = r.warning
        startedAt = r.startedAt
        finishedAt = r.finishedAt
        if status == .completed { copiedBytes = totalBytes }
    }
}
