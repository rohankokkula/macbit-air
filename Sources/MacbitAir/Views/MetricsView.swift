import AppKit
import SwiftUI

enum Palette {
    static let sleep = Color(red: 0.56, green: 0.49, blue: 1.0)
    static let steps = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let heart = Color(red: 1.0, green: 0.35, blue: 0.43)
    static let dim = Color.white.opacity(0.45)
}

struct ExpandedContent: View {
    var store: HealthStore
    var expanded: Bool

    var body: some View {
        switch store.status {
        case .needsConfig:
            Prompt(text: "Add your Google OAuth client to config.json",
                   button: "Open folder") {
                AppConfig.ensureTemplate()
                NSWorkspace.shared.open(AppConfig.directory)
            }
        case .signedOut:
            Prompt(text: "Connect your Fitbit through Google Health", button: "Sign in") {
                store.signIn()
            }
        default:
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 0) {
                    column(.sleep)
                    column(.steps)
                    column(.heart)
                }
                if expanded { footer.transition(.opacity) }
            }
        }
    }

    private enum Metric { case sleep, steps, heart }

    @ViewBuilder private func column(_ m: Metric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch m {
            case .sleep:
                MetricTile(icon: "moon.fill", tint: Palette.sleep,
                           value: store.sleep.map { Format.duration($0.asleep) } ?? "—",
                           caption: "sleep")
                if expanded { SleepStagesBar(sleep: store.sleep) }
            case .steps:
                MetricTile(icon: "figure.walk", tint: Palette.steps,
                           value: store.stepsToday.map(Format.number) ?? "—",
                           caption: "steps today")
                if expanded { HourlyStepsBars(hours: store.hourlySteps) }
            case .heart:
                MetricTile(icon: "heart.fill", tint: Palette.heart,
                           value: store.heartRate.map { "\($0)" } ?? "—",
                           unit: store.heartRate == nil ? nil : "bpm",
                           caption: store.restingHeartRate.map { "resting \($0)" } ?? "heart rate")
                if expanded { HeartSparkline(values: store.heartSeries) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if case .error(let msg) = store.status {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(msg).lineLimit(1)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(Format.freshness(store.dataAsOf))
                }
            }
            Spacer()
            Text("click to collapse")
        }
        .font(.system(size: 10))
        .foregroundStyle(Palette.dim)
    }
}

private struct MetricTile: View {
    var icon: String
    var tint: Color
    var value: String
    var unit: String? = nil
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.dim)
                }
            }
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(Palette.dim)
        }
    }
}

private struct Prompt: View {
    var text: String
    var button: String
    var action: () -> Void

    var body: some View {
        HStack {
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
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

    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func number(_ n: Int) -> String { grouped.string(from: NSNumber(value: n)) ?? "\(n)" }

    static func freshness(_ d: Date?) -> String {
        guard let d else { return "Waiting for data" }
        let mins = Int(Date().timeIntervalSince(d) / 60)
        switch mins {
        case ..<1: return "Fitbit data: just now"
        case ..<60: return "Fitbit data: \(mins)m ago"
        default: return "Fitbit data: \(mins / 60)h \(mins % 60)m ago"
        }
    }
}
