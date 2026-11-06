import Foundation
import AppKit
import InspectorModel

public enum SystemInfo {
    public static func current() -> OSInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return OSInfo(version: OSVersion(v.majorVersion, v.minorVersion, v.patchVersion), build: build())
    }
    static func build() -> String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &buf, &size, nil, 0)
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Detects Full Disk Access by attempting a read-open of a TCC-protected file.
/// The probe path itself is a Phase 0 gate on macOS 27: any failure other than EPERM/EACCES is `indeterminate`.
public extension SystemInfo {
    /// Last boot time from `kern.boottime`; nil if unavailable.
    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }
}

public enum AccessProbe {
    public static func userTCCPath() -> String {
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
    }
    public static let systemTCCPath = "/Library/Application Support/com.apple.TCC/TCC.db"

    public static func fullDiskAccess(probePath: String? = nil) -> AccessLevel {
        let path = probePath ?? userTCCPath()
        let fd = open(path, O_RDONLY)
        if fd >= 0 { close(fd); return .granted }
        switch errno {
        case EPERM, EACCES: return .notGranted
        case ENOENT: return .indeterminate("probe file missing: \(path)")
        default: return .indeterminate("open failed errno \(errno)")
        }
    }
}

public enum SystemSettingsLinker {
    public static let privacyRoot = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
    public static let loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

    /// Fallback chain: specific anchor → pane root. (Opening System Settings itself is the last resort.)
    public static func privacyURLs(anchor: String?) -> [URL] {
        var urls: [URL] = []
        if let anchor, let u = URL(string: "\(privacyRoot)?\(anchor)") { urls.append(u) }
        if let u = URL(string: privacyRoot) { urls.append(u) }
        return urls
    }

    @MainActor @discardableResult
    public static func openPrivacy(anchor: String?) -> Bool {
        for u in privacyURLs(anchor: anchor) where NSWorkspace.shared.open(u) { return true }
        return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    @MainActor
    public static func openFullDiskAccess() { openPrivacy(anchor: "Privacy_AllFiles") }
}
