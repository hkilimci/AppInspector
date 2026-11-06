# App Inspector for macOS: Feasibility, Architecture & Phased MVP Plan

*Working name. This is a planning document only; nothing has been implemented.*
*Prepared 2026-11-05. Local evidence was probed on macOS 26.5.1 (25F80), Apple Silicon, with no Full Disk Access and no root.*

Legend for source claims: **[V]** verified on the dev Mac · **[?]** unverified, resolved in Phase 0 · **[web]** third-party web source. Other tags, such as [RN27] or [DTS-713830], point to §11 References. Source *tiers* (A–E) are defined in §4.6.

---

## 1. Context

macOS spreads per-app trust state across System Settings (Privacy & Security; General › Login Items & Extensions; Keyboard › Keyboard Shortcuts), browser settings, and launchd. No single place answers "what may this app access, what does it plug into, and what does it run in the background?"

**Goal:** a native inspector that is read-only except for confirmed privacy resets (see Mutations below). The sidebar lists applications. The detail view groups each app's privacy permissions, extensions, and startup/background items (keyboard shortcuts come later). Every state shows where it came from and links to the matching System Settings page.

**Hard rule:** confirmed states must look and behave differently from unknown or inaccessible ones. Missing or unreadable data never renders as *Denied* or *Disabled*.

### Decisions (confirmed 2026-11-05)

| Topic | Decision |
|---|---|
| Distribution | Developer ID–signed, notarized, hardened runtime, **not sandboxed**. No Mac App Store edition. |
| Minimum OS | **macOS 15 Sequoia.** Test matrix: 15.x, 26.x, 27.x. macOS 27 shipped 2026-09-14 and 27.2 is current; the dev Mac runs 26.5.1. |
| Root-only data | No privileged helper, and nothing for the user to do in Terminal (decided 2026-11-06). Background Task Management data is read from the database file `/private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v*.btm` with the app's Full Disk Access, on every scan, with no prompt and no root. `sfltool dumpbtm` remains only as an on-request fallback when the database layout isn't recognized; macOS asks for an administrator password on each run. Privacy resets that need root use the standard administrator authorization dialog, only when the user clicks Reset. |
| Mutations | One exception, changed 2026-11-06: `tccutil reset` for privacy decisions of bundle-ID clients, only after the user confirms each reset, and always verified by a fresh scan. `tccutil` rejects bundle IDs Launch Services can't resolve (`OSStatus -10814`), so for apps that are no longer installed a stub bundle (Info.plist plus a no-op script, under `~/Library/Caches`) is registered for the call and then unregistered and deleted. Entries that survive the user-level reset (system database) are retried as root behind the standard administrator dialog, with root's stubs under `/Library/Caches`. Never writes TCC.db directly. Never writes BTM, launchd or pluginkit state. Never calls `sfltool reset*`, `pluginkit -e`, or `launchctl enable/disable/bootout`. |
| Scope order | MVP: permissions, extensions, startup items. Shortcut discovery after MVP. |

---

## 2. Feasibility assessment

**Verdict: feasible as a non-sandboxed Developer ID app, with one major caveat. macOS 27 blocks apps from reading the TCC database directly, and that database is the only source for other apps' privacy grants.** Extensions and startup items are well covered with no grants at all. Privacy grants are fully readable on macOS 15 and 26 once the user grants Full Disk Access (FDA). On 27 they stay at risk until Phase 0 tests the system database and the new `tccutil list`.

| Category | macOS 15 / 26 | macOS 27 | Needs | Main limitation |
|---|---|---|---|---|
| Privacy: declared usage (Info.plist keys, entitlements) | ✔ | ✔ | none | A capability, not a grant |
| Privacy: grants | ✔ user and system TCC.db | ⚠ user DB moved and closed to apps; system DB and `tccutil list` [?] | FDA | Undocumented schema. Location Services and Local Network are not inspectable on any version. |
| App extensions | ✔ | ✔ [?] | none | pluginkit output is not API; "no election" is neither on nor off |
| System extensions | ✔ | ✔ [?] | none | Undocumented text/plist formats |
| Browser extensions: Chromium family, Firefox | ✔ | ✔ with FDA | none (27: FDA) | Formats change with browser releases |
| Browser extensions: Safari | presence ✔, state with FDA | presence ✔, state [?] | FDA for state | Per-profile state location unknown |
| Legacy launch agents/daemons | ✔ | ✔ [?] | none | `.notFound`/`.notRegistered` are ambiguous → Unknown |
| SMAppService agents/daemons | loaded jobs ✔ | [?] | none; complete state needs the BTM import | Not-loaded state is Unknown without BTM data |
| Open-at-login apps | ✔ (deprecated API) | [?] | none | The API could disappear |
| Menu shortcuts (post-MVP) | running apps only | running apps only | Accessibility | Lazily built menus; app must be running |
| Global hotkeys (post-MVP) | partial | partial | none | No API lists other apps' hotkey registrations |

**What each access level unlocks:**
- **No grants** (all verified on 26.5.1): app/system/Chromium/Firefox extensions; legacy agents/daemons with approval and runtime state; loaded SMAppService jobs with their parent app; open-at-login apps; declared permissions.
- **FDA adds:** privacy grants (15/26), Safari extension state, browser profiles on 27, and possibly direct BTM reads (Phase 0).
- **BTM import adds:** complete approval state, including turned-off SMAppService items and MDM-managed flags.

---

## 3. Distribution: Developer ID vs Mac App Store

| Requirement | Developer ID (chosen) | Mac App Store |
|---|---|---|
| Read TCC.db | Yes on 15/26, after the user grants FDA | No. FDA does not lift the App Sandbox [DTS-807142]. |
| Run `pluginkit`, `launchctl`, `systemextensionsctl` | Yes | Children inherit the sandbox. Blocked lookups can return empty output with exit code 0, which looks the same as "nothing installed". |
| Read `~/Library/LaunchAgents`, browser profiles | Yes | Only user-selected files, or temporary-exception entitlements that App Review decides case by case. |
| Accessibility API on other apps (shortcuts) | Yes, with the user's grant | Apple's sandbox guide lists assistive-app Accessibility use as incompatible; App Review has rejected non-accessibility use under 2.4.5. |
| Review rules | None; notarization is automated | Guideline 2.4.5 (revised 2026-10-16): sandboxed, no root or setuid, App Store-only updates; 2.5.2: no reading outside the container. |
| Delivery and updates | DMG/zip, notarized; Homebrew cask; optional Sparkle 2 | App Store |

**Verdict:** a Mac App Store build would shrink to static bundle analysis (declared permissions, bundled extensions and helpers). It would lose the confirmed states that are the product's point, so Developer ID is the only viable channel.

**Release requirements:**
- Developer ID Application certificate.
- Hardened runtime with no exceptions; library validation stays on.
- No special entitlements; no data source needs one.
- `notarytool` plus stapling; a signed DMG; optional Sparkle 2 with EdDSA.

**Full Disk Access onboarding:**
- There is no API to check or request FDA [tidbits].
- Detect it by probing a protected path. On 27, a TCC.db probe always fails, so probe something else, e.g. listing `~/Library/Safari`. The probe also adds the app to the FDA list.
- Then deep-link to `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles` [SDK].
- Apple has said granting FDA will require "very explicit user action" [Apple news], so onboarding must explain exactly what FDA unlocks.

---

## 4. Proposed architecture

### 4.1 Principles

