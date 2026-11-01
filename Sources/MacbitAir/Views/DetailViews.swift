import SwiftUI

private let axisFont = Font.system(size: 9, weight: .medium).monospacedDigit()
private let chartHeight: CGFloat = 96

// MARK: - Shell

/// One metric in depth: a header with back button and metric tabs, then that metric's view.
@MainActor
struct MetricDetail: View {
    var store: HealthStore
    var metric: Metric
    var select: (Metric?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Group {
                switch metric {
                case .sleep: SleepDetail(sleep: store.sleep)
                case .steps: StepsDetail(total: store.stepsToday, hours: store.hourlySteps)
                case .heart: HeartDetail(current: store.heartRate, resting: store.restingHeartRate,
                                         series: store.heartSeries)
                }
            }
            .id(metric)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { select(nil) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Back to overview")

            ForEach(Metric.allCases, id: \.self) { m in
                let on = m == metric
                Button { select(m) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: m.icon).font(.system(size: 9, weight: .bold))
                        Text(m.title).font(.system(size: 10.5, weight: .semibold))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .foregroundStyle(on ? m.tint : Palette.dim)
                    .background(Capsule().fill(on ? m.tint.opacity(0.2) : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 8)

            Group {
                if case .error(let msg) = store.status {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.awake)
                    Text(msg).lineLimit(1).truncationMode(.tail)
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(Format.freshness(store.dataAsOf))
                    }
                }
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Palette.faint)
        }
    }
}

// MARK: - Shared pieces

/// Left column: headline number, a caption, and a few label/value rows.
@MainActor
private struct Summary<Caption: View>: View {
    var value: String
    var unit: String? = nil
    var stats: [(String, String)]
    @ViewBuilder var caption: Caption

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BigValue(value: value, unit: unit, size: 28)
            caption.padding(.top, 2)
            VStack(spacing: 7) {
                ForEach(stats.indices, id: \.self) { i in
                    HStack {
                        Text(stats[i].0).foregroundStyle(Palette.dim)
                        Spacer(minLength: 6)
                        Text(stats[i].1).foregroundStyle(.white.opacity(0.9))
                    }
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    if i < stats.count - 1 { Divider().overlay(Color.white.opacity(0.06)) }
                }
            }
            .padding(.top, 12)
        }
        .frame(width: 148, alignment: .leading)
    }
}

/// Right column: a tinted panel holding the chart.
private struct ChartPanel<Content: View>: View {
    var tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CardBackground(tint: tint))
    }
}

private struct EmptyDetail: View {
    var icon: String
    var text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Palette.faint)
            Text(text).font(.system(size: 11)).foregroundStyle(Palette.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sleep

@MainActor
private struct SleepDetail: View {
    var sleep: SleepSummary?

    static let order: [SleepStage] = [.deep, .light, .rem, .awake]

    static func color(_ s: SleepStage) -> Color {
        switch s {
        case .deep: return Palette.sleep
        case .light: return Palette.sleep.opacity(0.5)
        case .rem: return Palette.rem
        case .awake: return Palette.awake
        }
    }

    var body: some View {
        if let sleep {
            let inBed = sleep.end.timeIntervalSince(sleep.start)
            let awake = sleep.stages[.awake] ?? max(0, inBed - sleep.asleep)
            let efficiency = inBed > 0 ? Int((sleep.asleep / inBed * 100).rounded()) : 0
            HStack(alignment: .top, spacing: 14) {
                Summary(value: Format.duration(sleep.asleep),
                        stats: [("In bed", Format.short(inBed)),
                                ("Efficiency", "\(efficiency)%"),
                                ("Awake", Format.short(awake))]) {
                    Text(Format.span(sleep.start, sleep.end)).captionStyle()
                }
                ChartPanel(tint: Palette.sleep) {
                    if !sleep.segments.isEmpty {
                        Hypnogram(sleep: sleep)
                    } else if !sleep.stages.isEmpty {
                        StageBars(stages: sleep.stages)
                    } else {
                        EmptyDetail(icon: "moon.zzz", text: "No stage data for this night")
                    }
                    if !sleep.stages.isEmpty { legend(sleep.stages) }
                }
            }
        } else {
            EmptyDetail(icon: "moon.zzz", text: "No sleep logged in the last 36 hours")
        }
    }

    private func legend(_ stages: [SleepStage: TimeInterval]) -> some View {
        let total = max(stages.values.reduce(0, +), 1)
        return HStack(spacing: 10) {
            ForEach(Self.order, id: \.self) { s in
                HStack(spacing: 4) {
                    Circle().fill(Self.color(s)).frame(width: 6, height: 6)
                    Text(s.label).foregroundStyle(Palette.dim)
                    Text(Format.short(stages[s] ?? 0)).foregroundStyle(.white.opacity(0.9))
                    Text("\(Int(((stages[s] ?? 0) / total * 100).rounded()))%").foregroundStyle(Palette.faint)
                }
            }
        }
        .font(axisFont)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// Stage-over-time chart: one lane per stage, Awake on top and Deep at the bottom.
private struct Hypnogram: View {
    var sleep: SleepSummary

    private static let lanes: [SleepStage] = [.awake, .rem, .light, .deep]

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Self.lanes, id: \.self) { s in
                        Text(s.label).frame(maxHeight: .infinity)
                    }
                }
                .font(axisFont)
                .foregroundStyle(Palette.faint)
                .frame(width: 32, alignment: .trailing)

                GeometryReader { geo in
                    let total = max(sleep.end.timeIntervalSince(sleep.start), 1)
                    let lane = geo.size.height / CGFloat(Self.lanes.count)
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<Self.lanes.count, id: \.self) { i in
                            Rectangle().fill(Color.white.opacity(0.04))
                                .frame(height: lane - 3)
                                .offset(y: CGFloat(i) * lane)
                        }
                        ForEach(sleep.segments.indices, id: \.self) { i in
                            let seg = sleep.segments[i]
                            let x = geo.size.width * seg.start.timeIntervalSince(sleep.start) / total
                            let w = geo.size.width * seg.end.timeIntervalSince(seg.start) / total
                            let row = CGFloat(Self.lanes.firstIndex(of: seg.stage) ?? 0)
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(SleepDetail.color(seg.stage))
                                .frame(width: max(1, w), height: lane - 3)
                                .offset(x: x, y: row * lane)
                        }
                    }
                }
            }
            .frame(height: 76)

            HStack {
                Text(Format.time(sleep.start))
                Spacer()
                Text(Format.time(sleep.start.addingTimeInterval(sleep.end.timeIntervalSince(sleep.start) / 2)))
                Spacer()
                Text(Format.time(sleep.end))
            }
            .font(axisFont)
            .foregroundStyle(Palette.faint)
            .padding(.leading, 38)
        }
    }
}

