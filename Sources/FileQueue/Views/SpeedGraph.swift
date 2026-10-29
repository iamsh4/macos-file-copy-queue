import SwiftUI
import Charts

/// Aggregate transfer speed over the last 10 minutes, one point every 5 seconds.
struct SpeedGraph: View {
    @Environment(QueueManager.self) private var queue
    @State private var hovered: SpeedSample?

    var body: some View {
        let samples = queue.speedHistory
        let active = samples.contains { $0.bytesPerSecond > 0 }

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Transfer Speed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("last 10 min")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if active {
                    stats(samples)
                }
            }
            if active {
                chart(samples)
            } else {
                Text("No transfers in the last 10 minutes")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 96)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transfer speed, last 10 minutes")
    }

    private func stats(_ samples: [SpeedSample]) -> some View {
        let moving = samples.filter { $0.bytesPerSecond > 0 }
        let avg = moving.map(\.bytesPerSecond).reduce(0, +) / Double(max(moving.count, 1))
        let peak = samples.map(\.bytesPerSecond).max() ?? 0
        return HStack(spacing: 10) {
            Text("avg \(Fmt.rate(avg))")
            Text("peak \(Fmt.rate(peak))")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func chart(_ samples: [SpeedSample]) -> some View {
        let end = samples.last?.time ?? Date()
        let start = end.addingTimeInterval(-QueueManager.speedWindow)
        let peak = samples.map(\.bytesPerSecond).max() ?? 1

        return Chart {
            ForEach(samples) { s in
                AreaMark(x: .value("Time", s.time), y: .value("Speed", s.bytesPerSecond))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor.opacity(0.12))
                LineMark(x: .value("Time", s.time), y: .value("Speed", s.bytesPerSecond))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let h = hovered {
                RuleMark(x: .value("Time", h.time))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", h.time), y: .value("Speed", h.bytesPerSecond))
                    .symbol {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    }
                    .annotation(position: .top, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Fmt.rate(h.bytesPerSecond))
                                .font(.caption.weight(.semibold).monospacedDigit())
                            Text(h.time, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...(peak * 1.2))
        .chartXAxis {
            AxisMarks(values: xTicks(start: start, end: end)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel(format: .dateTime.hour().minute())
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v == 0 ? "0" : Fmt.rate(v)).foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(point):
                            guard let plot = proxy.plotFrame else { return }
                            let x = point.x - geo[plot].origin.x
                            guard let date: Date = proxy.value(atX: x) else { return }
                            hovered = samples.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .frame(height: 104)
    }

    /// Whole two-minute marks, skipping any too close to either edge for their label to fit.
    private func xTicks(start: Date, end: Date) -> [Date] {
        let step: TimeInterval = 120
        var t = (start.timeIntervalSinceReferenceDate / step).rounded(.up) * step
        var ticks: [Date] = []
        while t <= end.timeIntervalSinceReferenceDate {
            let d = Date(timeIntervalSinceReferenceDate: t)
            if d.timeIntervalSince(start) > 45 && end.timeIntervalSince(d) > 45 { ticks.append(d) }
            t += step
        }
        return ticks
    }
}