1. **Read-only and local-only.** No network access except an opt-in update check. No telemetry. Exports only when the user asks.
2. **Evidence-first.** Every displayed state carries its source, observation time, OS build and a raw excerpt, viewable in an Evidence sheet.
3. **Fail to Unknown.** Errors, missing grants, unrecognized formats and timeouts produce `Unknown(reason)`, never `Denied`/`Disabled`.
4. **Quarantine fragile sources.** Each undocumented source sits behind a versioned parser with format detection. An unrecognized format yields Unknown plus a diagnostic; the parser never guesses.
5. **Progressive access.** Useful with zero grants. Full Disk Access, the BTM import and (later) Accessibility each unlock named columns, and the UI says which.

### 4.2 Runtime and process model

- Swift 6 with strict concurrency; SwiftUI (`NavigationSplitView`, `List`, `Table`, `.inspector`); AppKit bridges for `NSWorkspace` (icons, running apps, LaunchServices lookups) and `NSOpenPanel` (BTM import). Observation framework for view models.
- One non-sandboxed app process. Collectors run concurrently in a bounded `TaskGroup` with per-collector timeouts.
- CLI tools run through `Process` with absolute paths (`/usr/bin/pluginkit`, `/bin/launchctl`, `/usr/bin/systemextensionsctl`), argument arrays (no shell), `LC_ALL=C`, an output size cap and a timeout. Children inherit the app's TCC responsibility, so Full Disk Access covers them.
- SQLite through the system `libsqlite3`: `SQLITE_OPEN_READONLY`, short busy timeout, and no copies of TCC.db written to disk.
- The core has no third-party dependencies. Sparkle 2 (EdDSA-signed appcast) is considered at release time, opt-in.

### 4.3 Modules

Swift package `InspectorKit` (all logic unit-testable without UI) plus the app target:

| Module | Responsibility |
|---|---|
| `InspectorModel` | Value types: `AppRecord`, `PermissionItem`, `ExtensionItem`, `StartupItem`, `ShortcutItem`, `Determination`, `Evidence`, `SourceID`, `Association`. |
| `InspectorParsers` | Pure parsers (text, plist, JSON, SQLite rows → structs) for pluginkit, launchctl, systemextensionsctl, `sfltool dumpbtm`, TCC rows, system-extension `db.plist`, Chromium and Firefox profiles. Fixture-tested per OS build. |
| `InspectorPlatform` | Code signing (`SecStaticCode`), bundle reader (Info.plist, entitlements, embedded bundles), process runner, SQLite reader, FSEvents watcher, access probes (FDA, Accessibility), System Settings linker. |
| `InspectorSources` | One `Collector` per source; maps parser output to `Determination`s using the capability matrix (§4.6). |
| `InspectorAssociation` | Attributes helpers, extensions, TCC clients and launchd jobs to parent apps, with reason and confidence. |
| App target | Scan orchestrator, snapshot store, views, onboarding, diagnostics, BTM import, export. |

### 4.4 Data flow

```
Triggers: launch · ⌘R · FSEvents · NSWorkspace launch/quit · BTM import
  → ScanOrchestrator
      → Collectors (parallel, timed)        → RawFacts + SourceStatus
      → Normalizer (capability matrix: is this source authoritative for this item on this OS?)
      → AssociationEngine                   → parent app | developer group | unattributed
  → immutable Snapshot (versioned, diffable)
  → SwiftUI: sidebar · detail · diagnostics
```

Watched paths: `/Library/LaunchAgents`, `/Library/LaunchDaemons`, `~/Library/LaunchAgents`, `/Applications`, `~/Applications`, browser profile folders, `/Library/SystemExtensions/db.plist`. The TCC databases change constantly, so they are re-read with a debounce only while the app is frontmost or on refresh.

### 4.5 Evidence model (enforces the hard rule)

```swift
enum Determination<Value: Sendable>: Sendable {
    case confirmed(Value, Evidence)               // read from a source authoritative for this item on this OS
    case notRecorded(Evidence)                    // authoritative source read OK, no entry → "Not requested" / "No record"
    case declared(Evidence)                       // app declares it may use this (Info.plist key, entitlement): capability, not state
    case inferred(Value, Evidence, why: String)   // heuristic (e.g. same Team ID); never rendered as fact
    case unknown(UnknownReason)
}

enum UnknownReason: Sendable {
    case needsFullDiskAccess, needsBTMImport, needsAccessibility, appNotRunning
    case notInspectable(String)                   // e.g. Location Services clients (root-only store)
    case unsupportedOS(String), formatUnrecognized(SourceID, String)
    case sourceFailed(SourceID, String), timedOut(SourceID)
}

struct Evidence: Sendable {
    let source: SourceID; let locator: String     // file+row, command+label, API call
    let observedAt: Date; let osBuild: String; let excerpt: String?
}
```

Guards:

- Negative values (`.denied`, `.disabledByUser`, `.requiresApproval`) can only be built through a `ConfirmedSource` token that collectors receive when the capability matrix marks them authoritative for that item kind and OS range. That makes "missing ⇒ denied" a type error, not a code-review item.
- `notRecorded` is allowed only when the source was read successfully *and* the matrix marks it complete for that service (never for Location Services, for example).
- Property tests: every collector, fed an unreadable, empty-by-error or garbled source, emits only `.unknown`.

UI vocabulary:

| Determination | Chip | Example wording |
|---|---|---|
| confirmed, positive | solid green | Allowed · Enabled · Running |
| confirmed, negative | solid orange | Denied by user · Turned off in Login Items |
| confirmed, managed | solid purple + profile icon | Allowed by configuration profile |
| notRecorded | grey outline | Not requested · No background-task record |
| declared | blue outline + document icon | Declares camera use (Info.plist) |
| inferred | dotted outline | Probably part of "X" (same Team ID + ID prefix) |
| unknown | dashed grey + lock or "?" icon | Unknown: grant Full Disk Access to read · Unknown: app not running |

Every chip has a tooltip (source, time) and opens the Evidence sheet. Meaning never relies on color alone; VoiceOver reads state and certainty.

### 4.6 Source registry and capability matrix

Each `SourceID` declares:

- **Requirement:** none · Full Disk Access · BTM import · Accessibility.
- **Validated OS range**, e.g. 15.0–26.5.
- **Stability tier:** A public API · B documented CLI · C CLI output not declared as API · D undocumented file/DB format · E deprecated API.
- **Authoritative for:** which item kinds/services it can confirm, and whether absence is meaningful.
- **Parser version and format fingerprint**, e.g. hash of `PRAGMA table_info(access)`, or the set of field names in `pluginkit -vvv` output.

A **Diagnostics** window lists every source as OK / needs FDA / needs import / unsupported OS / format unrecognized / failed, with item counts and last run time. On an OS build outside the validated range, sources still run, but tier C/D results carry an "unvalidated on this macOS build" flag.

### 4.7 Association engine

