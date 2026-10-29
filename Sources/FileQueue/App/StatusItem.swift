import AppKit
import SwiftUI
import Observation

/// Drives the animated menu bar icon: a radial ring that eases toward the queue's progress,
/// spins while sizes are unknown, and draws itself into a checkmark when the queue finishes.
@MainActor
@Observable
final class StatusIconModel {
    static let shared = StatusIconModel()

    enum State: Equatable {
        case idle
        case active(fraction: Double?, paused: Bool)
        case done(success: Bool)
    }

    private(set) var image: NSImage

    @ObservationIgnored private var state: State = .idle
    @ObservationIgnored private var displayed: Double = 0
    @ObservationIgnored private var spin: Double = 0
    @ObservationIgnored private var checkProgress: Double = 1
    @ObservationIgnored private var timer: Timer?

    private init() {
        image = StatusIconRenderer.render(.idle, displayed: 0, spin: 0, check: 1)
    }

    func set(_ new: State) {
        guard new != state else { return }
        if case .done = new, !isDone(state) { checkProgress = 0 }
        if case .active = new, !isActive(state) { displayed = 0 }
        state = new
        tick()
        startTimerIfNeeded()
    }

    private func isDone(_ s: State) -> Bool { if case .done = s { true } else { false } }
    private func isActive(_ s: State) -> Bool { if case .active = s { true } else { false } }

    private var needsAnimation: Bool {
        switch state {
        case .idle: false
        case let .active(fraction, paused):
            fraction == nil ? !paused : abs((fraction ?? 0) - displayed) > 0.001
        case .done: checkProgress < 1
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil, needsAnimation else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            MainActor.assumeIsolated { StatusIconModel.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    fileprivate func tick() {
        switch state {
        case .idle:
            break
        case let .active(fraction, paused):
            if let fraction {
                displayed += (fraction - displayed) * 0.18
                if abs(fraction - displayed) < 0.002 { displayed = fraction }
            } else if !paused {
                spin = (spin + 0.035).truncatingRemainder(dividingBy: 1)
            }
        case .done:
            checkProgress = min(1, checkProgress + 0.07)
        }
        image = StatusIconRenderer.render(state, displayed: displayed, spin: spin, check: checkProgress)
        if !needsAnimation {
            timer?.invalidate()
            timer = nil
        }
    }
}

enum StatusIconRenderer {
    static let size = NSSize(width: 18, height: 18)

    static func render(_ state: StatusIconModel.State, displayed: Double, spin: Double, check: Double) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 7.3
            let line: CGFloat = 2.1
            NSColor.black.set()

            switch state {
            case .idle:
                let ring = NSBezierPath()
                ring.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                ring.lineWidth = 1.5
                ring.stroke()
                // Down arrow into a tray: "drop here".
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: center.x, y: center.y + 3.6))
                arrow.line(to: NSPoint(x: center.x, y: center.y - 2.4))
                arrow.move(to: NSPoint(x: center.x - 2.8, y: center.y + 0.4))
                arrow.line(to: NSPoint(x: center.x, y: center.y - 2.4))
                arrow.line(to: NSPoint(x: center.x + 2.8, y: center.y + 0.4))
                arrow.lineWidth = 1.6
                arrow.lineCapStyle = .round
                arrow.lineJoinStyle = .round
                arrow.stroke()

            case let .active(fraction, paused):
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = line
                NSColor.black.withAlphaComponent(0.25).set()
                track.stroke()
                NSColor.black.set()

                let arc = NSBezierPath()
                if fraction != nil {
                    let p = max(0.02, displayed)
                    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * p, clockwise: true)
                } else {
                    let start = 90 - 360 * spin
                    arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - 100, clockwise: true)
                }
                arc.lineWidth = line
                arc.lineCapStyle = .round
                arc.stroke()

