import Foundation

public enum SQLValue: Sendable, Hashable {
    case null, int(Int64), real(Double), text(String), blob(Data)
    public var intValue: Int64? { if case .int(let v) = self { v } else { nil } }
    public var textValue: String? { if case .text(let v) = self { v } else { nil } }
    public var blobValue: Data? { if case .blob(let v) = self { v } else { nil } }
}

/// A privacy permission state. Positive/neutral states are free; `denied` needs a `ConfirmedSource`.
public struct PermissionState: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case allowed, limited, ask, denied }
    public let kind: Kind
    /// Set by a configuration profile / policy rather than the user.
    public let managed: Bool
    /// TCC's recorded reason. nil when the state was not decoded from a TCC row.
    public let authReason: Int?
    private init(_ kind: Kind, managed: Bool, authReason: Int?) {
        self.kind = kind; self.managed = managed; self.authReason = authReason
    }

    public static func allowed(managed: Bool = false, authReason: Int? = nil) -> PermissionState {
        .init(.allowed, managed: managed, authReason: authReason)
    }
    public static func limited(managed: Bool = false, authReason: Int? = nil) -> PermissionState {
        .init(.limited, managed: managed, authReason: authReason)
    }
    public static func ask(authReason: Int? = nil) -> PermissionState { .init(.ask, managed: false, authReason: authReason) }
    public static func denied(managed: Bool = false, authReason: Int? = nil, token: ConfirmedSource) -> PermissionState {
        .init(.denied, managed: managed, authReason: authReason)
    }
    public var isNegative: Bool { kind == .denied }

    public var reasonDescription: String? {
        guard let authReason else { return nil }
        return switch authReason {
        case 1: "Error"
        case 2: "User consent"
        case 3: "Set in System Settings"
        case 4: "System policy"
        case 5: "Service policy"
        case 6: "MDM policy"
        case 7: "Override policy"
        case 8: "Missing usage string"
        case 9: "Prompt timed out"
        case 10: "Preflight unknown"
        case 11: "Entitlement"
        case 12: "App-type policy"
        case 13: "Prompt cancelled"
        default: "Unknown authorization reason \(authReason)"
        }
    }
}

public enum StoreHint: Sendable, Hashable { case user, system, either }

public struct ServiceInfo: Sendable, Hashable, Identifiable {
    public var id: String { raw }
    /// e.g. `kTCCServiceCamera`
    public let raw: String
    public let displayName: String
    /// `Privacy_Camera` etc.; nil → open the pane root.
    public let settingsAnchor: String?
    /// Info.plist usage-description keys that declare this capability.
    public let usageKeys: [String]
    /// Which TCC DB is expected to hold it. `.either` until Phase 0 calibration.
    public let store: StoreHint
}

