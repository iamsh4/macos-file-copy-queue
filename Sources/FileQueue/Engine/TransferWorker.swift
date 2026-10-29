import Foundation
import Darwin

struct TransferOptions {
    var engine: TransferEngineKind
    var conflict: ConflictPolicy
    var verify: Bool
    var trashMovedSources: Bool

    static var current: TransferOptions {
        TransferOptions(engine: Prefs.engine, conflict: Prefs.conflict, verify: Prefs.verify,
                        trashMovedSources: Prefs.trashMovedSources)
    }
}

enum TransferPhase {
    case preparing, copying, verifying, finishing

    var status: TransferStatus {
        switch self {
        case .preparing: .preparing
        case .copying: .copying
        case .verifying: .verifying
        case .finishing: .finishing
        }
    }
}

enum TransferOutcome {
    case completed(URL, warning: String?)
    case skipped(String)
    case failed(String)
    case cancelled
    /// A volume went away (NAS asleep, share unmounted). The item should go back to pending and the queue pause.
    case volumeUnavailable(String)
}

private struct Failure: Error { let message: String }
private struct Cancelled: Error {}
private struct VolumeUnavailable: Error { let message: String }

/// Performs one queued transfer, synchronously, on whatever thread calls `run()`.
///
/// Copies always land under a hidden temporary name inside the destination folder and are only
/// renamed into place after the copy (and optional verification) succeeds. For moves, the source
/// is only removed after that point, so an interrupted move never loses data.
final class TransferWorker: @unchecked Sendable {
    let id: UUID
    let source: URL
    let destinationFolder: URL
    let operation: TransferOperation
    let options: TransferOptions

    var onPhase: ((TransferPhase) -> Void)?
    var onTotal: ((FileOps.Tally) -> Void)?
    var onProgress: ((Int64) -> Void)?

    private let lock = NSLock()
    private var _cancelled = false
    private var finderProcess: Process?

    init(id: UUID, source: URL, destinationFolder: URL, operation: TransferOperation, options: TransferOptions) {
        self.id = id
        self.source = source.standardizedFileURL
        self.destinationFolder = destinationFolder.standardizedFileURL
        self.operation = operation
        self.options = options
    }

    var isCancelled: Bool { lock.withLock { _cancelled } }

    /// The Finder engine can't be interrupted cleanly (Finder keeps copying), so only `force` stops it.
    func cancel(force: Bool = false) {
        let process: Process? = lock.withLock {
            _cancelled = true
            return force ? finderProcess : nil
        }
        process?.terminate()
    }

    private var shortID: String { String(id.uuidString.prefix(8)) }

