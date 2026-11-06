import Foundation
import Security
import InspectorModel

public struct BundleInfo: Sendable {
    public let url: URL
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let build: String?
    /// All `NS*UsageDescription`-style keys with their text.
    public let usageDescriptions: [String: String]
}

public enum BundleReader {
    /// Reads Info.plist directly (no Bundle cache). nil when the bundle has no readable Info.plist.
    public static func read(_ appURL: URL) -> BundleInfo? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        let fallback = appURL.deletingPathExtension().lastPathComponent
        let name = (dict["CFBundleDisplayName"] as? String) ?? (dict["CFBundleName"] as? String) ?? fallback
        var usage: [String: String] = [:]
        for (k, v) in dict where k.hasPrefix("NS") && k.hasSuffix("UsageDescription") || k == "NSScreenCaptureDescription" {
            if let s = v as? String { usage[k] = s }
        }
        return BundleInfo(url: appURL, name: name, bundleID: dict["CFBundleIdentifier"] as? String,
                          version: dict["CFBundleShortVersionString"] as? String,
                          build: dict["CFBundleVersion"] as? String, usageDescriptions: usage)
    }
}

public enum CodeSigning {
    private static let reqApple = "anchor apple"
    private static let reqAppStore = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"
    private static let reqDevID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    private static let basic = SecCSFlags(rawValue: UInt32(kSecCSBasicValidateOnly))

    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func satisfies(_ code: SecStaticCode, _ req: String) -> Bool {
        var r: SecRequirement?
        guard SecRequirementCreateWithString(req as CFString, [], &r) == errSecSuccess, let r else { return false }
        return SecStaticCodeCheckValidity(code, basic, r) == errSecSuccess
    }

    public static func summary(of url: URL) -> SigningSummary {
        guard let code = staticCode(url) else { return SigningSummary(kind: .unknown("cannot open code object")) }
        let validity = SecStaticCodeCheckValidity(code, basic, nil)
        if validity == errSecCSUnsigned { return SigningSummary(kind: .unsigned) }

        var cfInfo: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(code, infoFlags, &cfInfo) == errSecSuccess,
              let info = cfInfo as? [String: Any] else {
            return SigningSummary(kind: .unknown("signing information unavailable"))
        }
        let flags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let ident = info[kSecCodeInfoIdentifier as String] as? String
        let ents = (info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]).map { Array($0.keys).sorted() } ?? []
        let adhoc = flags & 0x2 != 0
        let runtime = flags & 0x10000 != 0

        let kind: SignatureKind
        if adhoc { kind = .adHoc }
        else if satisfies(code, reqApple) { kind = .apple }
        else if satisfies(code, reqAppStore) { kind = .appStore }
        else if satisfies(code, reqDevID) { kind = .developerID }
        else if validity == errSecSuccess { kind = .unknown("signed by another authority") }
        else { kind = .unknown("signature invalid (OSStatus \(validity))") }
        return SigningSummary(kind: kind, teamID: teamID, identifier: ident, hardenedRuntime: runtime, entitlementKeys: ents)
    }

    /// Does the recorded `csreq` blob match the installed copy? nil → could not evaluate.
    public static func csreqMatches(_ csreq: Data, appURL: URL) -> Bool? {
        guard let code = staticCode(appURL) else { return nil }
        var req: SecRequirement?
        guard SecRequirementCreateWithData(csreq as CFData, [], &req) == errSecSuccess, let req else { return nil }
        let rc = SecStaticCodeCheckValidity(code, basic, req)
        switch rc {
        case errSecSuccess: return true
        case errSecCSReqFailed: return false
        default: return nil
        }
    }
}
