import AppKit
import Foundation
import Observation

/// Owns the polling loop and the small amount of state the notch shows.
@MainActor
@Observable
final class HealthStore {
    enum Status: Equatable {
        case needsConfig
        case signedOut
        case loading
        case ok
        case error(String)
    }

    // What the UI shows
    private(set) var status: Status = .loading
    private(set) var stepsToday: Int?
    private(set) var hourlySteps: [Double] = Array(repeating: 0, count: 24)
    private(set) var heartRate: Int?
    private(set) var restingHeartRate: Int?
    private(set) var heartSeries: [Double] = []        // per-minute averages, last 60 min
    private(set) var sleep: SleepSummary?
    /// Timestamp of the newest data point we have, so the UI can show how fresh the data really is.
    private(set) var dataAsOf: Date?
    private(set) var lastFetch: Date?

    let auth: GoogleAuth
    private let client: GoogleHealthClient

    // Caches keyed by data point name, so short incremental fetches can be merged.
    private var stepCache: [String: StepSample] = [:]
    private var hrCache: [String: HeartRateSample] = [:]
    private var cacheDay = Calendar.current.startOfDay(for: Date())

    private var loop: Task<Void, Never>?
    private var tick = 0
    private var backoffUntil: Date?
    private var screensAsleep = false

    init(auth: GoogleAuth) {
        self.auth = auth
        self.client = GoogleHealthClient { force in
            try await auth.accessToken(forceRefresh: force)
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = false
                self?.refreshNow()
            }
        }
    }

    // MARK: Loop

    /// Polls once now, then right after every minute boundary.
    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let now = Date()
                let next = (now.timeIntervalSince1970 / 60).rounded(.down) * 60 + 60 + 2
                try? await Task.sleep(for: .seconds(next - now.timeIntervalSince1970))
            }
        }
    }

    func refreshNow() {
        tick = 0           // forces a full refresh of every metric
        backoffUntil = nil
        Task { await poll() }
    }

    func signIn() {
        Task {
            do {
                status = .loading
                try await auth.signIn()
                refreshNow()
            } catch {
                status = auth.config == nil ? .needsConfig : .error(error.localizedDescription)
            }
        }
    }

    func signOut() {
        auth.signOut()
        stepCache = [:]; hrCache = [:]
        stepsToday = nil; heartRate = nil; restingHeartRate = nil; sleep = nil
        heartSeries = []; hourlySteps = Array(repeating: 0, count: 24); dataAsOf = nil
        status = .signedOut
    }

    // MARK: Poll

    private func poll() async {
        guard auth.config != nil else { status = .needsConfig; return }
        guard auth.isSignedIn else { status = .signedOut; return }
        if screensAsleep { return }
        if let until = backoffUntil, until > Date() { return }

        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        if today != cacheDay {                       // past midnight: new day, new totals
            cacheDay = today
            stepCache = [:]
            tick = 0
        }

        // Every minute: recent steps + heart rate. Wider windows less often to pick up
        // late syncs. Sleep every 15 min; resting HR hourly.
        let fullSteps = tick % 5 == 0
        let fullHR = tick % 10 == 0
        let doSleep = tick % 15 == 0
        let doResting = tick % 60 == 0
        tick += 1

        let stepsFrom = fullSteps ? today : max(today, now.addingTimeInterval(-3 * 3600))
        let hrFrom = now.addingTimeInterval(fullHR ? -3600 : -15 * 60)

        let client = self.client
        async let stepsReq = client.list(.steps, from: JSON.rfc3339(stepsFrom))
        async let hrReq = client.list(.heartRate, from: JSON.rfc3339(hrFrom))

        var errors: [Error] = []

        do {
            let samples = HealthParser.steps(try await stepsReq)
            if fullSteps { stepCache = [:] }
            for s in samples where s.start >= today { stepCache[s.id] = s }
            applySteps()
        } catch { errors.append(error) }

        do {
            let samples = HealthParser.heartRate(try await hrReq)
            if fullHR { hrCache = [:] }
            for s in samples { hrCache[s.id] = s }
            applyHeartRate(now: now)
        } catch { errors.append(error) }

        if doSleep {
            do {
                let points = try await client.list(.sleep, from: JSON.rfc3339(now.addingTimeInterval(-36 * 3600)))
                if let s = HealthParser.latestSleep(points) { sleep = s }
            } catch { errors.append(error); tick = 0 }   // retry sleep next minute
        }

        if doResting {
            // Optional: if this type or filter is not available, just hide the subtitle.
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let from = fmt.string(from: today.addingTimeInterval(-86400))
            if let points = try? await client.list(.restingHeartRate, from: from),
               let rhr = HealthParser.restingHeartRate(points) {
                restingHeartRate = Int(rhr.rounded())
            }
        }

        lastFetch = Date()
        handle(errors)
    }

    private func handle(_ errors: [Error]) {
        guard let first = errors.first else { status = .ok; return }
        for e in errors {
            if let apiError = e as? HealthAPIError, case .rateLimited(let retry) = apiError {
                backoffUntil = Date().addingTimeInterval(retry ?? 300)
            }
            if let authError = e as? AuthError, case .notSignedIn = authError {
                status = .signedOut
                return
            }
        }
        // Keep showing the last good numbers; only flag the problem.
        status = .error(first.localizedDescription)
    }

    private func applySteps() {
        var hours = Array(repeating: 0.0, count: 24)
        var total = 0.0
        var newest: Date?
        let cal = Calendar.current
        for s in stepCache.values {
            total += s.count
            hours[cal.component(.hour, from: s.start)] += s.count
            if newest == nil || s.start > newest! { newest = s.start }
        }
        stepsToday = Int(total.rounded())
        hourlySteps = hours
        bumpDataAsOf(newest)
    }

    private func applyHeartRate(now: Date) {
        let cutoff = now.addingTimeInterval(-3600)
        hrCache = hrCache.filter { $0.value.time >= cutoff }
        let sorted = hrCache.values.sorted { $0.time < $1.time }
        guard let latest = sorted.last else { heartRate = nil; heartSeries = []; return }
        heartRate = Int(latest.bpm.rounded())

        // Per-minute averages for the sparkline.
        var buckets: [Int: (sum: Double, n: Double)] = [:]
        for s in sorted {
            let minute = Int(s.time.timeIntervalSince1970 / 60)
            buckets[minute, default: (0, 0)].sum += s.bpm
            buckets[minute, default: (0, 0)].n += 1
        }
        heartSeries = buckets.keys.sorted().map { buckets[$0]!.sum / buckets[$0]!.n }
        bumpDataAsOf(latest.time)
    }

    private func bumpDataAsOf(_ d: Date?) {
        guard let d else { return }
        if dataAsOf == nil || d > dataAsOf! { dataAsOf = d }
    }
}
