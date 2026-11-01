import SwiftUI

/// One thin bar split by sleep stage, plus the deep/REM minutes.
struct SleepStagesBar: View {
    var sleep: SleepSummary?

    private func color(_ s: SleepStage) -> Color {
        switch s {
        case .deep: return Palette.sleep
        case .rem: return Color(red: 0.35, green: 0.75, blue: 1.0)
        case .light: return Palette.sleep.opacity(0.45)
        case .awake: return Color.orange.opacity(0.8)
        }
    }

    var body: some View {
        let stages = sleep?.stages ?? [:]
        let total = stages.values.reduce(0, +)
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    if total > 0 {
                        ForEach([SleepStage.deep, .light, .rem, .awake], id: \.self) { s in
                            if let d = stages[s], d > 0 {
                                color(s).frame(width: max(2, geo.size.width * d / total - 1.5))
                            }
                        }
                    } else {
                        Palette.sleep.opacity(sleep == nil ? 0.15 : 0.6)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)

            Text(caption(stages))
                .font(.system(size: 9.5))
                .foregroundStyle(Palette.dim)
                .lineLimit(1)
        }
        .frame(height: 56, alignment: .top)
        .padding(.trailing, 14)
    }

    private func caption(_ stages: [SleepStage: TimeInterval]) -> String {
        guard let sleep else { return "no sleep yet" }
        if stages.isEmpty {
            return "\(Self.clock.string(from: sleep.start))–\(Self.clock.string(from: sleep.end))"
        }
        return "deep \(Int((stages[.deep] ?? 0) / 60))m · rem \(Int((stages[.rem] ?? 0) / 60))m"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()
}

/// 24 tiny bars, one per hour today. The current hour is highlighted.
struct HourlyStepsBars: View {
    var hours: [Double]

    var body: some View {
        let peak = max(hours.max() ?? 0, 1)
        let now = Calendar.current.component(.hour, from: Date())
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<24, id: \.self) { h in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Palette.steps.opacity(h == now ? 1 : (h < now ? 0.55 : 0.12)))
                        .frame(height: max(2, 34 * hours[h] / peak))
                }
            }
            .frame(height: 34, alignment: .bottom)
            Text("this hour \(Format.number(Int(hours[now])))")
                .font(.system(size: 9.5))
                .foregroundStyle(Palette.dim)
        }
        .frame(height: 56, alignment: .top)
        .padding(.trailing, 14)
    }
}

/// The last 60 minutes of heart rate as a smooth line.
struct HeartSparkline: View {
    var values: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                if values.count >= 2 {
                    let lo = (values.min() ?? 0) - 3
                    let hi = (values.max() ?? 1) + 3
                    let pts = values.enumerated().map { i, v in
                        CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(values.count - 1),
                                y: geo.size.height * (1 - CGFloat((v - lo) / (hi - lo))))
                    }
                    Path { p in
                        p.move(to: pts[0])
                        for i in 1..<pts.count {
                            let a = pts[i - 1], b = pts[i]
                            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                            p.addQuadCurve(to: mid, control: a)
                            if i == pts.count - 1 { p.addLine(to: b) }
                        }
                    }
                    .stroke(Palette.heart, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                    Circle().fill(Palette.heart).frame(width: 5, height: 5)
                        .position(pts[pts.count - 1])
                } else {
                    Text("no recent samples").font(.system(size: 9.5)).foregroundStyle(Palette.dim)
                }
            }
            .frame(height: 34)
            Text(range)
                .font(.system(size: 9.5))
                .foregroundStyle(Palette.dim)
        }
        .frame(height: 56, alignment: .top)
    }

    private var range: String {
        guard let lo = values.min(), let hi = values.max() else { return "last hour" }
        return "1h \(Int(lo.rounded()))–\(Int(hi.rounded())) bpm"
    }
}
