import Foundation

// MARK: - Association

public enum AssociationConfidence: Int, Sendable, Hashable, Comparable {
    case suggestion = 1, developerGroup, probable, strong, definitive
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// Where an item belongs, and why. `reason` is always shown to the user.
public struct Association: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        case app(path: String)
        case developerGroup(teamID: String)
        case unattributed
    }
    public let target: Target
    /// 1 containment · 2 explicit parent · 3 executable inside bundle · 4 team + id prefix · 5 team only · 6 heuristic · 0 none
    public let rank: Int
    public let confidence: AssociationConfidence?
    public let reason: String

    public init(target: Target, rank: Int, confidence: AssociationConfidence?, reason: String) {
        self.target = target; self.rank = rank; self.confidence = confidence; self.reason = reason
    }
    public static let none = Association(target: .unattributed, rank: 0, confidence: nil, reason: "No signal links this item to an app")
}

/// Everything the association engine may use. All optional; absent signals are skipped, never guessed.
public struct AssociationSignals: Sendable, Hashable {
    /// Where the item itself lives (appex path, plist path, bundled helper path).
    public var itemPath: String?
    /// Executable it runs (launchd Program, ProgramArguments[0]).
    public var executablePath: String?
    /// Parent bundle path reported by the source (pluginkit `Parent Bundle`, sysext `container.bundlePath`).
    public var parentBundlePath: String?
    /// Parent bundle identifier reported by the source (launchd `parent bundle identifier`).
    public var parentBundleID: String?
    /// `AssociatedBundleIdentifiers`, sysext `references[].appIdentifier`.
    public var associatedBundleIDs: [String]
    /// The item's own identifier (bundle id or launchd label).
    public var identifier: String?
    public var teamID: String?

    public init(itemPath: String? = nil, executablePath: String? = nil, parentBundlePath: String? = nil,
                parentBundleID: String? = nil, associatedBundleIDs: [String] = [],
                identifier: String? = nil, teamID: String? = nil) {
        self.itemPath = itemPath; self.executablePath = executablePath
        self.parentBundlePath = parentBundlePath; self.parentBundleID = parentBundleID
        self.associatedBundleIDs = associatedBundleIDs; self.identifier = identifier; self.teamID = teamID
    }
}

// MARK: - Extensions

/// State of an extension. `ignored` and `disabled` are negative: they need a `ConfirmedSource`.
public struct ExtensionState: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// pluginkit `+`: the user elected to use it.
        case elected
        /// pluginkit: no election recorded. Shown as "System default", never Enabled/Disabled.
        case systemDefault
        /// pluginkit `=`: superseded by another version.
        case superseded
        /// pluginkit `-`: the user election says ignore.
        case ignored
        /// systemextensionsctl `activated enabled`.
        case activatedEnabled
        /// systemextensionsctl `activated waiting for user`.
        case waitingForUser
        /// systemextensionsctl `activated disabled`.
        case disabled
        /// systemextensionsctl `terminated waiting to uninstall on reboot`.
        case pendingUninstall
    }
    public let kind: Kind
    private init(_ kind: Kind) { self.kind = kind }

    public static let elected = ExtensionState(.elected)
    public static let systemDefault = ExtensionState(.systemDefault)
    public static let superseded = ExtensionState(.superseded)
    public static let activatedEnabled = ExtensionState(.activatedEnabled)
    public static let waitingForUser = ExtensionState(.waitingForUser)
    public static let pendingUninstall = ExtensionState(.pendingUninstall)
    public static func ignored(token: ConfirmedSource) -> ExtensionState { ExtensionState(.ignored) }
    public static func disabled(token: ConfirmedSource) -> ExtensionState { ExtensionState(.disabled) }

    public var isNegative: Bool { kind == .ignored || kind == .disabled }
}

public enum ExtensionKind: Sendable, Hashable {
    /// App extension with its extension point (pluginkit `SDK`), e.g. `com.apple.share-services`.
    case app(point: String)
    /// System extension with its category, e.g. `com.apple.system_extension.network_extension`.
    case system(category: String)
}

public struct ExtensionItem: Sendable, Identifiable {
    public let id: String
    public let kind: ExtensionKind
    public let identifier: String
    public let name: String
    public let version: String?
    public let path: String?
    public let teamID: String?
    public var state: Determination<ExtensionState>
    public var signals: AssociationSignals
    public var association: Association