public enum ServiceCatalog {
    public static let all: [ServiceInfo] = [
        s("kTCCServiceCamera", "Camera", "Privacy_Camera", ["NSCameraUsageDescription"]),
        s("kTCCServiceMicrophone", "Microphone", "Privacy_Microphone", ["NSMicrophoneUsageDescription"]),
        s("kTCCServiceScreenCapture", "Screen & System Audio Recording", "Privacy_ScreenCapture", ["NSScreenCaptureDescription"]),
        s("kTCCServiceAccessibility", "Accessibility", "Privacy_Accessibility", []),
        s("kTCCServiceListenEvent", "Input Monitoring", "Privacy_ListenEvent", []),
        s("kTCCServicePostEvent", "Input Event Posting", "Privacy_Accessibility", []),
        s("kTCCServiceSystemPolicyAllFiles", "Full Disk Access", "Privacy_AllFiles", []),
        s("kTCCServiceSystemPolicyDesktopFolder", "Desktop Folder", "Privacy_DesktopFolder", ["NSDesktopFolderUsageDescription"]),
        s("kTCCServiceSystemPolicyDocumentsFolder", "Documents Folder", "Privacy_DocumentsFolder", ["NSDocumentsFolderUsageDescription"]),
        s("kTCCServiceSystemPolicyDownloadsFolder", "Downloads Folder", "Privacy_DownloadsFolder", ["NSDownloadsFolderUsageDescription"]),
        s("kTCCServiceSystemPolicyNetworkVolumes", "Network Volumes", "Privacy_NetworkVolume", ["NSNetworkVolumesUsageDescription"]),
        s("kTCCServiceSystemPolicyRemovableVolumes", "Removable Volumes", "Privacy_RemovableVolume", ["NSRemovableVolumesUsageDescription"]),
        s("kTCCServiceSystemPolicyAppBundles", "App Management", "Privacy_AppBundles", []),
        s("kTCCServiceAppleEvents", "Automation", "Privacy_Automation", ["NSAppleEventsUsageDescription"]),
        s("kTCCServiceAddressBook", "Contacts", "Privacy_Contacts", ["NSContactsUsageDescription"]),
        s("kTCCServiceCalendar", "Calendars", "Privacy_Calendars",
          ["NSCalendarsUsageDescription", "NSCalendarsFullAccessUsageDescription", "NSCalendarsWriteOnlyAccessUsageDescription"]),
        s("kTCCServiceReminders", "Reminders", "Privacy_Reminders",
          ["NSRemindersUsageDescription", "NSRemindersFullAccessUsageDescription"]),
        s("kTCCServicePhotos", "Photos", "Privacy_Photos", ["NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"]),
        s("kTCCServiceBluetoothAlways", "Bluetooth", nil, ["NSBluetoothAlwaysUsageDescription"]),
        s("kTCCServiceSpeechRecognition", "Speech Recognition", nil, ["NSSpeechRecognitionUsageDescription"]),
        s("kTCCServiceMediaLibrary", "Media & Apple Music", nil, ["NSAppleMusicUsageDescription"]),
        s("kTCCServiceDeveloperTool", "Developer Tools", "Privacy_DevTools", []),
    ]
    public static let byRaw: [String: ServiceInfo] = Dictionary(uniqueKeysWithValues: all.map { ($0.raw, $0) })

    public static func info(for raw: String) -> ServiceInfo {
        byRaw[raw] ?? ServiceInfo(raw: raw, displayName: raw.replacingOccurrences(of: "kTCCService", with: ""),
                                  settingsAnchor: nil, usageKeys: [], store: .either)
    }
    private static func s(_ raw: String, _ name: String, _ anchor: String?, _ keys: [String]) -> ServiceInfo {
        ServiceInfo(raw: raw, displayName: name, settingsAnchor: anchor, usageKeys: keys, store: .either)
    }
}

public enum SignatureKind: Sendable, Hashable {
    case apple, appStore, developerID, adHoc, unsigned
    case unknown(String)
}

public struct SigningSummary: Sendable, Hashable {
    public var kind: SignatureKind
    public var teamID: String?
    public var identifier: String?
    public var hardenedRuntime: Bool?
    public var entitlementKeys: [String]
    public init(kind: SignatureKind, teamID: String? = nil, identifier: String? = nil,
                hardenedRuntime: Bool? = nil, entitlementKeys: [String] = []) {
        self.kind = kind; self.teamID = teamID; self.identifier = identifier
        self.hardenedRuntime = hardenedRuntime; self.entitlementKeys = entitlementKeys
    }
}