                if paused {
                    for dx in [-1.6, 1.6] {
                        NSBezierPath(roundedRect: NSRect(x: center.x + dx - 0.8, y: center.y - 2.5, width: 1.6, height: 5),
                                     xRadius: 0.8, yRadius: 0.8).fill()
                    }
                } else {
                    NSBezierPath(ovalIn: NSRect(x: center.x - 1.3, y: center.y - 1.3, width: 2.6, height: 2.6)).fill()
                }

            case let .done(success):
                let ring = NSBezierPath()
                ring.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                ring.lineWidth = line
                ring.stroke()
                if success {
                    // Checkmark drawn progressively along its two strokes.
                    let pts = [NSPoint(x: center.x - 3.4, y: center.y + 0.1),
                               NSPoint(x: center.x - 0.9, y: center.y - 2.5),
                               NSPoint(x: center.x + 3.6, y: center.y + 2.9)]
                    let l1 = hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
                    let l2 = hypot(pts[2].x - pts[1].x, pts[2].y - pts[1].y)
                    var remaining = (l1 + l2) * CGFloat(easeOut(check))
                    let mark = NSBezierPath()
                    mark.move(to: pts[0])
                    for (a, b, len) in [(pts[0], pts[1], l1), (pts[1], pts[2], l2)] where remaining > 0 {
                        let t = min(1, remaining / len)
                        mark.line(to: NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                        remaining -= len
                    }
                    mark.lineWidth = 2
                    mark.lineCapStyle = .round
                    mark.lineJoinStyle = .round
                    mark.stroke()
                } else {
                    let bang = NSBezierPath()
                    bang.move(to: NSPoint(x: center.x, y: center.y + 3.4))
                    bang.line(to: NSPoint(x: center.x, y: center.y - 0.6))
                    bang.lineWidth = 2
                    bang.lineCapStyle = .round
                    bang.stroke()
                    NSBezierPath(ovalIn: NSRect(x: center.x - 1.1, y: center.y - 3.9, width: 2.2, height: 2.2)).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
}

/// Lets AppKit code (Dock reopen, Services, Dock drops) open the SwiftUI window.
@MainActor
enum WindowOpener {
    static var open: (() -> Void)?

    static func showMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
    }
}

struct StatusLabel: View {
    @Environment(\.openWindow) private var openWindow
    private var model = StatusIconModel.shared

    var body: some View {
        Image(nsImage: model.image)
            .onAppear {
                WindowOpener.open = { openWindow(id: "main") }
            }
    }
}

struct StatusMenu: View {
    @Environment(QueueManager.self) private var queue

    var body: some View {
        let o = queue.overall
        if o.remainingItems > 0 {
            Text(headline(o))
            ForEach(queue.activeItems) { item in
                Text("\(item.operation == .copy ? "Copying" : "Moving") \(item.name) · \(item.fraction, format: .percent.precision(.fractionLength(0)))")
            }
        } else if queue.items.isEmpty {
            Text("Queue is empty")
        } else {
            Text("All transfers finished")
        }
        Divider()
        Button("Show FileQueue Window") { WindowOpener.showMainWindow() }
            .keyboardShortcut("0")
        if o.remainingItems > 0 {
            Button(queue.isPaused ? "Resume Queue" : "Pause Queue") { queue.isPaused.toggle() }
        }
        Button("Paste Items as Copy") { queue.pasteFromClipboard(.copy) }
        Button("Paste Items as Move") { queue.pasteFromClipboard(.move) }
        if !queue.finishedItems.isEmpty {
            Button("Clear Finished") { queue.clearFinished() }
        }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit FileQueue") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func headline(_ o: OverallProgress) -> String {
        var parts = [queue.isPaused ? "Paused" : "\(o.remainingItems) remaining"]
        if o.totalBytes > 0 { parts.append("\(Fmt.bytes(o.doneBytes)) of \(Fmt.bytes(o.totalBytes))") }
        if o.bytesPerSecond > 0 { parts.append(Fmt.rate(o.bytesPerSecond)) }
        return parts.joined(separator: " · ")
    }
}
