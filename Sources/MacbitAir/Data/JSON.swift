import Foundation

/// Small dynamic JSON value. The Google Health API returns a type-specific object per data
/// point; this lets us read fields without hard-failing if Google renames something minor.
enum JSON: Decodable, Sendable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return String(n)
        default: return nil
        }
    }

    /// Numbers, or numeric strings (proto int64 fields are serialized as strings).
    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var date: Date? {
        guard case .string(let s) = self else { return nil }
        return JSON.parseDate(s)
    }

    /// Breadth-first search for the first value stored under `key`.
    func find(_ key: String) -> JSON? {
        var queue: [JSON] = [self]
        while !queue.isEmpty {
            let node = queue.removeFirst()
            switch node {
            case .object(let o):
                if let hit = o[key] { return hit }
                queue.append(contentsOf: o.values)
            case .array(let a):
                queue.append(contentsOf: a)
            default: break
            }
        }
        return nil
    }

    func find(anyOf keys: [String]) -> JSON? {
        for k in keys { if let v = find(k) { return v } }
        return nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) ?? isoPlain.date(from: s) { return d }
        // Proto timestamps can carry up to 9 fractional digits; drop them and retry.
        if let dot = s.firstIndex(of: ".") {
            let rest = s[s.index(after: dot)...]
            let tz = rest.drop(while: { $0.isNumber })
            return isoPlain.date(from: String(s[..<dot]) + tz)
        }
        return nil
    }

    static func rfc3339(_ d: Date) -> String { isoPlain.string(from: d) }
}
