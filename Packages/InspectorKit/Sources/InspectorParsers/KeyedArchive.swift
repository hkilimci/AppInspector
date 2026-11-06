import Foundation

/// A value from an `NSKeyedArchiver` file, decoded without instantiating any archived class.
/// Private Apple classes (BTM's `ItemRecord`, `Storage`, …) come back as `.object` with their raw fields.
public indirect enum ArchiveValue: Sendable, Hashable {
    case null
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case data(Data)
    case date(Date)
    case array([ArchiveValue])
    case dict([String: ArchiveValue])
    case object(className: String, fields: [String: ArchiveValue])

    public var string: String? {
        switch self {
        case .string(let s): s
        case .object(_, let f): f["NS.string"]?.string ?? f["NS.relative"]?.string
        default: nil
        }
    }
    public var int: Int64? {
        switch self {
        case .int(let i): i
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }
    public var array: [ArchiveValue]? { if case .array(let a) = self { a } else { nil } }
    public var fields: [String: ArchiveValue]? {
        switch self {
        case .object(_, let f): f
        case .dict(let d): d
        default: nil
        }
    }
    public var className: String? { if case .object(let c, _) = self { c } else { nil } }
    public subscript(_ key: String) -> ArchiveValue? { fields?[key] }
}

public enum KeyedArchiveError: Error, Sendable, Equatable {
    case notAPropertyList
    case notAKeyedArchive
    case badReference(Int)
}

/// Decodes the `$objects` graph of an `NSKeyedArchiver` property list into `ArchiveValue`s.
/// Foundation collection, string, data, date, UUID and URL classes are flattened; everything else is kept as
/// `.object`. Shared references are decoded again where they appear; cycles become `.null`.
public enum KeyedArchive {
    public static func decode(_ data: Data) throws -> ArchiveValue {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw KeyedArchiveError.notAPropertyList
        }
        guard let objects = root["$objects"] as? [Any], let top = root["$top"] as? [String: Any] else {
            throw KeyedArchiveError.notAKeyedArchive
        }
        var decoder = Decoder(objects: objects)
        var out: [String: ArchiveValue] = [:]
        for (k, v) in top { out[k] = try decoder.value(v) }
        return out.count == 1 && out["root"] != nil ? out["root"]! : .dict(out)
    }

    /// The index stored in a `CFKeyedArchiverUID`. Foundation exposes no public accessor, so this reads the
    /// type's description, `<CFKeyedArchiverUID 0x…>{value = 12}`; anything else is not a UID.
    static func uid(_ v: Any) -> Int? {
        guard !(v is String), !(v is NSNumber), !(v is NSDictionary), !(v is NSArray), !(v is Data), !(v is Date) else { return nil }
        let d = String(describing: v)
        guard d.contains("CFKeyedArchiverUID"), let r = d.range(of: "value = ") else { return nil }
        return Int(d[r.upperBound...].prefix { $0.isNumber })
    }

    private struct Decoder {
        let objects: [Any]
        var inProgress: Set<Int> = []
        var depth = 0

        mutating func value(_ raw: Any) throws -> ArchiveValue {
            if let i = KeyedArchive.uid(raw) { return try object(at: i) }
            return try plain(raw)
        }

        mutating func object(at i: Int) throws -> ArchiveValue {
            guard objects.indices.contains(i) else { throw KeyedArchiveError.badReference(i) }
            guard !inProgress.contains(i), depth < 64 else { return .null }
            inProgress.insert(i); depth += 1
            defer { inProgress.remove(i); depth -= 1 }
            let o = objects[i]
            if let s = o as? String { return s == "$null" ? .null : .string(s) }
            guard let dict = o as? [String: Any], let classRef = dict["$class"].flatMap(KeyedArchive.uid) else { return try plain(o) }
            guard objects.indices.contains(classRef), let cls = objects[classRef] as? [String: Any],
                  let name = cls["$classname"] as? String else { throw KeyedArchiveError.badReference(classRef) }
            return try flatten(name, dict)
        }

        mutating func flatten(_ name: String, _ dict: [String: Any]) throws -> ArchiveValue {
            switch name {
            case "NSArray", "NSMutableArray", "NSSet", "NSMutableSet", "NSOrderedSet", "NSMutableOrderedSet":
                return .array(try (dict["NS.objects"] as? [Any] ?? []).map { try value($0) })
            case "NSDictionary", "NSMutableDictionary":
                let keys = try (dict["NS.keys"] as? [Any] ?? []).map { try value($0) }
                let vals = try (dict["NS.objects"] as? [Any] ?? []).map { try value($0) }
                var out: [String: ArchiveValue] = [:]
                for (k, v) in zip(keys, vals) { out[k.string ?? String(describing: k)] = v }
                return .dict(out)
            case "NSString", "NSMutableString":
                return try dict["NS.string"].map { try value($0) } ?? .null
            case "NSData", "NSMutableData":
                return try dict["NS.data"].map { try value($0) } ?? .null
            case "NSDate":
                return (dict["NS.time"] as? Double).map { .date(Date(timeIntervalSinceReferenceDate: $0)) } ?? .null
            case "NSUUID":
                guard let b = dict["NS.uuidbytes"] as? Data, b.count == 16 else { return .null }
                return .string(NSUUID(uuidBytes: [UInt8](b)).uuidString)
            case "NSURL":
                let rel = try dict["NS.relative"].map { try value($0) }?.string ?? ""
                let base = try dict["NS.base"].map { try value($0) }?.string
                return .string(base.flatMap { URL(string: rel, relativeTo: URL(string: $0))?.absoluteString } ?? rel)
            default:
                var fields: [String: ArchiveValue] = [:]
                for (k, v) in dict where k != "$class" { fields[k] = try value(v) }
                return .object(className: name, fields: fields)
            }
        }

        mutating func plain(_ o: Any) throws -> ArchiveValue {
            switch o {
            case let s as String: return .string(s)
            case let n as NSNumber:
                if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
                return CFNumberIsFloatType(n) ? .double(n.doubleValue) : .int(n.int64Value)
            case let d as Data: return .data(d)
            case let d as Date: return .date(d)
            case let a as [Any]: return .array(try a.map { try value($0) })
            case let d as [String: Any]:
                var out: [String: ArchiveValue] = [:]
                for (k, v) in d { out[k] = try value(v) }
                return .dict(out)
            default: return .null
            }
        }
    }
}