| Rank | Signal | Where it comes from | Result |
|---|---|---|---|
| 1 | **Containment:** item path is inside `X.app/` | appex in `Contents/PlugIns` or `Contents/Extensions`; `Contents/Library/LaunchAgents`, `/LaunchDaemons`, `/LoginItems`, `/SystemExtensions` | Definitive |
| 2 | **Explicit parent metadata** | launchd `parent bundle identifier` (SMAppService jobs) [V]; pluginkit `Parent Bundle` [V]; plist `AssociatedBundleIdentifiers` [V]; system-extension `db.plist` `container.bundlePath` / `references.appIdentifier` [V]; BTM import parent/associated IDs; browser native-messaging manifest `path` | Strong |
| 3 | **Executable resolves into a bundle** | launchd `Program` / `ProgramArguments[0]` / `BundleProgram`; TCC `client_type = 1` paths | Strong (nested helper apps, e.g. vendor updaters under `/Library/Application Support`, become child bundles) |
| 4 | **Code signing:** same Team ID *and* bundle-ID prefix (`com.vendor.app.helper` → `com.vendor.app`) | `SecCodeCopySigningInformation` | Probable |
| 5 | Same Team ID only | | Developer group, not a specific app |
| 6 | Name or label heuristics | | Suggestion only (dotted chip) |
| – | Nothing matches | | "Unattributed items" sidebar section, grouped by Team ID |

Signing data (team ID, signing identifier, entitlements, flags, cdhash) is cached by (path, inode, mtime). TCC rows map as: `client_type 0` → bundle ID → `NSWorkspace.urlsForApplications(withBundleIdentifier:)`; `client_type 1` → path → containing bundle or the "Command-line tools" group. The row's `csreq` blob is checked with `SecRequirementCreateWithData` + `SecStaticCodeCheckValidity`, giving "matches the installed copy" versus "recorded for a different signature" (stale grant or another copy). The UI always shows *why* an item is linked ("Linked via parent bundle identifier reported by launchd").

### 4.8 UI

- **Sidebar:** search; filter chips (Has grants · Runs in background · Has extensions · Needs attention · Has unknowns); "Show Apple apps" toggle; sections **Applications**, **Developer groups** (team-level items), **Unattributed items**, **Command-line tools** (TCC path clients). Each row: icon, name, compact per-category badges; a dashed badge marks a category that is partly unknown.
- **Detail header:** icon, name, version, bundle ID, path, signature kind (Apple / App Store / Developer ID / ad hoc / unsigned), Team ID, Gatekeeper/notarization result when computed.
- **Detail sections:**
  1. *Privacy & Security*: one row per service with state chip, declared usage text, last-modified time, "Open in System Settings".
  2. *Extensions*: app extensions (grouped by extension point), browser extensions (per browser and profile), system extensions.
  3. *Startup & Background*: open-at-login, launch agents, launch daemons, login-item helpers. Columns: background approval (BTM), launchd override, loaded/running, RunAtLoad/KeepAlive, path; "Open Login Items & Extensions".
  4. *Keyboard Shortcuts* (post-MVP).
  5. *Evidence*: every raw fact collected for this app.
- **Coverage banner:** e.g. "Privacy data unavailable: grant Full Disk Access" [Open Settings] [Why?]; "Background approvals partial: import a BTM report" [Show command].
- **Diagnostics window:** the source registry (§4.6).

### 4.9 System Settings links

`SystemSettingsLinker` keeps a per-OS URL table and a fallback chain: specific anchor → pane root → open System Settings. The only public API is `SMAppService.openSystemSettingsLoginItems()` [SDK]; everything else uses undocumented `x-apple.systempreferences:` URLs, verified per OS in the test matrix.

Extension IDs present on 26.5.1 [V]:

| Target | URL |
|---|---|
| Privacy & Security root | `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension` |
| A privacy pane | `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera` |
| Login Items & Extensions | `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` (or the public API) |
| Keyboard | `x-apple.systempreferences:com.apple.Keyboard-Settings.extension` |

Anchor strings found in the 26.5.1 Privacy & Security binary [V]: `Privacy_Accessibility`, `_Advertising`, `_Analytics`, `_AppleIntelligenceReport`, `_AudioCapture`, `_Automation`, `_Blocklist`, `_Calendars`, `_Camera`, `_DesktopFolder`, `_DevTools`, `_DocumentsFolder`, `_DownloadsFolder`, `_FilesAndFolders`, `_Location`, `_LocationServices`, `_Microphone`, `_NetworkVolume`, `_NudityDetection`, `_Pasteboard`, `_Photos`, `_RemovableVolume`, `_ScreenCapture`, `_SystemServices`, `_iCloudSearchReport`. More anchors:
- **Full Disk Access:** `Privacy_AllFiles` is the documented link in the Endpoint Security headers [SDK].
- **Community lists** (last tested on 14.2) add `Privacy_ListenEvent`, `Privacy_Contacts`, `Privacy_Reminders` and `Privacy_AppBundles` [bvanpeski].
- **No known anchor** for Bluetooth or Local Network, so those open the pane root [rmcdongit].
- **Login Items & Extensions:**
  - Sections: `?UserItems`, `?BackgroundItems`, `?ExtensionItems`, `?Section_Extensions`.
  - Per-extension-type sheet: `x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=<id>` (network extensions on 15, camera extensions on 26.2).
  - No anchor for the Endpoint Security sheet [rmcdongit][DTS-763382].
- **Keyboard:** no anchor for the Keyboard Shortcuts list.

Broken links fail silently: System Settings just opens at its top level. The per-OS check in §9 therefore clicks every link.

---

## 5. Data sources by category

### 5.1 App inventory and identity

| Source | Tier | Needs | Gives | Caveats |
|---|---|---|---|---|
| Directory scans: `/Applications` (plus 1–2 levels of vendor folders), `/Applications/Utilities`, `~/Applications`, `/System/Applications` (plus Utilities) | A (files) | none | App bundles | Safari lives in the App cryptex (`/System/Volumes/Preboot/Cryptexes/App/System/Applications`) and also appears in `/Applications`, so deduplicate on the resolved path [EL-safari]. |
| Spotlight `NSMetadataQuery` on `kMDItemContentTypeTree = com.apple.application-bundle` | A | none | Apps elsewhere (other volumes, unusual folders) | Excluded or unindexed volumes are missing, so directory scans stay primary. |
| `NSWorkspace.urlsForApplications(withBundleIdentifier:)` (12+) | A | none | Every registered copy of a bundle ID, best match first | Resolves bundle IDs from TCC, BTM and pluginkit to paths. No public "all apps" API exists; `_LSCopyAllApplicationURLs` is private. |
| Bundle reader | A | none | Info.plist (ID, name, version, usage descriptions, `NSServices`); embedded code in `Contents/PlugIns`, `Contents/Extensions`, `Contents/Library/{LaunchAgents,LaunchDaemons,LoginItems,SystemExtensions}`, `Contents/Helpers`, `Contents/XPCServices` | iPhone/iPad apps on Apple Silicon have an outer wrapper with a `WrappedBundle` link and a `Wrapper/` folder; read the inner bundle. Translocated copies (`…/AppTranslocation/<UUID>/d/`) are skipped; there is no supported API for their original path. |
| Code signing: `SecStaticCodeCreateWithPath` → `SecStaticCodeCheckValidity(kSecCSBasicValidateOnly \| kSecCSNoNetworkAccess)` → `SecCodeCopySigningInformation(kSecCSSigningInformation)` | A | none | Team ID, signing identifier, entitlements, flags, cdhash, certificate chain, platform identifier | Validate first, or the info can be partial. Always pass no-network. Only `errSecCSUnsigned` means unsigned; any other error means "unreadable", not "unsigned" [SDK][Apple-OSS]. |
| Notarization | A | none | "Notarized (ticket found locally)" | The `notarized` requirement checks only the local ticket store, so a failure means "not confirmed", never "not notarized". Validating a bundle registers its stapled ticket with the system, a benign side effect noted in "About this data" [Apple-OSS]. Online checks (`codesign --check-notarization`, `stapler`) and the private `SecAssessment` functions are not used. |