/// Fallback when only stage totals are known: one horizontal bar per stage.
private struct StageBars: View {
    var stages: [SleepStage: TimeInterval]

    var body: some View {
        let peak = max(stages.values.max() ?? 1, 1)
        VStack(spacing: 7) {
            ForEach(SleepDetail.order, id: \.self) { s in
                HStack(spacing: 6) {
                    Text(s.label).frame(width: 32, alignment: .trailing).foregroundStyle(Palette.faint)
                    GeometryReader { geo in
                        Capsule().fill(SleepDetail.color(s))
                            .frame(width: max(3, geo.size.width * (stages[s] ?? 0) / peak))
                    }
                    .frame(height: 8)
                }
                .font(axisFont)
            }
        }
        .frame(height: 88)
    }
}

// MARK: - Steps

@MainActor
private struct StepsDetail: View {
    var total: Int?
    var hours: [Double]

    var body: some View {
        let steps = total ?? 0
        let now = Calendar.current.component(.hour, from: Date())
        let peakHour = hours.indices.max { hours[$0] < hours[$1] } ?? 0
        let active = hours.filter { $0 >= 250 }.count
        let km = Double(steps) * 0.000762

        HStack(alignment: .top, spacing: 14) {
            Summary(value: total.map(Format.number) ?? "—",
                    stats: [("Distance", String(format: "≈ %.1f km", km)),
                            ("Peak hour", hours[peakHour] > 0
                                ? "\(Format.hour(peakHour)) · \(Format.number(Int(hours[peakHour])))" : "—"),
                            ("Active hours", "\(active) of \(now + 1)")]) {
                VStack(alignment: .leading, spacing: 2) {
                    GoalBar(progress: Double(steps) / Double(stepGoal))
                    Text(steps >= stepGoal ? "Goal reached 🎉"
                         : "\(Format.number(stepGoal - steps)) to go").captionStyle()
                }
            }
            ChartPanel(tint: Palette.steps) {
                StepsChart(hours: hours, now: now, peakHour: peakHour)
            }
        }
    }
}

private struct StepsChart: View {
    var hours: [Double]
    var now: Int
    var peakHour: Int

    var body: some View {
        let peak = max(hours.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Today, by hour")
                Spacer()
                Text("+\(Format.number(Int(hours[now]))) this hour").foregroundStyle(.white.opacity(0.85))
            }
            .font(axisFont)
            .foregroundStyle(Palette.faint)

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { h in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(h == now ? Palette.steps
                              : Palette.steps.opacity(h < now ? 0.5 : 0.1))
                        .frame(height: max(2, (chartHeight - 22) * hours[h] / peak))
                        .overlay(alignment: .top) {
                            if h == peakHour && hours[h] > 0 {
                                Text(Format.number(Int(hours[h])))
                                    .font(.system(size: 8, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.8))
                                    .fixedSize()
                                    .offset(y: -11)
                            }
                        }
                }
            }
            .frame(height: chartHeight - 10, alignment: .bottom)

            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text(Format.hour(h)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(axisFont)
            .foregroundStyle(Palette.faint)
        }
    }
}

