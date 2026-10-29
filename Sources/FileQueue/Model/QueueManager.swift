import AppKit
import Observation

struct SpeedSample: Identifiable {
    let time: Date
    let bytesPerSecond: Double
    var id: Date { time }
}

struct OverallProgress {
    var doneBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    var remainingItems = 0
    var unmeasuredItems = 0

    var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
    var eta: TimeInterval? {
        guard bytesPerSecond > 1, totalBytes > doneBytes else { return nil }
        return Double(totalBytes - doneBytes) / bytesPerSecond
    }
}

@MainActor
@Observable
final class QueueManager {
    static let shared = QueueManager()

    private(set) var items: [TransferItem] = []
    private(set) var recents: [URL] = []
    private(set) var favorites: [URL] = []
    private(set) var pauseReason: String?
    /// Aggregate throughput, one sample per `speedSampleInterval`, covering the last `speedWindow`.
    private(set) var speedHistory: [SpeedSample] = []

    static let speedSampleInterval: TimeInterval = 5
    static let speedWindow: TimeInterval = 10 * 60

    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if !isPaused { pauseReason = nil }
            scheduleSave()
            schedule()
        }
    }

    var destination: URL? {
        didSet {
            guard destination != oldValue else { return }
            Prefs.d.set(destination?.path, forKey: PrefKey.destination)
            if let destination { noteRecent(destination) }
        }
    }

    @ObservationIgnored private var workers: [UUID: TransferWorker] = [:]
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var quitCompletion: (() -> Void)?
    @ObservationIgnored private let dock = DockProgress()
    @ObservationIgnored private var sessionStart: Date?
    @ObservationIgnored private var sessionCompleted = 0
    @ObservationIgnored private var sessionFailed = 0
    /// Result of the last finished run, shown as a checkmark (or alert) in the menu bar until new work starts.
    @ObservationIgnored private var lastRunSucceeded: Bool?
    @ObservationIgnored private var bytesTransferred: Int64 = 0
    @ObservationIgnored private var lastSpeedSample = (time: ProcessInfo.processInfo.systemUptime, bytes: Int64(0))
    @ObservationIgnored private let tallyQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    private init() {
        Prefs.register()
        load()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        DispatchQueue.main.async { self.schedule() }

        let timer = Timer(timeInterval: Self.speedSampleInterval, repeats: true) { _ in
            MainActor.assumeIsolated { QueueManager.shared.sampleSpeed() }
        }
        RunLoop.main.add(timer, forMode: .common)

        // Debug: `open FileQueue.app --args -FQDemoSpeed YES` seeds the graph with synthetic data.
        if Prefs.d.bool(forKey: "FQDemoSpeed") {
            let now = Date()
            speedHistory = (0..<120).map { i in
                let t = Double(i)
                let rate = i < 20 ? 0 : 95e6 + 18e6 * sin(t / 6) + Double((i * 7919) % 13) * 1.5e6 - (i > 70 && i < 80 ? 70e6 : 0)
                return SpeedSample(time: now.addingTimeInterval(-Double(119 - i) * Self.speedSampleInterval), bytesPerSecond: max(0, rate))
            }
        }
    }

    /// Records bytes moved since the last sample. Keeps sampling (zeros included) while anything
    /// is running or the window still shows activity, so the graph decays to empty after going idle.
    private func sampleSpeed() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastSpeedSample.time
        let rate = dt > 0 ? Double(bytesTransferred - lastSpeedSample.bytes) / dt : 0
        lastSpeedSample = (now, bytesTransferred)

        let cutoff = Date().addingTimeInterval(-Self.speedWindow)
        speedHistory.removeAll { $0.time < cutoff }
        if rate > 0 || !workers.isEmpty || speedHistory.contains(where: { $0.bytesPerSecond > 0 }) {
            speedHistory.append(SpeedSample(time: Date(), bytesPerSecond: rate))
        } else if !speedHistory.isEmpty {
            speedHistory.removeAll()
        }
    }

    // MARK: Derived state

    var activeItems: [TransferItem] { items.filter { $0.status.isActive } }
    var pendingItems: [TransferItem] { items.filter { $0.status == .pending } }
    var finishedItems: [TransferItem] {
        items.filter { $0.status.isFinished }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }
    var hasWork: Bool { items.contains { $0.status == .pending || $0.status.isActive } }
    var hasActiveTransfers: Bool { !workers.isEmpty }

    var overall: OverallProgress {
        var o = OverallProgress()
        let start = sessionStart ?? .distantFuture
        for item in items {
            switch item.status {
            case .pending:
                o.remainingItems += 1
                if item.sizeKnown { o.totalBytes += item.totalBytes } else { o.unmeasuredItems += 1 }
            case .preparing, .copying, .verifying, .finishing:
                o.remainingItems += 1
                o.totalBytes += item.totalBytes
                o.doneBytes += item.copiedBytes
                o.bytesPerSecond += item.bytesPerSecond
            case .completed where (item.finishedAt ?? .distantPast) >= start:
                o.totalBytes += item.totalBytes
                o.doneBytes += item.totalBytes
            default:
                break
            }
        }
        return o
    }

    func item(_ id: UUID) -> TransferItem? { items.first { $0.id == id } }

    // MARK: Enqueueing

    @discardableResult
    func enqueue(_ urls: [URL], operation: TransferOperation, to folder: URL? = nil) -> Int {
        guard let dest = (folder ?? destination)?.standardizedFileURL else { return 0 }
        var added = 0
        for url in urls {
            let src = url.standardizedFileURL
            let duplicate = items.contains {
                !$0.status.isFinished && $0.source == src && $0.destinationFolder == dest
            }
            if duplicate { continue }
            let item = TransferItem(source: src, destinationFolder: dest, operation: operation)
            items.append(item)
            measure(item)
            added += 1
        }
        guard added > 0 else { return 0 }
        noteRecent(dest)
        Notifier.requestAuthorizationIfNeeded()
        scheduleSave()
        schedule()
        return added
    }

    /// Entry point for Dock drops, Services, and paste: brings the app forward and needs a destination.
    func enqueueExternal(_ urls: [URL], operation: TransferOperation) {
        WindowOpener.showMainWindow()
        guard !urls.isEmpty, ensureDestination() else { return }
        enqueue(urls, operation: operation)
    }

    /// Pre-measures local sources so overall progress and ETA cover the whole queue.
    /// Network sources are measured when they start, to avoid competing with the active transfer.
    private func measure(_ item: TransferItem) {
        let id = item.id
        let url = item.source
        tallyQueue.addOperation {
            guard FileOps.isLocalVolume(url) else { return }
            let t = FileOps.tally(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let item = self.item(id), item.status == .pending, !item.sizeKnown else { return }
                    item.totalBytes = t.bytes
                    item.fileCount = t.files
                    item.sizeKnown = true
                }
            }
        }
    }

    // MARK: Queue editing

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) && !$0.status.isActive }
        scheduleSave()
    }

    func cancel(_ id: UUID) {
        workers[id]?.cancel()
    }

    func cancelAll() {
        for (_, w) in workers where w.options.engine == .builtIn { w.cancel() }
        for item in items where item.status == .pending { item.status = .cancelled; item.finishedAt = Date() }
        scheduleSave()
    }

    func retry(_ ids: Set<UUID>) {
        let retried = items.filter { ids.contains($0.id) && $0.status.isRetryable }
        guard !retried.isEmpty else { return }
        items.removeAll { r in retried.contains { $0 === r } }
        for item in retried {
            item.status = .pending
            item.copiedBytes = 0
            item.finishedAt = nil
            item.warning = nil
            items.append(item)
        }
        scheduleSave()
        schedule()
    }

    func moveToTop(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].status == .pending else { return }
        let item = items.remove(at: idx)
        items.insert(item, at: 0)
        scheduleSave()
    }

    func movePending(from offsets: IndexSet, to destination: Int) {
        var pending = pendingItems
        pending.move(fromOffsets: offsets, toOffset: destination)
        items = items.filter { $0.status != .pending } + pending
        scheduleSave()
    }

    func setOperation(_ op: TransferOperation, for ids: Set<UUID>) {
        for item in items where ids.contains(item.id) && item.status == .pending { item.operation = op }
        scheduleSave()
    }

    func clearFinished() {
        items.removeAll { $0.status.isFinished }
        lastRunSucceeded = nil
        updateDock()
        scheduleSave()
    }

    // MARK: Scheduling

    func schedule() {
        guard quitCompletion == nil else { return }
        while !isPaused, workers.count < Prefs.maxConcurrent,
              let next = items.first(where: { $0.status == .pending }) {
            start(next)
        }
        updateSleepAssertion()
        updateDock()
    }

    private func start(_ item: TransferItem) {
        lastRunSucceeded = nil
        if sessionStart == nil {
            sessionStart = Date()
            sessionCompleted = 0
            sessionFailed = 0
        }
        let options = TransferOptions.current
        let worker = TransferWorker(id: item.id, source: item.source, destinationFolder: item.destinationFolder,
                                    operation: item.operation, options: options)
        workers[item.id] = worker

        item.status = .preparing
        item.startedAt = Date()
        item.finishedAt = nil
        item.copiedBytes = 0
        item.bytesPerSecond = 0
        item.lastSample = nil
        item.finalURL = nil
        item.warning = nil
        item.isCancellable = options.engine == .builtIn

        let id = item.id
        worker.onPhase = { phase in
            Self.onMain { $0.item(id).map { if $0.status.isActive { $0.status = phase.status } } }
        }
        worker.onTotal = { tally in
            Self.onMain { q in
                guard let item = q.item(id) else { return }
                item.totalBytes = tally.bytes
                item.fileCount = tally.files
                item.sizeKnown = true
            }
        }
        worker.onProgress = { bytes in
            Self.onMain { $0.updateProgress(id, bytes) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = worker.run()
            Self.onMain { $0.finish(id, outcome) }
        }
    }

    /// Hops to the main queue in FIFO order (unlike unstructured Tasks), so a late progress
    /// update can never land after the item's completion.
    nonisolated private static func onMain(_ body: @escaping @MainActor (QueueManager) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { body(QueueManager.shared) }
        }
    }

    private func updateProgress(_ id: UUID, _ bytes: Int64) {
        guard let item = item(id), item.status.isActive else { return }
        bytesTransferred += max(0, bytes - item.copiedBytes)
        item.copiedBytes = bytes
        let now = ProcessInfo.processInfo.systemUptime
        if let s = item.lastSample {
            let dt = now - s.time
            if dt >= 0.5 {
                let instant = max(0, Double(bytes - s.bytes) / dt)
                item.bytesPerSecond = item.bytesPerSecond == 0 ? instant : item.bytesPerSecond * 0.75 + instant * 0.25
                item.lastSample = (now, bytes)
            }
        } else {
            item.lastSample = (now, bytes)
        }
        updateDock()
    }

    private func finish(_ id: UUID, _ outcome: TransferOutcome) {
        workers[id] = nil
        if let item = item(id) {
            item.bytesPerSecond = 0
            switch outcome {
            case let .completed(url, warning):
                item.status = .completed
                item.finalURL = url
                item.warning = warning
                bytesTransferred += max(0, item.totalBytes - item.copiedBytes)
                item.copiedBytes = item.totalBytes
                sessionCompleted += 1
            case let .skipped(reason):
                item.status = .skipped(reason)
            case let .failed(message):
                item.status = .failed(message)
                sessionFailed += 1
                if !NSApp.isActive {
                    Notifier.post(title: "Couldn't \(item.operation.verb) “\(item.name)”", body: message)
                }
            case .cancelled:
                item.status = quitCompletion == nil ? .cancelled : .pending
            case let .volumeUnavailable(message):
                item.status = .pending
                item.copiedBytes = 0
                isPaused = true
                pauseReason = message
                Notifier.post(title: "FileQueue paused", body: message)
            }
            if item.status.isFinished { item.finishedAt = Date() }
        }
        scheduleSave()

        if let quitCompletion, workers.isEmpty {
            saveNow()
            quitCompletion()
            return
        }
        schedule()
        if workers.isEmpty && !hasWork { queueDrained() }
    }

    private func queueDrained() {
        defer { sessionStart = nil }
        if sessionCompleted + sessionFailed > 0 { lastRunSucceeded = sessionFailed == 0 }
        updateDock()
        guard sessionCompleted + sessionFailed > 0, !NSApp.isActive else { return }
        let done = "\(sessionCompleted) item\(sessionCompleted == 1 ? "" : "s") transferred"
        let failed = sessionFailed > 0 ? ", \(sessionFailed) failed" : ""
        Notifier.post(title: "Queue finished", body: done + failed)
    }

    func stopForQuit(_ completion: @escaping () -> Void) {
        guard !workers.isEmpty else { completion(); return }
        var called = false
        let once = { if !called { called = true; completion() } }
        quitCompletion = once
        for (_, w) in workers { w.cancel(force: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.saveNow()
            once()
        }
    }

    // MARK: System integration

    private func updateSleepAssertion() {
        let want = Prefs.preventSleep && !workers.isEmpty
        if want, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Transferring queued files")
        } else if !want, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    private func updateDock() {
        let o = overall
        dock.update(fraction: workers.isEmpty ? nil : o.fraction, badge: o.remainingItems)

        let icon: StatusIconModel.State
        if o.remainingItems > 0 {
            let measuring = workers.isEmpty ? false : o.totalBytes == 0
            icon = .active(fraction: measuring ? nil : o.fraction, paused: isPaused)
        } else if let lastRunSucceeded {
            icon = .done(success: lastRunSucceeded)
        } else {
            icon = .idle
        }
        StatusIconModel.shared.set(icon)
    }

    // MARK: Destinations

    func noteRecent(_ url: URL) {
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        if recents.count > 10 { recents.removeLast(recents.count - 10) }
        Prefs.d.set(recents.map(\.path), forKey: PrefKey.recents)
    }

    func removeRecent(_ url: URL) {
        recents.removeAll { $0 == url }
        Prefs.d.set(recents.map(\.path), forKey: PrefKey.recents)
    }

    func isFavorite(_ url: URL) -> Bool { favorites.contains(url) }

    func toggleFavorite(_ url: URL) {
        if let i = favorites.firstIndex(of: url) { favorites.remove(at: i) } else { favorites.append(url) }
        Prefs.d.set(favorites.map(\.path), forKey: PrefKey.favorites)
    }

    // MARK: Panels

    @discardableResult
    func ensureDestination() -> Bool {
        if destination != nil { return true }
        let alert = NSAlert()
        alert.messageText = "Choose a destination folder"
        alert.informativeText = "Queued items are transferred to the destination shown on the right side of the window."
        alert.addButton(withTitle: "Choose…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { chooseDestination() }
        return destination != nil
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Set Destination"
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url { destination = url.standardizedFileURL }
    }

    func presentAddPanel(_ op: TransferOperation) {
        guard ensureDestination(), let dest = destination else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Queue \(op.title)"
        panel.message = "Choose items to \(op.verb) to “\(dest.lastPathComponent)”"
        if panel.runModal() == .OK { enqueue(panel.urls, operation: op) }
    }

    func pasteFromClipboard(_ op: TransferOperation) {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { NSSound.beep(); return }
        enqueueExternal(urls, operation: op)
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var items: [TransferItem.Record]
        var isPaused: Bool
    }

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FileQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.json")
    }

    private func load() {
        if let path = Prefs.d.string(forKey: PrefKey.destination) { destination = URL(fileURLWithPath: path, isDirectory: true) }
        recents = (Prefs.d.stringArray(forKey: PrefKey.recents) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        favorites = (Prefs.d.stringArray(forKey: PrefKey.favorites) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let data = try? Data(contentsOf: Self.storeURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        items = snap.items.map(TransferItem.init(record:))
        isPaused = snap.isPaused
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        let snap = Snapshot(items: items.map(\.record), isPaused: isPaused)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }
}
