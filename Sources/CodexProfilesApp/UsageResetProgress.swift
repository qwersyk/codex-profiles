import SwiftUI

/// The solid fill is remaining quota; the translucent layer is elapsed reset time.
struct UsageLimitProgress: View {
    let window: UsageWindow
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                let elapsed = window.resetProgress(at: date)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(window.remainingPercent < 10 ? Color.orange : Color.accentColor)
                        .frame(width: geometry.size.width * window.remainingPercent / 100)
                    if let elapsed {
                        Rectangle()
                            .fill(Color.primary.opacity(0.14))
                            .overlay(Color.white.opacity(0.20))
                            .frame(width: geometry.size.width * elapsed)
                        if elapsed > 0, elapsed < 1 {
                            Rectangle().fill(Color.primary.opacity(0.45))
                                .frame(width: 1)
                                .offset(x: geometry.size.width * elapsed)
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            if let countdown = window.resetCountdown(at: date) {
                HStack {
                    Label(countdown, systemImage: "clock")
                    Spacer()
                    if let elapsed = window.resetProgress(at: date) {
                        Text("\(Int(elapsed * 100))% of period elapsed")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.durationLabel): \(Int(window.remainingPercent))% quota remaining. \(window.resetCountdown(at: date) ?? "Reset time unavailable")")
    }
}

/// Quota controls geometry; elapsed reset time controls brightness on that same geometry.
struct QuotaBadge: View {
    let windows: [UsageWindow]
    let date: Date
    let isStale: Bool
    let symbol: String

    var body: some View {
        ZStack {
            ZStack(alignment: .bottom) {
                Color.primary.opacity(0.08)
                if let first = windows.first {
                    let elapsed = first.resetProgress(at: date)
                    quotaColor(first.remainingPercent)
                        .overlay(Color.white.opacity((elapsed ?? 0) * 0.18))
                        .opacity((elapsed.map { 0.22 + 0.60 * $0 } ?? 0.4) * (isStale ? 0.55 : 1))
                        .frame(height: 30 * first.remainingPercent / 100)
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(ClockwiseQuotaBorder(cornerRadius: 8))

            ClockwiseQuotaBorder(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 2)
                .frame(width: 30, height: 30)

            if windows.count > 1, let last = windows.last {
                let elapsed = last.resetProgress(at: date)
                ClockwiseQuotaBorder(cornerRadius: 8)
                    .trim(from: 0, to: last.remainingPercent / 100)
                    .stroke(quotaColor(last.remainingPercent)
                        .opacity((elapsed.map { 0.35 + 0.65 * $0 } ?? 1) * (isStale ? 0.55 : 1)),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 30, height: 30)
            }

            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

func quotaColor(_ remaining: Double) -> Color {
    remaining <= 10 ? .red : remaining <= 30 ? .orange : .green
}

// Start at twelve o'clock. Circular arcs match the fill and every progress outline.
struct ClockwiseQuotaBorder: Shape {
    var cornerRadius: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