    public init(id: String, kind: ExtensionKind, identifier: String, name: String, version: String?, path: String?,
                teamID: String?, state: Determination<ExtensionState>, signals: AssociationSignals,
                association: Association = .none) {
        self.id = id; self.kind = kind; self.identifier = identifier; self.name = name; self.version = version
        self.path = path; self.teamID = teamID; self.state = state; self.signals = signals; self.association = association
    }
}

// MARK: - Startup & background items

/// Whether launchd currently has the job loaded. Neutral facts, no token needed.
public struct StartupState: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case running(pid: Int), loaded, notLoaded }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
}

/// `launchctl print-disabled` override. `disabled` is negative: needs a `ConfirmedSource`.
public struct LaunchdOverride: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case enabled, disabled }
    public let kind: Kind
    private init(_ kind: Kind) { self.kind = kind }
    public static let enabled = LaunchdOverride(.enabled)
    public static func disabled(token: ConfirmedSource) -> LaunchdOverride { LaunchdOverride(.disabled) }
    public var isNegative: Bool { kind == .disabled }
}

public enum StartupKind: Sendable, Hashable {
    /// Plist in a LaunchAgents folder.
    case launchAgent
    /// Plist in LaunchDaemons.
    case launchDaemon
    /// `Contents/Library/LoginItems/*.app` helper.
    case loginItemHelper
    /// Registered through ServiceManagement (launchd reports a parent bundle), no legacy plist.
    case serviceManagement
    /// Launch plist found inside an app (`Contents/Library/LaunchAgents|LaunchDaemons`). A declaration, not proof of registration.
    case bundledLaunchPlist
}

public enum LaunchdDomain: Sendable, Hashable { case gui, system }

public struct StartupItem: Sendable, Identifiable {
    public let id: String
    public let kind: StartupKind
    public let domain: LaunchdDomain
    public let label: String
    public let plistPath: String?
    public let program: String?
    public let runAtLoad: Bool?
    public let keepAlive: Bool?
    /// Loaded / running / not loaded, from `launchctl`.
    public var loadState: Determination<StartupState>
    /// `launchctl print-disabled` override.
    public var override: Determination<LaunchdOverride>
    /// Background-task-management approval. Unknown until a BTM report is imported (Phase 3).
    public var approval: Determination<BackgroundApproval>
    public var signals: AssociationSignals
    public var association: Association

    public init(id: String, kind: StartupKind, domain: LaunchdDomain, label: String, plistPath: String?,
                program: String?, runAtLoad: Bool?, keepAlive: Bool?, loadState: Determination<StartupState>,
                override: Determination<LaunchdOverride>, approval: Determination<BackgroundApproval> = .unknown(.needsBTMImport),
                signals: AssociationSignals, association: Association = .none) {
        self.id = id; self.kind = kind; self.domain = domain; self.label = label; self.plistPath = plistPath
        self.program = program; self.runAtLoad = runAtLoad; self.keepAlive = keepAlive
        self.loadState = loadState; self.override = override; self.approval = approval
        self.signals = signals; self.association = association
    }
}

public struct DeveloperGroup: Sendable, Identifiable {
    public var id: String { teamID }
    public let teamID: String
    public var extensions: [ExtensionItem]
    public var startupItems: [StartupItem]
    public init(teamID: String, extensions: [ExtensionItem] = [], startupItems: [StartupItem] = []) {
        self.teamID = teamID; self.extensions = extensions; self.startupItems = startupItems
    }
}

/// Background Task Management disposition (Login Items & Extensions). Both halves can be negative, so every
/// value needs a `ConfirmedSource`: a BTM report must have been read by a source the matrix trusts for startup items.
public struct BackgroundApproval: Sendable, Hashable {
    /// BTM `enabled` (the user's toggle is on) versus `disabled`.
    public let enabled: Bool
    /// BTM `allowed` versus `disallowed` (blocked by policy).
    public let allowed: Bool
    /// BTM `notified`: the user has been shown the "item added" notification.
    public let notified: Bool
    private init(enabled: Bool, allowed: Bool, notified: Bool) { self.enabled = enabled; self.allowed = allowed; self.notified = notified }
    public static func from(enabled: Bool, allowed: Bool, notified: Bool, token: ConfirmedSource) -> BackgroundApproval {
        BackgroundApproval(enabled: enabled, allowed: allowed, notified: notified)
    }
    public var isNegative: Bool { !enabled || !allowed }
}
