import Foundation

/// Every name the API uses for a data type, in one place, so it is easy to adjust
/// if Google changes something. URL paths are kebab-case, filters are snake_case,
/// and JSON response keys are camelCase.
struct HealthDataType: Sendable {
    let path: String        // /v4/users/me/dataTypes/{path}/dataPoints
    let jsonKey: String     // key of the type-specific object inside each data point
    let timeFilterField: String

    static let steps = HealthDataType(path: "steps", jsonKey: "steps",
                                      timeFilterField: "steps.interval.start_time")
    static let heartRate = HealthDataType(path: "heart-rate", jsonKey: "heartRate",
                                          timeFilterField: "heart_rate.sample_time.physical_time")
    static let sleep = HealthDataType(path: "sleep", jsonKey: "sleep",
                                      timeFilterField: "sleep.interval.end_time")
    static let restingHeartRate = HealthDataType(path: "daily-resting-heart-rate",
                                                 jsonKey: "dailyRestingHeartRate",
                                                 timeFilterField: "daily_resting_heart_rate.date")
}

enum HealthAPIError: LocalizedError {
    case http(Int, String)
    case rateLimited(retryAfter: TimeInterval?)
    case decoding

    var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return "API \(code): \(msg)"
        case .rateLimited: return "Rate limited, backing off"
        case .decoding: return "Unexpected API response"
        }
    }
}

struct GoogleHealthClient: Sendable {
    typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    static let base = URL(string: "https://health.googleapis.com/v4/users/me/dataTypes/")!
    let token: TokenProvider

    /// Lists data points with `field >= from` (and optionally `< to`), following pagination.
    func list(_ type: HealthDataType, from: String, to: String? = nil,
              pageSize: Int = 1000, maxPages: Int = 10) async throws -> [JSON] {
        var filter = "\(type.timeFilterField) >= \"\(from)\""
        if let to { filter += " AND \(type.timeFilterField) < \"\(to)\"" }

        var points: [JSON] = []
        var pageToken: String?
        var pages = 0
        repeat {
            var comps = URLComponents(url: Self.base.appendingPathComponent("\(type.path)/dataPoints"),
                                      resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "filter", value: filter),
                         URLQueryItem(name: "pageSize", value: String(pageSize))]
            if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
            comps.queryItems = items

            let page = try await get(comps.url!)
            points += page["dataPoints"]?.array ?? []
            pageToken = page["nextPageToken"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            pages += 1
        } while pageToken != nil && pages < maxPages
        return points
    }

    private func get(_ url: URL, retried: Bool = false) async throws -> JSON {
        let accessToken = try await token(retried)
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            guard let json = try? JSONDecoder().decode(JSON.self, from: data) else {
                throw HealthAPIError.decoding
            }
            return json
        case 401 where !retried:
            return try await get(url, retried: true)       // token expired early, so refresh once
        case 429:
            let retry = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            throw HealthAPIError.rateLimited(retryAfter: retry)
        default:
            let json = try? JSONDecoder().decode(JSON.self, from: data)
            let msg = json?["error"]?["message"]?.string
                ?? String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
            throw HealthAPIError.http(status, msg)
        }
    }
}

// MARK: - Parsing data points into app models

struct StepSample: Sendable {
    let id: String
    let start: Date
    let count: Double
}

struct HeartRateSample: Sendable {
    let id: String
    let time: Date
    let bpm: Double
}

enum SleepStage: String, CaseIterable, Sendable {
    case deep = "DEEP", light = "LIGHT", rem = "REM", awake = "AWAKE"

    var label: String {
        switch self {
        case .deep: return "Deep"
        case .light: return "Light"
        case .rem: return "REM"
        case .awake: return "Awake"
        }
    }
}

struct SleepSegment: Sendable, Equatable {
    let stage: SleepStage
    let start: Date
    let end: Date
}

struct SleepSummary: Sendable, Equatable {
    let start: Date
    let end: Date
    let asleep: TimeInterval
    let stages: [SleepStage: TimeInterval]   // empty for "classic" logs without stages
    var segments: [SleepSegment] = []        // stage timeline, sorted by start
}

enum HealthParser {
    static func steps(_ points: [JSON]) -> [StepSample] {
        points.compactMap { p in
            let obj = p[HealthDataType.steps.jsonKey] ?? p
            guard let count = obj.find("count")?.double,
                  let start = (obj["interval"] ?? obj).find(anyOf: ["startTime", "physicalTime"])?.date
            else { return nil }
            return StepSample(id: p["name"]?.string ?? "\(start.timeIntervalSince1970)",
                              start: start, count: count)
        }
    }

    static func heartRate(_ points: [JSON]) -> [HeartRateSample] {
        points.compactMap { p in
            let obj = p[HealthDataType.heartRate.jsonKey] ?? p
            guard let bpm = obj.find(anyOf: ["beatsPerMinute", "bpm", "value"])?.double,
                  let time = obj.find(anyOf: ["physicalTime", "time", "startTime"])?.date
            else { return nil }
            return HeartRateSample(id: p["name"]?.string ?? "\(time.timeIntervalSince1970)",
                                   time: time, bpm: bpm)
        }
    }

    static func restingHeartRate(_ points: [JSON]) -> Double? {
        // Daily points: pick the last one returned that carries a value.
        points.compactMap { p -> Double? in
            let obj = p[HealthDataType.restingHeartRate.jsonKey] ?? p
            return obj.find(anyOf: ["beatsPerMinute", "bpm", "value"])?.double
        }.last
    }

    /// The most recent main sleep (ignores naps shorter than 2 h when a longer one exists).
    static func latestSleep(_ points: [JSON]) -> SleepSummary? {
        let sessions: [SleepSummary] = points.compactMap { p in
            let obj = p[HealthDataType.sleep.jsonKey] ?? p
            let interval = obj["interval"] ?? obj
            guard let start = interval["startTime"]?.date ?? interval.find("startTime")?.date,
                  let end = interval["endTime"]?.date ?? interval.find("endTime")?.date,
                  end > start else { return nil }

            var stages: [SleepStage: TimeInterval] = [:]
            var segments: [SleepSegment] = []
            for s in obj.find("stages")?.array ?? [] {
                guard let raw = s.find(anyOf: ["type", "stage"])?.string?.uppercased() else { continue }
                let stage: SleepStage? = SleepStage(rawValue: raw)
                    ?? (raw.contains("WAKE") ? .awake : nil)
                guard let stage,
                      let ss = s.find("startTime")?.date, let se = s.find("endTime")?.date else { continue }
                stages[stage, default: 0] += se.timeIntervalSince(ss)
                segments.append(SleepSegment(stage: stage, start: ss, end: se))
            }

            let asleep: TimeInterval
            if let minutes = obj.find(anyOf: ["minutesAsleep", "asleepMinutes"])?.double {
                asleep = minutes * 60
            } else if !stages.isEmpty {
                asleep = stages.filter { $0.key != .awake }.values.reduce(0, +)
            } else {
                asleep = end.timeIntervalSince(start)
            }
            return SleepSummary(start: start, end: end, asleep: asleep, stages: stages,
                                segments: segments.sorted { $0.start < $1.start })
        }
        let main = sessions.filter { $0.asleep >= 2 * 3600 }
        return (main.isEmpty ? sessions : main).max { $0.end < $1.end }
    }
}
