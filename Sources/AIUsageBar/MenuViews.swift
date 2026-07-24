import AppKit

// Shared layout metrics for the custom popover rows so every row's text and
// bars align to the same left/right edges regardless of row type.
enum MenuMetrics {
    static let width: CGFloat = 380
    static let inset: CGFloat = 14
    static var contentWidth: CGFloat { width - inset * 2 }
}

/// Traffic-light color for a remaining-capacity percentage. The red threshold
/// follows the user's warning setting; orange covers the band above it.
func limitColor(_ remainingPercent: Double) -> NSColor {
    if remainingPercent < AppSettings.shared.warnBelowRemaining { return .systemRed }
    if remainingPercent < 50 { return .systemOrange }
    return .systemGreen
}

/// Rounded capsule meter. Fills with remaining capacity in remaining mode and
/// with consumed capacity in used mode; color always tracks how close the
/// limit is. Draws with semantic colors so it adapts to light/dark. Hosted in
/// the popover via `NSViewRepresentable`.
final class LimitBarView: NSView {
    var remainingPercent: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let clamped = max(0, min(100, remainingPercent))
        let shown = AppSettings.shared.displayMode == .used ? 100 - clamped : clamped
        let w = bounds.width * CGFloat(shown / 100)
        guard w > 0 else { return }
        // Never draw the fill narrower than the capsule's own radius.
        let fillRect = NSRect(x: 0, y: 0, width: max(w, bounds.height), height: bounds.height)
        limitColor(clamped).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }
}

private func label(_ text: String, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = font
    l.textColor = color
    l.alignment = alignment
    l.lineBreakMode = .byTruncatingTail
    return l
}

/// "Updated 20:10" row with a live countdown ring to the next refresh.
/// The ring drains clockwise and the label counts down in seconds. Hosted in
/// the popover via `NSViewRepresentable`; a fresh instance is created (via
/// SwiftUI's `.id()`) whenever the underlying refresh time changes, so the
/// view's own state can stay purely init-time like it always has.
final class RefreshCountdownView: NSView {
    private let nextFire: Date
    private let interval: TimeInterval
    private let updatedText: String
    private let label: NSTextField
    private var timer: Timer?

    private static let ringSize: CGFloat = 12

    init(updatedAt: Date, nextFire: Date, interval: TimeInterval) {
        self.nextFire = nextFire
        self.interval = max(1, interval)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        self.updatedText = "Updated \(fmt.string(from: updatedAt))"
        self.label = NSTextField(labelWithString: "")
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 20))
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(
            x: MenuMetrics.inset + Self.ringSize + 6, y: 3,
            width: MenuMetrics.contentWidth - Self.ringSize - 6, height: 14)
        addSubview(label)
        updateLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { timer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateLabel()
            self?.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var remaining: TimeInterval { max(0, nextFire.timeIntervalSinceNow) }

    private func updateLabel() {
        label.stringValue = remaining <= 0
            ? "\(updatedText) · refreshing…"
            : "\(updatedText) · refresh in \(Int(remaining.rounded()))s"
        setAccessibilityLabel(label.stringValue)
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = Self.ringSize
        let rect = NSRect(x: MenuMetrics.inset, y: (bounds.height - size) / 2, width: size, height: size)
            .insetBy(dx: 1, dy: 1)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2

        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = 2
        NSColor.quaternaryLabelColor.setStroke()
        track.stroke()

        let fraction = CGFloat(remaining / interval)
        guard fraction > 0 else { return }
        // Ring drains as the countdown approaches zero: green → orange → red.
        let color: NSColor = fraction > 0.5 ? .systemGreen : (fraction > 0.2 ? .systemOrange : .systemRed)
        let arc = NSBezierPath()
        // NSBezierPath angles are counter-clockwise; sweep backwards from 12
        // o'clock so the ring visually drains clockwise.
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: 90, endAngle: 90 - fraction * 360, clockwise: true)
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }
}

/// Compact hourly usage chart. Values are normalized to the busiest hour so
/// providers with different units can still be viewed together as activity.
/// Hosted in the popover via `NSViewRepresentable`.
final class HourlyUsageChartView: NSView {
    private let usage: HourlyUsage

    init(usage: HourlyUsage) {
        self.usage = usage
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 132))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(usage.peakHour.map { "Peak usage at \($0):00" } ?? "No usage recorded today")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let plot = bounds.insetBy(dx: MenuMetrics.inset, dy: 12)
        let chart = NSRect(x: plot.minX, y: plot.minY + 10, width: plot.width, height: plot.height - 22)
        let maxValue = CGFloat(max(1, usage.values.max() ?? 0))

        NSColor.quaternaryLabelColor.setStroke()
        for fraction in [0.0, 0.5, 1.0] {
            let y = chart.minY + chart.height * CGFloat(fraction)
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: chart.minX, y: y))
            grid.line(to: NSPoint(x: chart.maxX, y: y))
            grid.lineWidth = 0.5
            grid.stroke()
        }

        guard usage.total > 0 else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            ("No usage recorded today" as NSString).draw(
                in: NSRect(x: chart.minX, y: chart.midY - 8, width: chart.width, height: 16),
                withAttributes: attrs)
            return
        }

        let step = chart.width / 23
        func point(_ index: Int) -> NSPoint {
            let value = CGFloat(usage.values[index]) / maxValue
            return NSPoint(x: chart.minX + CGFloat(index) * step, y: chart.minY + chart.height * value)
        }

        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: chart.minX, y: chart.minY))
        fill.line(to: point(0))
        for index in 1..<24 { fill.line(to: point(index)) }
        fill.line(to: NSPoint(x: chart.maxX, y: chart.minY))
        fill.close()
        NSColor.systemBlue.withAlphaComponent(0.12).setFill()
        fill.fill()

        let line = NSBezierPath()
        line.move(to: point(0))
        for index in 1..<24 { line.line(to: point(index)) }
        line.lineWidth = 2
        NSColor.systemBlue.setStroke()
        line.stroke()

        if let peak = usage.peakHour {
            let dot = NSBezierPath(ovalIn: NSRect(x: point(peak).x - 3, y: point(peak).y - 3, width: 6, height: 6))
            NSColor.systemBlue.setFill()
            dot.fill()
        }

        for index in [0, 6, 12, 18, 23] {
            let text = label(String(format: "%02d", index), font: .monospacedDigitSystemFont(ofSize: 9, weight: .regular), color: .secondaryLabelColor, alignment: .center)
            text.frame = NSRect(x: point(index).x - 12, y: chart.minY - 15, width: 24, height: 12)
            text.draw(text.bounds)
        }
    }
}