    func run() -> TransferOutcome {
        do {
            return try perform()
        } catch is Cancelled {
            return .cancelled
        } catch let f as Failure {
            return .failed(f.message)
        } catch let v as VolumeUnavailable {
            return .volumeUnavailable(v.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func checkCancelled() throws {
        if isCancelled { throw Cancelled() }
    }

    private func perform() throws -> TransferOutcome {
        let fm = FileManager.default
        onPhase?(.preparing)

        // Unmounted volumes pause the queue instead of failing items.
        for url in [source, destinationFolder] {
            if let root = FileOps.mountRoot(of: url), !FileOps.exists(root) {
                throw VolumeUnavailable(message: "“\(root.lastPathComponent)” isn't mounted.")
            }
        }
        guard FileOps.isFolder(destinationFolder) else {
            throw VolumeUnavailable(message: "The destination folder “\(destinationFolder.lastPathComponent)” isn't available.")
        }
        guard FileOps.exists(source) else {
            throw Failure(message: "The original item no longer exists.")
        }
        if FileOps.isSameOrDescendant(destinationFolder, of: source) {
            throw Failure(message: "Can't \(operation.verb) a folder into itself.")
        }
        if operation == .move {
            if source.deletingLastPathComponent().standardizedFileURL.path == destinationFolder.path {
                return .skipped("Already in the destination folder.")
            }
            if !fm.isDeletableFile(atPath: source.path) {
                throw Failure(message: "The original can't be removed (read-only or no permission). Use Copy instead.")
            }
        }

        let name = source.lastPathComponent
        let srcIsDir = FileOps.isDirectory(source)
        var target = destinationFolder.appendingPathComponent(name)
        var replacing: URL?
        if FileOps.exists(target) {
            switch options.conflict {
            case .skip:
                return .skipped("“\(name)” already exists in the destination.")
            case .replace where target.path != source.path:
                replacing = target
            case .replace, .keepBoth:
                target = FileOps.uniqueURL(named: name, in: destinationFolder, isDirectory: srcIsDir)
            }
        }

        // Same-volume move: a rename, exactly what Finder does.
        if operation == .move && FileOps.sameVolume(source, destinationFolder) {
            onPhase?(.finishing)
            if let replacing { try FileOps.discard(replacing, preferTrash: true) }
            try fm.moveItem(at: source, to: target)
            return .completed(target, warning: nil)
        }

        let srcTally = FileOps.tally(source, cancelled: { self.isCancelled })
        try checkCancelled()
        onTotal?(srcTally)

        if let free = FileOps.availableCapacity(destinationFolder), free < srcTally.bytes {
            let fmt = ByteCountFormatter.string(fromByteCount:countStyle:)
            throw Failure(message: "Not enough space: needs \(fmt(srcTally.bytes, .file)), \(fmt(free, .file)) available.")
        }

        onPhase?(.copying)
        let staged: URL
        let cleanup: URL
        switch options.engine {
        case .builtIn:
            let partial = destinationFolder.appendingPathComponent(".filequeue-\(shortID)-\(name)")
            staged = partial
            cleanup = partial
            FileOps.removeQuietly(partial)
            do {
                try copyWithCopyfile(to: partial, total: srcTally.bytes, isDirectory: srcIsDir)
            } catch {
                FileOps.removeQuietly(partial)
                throw error
            }
        case .finder:
            let staging = destinationFolder.appendingPathComponent(".filequeue-\(shortID)", isDirectory: true)
            staged = staging.appendingPathComponent(name)
            cleanup = staging
            FileOps.removeQuietly(staging)
            do {
                try copyWithFinder(into: staging, staged: staged)
            } catch {
                FileOps.removeQuietly(staging)
                throw error
            }
        }
        onProgress?(srcTally.bytes)

        do {
            try checkCancelled()
            if options.verify {
                onPhase?(.verifying)
                let dstTally = FileOps.tally(staged)
                if dstTally != srcTally {
                    let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                    throw Failure(message: "Verification failed: copied \(dstTally.files) items / \(fmt(dstTally.bytes)), expected \(srcTally.files) / \(fmt(srcTally.bytes)).")
                }
            }
            try checkCancelled()
            onPhase?(.finishing)
            if let replacing { try FileOps.discard(replacing, preferTrash: true) }
            try fm.moveItem(at: staged, to: target)
        } catch {
            FileOps.removeQuietly(cleanup)
            throw error
        }
        if cleanup != staged { FileOps.removeQuietly(cleanup) }

        if operation == .move {
            do {
                try FileOps.discard(source, preferTrash: options.trashMovedSources)
            } catch {
                return .completed(target, warning: "Copied, but the original couldn't be removed: \(error.localizedDescription)")
            }
        }
        return .completed(target, warning: nil)
    }

    // MARK: Built-in engine (copyfile)

    private func copyWithCopyfile(to dst: URL, total: Int64, isDirectory: Bool) throws {
        let ctx = CopyContext(worker: self)
        guard let state = copyfile_state_alloc() else { throw Failure(message: "Couldn't start the copy.") }
        defer { copyfile_state_free(state) }

        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyfileStatusCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(ctx).toOpaque())

        // COPYFILE_ALL preserves data, xattrs, ACLs, resource forks, tags, and timestamps (the same
        // metadata Finder preserves). Cloning is attempted for single files on APFS.
        var flags = Int32(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC)
        if !isDirectory { flags |= Int32(COPYFILE_CLONE) }

        let rc = withExtendedLifetime(ctx) {
            copyfile(source.path, dst.path, state, copyfile_flags_t(flags))
        }
        let err = errno
        try checkCancelled()
        if rc != 0 {
            let code = ctx.failedErrno != 0 ? ctx.failedErrno : err
            var message = String(cString: strerror(code))
            if let path = ctx.failedPath, path != source.path {
                message += " (\((path as NSString).lastPathComponent))"
            }
            if code == ENOENT || code == ENXIO || code == EIO, let root = FileOps.mountRoot(of: destinationFolder), !FileOps.exists(root) {
                throw VolumeUnavailable(message: "“\(root.lastPathComponent)” disconnected during the transfer.")
            }
            throw Failure(message: message)
        }
    }

    // MARK: Finder engine (Apple Events)

    private func copyWithFinder(into staging: URL, staged: URL) throws {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)

        let script = [
            "on run argv",
            "set srcItem to (POSIX file (item 1 of argv)) as alias",
            "set dstFolder to (POSIX file (item 2 of argv)) as alias",
            "with timeout of 2592000 seconds",
            "tell application \"Finder\" to duplicate srcItem to dstFolder",
            "end timeout",
            "end run",
        ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = script.flatMap { ["-e", $0] } + [source.path, staging.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice

        try lock.withLock {
            if _cancelled { throw Cancelled() }
            try process.run()
            finderProcess = process
        }
        defer { lock.withLock { finderProcess = nil } }

        // Finder doesn't report progress over Apple Events; measure what has landed so far.
        while process.isRunning {
            let t0 = ProcessInfo.processInfo.systemUptime
            if FileOps.exists(staged) { onProgress?(FileOps.tally(staged).bytes) }
            let wait = max(1.0, (ProcessInfo.processInfo.systemUptime - t0) * 4)
            let until = Date().addingTimeInterval(wait)
            while process.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.1) }
        }
        process.waitUntilExit()
        try checkCancelled()

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("-1743") {
                throw Failure(message: "FileQueue isn't allowed to control Finder. Allow it in System Settings › Privacy & Security › Automation, or switch to the built-in engine.")
            }
            let cleaned = text.replacingOccurrences(of: #"^\d+:\d+: execution error: "#, with: "", options: .regularExpression)
            throw Failure(message: "Finder: \(cleaned.isEmpty ? "the copy failed" : cleaned)")
        }
        guard FileOps.exists(staged) else {
            throw Failure(message: "Finder reported success but the copy wasn't found.")
        }
    }
}

// MARK: - copyfile callback

private final class CopyContext {
    let worker: TransferWorker
    var completed: Int64 = 0
    var current: Int64 = 0
    var lastReport: TimeInterval = 0
    var failedErrno: Int32 = 0
    var failedPath: String?

    init(worker: TransferWorker) { self.worker = worker }

    func report() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReport >= 0.1 else { return }
        lastReport = now
        worker.onProgress?(completed + current)
    }
}

private let copyfileStatusCallback: copyfile_callback_t = { what, stage, state, src, _, ctx in
    guard let ctx else { return COPYFILE_CONTINUE }
    let c = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
    if c.worker.isCancelled { return COPYFILE_QUIT }

    switch (what, stage) {
    case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
        var copied: off_t = 0
        if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
            c.current = Int64(copied)
            c.report()
        }
    case (COPYFILE_RECURSE_FILE, COPYFILE_START):
        c.current = 0
    case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
        if let src {
            var st = stat()
            if lstat(src, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { c.completed += Int64(st.st_size) }
        }
        c.current = 0
        c.report()
    case (COPYFILE_COPY_XATTR, COPYFILE_ERR):
        // Some NAS shares reject individual extended attributes; Finder carries on too.
        return COPYFILE_CONTINUE
    case (_, COPYFILE_ERR):
        c.failedErrno = errno
        c.failedPath = src.map { String(cString: $0) }
        return COPYFILE_QUIT
    default:
        break
    }
    return COPYFILE_CONTINUE
}
