import Foundation
import AppKit

/// One `tccutil reset` call. `service == nil` resets every service recorded for the bundle.
public struct TCCResetRequest: Sendable, Hashable {
    /// Raw TCC service (`kTCCServiceCamera`), or nil for all services.
    public let service: String?
    public let bundleID: String
    public init(service: String?, bundleID: String) { self.service = service; self.bundleID = bundleID }
    /// The name `tccutil` accepts: the raw service without its `kTCCService` prefix, or `All`.
    public var tccutilService: String { service.map(TCCReset.tccutilName) ?? "All" }
}

public enum TCCResetOutcome: Sendable, Equatable {
    case succeeded
    case refused(String)
    case failed(String)
}

/// The only mutation App Inspector performs: `tccutil reset`, after the user confirms (plan §1, Decisions).
///
/// `tccutil` accepts only bundle IDs that Launch Services can resolve. It rejects one whose app is gone
/// with `OSStatus -10814`, which is exactly the leftover entry System Settings no longer lists. For those,
/// a stub bundle (Info.plist plus a no-op script) is registered for the duration of the call and then
/// unregistered and deleted. Verified on 26.5.1 (25F80): the stub must live outside `/tmp`, and needs no signature.
public enum TCCReset {
    public static let tccutil = "/usr/bin/tccutil"
    public static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    public static func tccutilName(_ raw: String) -> String {
        raw.hasPrefix("kTCCService") ? String(raw.dropFirst("kTCCService".count)) : raw
    }