public struct PermissionItem: Sendable, Identifiable {
    public var id: String { indirectObject.map { "\(service.raw):\($0)" } ?? service.raw }
    public let service: ServiceInfo
    /// The target of a scoped decision, e.g. the bundle ID controlled through Automation.
    public let indirectObject: String?
    public var displayName: String { indirectObject.map { "\(service.displayName) → \($0)" } ?? service.displayName }
    public var state: Determination<PermissionState>
    /// Present when the app's Info.plist declares usage; text goes in `excerpt`.
    public var declared: Evidence?
    public var lastModified: Date?
    /// Does the grant's recorded code requirement match the installed copy?
    public var signatureMatch: Determination<Bool>?
    /// TCC databases holding a row for this item, whether or not its value could be decoded.
    /// Empty when the item comes only from a declaration or from the absence of a row.
    public var recordedIn: Set<SourceID>
    public init(service: ServiceInfo, state: Determination<PermissionState>, declared: Evidence? = nil,
                lastModified: Date? = nil, signatureMatch: Determination<Bool>? = nil, indirectObject: String? = nil,
                recordedIn: Set<SourceID> = []) {
        self.service = service; self.indirectObject = indirectObject; self.state = state; self.declared = declared
        self.lastModified = lastModified; self.signatureMatch = signatureMatch; self.recordedIn = recordedIn
    }
}

public struct AppRecord: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let build: String?
    public var signing: SigningSummary
    public var permissions: [PermissionItem]
    public var extensions: [ExtensionItem]
    public var startupItems: [StartupItem]
    public var isApple: Bool { signing.kind == .apple }
    public init(path: String, name: String, bundleID: String?, version: String?, build: String?,
                signing: SigningSummary, permissions: [PermissionItem] = [],
                extensions: [ExtensionItem] = [], startupItems: [StartupItem] = []) {
        self.path = path; self.name = name; self.bundleID = bundleID; self.version = version
        self.build = build; self.signing = signing; self.permissions = permissions
        self.extensions = extensions; self.startupItems = startupItems
    }
}

/// A TCC client that is not an inventoried app: a bare executable, or a bundle ID with no installed app found.
public struct UnattributedClient: Sendable, Identifiable {
    public enum Kind: Sendable, Hashable { case commandLine, unresolvedBundleID }
    public var id: String { "\(kind)-\(client)" }
    public let kind: Kind
    /// Absolute path (commandLine) or bundle identifier (unresolvedBundleID).
    public let client: String
    public var permissions: [PermissionItem]
    public init(kind: Kind, client: String, permissions: [PermissionItem]) {
        self.kind = kind; self.client = client; self.permissions = permissions
    }
}

public struct SourceStatus: Sendable, Identifiable {
    public enum State: Sendable, Equatable {
        case ok, needsFullDiskAccess, needsImport, unsupportedOS(String)
        case formatUnrecognized(String), failed(String), timedOut
    }
    public var id: SourceID
    public var state: State
    public var itemCount: Int
    public var lastRun: Date
    public var durationMs: Int
    public var note: String?
    public init(id: SourceID, state: State, itemCount: Int, lastRun: Date = Date(), durationMs: Int = 0, note: String? = nil) {
        self.id = id; self.state = state; self.itemCount = itemCount
        self.lastRun = lastRun; self.durationMs = durationMs; self.note = note
    }
}

public enum AccessLevel: Sendable, Equatable { case granted, notGranted, indeterminate(String) }

public struct Snapshot: Sendable {
    public var apps: [AppRecord]
    public var unattributed: [UnattributedClient]
    public var developerGroups: [DeveloperGroup]
    public var unattributedExtensions: [ExtensionItem]
    public var unattributedStartup: [StartupItem]
    public var sources: [SourceStatus]
    public var os: OSInfo
    public var fullDiskAccess: AccessLevel
    public var createdAt: Date
    public init(apps: [AppRecord], unattributed: [UnattributedClient], sources: [SourceStatus],
                os: OSInfo, fullDiskAccess: AccessLevel, createdAt: Date = Date(),
                developerGroups: [DeveloperGroup] = [], unattributedExtensions: [ExtensionItem] = [],
                unattributedStartup: [StartupItem] = []) {
        self.developerGroups = developerGroups; self.unattributedExtensions = unattributedExtensions
        self.unattributedStartup = unattributedStartup
        self.apps = apps; self.unattributed = unattributed; self.sources = sources
        self.os = os; self.fullDiskAccess = fullDiskAccess; self.createdAt = createdAt
    }
}
