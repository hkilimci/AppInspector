import Foundation
import InspectorParsers

/// `open AppInspector.app --args --probe-btm <file>`: writes the layout of the Background Task Management
/// database (class names, field names, value kinds, one sample record) for calibrating a new macOS release.
/// Launch it with `open` so macOS applies the app's own Full Disk Access grant.
enum BTMProbe {
    static let directory = "/private/var/db/com.apple.backgroundtaskmanagement"

    static func run(output: String) -> Never {
        var out: [String] = ["macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
            for n in names {
                let size = (try? FileManager.default.attributesOfItem(atPath: "\(directory)/\(n)")[.size] as? Int) ?? -1
                out.append("file \(n) \(size) bytes")
            }
            for n in names where n.hasPrefix("BackgroundItems-v") && n.hasSuffix(".btm") {
                out.append("--- \(n)")
                do {
                    let v = try KeyedArchive.decode(try Data(contentsOf: URL(fileURLWithPath: "\(directory)/\(n)")))
                    var shapes: [String: [String: Set<String>]] = [:]
                    var counts: [String: Int] = [:]
                    var sample: ArchiveValue?
                    collect(v, &shapes, &counts, &sample)
                    out.append("top: \(kind(v)) keys=\(v.fields.map { $0.keys.sorted().joined(separator: ",") } ?? "-")")
                    for (cls, fields) in shapes.sorted(by: { $0.key < $1.key }) {
                        out.append("class \(cls) ×\(counts[cls] ?? 0)")
                        for (f, kinds) in fields.sorted(by: { $0.key < $1.key }) { out.append("  \(f): \(kinds.sorted().joined(separator: "|"))") }
                    }
                    if let sample { out.append("sample \(sample.className ?? "?"):"); render(sample, indent: "  ", into: &out, depth: 0) }
                } catch {
                    out.append("decode failed: \(error)")
                }
            }
        } catch {
            out.append("cannot list \(directory): \(error.localizedDescription)")
        }
        try? out.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
        exit(0)
    }

    private static func kind(_ v: ArchiveValue) -> String {
        switch v {
        case .null: "null"
        case .string: "string"
        case .int: "int"
        case .double: "double"
        case .bool: "bool"
        case .data: "data"
        case .date: "date"
        case .array(let a): "array<\(Set(a.map(kind)).sorted().joined(separator: "|"))>"
        case .dict: "dict"
        case .object(let c, _): c
        }
    }

    private static func collect(_ v: ArchiveValue, _ shapes: inout [String: [String: Set<String>]],
                                _ counts: inout [String: Int], _ sample: inout ArchiveValue?) {
        switch v {
        case .object(let c, let f):
            counts[c, default: 0] += 1
            for (k, x) in f { shapes[c, default: [:]][k, default: []].insert(kind(x)) }
            if sample == nil, c.localizedCaseInsensitiveContains("item") { sample = v }
            for x in f.values { collect(x, &shapes, &counts, &sample) }
        case .array(let a): for x in a { collect(x, &shapes, &counts, &sample) }
        case .dict(let d): for x in d.values { collect(x, &shapes, &counts, &sample) }
        default: break
        }
    }

    private static func render(_ v: ArchiveValue, indent: String, into out: inout [String], depth: Int) {
        guard depth < 3, let f = v.fields else { return }
        for (k, x) in f.sorted(by: { $0.key < $1.key }) {
            switch x {
            case .object, .dict:
                out.append("\(indent)\(k): \(kind(x))")
                render(x, indent: indent + "  ", into: &out, depth: depth + 1)
            case .array(let a):
                out.append("\(indent)\(k): \(kind(x)) count=\(a.count) first=\(a.first.map { String(describing: $0).prefix(120) } ?? "-")")
            default:
                out.append("\(indent)\(k) = \(String(describing: x).prefix(160))")
            }
        }
    }
}
