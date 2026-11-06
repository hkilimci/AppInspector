import Foundation

/// Text for the in-app "About this data" page: what each source reads, what it needs, and where it can mislead.
public struct SourceInfo: Sendable, Identifiable {
    public var id: SourceID
    public let title: String
    public let reads: String
    public let requirement: String
    public let tier: String
    public let trustedFor: String
    public let limits: String
}

public enum SourceCatalog {
    public static let all: [SourceInfo] = [
        .init(id: .appInventory, title: "Installed apps", reads: "Info.plist and code signature of apps in /Applications, /System/Applications and ~/Applications.",
              requirement: "None", tier: "A: public APIs", trustedFor: "Names, versions, bundle IDs, signature kind, Team ID, declared usage strings.",
              limits: "Apps elsewhere (for example a Downloads folder) are not listed. A declared usage string is a capability, not a granted permission."),
        .init(id: .tccUser, title: "Privacy database (your account)", reads: "~/Library/Application Support/com.apple.TCC/TCC.db, read-only, never copied.",
              requirement: "Full Disk Access", tier: "D: undocumented database", trustedFor: "Camera, microphone, files and folders, automation, contacts and other per-user decisions.",
              limits: "Without Full Disk Access every privacy state is Unknown. Location Services and some services are not stored here."),
        .init(id: .tccSystem, title: "Privacy database (system)", reads: "/Library/Application Support/com.apple.TCC/TCC.db, read-only.",
              requirement: "Full Disk Access", tier: "D: undocumented database", trustedFor: "Full Disk Access, Accessibility, screen recording, input monitoring and other system-wide decisions.",
              limits: "macOS 27 may close this database to apps. The app then shows Unknown with the reason."),
        .init(id: .pluginkit, title: "App extensions", reads: "`pluginkit -mAvvv` output: every registered extension, its extension point and your election mark.",
              requirement: "None", tier: "C: command output, not declared as an API", trustedFor: "That an extension is registered and which election mark it carries.",
              limits: "No mark means \"system default\", never Enabled or Disabled. How marks map to the System Settings toggles is not fully verified."),
        .init(id: .systemExtensionsCtl, title: "System extensions (state)", reads: "`systemextensionsctl list`.",
              requirement: "None", tier: "C: command output", trustedFor: "Enabled, waiting for approval, disabled, pending removal.",
              limits: "Output that does not match the expected layout or declared count is rejected, not partly used."),
        .init(id: .systemExtensionsDB, title: "System extensions (parent app)", reads: "/Library/SystemExtensions/db.plist.",
              requirement: "None", tier: "D: undocumented file", trustedFor: "Which app contains a system extension.", limits: "Format can change between macOS versions."),
        .init(id: .launchdPlists, title: "Launch agents and daemons (files)", reads: "Plists in ~/Library/LaunchAgents, /Library/LaunchAgents and /Library/LaunchDaemons.",
              requirement: "None", tier: "A: files", trustedFor: "Label, program, RunAtLoad, KeepAlive, associated app IDs.",
              limits: "Plists only root can read are listed as Unknown. A file existing does not mean the job is loaded or approved."),
        .init(id: .launchctlDomain, title: "Loaded jobs", reads: "`launchctl print` for your session and the system.",
              requirement: "None", tier: "C: command output", trustedFor: "Whether a job is running or loaded.",
              limits: "\"Not loaded\" is shown only when the whole list was read; a partial or empty list makes every state Unknown. Jobs in other launchd domains are not checked."),
        .init(id: .launchctlDisabled, title: "launchctl overrides", reads: "`launchctl print-disabled` for your session and the system.",
              requirement: "None", tier: "C: command output", trustedFor: "Jobs disabled with `launchctl disable`.", limits: "An unrecognized entry rejects the whole listing."),
        .init(id: .launchctlJobs, title: "Registered background items", reads: "`launchctl print <job>` for jobs with no plist the app knows about.",
              requirement: "None", tier: "C: command output", trustedFor: "Jobs registered through ServiceManagement and their parent app.", limits: "Lookups are capped; skipped or failed lookups are reported."),
        .init(id: .bundledHelpers, title: "Items bundled in apps", reads: "Contents/Library/LoginItems, LaunchAgents and LaunchDaemons inside each app.",
              requirement: "None", tier: "A: files", trustedFor: "That an app ships a login item or launch plist.", limits: "Shipping one is a declaration, not proof it is registered."),
        .init(id: .btm, title: "Background Task Management", reads: "The Background Task Management database (`BackgroundItems-v*.btm`), read directly on every scan. Fallback when its layout isn't recognized: `sfltool dumpbtm`, on request.",
              requirement: "Full Disk Access (the fallback asks for an administrator password each run)", tier: "D: undocumented archive format", trustedFor: "Login Items & Extensions approval: enabled, allowed, notified.",
              limits: "Only a complete live read can say \"no record\". An imported file or a report older than the last boot can confirm what it lists but never that something is missing. Removed items can linger until overnight maintenance."),
    ]
    public static func info(for id: SourceID) -> SourceInfo? { all.first { $0.id == id } }
}