    /// Reverse-DNS characters only, starting with a letter or digit. Anything else is refused, never quoted,
    /// because the value is interpolated into a pasteable script and a stub Info.plist.
    public static func isValidBundleID(_ s: String) -> Bool {
        guard let first = s.first, s.count <= 255, first.isASCII, first.isLetter || first.isNumber else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    public static func isValidService(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// True when Launch Services finds an app with this bundle ID, i.e. a plain `tccutil reset` will accept it.
    public static func isResolvable(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    // MARK: privileged script

    /// The `/bin/sh` script run as root through the administrator authorization dialog. Bundle IDs in `stale` go
    /// through the stub function (registered in root's Launch Services context, under `/Library/Caches`);
    /// others get a plain `tccutil reset`. Requests with unexpected characters are left out. A failing reset
    /// does not stop the others: the caller checks the outcome with a fresh scan.
    public static func privilegedScript(_ requests: [TCCResetRequest], stale: Set<String>) -> String {
        let valid = requests.filter { isValidBundleID($0.bundleID) && isValidService($0.tccutilService) }
        var lines = ["# App Inspector: reset privacy (TCC) decisions as root."]
        if valid.contains(where: { stale.contains($0.bundleID) }) {
            lines += [
                "# tccutil only accepts bundle IDs that macOS can find. For apps that are no longer installed,",
                "# tcc_reset_stale registers an empty placeholder bundle for the call, then removes it.",
                "tcc_reset_stale() {",
                "  local dir app",
                "  dir=$(/usr/bin/mktemp -d /Library/Caches/AppInspectorStub.XXXXXX) || return 1",
                "  app=\"$dir/Stub.app\"",
                "  /bin/mkdir -p \"$app/Contents/MacOS\"",
                "  /usr/bin/printf '%s\\n' '<?xml version=\"1.0\" encoding=\"UTF-8\"?>' '<plist version=\"1.0\"><dict>' \\",
                "    \"<key>CFBundleIdentifier</key><string>$2</string>\" '<key>CFBundlePackageType</key><string>APPL</string>' \\",
                "    '<key>CFBundleExecutable</key><string>Stub</string>' '</dict></plist>' > \"$app/Contents/Info.plist\"",
                "  /usr/bin/printf '#!/bin/sh\\nexit 0\\n' > \"$app/Contents/MacOS/Stub\" && /bin/chmod +x \"$app/Contents/MacOS/Stub\"",
                "  \(lsregister) -f -R \"$app\"",
                "  \(tccutil) reset \"$1\" \"$2\"",
                "  \(lsregister) -u \"$app\"",
                "  /bin/rm -rf \"$dir\"",
                "}",
            ]
        }
        for r in valid {
            lines.append(stale.contains(r.bundleID)
                ? "tcc_reset_stale \(r.tccutilService) \(r.bundleID)"
                : "\(tccutil) reset \(r.tccutilService) \(r.bundleID)")
        }
        lines.append("true")
        return lines.joined(separator: "\n") + "\n"
    }

    public enum AdministratorOutcome: Sendable, Equatable {
        case ran
        case cancelled
        case failed(String)
    }

    /// Runs `privilegedScript` as root behind the standard macOS administrator dialog ("App Inspector wants to
    /// make changes"). The same stubs are also registered in the user's Launch Services context for the duration,
    /// so tccutil can resolve the bundle whichever context it looks in.
    @MainActor
    public static func performAsAdministrator(_ requests: [TCCResetRequest], stale: Set<String>) async -> AdministratorOutcome {
        let script = privilegedScript(requests, stale: stale)
        guard script.contains("tccutil") else { return .failed("No valid requests") }
        var stubs: [URL] = []
        for id in Set(requests.map(\.bundleID)).intersection(stale).sorted() where isValidBundleID(id) {
            if let s = try? await registerStub(bundleID: id) { stubs.append(s) }
        }
        let prompt = "App Inspector needs administrator rights to remove privacy permissions stored in the system database."
        let source = "do shell script \(appleScriptString(script)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        // Unregister before returning: a stub still registered during the next scan would look like an installed app.
        for s in stubs { await unregisterStub(s) }
        await removeEmptyStubRoot()
        guard let error else { return .ran }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }   // userCanceledErr
        return .failed((error[NSAppleScript.errorMessage] as? String) ?? "Authorization failed")
    }

    /// An AppleScript string literal. The script text is built only from validated IDs and fixed strings;
    /// escaping is a second line of defence.
    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: in-app reset

    /// Where stubs live while registered. Must be outside `/tmp`, which Launch Services does not resolve from.
    public static var stubRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppInspector-ResetStubs", isDirectory: true)
    }

    /// Runs each request without administrator rights. One stub per stale bundle, removed before returning.
    public static func perform(_ requests: [TCCResetRequest], stale: Set<String>) async -> [TCCResetRequest: TCCResetOutcome] {
        await removeLeftoverStubs()
        var out: [TCCResetRequest: TCCResetOutcome] = [:]
        let byBundle = Dictionary(grouping: requests, by: \.bundleID)
        for bundleID in byBundle.keys.sorted() {
            let group = byBundle[bundleID] ?? []
            guard isValidBundleID(bundleID) else {
                for r in group { out[r] = .refused("Unexpected characters in bundle ID") }
                continue
            }
            var stub: URL?
            if stale.contains(bundleID) {
                do { stub = try await registerStub(bundleID: bundleID) }
                catch {
                    for r in group { out[r] = .failed("Could not register a placeholder bundle: \(error.localizedDescription)") }
                    continue
                }
            }
            for r in group { out[r] = await runTCCUtil(r) }
            if let stub { await unregisterStub(stub) }
        }
        await removeEmptyStubRoot()
        return out
    }

    private static func removeEmptyStubRoot() async {
        if (try? FileManager.default.contentsOfDirectory(atPath: stubRoot.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: stubRoot)
        }
    }

    private static func runTCCUtil(_ r: TCCResetRequest) async -> TCCResetOutcome {
        guard isValidService(r.tccutilService) else { return .refused("Unexpected characters in service name") }
        do {
            let res = try await ProcessRunner.run(tccutil, ["reset", r.tccutilService, r.bundleID], timeout: .seconds(30))
            if res.timedOut { return .failed("tccutil timed out") }
            if res.status == 0 { return .succeeded }
            let msg = String(decoding: res.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(msg.isEmpty ? "tccutil exited with status \(res.status)" : msg)
        } catch {
            return .failed("Could not run tccutil: \(error)")
        }
    }

    private struct StubError: LocalizedError {
        let errorDescription: String?
    }

    private static func registerStub(bundleID: String) async throws -> URL {
        let dir = stubRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = dir.appendingPathComponent("Stub.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": "App Inspector Reset Stub",
                                    "CFBundlePackageType": "APPL", "CFBundleExecutable": "Stub"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let exe = macOS.appendingPathComponent("Stub")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let res = try await ProcessRunner.run(lsregister, ["-f", "-R", app.path], timeout: .seconds(30))
        guard res.status == 0, !res.timedOut else {
            try? FileManager.default.removeItem(at: dir)
            throw StubError(errorDescription: "lsregister exited with status \(res.status)")
        }
        return dir
    }

    private static func unregisterStub(_ dir: URL) async {
        let app = dir.appendingPathComponent("Stub.app", isDirectory: true)
        _ = try? await ProcessRunner.run(lsregister, ["-u", app.path], timeout: .seconds(30))
        try? FileManager.default.removeItem(at: dir)
    }

    /// A crash between register and unregister would leave a stub claiming someone else's bundle ID.
    private static func removeLeftoverStubs() async {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: stubRoot, includingPropertiesForKeys: nil)) ?? []
        for d in dirs { await unregisterStub(d) }
    }
}
