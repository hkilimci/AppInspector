import Foundation
import Darwin.membership
import InspectorModel
import InspectorParsers
import InspectorPlatform

/// Reads Background Task Management data.
///
/// Primary source: the BTM database file, read directly with the app's Full Disk Access. No root, no prompt,
/// fast enough to repeat on every scan. Fallback, only when the user asks: `sfltool dumpbtm`, which shows an
/// administrator authorization dialog on every run. A report file can still be imported.
public struct BTMCollector: Sendable {
    public var run: CommandRunner
    public var now: Date
    /// Where `BackgroundItems-v*.btm` lives; overridable for tests.
    public var databaseDirectory: String
    public static let command = "sudo sfltool dumpbtm > ~/Desktop/btm-report.txt"

    /// `sfltool dumpbtm` is slow and variable (seconds to over a minute on 26.5.1): give it a long, separate timeout.
    public static let slowRunner: CommandRunner = { exe, args in
        try await ProcessRunner.run(exe, args, timeout: .seconds(150), maxBytes: 20_000_000)
    }
    public init(run: @escaping CommandRunner = BTMCollector.slowRunner, now: Date = Date(),
                databaseDirectory: String = BTMDatabaseParser.directory) {
        self.run = run; self.now = now; self.databaseDirectory = databaseDirectory
    }

    /// Database first. `allowPrompt: true` falls back to `sfltool`, which asks for an administrator authorization.
    public func collectLive(allowPrompt: Bool = false) async -> (report: BTMReport?, status: SourceStatus) {
        let db = collectDatabase()
        if db.report != nil || !allowPrompt { return db }
        let start = Date()
        let out = await runText(run, "/usr/bin/sfltool", ["dumpbtm"])
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        guard let text = out.text else {
            return (nil, SourceStatus(id: .btm, state: .needsImport, itemCount: 0, durationMs: ms,
                                      note: "\(db.status.note ?? "database unreadable"); sfltool failed (\(out.failure ?? "?"))"))
        }
        return Self.status(for: text, importedAt: now, isLiveRead: true, ms: ms, label: "sfltool live read")
    }

    /// Reads the current `BackgroundItems-v*.btm`. Without Full Disk Access the directory is unreadable.
    public func collectDatabase() -> (report: BTMReport?, status: SourceStatus) {
        let start = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: databaseDirectory) }
        catch {
            return (nil, SourceStatus(id: .btm, state: .needsFullDiskAccess, itemCount: 0, durationMs: ms(),
                                      note: "BTM database unreadable without Full Disk Access"))
        }
        guard let file = BTMDatabaseParser.currentFile(in: names) else {
            return (nil, SourceStatus(id: .btm, state: .formatUnrecognized("no BackgroundItems-v*.btm file"), itemCount: 0, durationMs: ms()))
        }
        let path = (databaseDirectory as NSString).appendingPathComponent(file.name)
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            // The file is the live store, so its contents are current as of this read.
            let report = try BTMDatabaseParser.parse(try KeyedArchive.decode(data), uidForUserKey: Self.uid(forUserKey:),
                                                     importedAt: now)
            let validated = BTMDatabaseParser.validatedVersions.contains(file.version)
            let note = "database \(file.name)\(validated ? "" : " (layout not validated)"), fields \(report.fieldFingerprint), UIDs \(report.uids.map(String.init).joined(separator: ","))"
            let state: SourceStatus.State = report.isComplete ? .ok : .formatUnrecognized("\(report.skippedItems) items unreadable")
            return (report, SourceStatus(id: .btm, state: state, itemCount: report.records.count, lastRun: now,
                                         durationMs: ms(), note: note))
        } catch {
            return (nil, SourceStatus(id: .btm, state: .formatUnrecognized("\(file.name): \(error)"), itemCount: 0, durationMs: ms()))
        }
    }

    /// Keys of `itemsByUserIdentifier` are user UUIDs; a plain number is taken as the UID itself.
    static func uid(forUserKey key: String) -> Int? {
        if let n = Int(key) { return n }
        guard let uuid = UUID(uuidString: key) else { return nil }
        var bytes = uuid.uuid
        var id: id_t = 0
        var type: Int32 = 0
        let rc = withUnsafeBytes(of: &bytes) { raw in
            mbr_uuid_to_id(raw.bindMemory(to: UInt8.self).baseAddress!, &id, &type)
        }
        // id_t is unsigned; sfltool prints `nobody` as -2, so keep the signed reading.
        return rc == 0 && type == ID_TYPE_UID ? Int(Int32(bitPattern: id)) : nil
    }

    /// A report from a file the user chose. `modified` is the file's modification time (the best available import time).
    public static func importReport(text: String, modified: Date) -> (report: BTMReport?, status: SourceStatus) {
        status(for: text, importedAt: modified, isLiveRead: false, ms: 0, label: "imported file")
    }

    private static func status(for text: String, importedAt: Date, isLiveRead: Bool, ms: Int, label: String) -> (BTMReport?, SourceStatus) {
        do {
            let r = try BTMParser.parse(text, importedAt: importedAt, isLiveRead: isLiveRead)
            let note = "\(label), fields \(r.fieldFingerprint), UIDs \(r.uids.map(String.init).joined(separator: ","))"
            let state: SourceStatus.State = r.isComplete ? .ok : .formatUnrecognized("\(r.skippedItems) items unreadable")
            return (r, SourceStatus(id: .btm, state: state, itemCount: r.records.count, lastRun: importedAt, durationMs: ms, note: note))
        } catch {
            return (nil, SourceStatus(id: .btm, state: .formatUnrecognized("\(error)"), itemCount: 0, lastRun: importedAt, durationMs: ms, note: label))
        }
    }
}