**Signature classes:**
- Apple platform: platform identifier set.
- Mac App Store: leaf OID `1.2.840.113635.100.6.1.9`.
- Developer ID: intermediate OID `…100.6.2.6` plus leaf `…100.6.1.13`.
- Apple Development: leaf `…100.6.1.12`.
- Ad hoc: flag `0x2`; linker-signed `0x20000`.
- Unsigned.

Sources: [TN3127][SDK].

**Cost:** a full check takes about 0.05 s for a simple app. Basic validation without resource hashing (`kSecCSDoNotValidateResources`, plus `kSecCSFastExecutableValidation` on 11.3+) keeps a 500-app scan within budget. Results are cached by (path, inode, mtime).

### 5.2 Privacy permissions

No public API reports another app's authorization. `AVCaptureDevice.authorizationStatus`, `CGPreflightScreenCaptureAccess`, `CGPreflightListenEventAccess`/`PostEventAccess`, `IOHIDCheckAccess` and `AXIsProcessTrusted` all describe the calling process only [SDK].

| Source | Tier | Needs | Confirms | OS |
|---|---|---|---|---|
| Declared capabilities: Info.plist `NS*UsageDescription` keys; entitlements such as `com.apple.security.device.camera`, `…device.audio-input`, `…personal-information.*`, `…automation.apple-events` | A | none | "May ask for X". Shown as declared, never as granted. | all |
| User TCC.db: `~/Library/Application Support/com.apple.TCC/TCC.db` | D | FDA | Prompted services: Camera, Microphone, Automation, Files & Folders, Photos, Contacts, Calendars, Reminders, … | 15, 26. **27: moved to `/private/var/containers/Data/ProtectedSystem/<UUID>/…` and closed to apps** [RN27][WR] |
| System TCC.db: `/Library/Application Support/com.apple.TCC/TCC.db` | D | FDA | Settings-managed services: Full Disk Access, Accessibility, Screen Recording, Input Monitoring, PostEvent | 15, 26; 27 [?] |
| `MDMOverrides.plist` (next to the system DB) | D | FDA | Profile-managed decisions (client → service → Allowed) | 15, 26. 27 moves Camera, Microphone, Accessibility and Speech to declarative privacy defaults [?] |
| `tccutil list` | B | [?]; documented "on managed devices" | Current authorizations per service and app | 27 only. Phase 0 decides whether a user-run import (like BTM's) works on unmanaged Macs. |
| `~/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist` | D | FDA | Screen Recording reminder timestamps only; the grant itself is the TCC row | 15+ |
| locationd `clients.plist`; Local Network rules (Network Extension, not TCC) | – | root / unknown | – | Not inspected → Unknown, with a deep link |
| Endpoint Security `NOTIFY_TCC_MODIFY` (15.4+) | A, restricted | ES entitlement + root + FDA | Change events only, no snapshot | Not used |

**Row decoding** (community-documented; matches the public Endpoint Security enums [SDK]):
- Columns of `access`: service, client, client_type (0 = bundle ID, 1 = path), auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier(_type), indirect_object_code_identity, flags, last_modified; since 14 also pid, pid_version, boot_uuid, last_reminded. Fingerprint the table with `PRAGMA table_info(access)` and read known columns only.
- `auth_value`: 0 denied · 1 unknown · 2 allowed · 3 limited.
- `auth_reason`: 1 error · 2 user consent (prompt) · 3 user set (Settings) · 4 system set · 5 service policy · 6 MDM policy · 7 override policy · 8 missing usage string · 9 prompt timeout · 10 preflight unknown · 11 entitled · 12 app-type policy · 13 prompt cancel.
- Automation rows put the target app in `indirect_object_identifier`; show them as "X controls Y".
- `csreq` is validated against the installed code (§4.7).

**Mapping to the UI** (enforces the hard rule):

| Situation | Shown as |
|---|---|
| Row, `auth_value` 2 or 3 | Allowed / Limited (confirmed), with the reason ("allowed in Settings", "MDM policy", …) |
| Row, `auth_value` 0 | Denied (confirmed), with the reason; reasons 8, 9 and 13 shown verbatim (e.g. "missing usage string") |
| Row whose `csreq` doesn't match the installed copy | "Recorded for a different build or copy" (neutral) |
| No row, DB read OK, prompted service | Not requested (no decision recorded) |
| No row, DB read OK, Settings-only service | Not in list (neutral grey). Apple-entitled or profile-granted access can still exist [mazurek][objective-see]. |
| DB unreadable | Unknown: needs FDA · Unknown: macOS 27 doesn't let apps read this |
| Location Services, Local Network | Unknown: not inspectable · Open Settings |

A row does not prove the app asked: merely touching protected files adds an app to the FDA list [tidbits].

**Service catalog.** This is a seed list. The DB's own `service` values drive what's shown, and unknown keys appear raw. The "Usual DB" column is community knowledge, so the collector reads both databases for every service.

| Settings pane | TCC service | Usual DB | Anchor |
|---|---|---|---|
| Camera | `kTCCServiceCamera` | user | `Privacy_Camera` [V] |
| Microphone | `kTCCServiceMicrophone` | user | `Privacy_Microphone` [V] |
| Accessibility | `kTCCServiceAccessibility`, `kTCCServicePostEvent` | system | `Privacy_Accessibility` [V] |
| Input Monitoring | `kTCCServiceListenEvent` | system | `Privacy_ListenEvent` [web] |
| Screen & System Audio Recording | `kTCCServiceScreenCapture` (audio-only variant [?]) | system | `Privacy_ScreenCapture`, `Privacy_AudioCapture` [V] |
| Full Disk Access | `kTCCServiceSystemPolicyAllFiles` | system | `Privacy_AllFiles` [SDK] |
| Files & Folders | `kTCCServiceSystemPolicy{Desktop,Documents,Downloads}Folder`, `…NetworkVolumes`, `…RemovableVolumes` | user | `Privacy_FilesAndFolders`, plus per-folder anchors [V] |
| Automation | `kTCCServiceAppleEvents` (+ target app) | user | `Privacy_Automation` [V] |
| Photos | `kTCCServicePhotos` (+ `PhotosAdd`) | user | `Privacy_Photos` [V] |
| Contacts / Calendars / Reminders | `kTCCServiceAddressBook` / `Calendar` / `Reminders` | user | `Privacy_Contacts` [web] / `Privacy_Calendars` [V] / `Privacy_Reminders` [web] |
| App Management | `kTCCServiceSystemPolicyAppBundles` | sources conflict | `Privacy_AppBundles` [web] |
| Developer Tools | `kTCCServiceDeveloperTool` | [?] | `Privacy_DevTools` [V] |
| Bluetooth | `kTCCServiceBluetoothAlways` | [?] | none found → pane root |
| Paste from other apps | Pasteboard service (15.4+ preview) | [?] | `Privacy_Pasteboard` [V] |
| Location Services | locationd (not TCC) | – | `Privacy_LocationServices` [V] |
| Local Network | Network Extension rules (not TCC) | – | none found → pane root |

### 5.3 Extensions

**App extensions** (Share, Finder Sync, Quick Look, Spotlight, widgets, File Provider, Safari, …)

| Source | Tier | Needs | Confirms | Caveats |
|---|---|---|---|---|
| `pluginkit -mAvvv` | C | none [V] | Registered extensions: extension point (`SDK`), path, version, `Parent Bundle`/`Parent Name` for an appex inside an app; user election `+` use, `-` ignore, `=` superseded, `!` debugger [V][pluginkit(1)] | Man page calls pluginkit a debugging tool; output is not API. No mark (421 of 463 here) = no user choice → show "System default", never Enabled/Disabled. `-p <point>` returned 0 for points that exist → filter on `SDK` ourselves [V]. |
| Bundle scan of `Contents/PlugIns/*.appex` and `Contents/Extensions/*.appex` (ExtensionKit) | A (files) | none | Presence, `NSExtensionPointIdentifier` / `EXAppExtensionAttributes`, display name | Registration happens through LaunchServices after install or launch. Present but unregistered → "Not registered (app may never have been opened)", never Disabled [EL-pkd]. |
| Public enumeration API | – | – | None exists. `EXAppExtensionBrowserViewController` covers only the caller's own extension points [SDK] | |

Elections persist in pkd's private registry under `/var/folders` and are not read directly. The mapping between elections and the Settings toggles of each extension type is a Phase 0 item [?].

**System extensions** (network, Endpoint Security, DriverKit)

| Source | Tier | Needs | Confirms | Caveats |
|---|---|---|---|---|
| `systemextensionsctl list` | C | none [V] | Category, enabled, active, Team ID, bundle ID, version, name, state (`activated enabled`, `activated waiting for user`, `activated disabled`, `terminated waiting to uninstall on reboot`) | Text output. On 26.5.1 each category header names its Settings location [V]. |
| `/Library/SystemExtensions/db.plist` | D | none: world-readable on 26.5.1 [V] | Per extension: `identifier`, `teamID`, `state`, `categories`, `container.bundlePath` (containing app), `originPath`, `references[].appIdentifier`, staged cdhashes; top-level `extensionPolicies` (MDM) [V][osquery] | Undocumented; schema fingerprint per OS. Best association source. |
| Containment scan of `Contents/Library/SystemExtensions/*.systemextension` | A | none | Presence | |

Network-extension *configurations* (VPN, filter and DNS settings) are not inspectable: the public API returns only the caller's own [SDK]. Legacy kernel extensions (`kmutil showloaded`, `/Library/Extensions` scan) are deferred; their approval database (KextPolicy) needs root, so approval stays Unknown.

**Browser extensions**

| Browser | Source | Tier | Needs | Confirms / caveats |
|---|---|---|---|---|
| Safari | pluginkit SDKs `com.apple.Safari.web-extension`, `com.apple.Safari.content-blocker`, `com.apple.Safari.extension` (legacy) | C | none [V] | Installed extension plus its containing app. |
| Safari | `~/Library/Containers/com.apple.Safari/Data/Library/Safari/WebExtensions/Extensions.plist` (and `AppExtensions/`) | D | FDA | Enabled state [ENG]. Per-profile storage (Safari 17+) not found [?] → Unknown until verified. Public `SFSafariExtensionManager` reports only the caller's own extension, "on in any profile". |
| Chromium family: Chrome (+Beta/Canary), Edge, Brave, Vivaldi, Arc, Chromium, Opera | `Local State` → `profile.info_cache`; per profile `Secure Preferences` **and** `Preferences` → `extensions.settings.<id>` | D | none on 15/26 [V]; **FDA on 27** [WR] | Current Chrome keeps entries in `Secure Preferences`, has no `state` field, and stores `disable_reasons` as a list of ints [V][CR-prefs]. Enabled ⇔ not blocklisted and `disable_reasons` empty or absent. `location`: 1 Web Store · 2/3/6 external · 4 unpacked · 5 component · 7/9 policy · 8 command line · 10 external component [CR-mojom]. Name and version from `manifest`, or from `Extensions/<id>/<ver>/manifest.json` on disk (resolve `__MSG_` names via `_locales`). |
| Firefox | `profiles.ini` → `<profile>/extensions.json` | D | none on 15/26; FDA on 27 [WR] | `addons[]`: id, type, version, `active`, `userDisabled`, `appDisabled`, `softDisabled`, `location`. Firefox 149+ can keep profiles in an App Group container, which is protected from 15 on [?]. |
| All | Native-messaging manifests in `{~,}/Library/Application Support/<browser>/NativeMessagingHosts` (Chrome system-wide: `/Library/Google/Chrome/NativeMessagingHosts`) | D | none; excluded from 27's protection [WR] | `path` plus `allowed_origins` / `allowed_extensions` tie an extension to a helper binary, and so to the helper's app ("Related"). |
| All | Policy: `/Library/Managed Preferences/<browser-domain>.plist` (e.g. Chrome `ExtensionInstallForcelist`), Firefox `policies.json` | B/D | none | "Installed by policy" (managed). |

Browser extensions are listed under the browser app, per profile, and also as "Related" under a helper's app when a native-messaging host links them.

### 5.4 Startup and background items

Each item shows four independent layers. The UI never collapses them into a single on/off unless all four are known.

| Layer | Question | Sources |
|---|---|---|
| Approval (BTM) | Is it allowed to run in the background or at login? | `statusForLegacyPlist(at:)` (legacy plists), `LSSharedFileList` (login apps), BTM import |
| launchd override | Has it been `launchctl disable`d? | `launchctl print-disabled` |
| Runtime | Is it loaded or running now? | `launchctl print`, process list |
| Configuration | What does it ask for? | plist: RunAtLoad, KeepAlive, intervals, MachServices, program |

Apple DTS: the "Allow in the Background" list is an allowlist of what *may* launch, not a list of what *will* launch [DTS-713830]. UI wording follows that: "Allowed to run in background" is distinct from "Running".

| Item kind | Source | Tier | Needs | Confirms / caveats |
|---|---|---|---|---|
| Legacy agents and daemons (`/Library/LaunchAgents`, `/Library/LaunchDaemons`, `~/Library/LaunchAgents`) | plist scan | A (files) | none | Label, program, RunAtLoad, KeepAlive, `AssociatedBundleIdentifiers` (6 of 28 here [V]), `Disabled` key, quarantine xattr. Plists only root can read → Unknown. |
| ″ | `SMAppService.statusForLegacyPlist(at:)` (ObjC `statusForLegacyURL:`) | A, off-label | none [V] | The header intends it for the caller's own legacy items; here it works on any plist. Calibration [V]: `.enabled` ⇔ loaded (22/22), `.requiresApproval` ⇔ not loaded (3/3), `.notFound` ⇔ plist unreadable by the caller (3/3). Mapping: enabled → Allowed; requiresApproval → "Turned off or awaiting approval"; notRegistered and notFound → Unknown (`.notFound` has also been reported for running helpers [DTS-750685]). |
| ″ | `launchctl print gui/<uid>/<label>` and `system/<label>` | C | none [V]; "anyone may read or query the system domain" [launchctl(1)] | state, pid, program, last exit code, spawn type, properties (`runatload`, `keepalive`, `managed LWCR`, …). The output "is NOT API in any sense at all" [launchctl(1)] → tolerant parser plus per-OS fixtures. |
| ″ | `launchctl print-disabled gui/<uid>` / `system` | C | none [V] | Explicit overrides: `"label" => enabled \| disabled`. |
| SMAppService agents and daemons (`Contents/Library/LaunchAgents\|LaunchDaemons`, `BundleProgram`) | bundle scan | A | none | Presence and declared configuration. |
| ″ | `launchctl print` | C | none [V] | Registered, loaded jobs show `type = Submitted`, `parent bundle identifier`, `parent bundle version`, `program identifier` [V] → confirmed "Registered; loaded/running". Not loaded → Unknown: unregistered, turned off and awaiting approval look the same without BTM data. `statusForLegacyPlist` returns `.notFound` for most of these (5/6 [V]) and is not used. |
| Open-at-login apps | `LSSharedFileList` session login items | E (deprecated 10.11) | none [V: 10 apps returned on 26.5.1] | Item URL and hidden flag. Whether SMAppService `mainApp` registrations appear is a Phase 0 item [?]. If Apple removes the API, this falls back to Unknown. |
| Login-item helpers (`Contents/Library/LoginItems/*.app`; `SMLoginItemSetEnabled`, deprecated in 13) | bundle scan + `launchctl print gui/<uid>/<helper-id>` | A + C | none [V: 1 loaded, 5 not] | Loaded → "Enabled (loaded)". Not loaded → "Not loaded" (neutral). |
| Running helpers | `NSWorkspace.runningApplications`, `proc_listallpids` + `proc_pidpath` | A | none | Processes executing from inside the bundle → "Running now". |
| All kinds: authoritative approvals, MDM-managed flag, Spotlight/Quick Look/developer types | `sudo sfltool dumpbtm`, run by the user and imported | U (text) | root, user-run | Records per UID: Name, Developer Name, Team Identifier, Type bitmask (app 0x2, login item 0x4, agent 0x8, daemon 0x10, legacy 0x10000, curated 0x80000, …), Disposition (enabled, allowed, visible, notified), Identifier, URL, Executable Path, Generation, Assoc. Bundle IDs, Parent Identifier [DumpBTM][EL26]. Removed items linger until overnight maintenance [EL23] → cross-check that paths exist; show the import's age. |
| ″ | Direct read of `/private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v*.btm` (v4 on 13.0 … v16 on 26) | D | FDA, reportedly [DumpBTM] [?] | Binary keyed archive of private classes. Phase 0 spike: if FDA alone can read it, walk the archive's object graph generically (no private classes) and make the import optional. Glob `v*`; never hard-code the version. |

Out of MVP scope: cron/periodic jobs, login hooks, BTM Spotlight/Quick Look/"developer" types beyond listing them from BTM data, and Endpoint Security BTM events (restricted entitlement plus root).

Version notes: (26) a prompt appears when an app's background tasks keep running after it quits, and Settings now calls the list "App Background Activity" [APD][EL25]. (27) launchd no longer loads plists that carry the quarantine xattr [RN27] → show "Will not load (quarantined)" when the xattr is present.

### 5.5 Keyboard shortcuts (post-MVP, Phase 4)

| Kind | Source | Tier | Needs | Confirms / caveats |
|---|---|---|---|---|
| Menu shortcuts of running apps | AX: `AXUIElementCreateApplication(pid)` → `kAXMenuBarAttribute` → items with `AXMenuItemCmdChar`, `…CmdVirtualKey`, `…CmdGlyph`, `…CmdModifiers` | A | Accessibility, checked with `AXIsProcessTrustedWithOptions` without prompting until the user opts in | Effective menu key equivalents. Modifiers: 0 = ⌘ alone; Shift 1<<0, Option 1<<1, Control 1<<2, NoCommand 1<<3. Glyphs are Carbon `kMenu*Glyph` codes [SDK]. Reading runs the target's `menuNeedsUpdate:`, so its code executes. Menus filled only when opened read as empty → "Not loaded", never "no shortcuts". Never `AXPress`. Batch with `AXUIElementCopyMultipleAttributeValues`, set `AXUIElementSetMessagingTimeout`, and map every AX error to Unknown. |
| Shortcuts AX cannot see | Electron renderer handlers (`before-input-event`), `globalShortcut`; hidden items with `allowsKeyEquivalentWhenHidden` | – | – | Listed as a known gap per app framework. |
| Menu shortcuts of apps that aren't running | – | – | – | No supported way. Nib parsing is reverse-engineered and misses menus built in code, so it isn't planned → Unknown ("app not running"). |
| User-customized app shortcuts | `NSUserKeyEquivalents` in the global domain and each app's domain (`@`⌘ `$`⇧ `~`⌥ `^`⌃; submenu paths `\033Menu\033Item`) | D | none for non-sandboxed apps. A sandboxed app's container prefs prompt (14+) or are denied (27) → Unknown | "Configured" overrides; AX shows what is in effect. `CFPreferences` silently falls back for container domains, so nil = Unknown. Apps can opt out (`usesUserKeyEquivalents`). Settings caches its app list in `com.apple.universalaccess` → `com.apple.custommenu.apps`. |
| System shortcuts | `com.apple.symbolichotkeys` → `AppleSymbolicHotKeys`: `{enabled, value.parameters = [char or 65535, keycode, modifiers]}` with ⇧ 1<<17, ⌃ 1<<18, ⌥ 1<<19, ⌘ 1<<20, keypad 1<<21, fn 1<<23 [V: 49 entries]; Carbon `CopySymbolicHotKeys` for effective values including defaults | D + A | none | System hotkeys and their enabled state. A missing ID means "default", not "disabled". The ID → action table is reverse-engineered [CGSInternal], so unknown IDs are shown raw. |
| Services shortcuts | Info.plist `NSServices` → `NSKeyEquivalent` (documented); user changes in `pbs` → `NSServicesStatus` (undocumented) | A + D | none | Service key equivalents. |
| Third-party global hotkeys | No API lists other processes' `RegisterEventHotKey` registrations. Carbon hotkeys need no permission and create no event tap. | – | – | "Not discoverable", unless an adapter (below) finds them. |
| Keyboard monitoring or interception | `CGGetEventTapList`: tapping PID, tapped PID (0 = all), `eventsOfInterest`, options (listen-only vs active filter), enabled | A | none [V: 14 taps, 5 keyboard, on 26.5.1 without grants] | "Monitors keyboard" / "Can modify keyboard input" per app. Refresh on `kCGNotifyEventTapAdded`/`Removed`. Shown next to the app's Input Monitoring and Accessibility grants (§5.2). |
| Hotkeys stored by common libraries and apps | Adapters: KeyboardShortcuts (`KeyboardShortcuts_<name>`, JSON `{carbonKeyCode, carbonModifiers}`); MASShortcut (keyed archive or `{keyCode, modifierFlags}`); ShortcutRecorder (`keyCode`, `modifierFlags`, …); Rectangle (`com.knollsoft.Rectangle`, one key per action) | D | none for non-sandboxed apps; containers as above | Configured hotkeys, shown as inferred (configured ≠ registered) with dotted chips. Versioned adapter registry. Raycast, Alfred and Magnet formats not found. |

Phase 4 adds a conflict view: system, app-menu and adapter-found hotkeys overlaid, with duplicates flagged and certainty shown.

Version notes: (26) Spotlight quick keys, and a "Menu Customization" section in the release notes, details not found → Phase 4 spike. (27) Menu-bar overflow; its effect on AX traversal is unknown [?].

---

## 6. macOS version differences (supported range 15 → 27)

| Area | 15 Sequoia | 26 Tahoe | 27 (shipped 2026-09-14; 27.2 current) |
|---|---|---|---|
| TCC.db | User and system DBs readable with FDA; schema unchanged since 14 | Same; no new TCC API in the 26.5 SDK | User DB moved under `/private/var/containers/Data/ProtectedSystem/…`. Release notes: apps can no longer access the local TCC database directly [RN27]. System DB stays put (readable with FDA? [?]). New `tccutil list` for managed devices. |
| FDA detection | Probe TCC.db | Same | A TCC.db probe always fails → probe another protected path |
| MDM privacy | PPPC + `MDMOverrides.plist` | 26.2 shows managed permissions in Settings; PPPC can no longer grant Accessibility | PPPC keys for Camera, Microphone, Accessibility and Speech Recognition deprecated in favour of declarative privacy defaults (supervised devices) |
| Screen Recording | Reminder prompts (weekly, then monthly, 90 days for heavy use); `ScreenCaptureApprovals.plist` | 26.3 display fix | not found |
| Pasteboard privacy | 15.4 developer preview | Settings anchor present [V] | not found |
| Local Network | Network Extension rules, not TCC | Same | 27.2 adds add/remove controls in Settings |
| Other apps' data | (14) container prompt; (15) adds app-group containers | Same | Other teams' containers and group containers denied by default with no prompt. XProtect guards browser and wallet data, so Chromium and Firefox profiles need FDA. |
| Login items | Extensions and system extensions move to General › Login Items & Extensions | Called "App Background Activity"; prompt when background tasks keep running after quit; BTM store v16 | Quarantined launchd plists no longer load; Intel-only plug-ins may not appear in Settings |
| Settings deep links | Legacy `com.apple.preference.security?…` may open the pane without selecting the row | Screen Saver pane removed; Network `?Firewall` anchor broken | not found → re-verify every link |

---

## 7. Limitations and risks

| # | Risk | Likelihood / impact | Mitigation |
|---|---|---|---|
| R1 | macOS 27 closes TCC.db to apps, and the system DB may follow | Certain on 27 / **High**: privacy grants are the headline feature | Phase 0 gate on 27: test the system DB with FDA, and test `tccutil list` (a user-run import, like BTM's, if admins can run it on unmanaged Macs). Otherwise ship 27 support with declared capabilities, exact deep links and plain "macOS 27 hides these decisions" copy. Keep the TCC collector isolated so dropping it is cheap. |
| R2 | Undocumented formats change: TCC schema, pluginkit/launchctl text, BTM dump, `db.plist`, browser prefs | High / Medium | Format fingerprints, per-OS fixtures, "unvalidated on this build" flag, fail to Unknown, quick patch releases |
| R3 | Deprecated or off-label APIs vanish (`LSSharedFileList`; `statusForLegacyPlist` on other apps' plists) | Medium / Medium | Treated as tier E; the BTM import covers the same facts; failure → Unknown |
| R4 | Apple makes FDA harder to grant | Medium / Medium | The app stays useful without FDA (startup items, extensions, declared permissions); onboarding explains each unlock |
| R5 | "No record" doesn't prove "no access" (Apple-private entitlements, MDM, silent policy denials) | Certain / Low with correct wording | Neutral "Not in list" wording; tooltip explains |
| R6 | Stale data: BTM keeps removed items until overnight cleanup; TCC rows outlive old builds | Certain / Low | Path-existence checks, `csreq` checks, import age shown |
| R7 | No public way to read other apps' SMAppService state | Certain / Medium | Loaded jobs via launchctl; the rest Unknown until a BTM import (or an FDA read, if Phase 0 allows) |
| R8 | Location Services and Local Network are not inspectable | Certain / Low | Unknown with an explanation and a deep link |
| R9 | The inspector holds FDA, making it an attractive target | Low / High | No network by default; hardened runtime with library validation; no plug-ins; no shell; read-only DB opens; signed updates; consider open-sourcing the parsers |
| R10 | Sensitive data in exports (paths, extension lists) | Medium / Medium | Export only on request; redaction option; local files only |
| R11 | Shortcut discovery is inherently incomplete | Certain / Low (post-MVP) | Every source labelled; non-running apps Unknown; heuristics shown dotted |
| R12 | Scan cost (code signing, subprocesses) on large app sets | Medium / Low | Cache by inode and mtime; basic validation only; bounded concurrency; deep checks on demand |

---

## 8. Phased MVP plan

Estimates assume one experienced macOS developer.

### Phase 0: validation spikes and fixture corpus (≈1–2 weeks)

Goal: turn every **[?]** in this document into a per-OS yes/no.

- Build three VMs (15.x, 26.x, 27.x) with Virtualization.framework tooling (e.g. UTM or tart) and snapshot a clean state.
- Scenario kit: small signed test apps that (a) request camera, microphone, screen recording, Automation and Files & Folders; (b) register an SMAppService agent and a `mainApp` login item; (c) install a legacy LaunchAgent/Daemon with and without `AssociatedBundleIdentifiers`; (d) ship Share, Finder Sync, Quick Look and Safari web extensions; (e) install Chrome/Firefox test extensions and a native-messaging host.
- `Tools/capture-fixtures.sh` (run inside each VM, `sudo` only for BTM): `pluginkit -mAvvv`, `launchctl print` (gui, system, per job), `launchctl print-disabled`, `systemextensionsctl list`, `db.plist`, `sfltool dumpbtm`, TCC.db copies (VM-only, never from user machines), browser profile samples, plus System Settings screenshots as ground truth.
- Calibrate: `statusForLegacyPlist(at:)` results against BTM toggles; `LSSharedFileList` versus SMAppService `mainApp` login items; pluginkit elections versus Settings toggles per extension type; TCC services versus DB versus Settings anchors; Safari extension state storage; every deep link.
- **macOS 27 gates** (decide R1 first; the outcome reshapes Phase 1):
  - Can an FDA-granted app read the system TCC.db?
  - What does `tccutil list` need on an unmanaged Mac (user, admin, `sudo`), and what does its output look like?
  - Which FDA probe path works?
  - Can FDA alone read `BackgroundItems-v*.btm` on each OS?
  - Do Chromium/Firefox profiles open with FDA?
- **Exit:** capability matrix complete (tier, requirement, OS range, authoritative-for) and a go/no-go per source.

### Phase 1: skeleton, identity, privacy (MVP-α, ≈3–4 weeks)

- App target and packages; `Collector` protocol; `Determination`/`Evidence`; Diagnostics window.
- App inventory, bundle reader, code-signing summary, declared capabilities (usage-description keys, entitlements).
- TCC collector: user and system DBs, schema fingerprint, `csreq` validation, MDM overrides, service catalog with per-OS gaps.
- Full Disk Access onboarding: detect, explain, deep link, re-scan; coverage banner.
- UI: sidebar, detail header, Privacy section, Evidence sheet, deep links.
- **Exit:** on the 15 and 26 VMs, scenario apps' privacy rows match System Settings. On 27, every row is either confirmed by a source validated in Phase 0 or Unknown with the correct reason. With FDA revoked, no confirmed negative appears anywhere.

### Phase 2: extensions, startup items, association (MVP-β, ≈3–4 weeks)

- App extensions: pluginkit plus bundle scan, elections, extension-point catalog with Settings links.
- System extensions: `systemextensionsctl` plus `db.plist` plus containment.
- Browser extensions: Safari (pluginkit; enabled state where readable), Chromium family, Firefox, native-messaging hosts.
- Startup: plist scan, `statusForLegacyPlist(at:)`, `launchctl print` / `print-disabled`, open-at-login apps, LoginItems helpers, running processes.
- Association engine (full ladder); Developer groups and Unattributed sections.
- **Exit:** every scenario item attributed correctly; Unknown shown wherever only the BTM import could confirm a state.

### Phase 3: BTM import, live refresh, release (MVP 1.0, ≈2–3 weeks)

- BTM import: copyable command, file picker, tolerant per-OS parser, merge with live data, staleness indicator (import time versus last boot and now).
- FSEvents/NSWorkspace refresh; in-memory "new since last scan" diff; optional JSON export with path redaction.
- Performance budget: full scan of ~500 apps under 10 s cold and under 2 s warm (signing info cached).
- Hardening: fuzz parsers with corrupted fixtures; VoiceOver pass; localizable strings; in-app "About this data" page per source.
- Distribution: Developer ID signing, hardened runtime, `notarytool`, stapling, DMG; optional Sparkle.
- **Exit:** notarized build passes the full test matrix.

### Phase 4: keyboard shortcuts (post-MVP, ≈3 weeks)

- Menu shortcuts of running apps via Accessibility (opt-in); `NSUserKeyEquivalents`; system symbolic hotkeys; Services shortcuts; event-tap list; per-app/library adapters; conflict view. Non-running apps show Unknown, not "no shortcuts".

### Phase 5: options, only if wanted

- Persistent history and diffs across launches; CLI/JSON output for admins; MDM-oriented reports; more browsers.

---

## 9. Verification strategy

- **Unit:** every parser against the fixture corpus for each OS build; truncated or malformed input must yield `.unknown`.
- **Property:** for each collector, simulate denied, missing and garbled sources; assert no confirmed negative is produced.
- **Integration (VMs):** scripted scenarios → snapshot JSON → compared with golden expectations taken from System Settings and `sudo sfltool dumpbtm`.
- **Access matrix:** {no FDA, FDA} × {no BTM import, import} (× {Accessibility off, on} in Phase 4).
- **Manual, per release:** walk each System Settings pane against the inspector on every VM; click every deep link.
- **Performance:** scan time and memory on a machine with 500+ apps.
- **Self-audit:** `fs_usage` during a scan shows no writes to protected stores; no network traffic (`nettop`); hardened runtime and notarization verified with `codesign -dv` and `spctl -a -vv`.

---

## 10. Proposed repository layout

```
AppInspector/
├─ AppInspector.xcodeproj        # app target: macOS 15+, Developer ID, hardened runtime, no sandbox
├─ App/                          # SwiftUI views, view models, onboarding, diagnostics, import/export
├─ Packages/InspectorKit/
│  ├─ Sources/InspectorModel/
│  ├─ Sources/InspectorParsers/
│  ├─ Sources/InspectorPlatform/
│  ├─ Sources/InspectorSources/
│  ├─ Sources/InspectorAssociation/
│  └─ Tests/                     # + Fixtures/<os-build>/…
└─ Tools/capture-fixtures.sh     # run inside test VMs (sudo only for BTM)
```

---

## 11. References

Research agents collected the web sources on 2026-11-05, and not every link was re-opened afterwards. Claims still marked [?] are validated in Phase 0.

**Apple (primary)**
- [SDK] macOS 26.5 SDK headers:
  - ServiceManagement `SMAppService.h`
  - EndpointSecurity `ESTypes.h`, `ESMessage.h`, `ESClient.h`
  - HIServices `AXAttributeConstants.h`, `AXUIElement.h`
  - CoreGraphics `CGEvent.h`, `CGEventTypes.h`, `CGWindow.h`
  - Security `SecCode.h`, `SecStaticCode.h`, `SecRequirement.h`, `CSCommon.h`
  - AppKit `NSWorkspace.h`, `NSMenuItem.h`, `NSPasteboard.h`
  - ExtensionKit `EXAppExtensionBrowserViewController.h`
  - SafariServices `SFSafariExtensionManager.h`
  - IOKit `IOHIDLib.h`
- Man pages: [launchctl(1)], launchd.plist(5), [pluginkit(1)], systemextensionsctl(8), kmutil(8), codesign(1), syspolicy_check(1).
- Release notes:
  - [RN27] https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
  - macOS 15 and 26 release notes (same site).
- [APD] Apple Platform Deployment:
  - Login and background items: https://support.apple.com/guide/deployment/depdca572563
  - Managed login items: https://support.apple.com/guide/deployment/dep07b92494
- Enterprise notes:
  - macOS 27 (`tccutil list`): https://support.apple.com/en-us/148830
  - macOS 26: https://support.apple.com/en-us/124963
- Distribution rules:
  - App Review Guidelines 2.4.5 and 2.5.2: https://developer.apple.com/app-store/review/guidelines/
  - App Sandbox: https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox
- Technotes:
  - [TN3127] https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
  - TN3179 (local network privacy): https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- Developer Forums threads [DTS-713830], [DTS-750685], [DTS-807142], [DTS-763382]: https://developer.apple.com/forums/thread/<number>
- [Apple news] https://developer.apple.com/news/?id=p6zjojqw
- Device-management schemas (PPPC, declarative app settings): https://github.com/apple/device-management
- [Apple-OSS] Security framework source (`StaticCode.cpp`, `notarization.cpp`): https://github.com/apple-oss-distributions/Security

**Community and research**
- Eclectic Light:
  - [EL23] https://eclecticlight.co/2023/02/15/controlling-login-and-background-items-in-ventura/
  - [EL25] https://eclecticlight.co/2025/12/03/manage-login-and-background-items/
  - [EL26] https://eclecticlight.co/2026/02/20/in-the-background-identification/
  - [EL-pkd] https://eclecticlight.co/2025/04/16/how-pluginkit-enables-app-extensions/
  - [EL-safari] https://eclecticlight.co/2024/09/04/where-has-safari-gone-and-why-are-macos-updates-larger-for-apple-silicon/
- Objective-See:
  - [DumpBTM] https://github.com/objective-see/DumpBTM
  - [objective-see] https://objective-see.org/blog/blog_0x7F.html
- [WR] https://wojciechregula.blog/post/golden-gate-appdata-protection/
- [mazurek] https://karol-mazurek.medium.com/snake-apple-ix-tcc-ae822e3e2718
- [tidbits] https://tidbits.com/2026/10/12/why-full-disk-access-matters-and-what-apple-should-fix/
- System Settings URL lists:
  - [bvanpeski] https://github.com/bvanpeski/SystemPreferences
  - [rmcdongit] https://gist.github.com/rmcdongit/f66ff91e0dad78d4d6346a75ded4b751
- [osquery] https://github.com/osquery/osquery/blob/master/osquery/tables/system/darwin/system_extensions.mm
- [ENG] https://engineered.at/articles/more-disappearing-safari-extensions
- Chromium source:
  - [CR-prefs] https://chromium.googlesource.com/chromium/src/+/main/extensions/browser/extension_prefs.cc
  - [CR-mojom] https://chromium.googlesource.com/chromium/src/+/main/extensions/common/mojom/manifest.mojom
- Native messaging and browser policy:
  - https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging
  - https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_manifests
  - https://mozilla.github.io/policy-templates/
- Screen Recording reminders: https://stclairsoft.com/blog/2025/03/03/disruptive-screen-recording-reminders/
- Hotkeys:
  - [CGSInternal] https://github.com/NUIKit/CGSInternal/blob/master/CGSHotKeys.h
  - Libraries on GitHub: sindresorhus/KeyboardShortcuts, cocoabits/MASShortcut, Kentzo/ShortcutRecorder, soffes/HotKey, rxhanson/Rectangle
