import AppKit
import UserNotifications

// MARK: - Dock tile

@MainActor
final class DockProgress {
    private var view: DockProgressView?
    private var lastPercent = -1
    private var lastBadge: String?

    func update(fraction: Double?, badge: Int) {
        guard let app = NSApp else { return }
        let tile = app.dockTile
        let label = badge > 0 ? "\(badge)" : nil
        if label != lastBadge {
            tile.badgeLabel = label
            lastBadge = label
        }
        let percent = fraction.map { Int(($0 * 100).rounded()) } ?? -1
        guard percent != lastPercent else { return }
        lastPercent = percent
        if percent < 0 {
            tile.contentView = nil
        } else {
            let v = view ?? DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
            view = v
            v.progress = Double(percent) / 100
            tile.contentView = v
        }
        tile.display()
    }
}

final class DockProgressView: NSView {
    var progress: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let inset = bounds.width * 0.12
        let height = bounds.height * 0.11
        let track = NSRect(x: inset, y: bounds.height * 0.1, width: bounds.width - inset * 2, height: height)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
        let pad = height * 0.18
        let inner = track.insetBy(dx: pad, dy: pad)
        let fill = NSRect(x: inner.minX, y: inner.minY, width: max(inner.height, inner.width * progress), height: inner.height)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }
}

// MARK: - Notifications

enum Notifier {
    private static var requested = false

    static func requestAuthorizationIfNeeded() {
        guard !requested, Prefs.notify else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard Prefs.notify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - Services menu ("Queue Copy/Move with FileQueue" in Finder's right-click menu)

final class ServiceProvider: NSObject {
    @objc func queueCopy(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pboard, .copy)
    }

    @objc func queueMove(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pboard, .move)
    }

    private func handle(_ pboard: NSPasteboard, _ op: TransferOperation) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        DispatchQueue.main.async {
            MainActor.assumeIsolated { QueueManager.shared.enqueueExternal(urls, operation: op) }
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        _ = QueueManager.shared
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        QueueManager.shared.enqueueExternal(urls, operation: Prefs.defaultOperation)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowOpener.showMainWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let queue = QueueManager.shared
        guard queue.hasActiveTransfers else {
            queue.saveNow()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Transfers are in progress"
        alert.informativeText = "Quitting stops the current transfer and removes its partial copy. Originals are untouched, and remaining items resume the next time you open FileQueue."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        queue.stopForQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
