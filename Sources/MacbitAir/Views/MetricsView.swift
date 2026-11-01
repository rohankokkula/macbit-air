import AppKit
import SwiftUI

enum Palette {
    static let sleep = Color(red: 0.62, green: 0.55, blue: 1.0)
    static let rem = Color(red: 0.38, green: 0.78, blue: 1.0)
    static let steps = Color(red: 0.24, green: 0.86, blue: 0.62)
    static let heart = Color(red: 1.0, green: 0.38, blue: 0.46)
    static let awake = Color(red: 1.0, green: 0.67, blue: 0.30)
    static let dim = Color.white.opacity(0.5)
    static let faint = Color.white.opacity(0.28)
}

/// Daily step goal used for the progress bar.
let stepGoal = 10_000

extension Metric {
    var title: String {
        switch self {
        case .sleep: return "Sleep"
        case .steps: return "Steps"
        case .heart: return "Heart"
        }
    }

    var icon: String {
        switch self {
        case .sleep: return "moon.fill"
        case .steps: return "figure.walk"
        case .heart: return "heart.fill"
        }
    }

    var tint: Color {
        switch self {
        case .sleep: return Palette.sleep
        case .steps: return Palette.steps
        case .heart: return Palette.heart
        }
    }
}

/// Everything below the camera area: the three cards, or one metric's detail view.
@MainActor
struct ExpandedContent: View {
    var store: HealthStore
    var detail: Metric?
    var select: (Metric?) -> Void

    var body: some View {
        switch store.status {
        case .needsConfig:
            Prompt(icon: "key.fill", text: "Add your Google OAuth client to config.json",
                   button: "Open folder") {
                AppConfig.ensureTemplate()
                NSWorkspace.shared.open(AppConfig.directory)
            }
        case .signedOut:
            Prompt(icon: "heart.text.square.fill", text: "Connect your Fitbit through Google Health",
                   button: "Sign in") {
                store.signIn()
            }
        default:
            if let detail {
                MetricDetail(store: store, metric: detail, select: select)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else {
                HStack(alignment: .top, spacing: 8) {
                    sleepCard
                    stepsCard
                    heartCard
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: Cards

    private var sleepCard: some View {
        MetricCard(metric: .sleep, open: select) {
            BigValue(value: store.sleep.map { Format.duration($0.asleep) } ?? "—")
            Text(store.sleep.map { Format.span($0.start, $0.end) } ?? "last night")
                .captionStyle()
        }
    }

    private var stepsCard: some View {
        MetricCard(metric: .steps, open: select) {
            BigValue(value: store.stepsToday.map(Format.number) ?? "—")
            GoalBar(progress: Double(store.stepsToday ?? 0) / Double(stepGoal))
        }
    }

    private var heartCard: some View {
        MetricCard(metric: .heart, pulse: store.heartRate != nil, open: select) {
            BigValue(value: store.heartRate.map { "\($0)" } ?? "—",
                     unit: store.heartRate == nil ? nil : "bpm")
            Text(store.restingHeartRate.map { "resting \($0)" } ?? "latest")
                .captionStyle()
        }
    }
}

// MARK: - Building blocks

/// A clickable summary card. Brightens on hover; clicking opens the metric's detail view.
@MainActor
private struct MetricCard<Summary: View>: View {
    var metric: Metric
    var pulse = false
    var open: (Metric?) -> Void
    @ViewBuilder var summary: Summary
    @State private var hovering = false

    var body: some View {
        Button { open(metric) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: metric.icon)
                        .font(.system(size: 9.5, weight: .bold))
                        .symbolEffect(.pulse, options: .repeating, isActive: pulse)
                    Text(metric.title.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(hovering ? 1 : 0.35)
                        .offset(x: hovering ? 1 : 0)
                }
                .foregroundStyle(metric.tint)
                .padding(.bottom, 5)

                VStack(alignment: .leading, spacing: 3) { summary }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(CardBackground(tint: metric.tint, highlighted: hovering))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help("Show \(metric.title.lowercased()) details")
    }
}

/// Soft tinted gradient with a hairline border, shared by cards and detail panels.
struct CardBackground: View {
    var tint: Color
    var highlighted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(highlighted ? 0.26 : 0.16),
                                          tint.opacity(highlighted ? 0.08 : 0.04)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(highlighted ? tint.opacity(0.45) : Color.white.opacity(0.07),
                                  lineWidth: highlighted ? 1 : 0.5)
            }
    }
}

@MainActor
struct BigValue: View {
    var value: String
    var unit: String? = nil
    var size: CGFloat = 22

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let unit {
                Text(unit).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(Palette.dim)
            }
        }
    }
}

/// Thin progress bar toward the daily step goal, with a percent label.
@MainActor
struct GoalBar: View {
    var progress: Double

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(Palette.steps)
                        .frame(width: max(3, geo.size.width * min(progress, 1)))
                }
            }
            .frame(height: 4)
            Text("\(Int((progress * 100).rounded()))%")
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(progress >= 1 ? Palette.steps : Palette.dim)
        }
        .frame(height: 12)
    }
}

extension Text {
    func captionStyle() -> some View {
        self.font(.system(size: 10))
            .foregroundStyle(Palette.dim)
            .lineLimit(1)
            .frame(height: 12, alignment: .leading)
    }
}

@MainActor
private struct Prompt: View {
    var icon: String
    var text: String
    var button: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Palette.heart)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Palette.steps)
        }
        .frame(maxHeight: .infinity)
    }
}

enum Format {
    static func duration(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        return "\(m / 60)h \(m % 60)m"
    }

    /// Compact duration: "45m" or "4h05".
    static func short(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        return m < 60 ? "\(m)m" : String(format: "%dh%02d", m / 60, m % 60)
    }

    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func number(_ n: Int) -> String { grouped.string(from: NSNumber(value: n)) ?? "\(n)" }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "a"
        f.pmSymbol = "p"
        return f
    }()

    static func time(_ d: Date) -> String { clock.string(from: d) }

    static func span(_ a: Date, _ b: Date) -> String { "\(time(a)) – \(time(b))" }

    /// Hour of day as "12a", "6a", "3p".
    static func hour(_ h: Int) -> String {
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12)\(h < 12 ? "a" : "p")"
    }

    static func freshness(_ d: Date?) -> String {
        guard let d else { return "Waiting for Fitbit data" }
        let mins = Int(Date().timeIntervalSince(d) / 60)
        switch mins {
        case ..<1: return "Synced just now"
        case ..<60: return "Synced \(mins)m ago"
        default: return "Synced \(mins / 60)h \(mins % 60)m ago"
        }
    }
}