// MARK: - Heart

@MainActor
private struct HeartDetail: View {
    var current: Int?
    var resting: Int?
    var series: [Double]

    var body: some View {
        let avg = series.isEmpty ? nil : series.reduce(0, +) / Double(series.count)
        HStack(alignment: .top, spacing: 14) {
            Summary(value: current.map { "\($0)" } ?? "—",
                    unit: current == nil ? nil : "bpm",
                    stats: [("Resting", resting.map { "\($0) bpm" } ?? "—"),
                            ("1h average", avg.map { "\(Int($0.rounded())) bpm" } ?? "—"),
                            ("1h range", range)]) {
                HStack(spacing: 4) {
                    Circle().fill(zone.color).frame(width: 6, height: 6)
                    Text(zone.label).captionStyle()
                }
            }
            ChartPanel(tint: Palette.heart) {
                if series.count >= 2 {
                    HeartChart(values: series, resting: resting.map(Double.init))
                } else {
                    EmptyDetail(icon: "waveform.path.ecg", text: "No heart rate in the last hour")
                }
            }
        }
    }

    private var range: String {
        guard let lo = series.min(), let hi = series.max() else { return "—" }
        return "\(Int(lo.rounded()))–\(Int(hi.rounded()))"
    }

    /// Rough effort zone from how far the current rate sits above resting.
    private var zone: (label: String, color: Color) {
        guard let current else { return ("No recent reading", Palette.faint) }
        guard let resting else { return ("Latest reading", Palette.heart) }
        switch current - resting {
        case ..<10: return ("At rest", Palette.steps)
        case ..<30: return ("Light activity", Palette.rem)
        case ..<60: return ("Elevated", Palette.awake)
        default: return ("High", Palette.heart)
        }
    }
}

private struct HeartChart: View {
    var values: [Double]
    var resting: Double?

    var body: some View {
        let lo = min(values.min() ?? 0, resting ?? .infinity) - 4
        let hi = max(values.max() ?? 1, resting ?? -.infinity) + 4
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last 60 minutes")
                Spacer()
                if resting != nil {
                    HStack(spacing: 3) {
                        Rectangle().fill(Palette.dim).frame(width: 8, height: 1)
                        Text("resting")
                    }
                }
            }
            .font(axisFont)
            .foregroundStyle(Palette.faint)

            GeometryReader { geo in
                let pts = points(in: geo.size, lo: lo, hi: hi)
                ZStack(alignment: .topLeading) {
                    if let resting {
                        let y = geo.size.height * (1 - CGFloat((resting - lo) / (hi - lo)))
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(Palette.dim, style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    }
                    area(pts, height: geo.size.height)
                        .fill(LinearGradient(colors: [Palette.heart.opacity(0.35), Palette.heart.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                    line(pts)
                        .stroke(Palette.heart, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    Circle().fill(Palette.heart.opacity(0.3)).frame(width: 12, height: 12)
                        .position(pts[pts.count - 1])
                    Circle().fill(.white).frame(width: 5, height: 5)
                        .position(pts[pts.count - 1])
                }
                .overlay(alignment: .topTrailing) {
                    Text("\(Int(hi - 4))").offset(x: 0, y: -2)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(Int(lo + 4))").offset(x: 0, y: 2)
                }
                .font(axisFont)
                .foregroundStyle(Palette.faint)
            }
            .frame(height: chartHeight - 26)

            HStack {
                Text("60m ago")
                Spacer()
                Text("30m")
                Spacer()
                Text("now")
            }
            .font(axisFont)
            .foregroundStyle(Palette.faint)
        }
    }

    private func points(in size: CGSize, lo: Double, hi: Double) -> [CGPoint] {
        values.enumerated().map { i, v in
            CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                    y: size.height * (1 - CGFloat((v - lo) / (hi - lo))))
        }
    }

    private func line(_ pts: [CGPoint]) -> Path {
        Path { p in
            p.move(to: pts[0])
            for i in 1..<pts.count {
                let a = pts[i - 1], b = pts[i]
                p.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
                if i == pts.count - 1 { p.addLine(to: b) }
            }
        }
    }

    private func area(_ pts: [CGPoint], height: CGFloat) -> Path {
        var p = line(pts)
        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: height))
        p.addLine(to: CGPoint(x: pts[0].x, y: height))
        p.closeSubpath()
        return p
    }
}
