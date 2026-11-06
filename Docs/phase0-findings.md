# Phase 0 findings (running log)

Capability matrix columns: source | tier | requirement | OS range | authoritative-for | go/no-go.

## Done so far (host: macOS 26.5.1 / 25F80, arm64, real machine, no sudo)

| Source | Result on 26.5.1 | Notes |
|---|---|---|
| `pluginkit -mAvvv`, `-mAD` | works unprivileged (~208 KB / 25 KB) | extension inventory + elections |
| `systemextensionsctl list` | works | |
| `launchctl print gui/<uid>` / `system` | works unprivileged | per-job detail captured for 50 plists |
| `launchctl print-disabled` | works | |
| `system_profiler SPApplicationsDataType -json` | works (~200 KB) | app identity |
| `profiles list/show` | exit 0 | MDM overrides need a managed VM to calibrate |
| `tccutil` | **no `list` subcommand on 26** (exit 64, usage: `reset` only) | R1 gate: on 27 it must be re-tested |
| `tccutil reset SERVICE BUNDLE_ID` | **rejects bundle IDs Launch Services can't resolve** (exit 64, `OSStatus -10814`). Works once a stub bundle with that ID is registered with `lsregister -f`, outside `/tmp` (a stub under `/private/tmp` is not resolved); no signature needed; after `lsregister -u` the ID is rejected again. Verified 2026-11-06 on 26.5.1 with a made-up ID. | Not yet verified against real stale rows: the app checks every reset with a fresh scan |
| `/private/var/db/com.apple.backgroundtaskmanagement/` | **Operation not permitted** without FDA | **Resolved 2026-11-06:** readable with the app's FDA, no root. `BackgroundItems-v16.btm` (current on 26.5.1; v9/v13 are leftovers from older OS versions) is an `NSKeyedArchiver` file: `store` → `Storage.itemsByUserIdentifier` (user UUID → `[ItemRecord]`). `ItemRecord` fields match `sfltool dumpbtm` (identifier, type, disposition int, flags int, url, executablePath, teamIdentifier, items, associatedBundleIdentifiers…); no parent field, as parents are derived from `items`. 100 items decode in ~55 ms. |
| `sfltool dumpbtm` unprivileged | Shows an administrator authorization dialog (right `com.apple.auth.admin`) on **every** run; approval isn't kept between runs | Now only an on-request fallback |

## Still open (needs VMs 15.x / 26.x / 27.x, or FDA grant)
- R1: FDA app reading system TCC.db on 27; `tccutil list` on 27.
- FDA probe path; FDA-only read of `BackgroundItems-v*.btm` per OS.
- Chromium/Firefox profile reads with FDA.
- `sfltool dumpbtm` (sudo), TCC.db copies (VM only, `--vm --tcc`).
- Scenario kit apps (signed test apps), Settings screenshots as ground truth.
- Deep-link calibration.

## Phase 1 status (code complete for the host-verifiable part)

Built: `InspectorModel` (Determination/Evidence, `ConfirmedSource` token gating `.denied`, capability matrix, service catalog),
`InspectorParsers` (TCC parser + schema fingerprint), `InspectorPlatform` (ProcessRunner, read-only SQLite, bundle reader,
code-signing summary + csreq check, FDA probe, Settings linker), `InspectorSources` (inventory + TCC collectors, permission builder,
orchestrator), SwiftUI dev harness in `App/` (sidebar, privacy section, evidence sheet, coverage banner, diagnostics).
`swift test` in `Packages/InspectorKit`: 36 tests pass, covering the fail-to-Unknown matrix and regressions for independent
Automation targets, neutral signature mismatches, every installed bundle-ID copy, blocked collectors and caller cancellation,
and preserved authorization reasons. `swift test` in `App`: 5 presentation tests pass, covering neutral chips and grant filters,
denial labels, and Unknown empty states when either privacy database is unreadable or missing from the scan.

Real-host run (26.5.1, FDA not granted, `AppInspector --dump`): 142 apps, 225 permission states, all `unknown`, zero confirmed negatives.

**Not verified (needs FDA grant / VMs):** real TCC.db parsing (schema fingerprint on 15/26/27), `auth_reason` code table,
which DB holds which service (`StoreHint` is `.either` until calibrated), csreq match on real grants, MDM override rows,
deep links per OS, scenario-app comparison against System Settings (Phase 1 exit criterion).
Matrix `validatedOS` is provisional (26.x only).

## Real TCC read on 26.5.1 / 25F80 (FDA granted to `build/AppInspector.app`)

- Launch through LaunchServices (`open -W -n --stdout F build/AppInspector.app --args --dump`). Running the binary directly from a shell
  attributes TCC to the parent process (FDA=notGranted), not the app.
- user TCC.db: 446 rows; system TCC.db: 154 rows; both parse with no skipped rows. **Schema fingerprint `14a853b43fbcf349` on both.**
- 142 apps, 214 unattributed clients. States: 142 confirmed-allowed, 43 confirmed-denied, 185 notRecorded, 8 unknown.
- Not yet checked: why 8 are unknown; any row compared to a System Settings toggle; auth_reason distribution; which DB holds which service.
- Caveat: that binary predates later source edits (authReason, `recordedForDifferentSignature`, cancellation). Rebuilding changes the ad-hoc
  signature, so FDA must be re-granted after each rebuild.

## Phase 2 status: extensions, startup items, association (host-verified on 26.5.1 only)

Built: parsers (pluginkit `-mAvvv`, `systemextensionsctl list`, `db.plist`, `launchctl print` services/job, `print-disabled`, legacy plists),
`ExtensionCollector`, `StartupCollector` (plists, bundled login-item helpers and launch plists, registered jobs via per-job `launchctl print`),
`InspectorAssociation` engine (ranks 1-6 with reasons), orchestrator wiring, UI sections (Extensions, Startup & Background, developer groups, unattributed).
Tests: 79 kit tests + 5 app tests pass, including fail-to-Unknown for every degraded `launchctl`/`pluginkit`/`systemextensionsctl` case.

Real host (26.5.1, no FDA needed for these sources): pluginkit 463 entries, no skipped lines (**matches the plan's 463 / 421-unmarked [V]**);
466 extensions (34 elected, 8 ignored, 421 system default, 2 sysext enabled, 1 waiting for user); 42 startup items (13 running, 15 loaded,
11 not loaded, 3 unknown = root-only plists); 910 launchd services, 70 overrides; association ranks: containment 126, explicit parent 3,
executable-in-bundle 4, team+prefix 1, developer group 16, suggestion 32, none 326 (mostly Apple system appex with no inventoried parent).

Decisions and caveats:
- pluginkit `-` is shown as "Ignored (user election)", `+` as "Use (user election)", no mark as "System default". The mapping to System Settings toggles is still a Phase 0 [?].
- Mac Catalyst extensions are included (81 on this host); other platforms are excluded.
- Rank 6 (suggestion) fires only when exactly one installed app shares the first three identifier components.
- BTM approval is always Unknown until Phase 3's import. Browser extensions, Safari extension state and `sfltool` import are not built yet.
- Fixed in passing: symlink-aware path matching now handles paths whose leaf does not exist (`PathResolver`).
- Not verified: 15 and 27 output formats for any Phase 2 source; per-OS fingerprints; Settings toggle comparison; the UI was built but not visually checked.

## Phase 2 review fixes (from the Muzakere review; Codex round 1 findings checked against the code)

Fixed:
- `launchctl` services and `print-disabled` parsers are strict: empty output, an unclosed block, an unparseable row or an unknown override value now throw, so a partial list can no longer produce "Not loaded" or "No record". `systemextensionsctl list` is strict the same way (malformed rows under a header no longer parse as "no extensions").
- A label declared by more than one plist in a domain gets Unknown load state and override (launchd state cannot be assigned to one file).
- Association: bundle-ID matches (rank 2) count only when exactly one installed app has that ID; rank 4 ties fall through to the developer group. Executable location (rank 3) disambiguates copies.
- Coverage: unlistable existing folders, unreadable bundled items, failed per-job lookups and the lookup cap now show up as non-OK source status (`launchd-plists`, `bundled-helpers`, new `launchctl-job-lookups`). The UI says "Unknown" instead of "No ... found" when a source behind the list failed.
- Bundled launch plists are a new kind (`bundledLaunchPlist`, "declared in the app, not proof of registration"), separate from jobs launchd reports as registered.
- `ProcessRunner` rewritten: each pipe is read only by its handler until EOF (no second reader), completion needs exit plus both EOFs, a descendant holding a pipe is bounded and marks the result truncated, timeout and task cancellation send SIGTERM then SIGKILL.

Not changed: the guess that a job loaded only in another launchd domain reads as "Not loaded" (no instance on this Mac; the check found 0). Top identity defects have 0 occurrences here (143 apps, 0 duplicate bundle IDs, 0 duplicate labels), so they are latent hardening, not observed failures.
Tests: 100 kit tests and 6 app tests pass. Real-host scan on 26.5.1 accepts the stricter parsers (same counts as before).

## Phase 3 status: BTM, live refresh, export, hardening (host-verified on 26.5.1)

Phase 0 finding that changes the plan: **`sfltool dumpbtm` needs no root on 26.5.1** (it works from an unprivileged process). It is slow and variable
(9.5 s to 78 s observed), so the app reads it in the background with a 150 s timeout and re-merges, instead of blocking the first scan.
Real dump: 100 records over UIDs -2 (global), 0 (system) and 502 (user); 37 app, 19 developer, 15 legacy daemon, 14 legacy agent, 7 quicklook,
3 login item, 2 daemon, 1 each agent / dock tile / spotlight. The parser read all 100 with 0 skipped. Format notes: identifier carries a numeric type
prefix (`16.` / `8.` / `2.` / `4.`); login-item and registered-item URLs are relative to the parent; disposition is `[enabled|disabled, allowed|disallowed, notified|not notified]`.

Built:
- `BTMParser` (tolerant per item, strict per report), `BTMCollector` (live read + file import), `BTMMerger` (matching by path then label, filtered to the
  current user, global and system UIDs), `BackgroundApproval` (negative values need a `ConfirmedSource`), staleness (report older than last boot, or an imported file older than a day).
- "No record" is claimed only from a complete LIVE read that is not stale and not older than the item. An imported file or incomplete report can confirm what it lists, never absence.
  Records for files that no longer exist are not listed (BTM keeps removed items until overnight maintenance).
- Real host: 29 enabled, 4 not allowed (GlobalProtect items, matches the 4 `disallowed` records), 8 "no record", 1 ambiguous (two records disagree).
- Live refresh: FSEvents on the plan's folders + NSWorkspace launch/quit, 2 s debounce, rescans only while the app is active. TCC databases are not watched.
- "New since last scan" (in memory), JSON export with path redaction, "About this data" page for every source, BTM banner (read now / import / copyable command).
- `SigningCache` (keyed by path, inode, mtime, size). Benchmark, debug build, 142 apps: cold 0.90 s, warm 0.32 s (budget: 500 apps under 10 s cold, 2 s warm).
- `systemextensionsctl list` rows are now cross-checked against the declared "N extension(s)" count.
- Fuzz tests: truncation at every offset and seeded random corruption for BTM, launchctl, sysext, pluginkit and TCC parsers. Invariants: a surviving BTM record's disposition never changes;
  a services/override/sysext list cut before its end always throws.
- Bug found by a test: `JSONEncoder` escapes `/` as `\/`, which made path redaction miss everything. Fixed with `.withoutEscapingSlashes`.
- `Tools/release.sh` (Developer ID, hardened runtime, notarytool, staple, DMG), `Tools/self-audit.sh`, `Tools/AppInspector.entitlements`.

Not done:
- Release itself: `release.sh` was not run (it uploads the app to Apple for notarization and needs a notary keychain profile). A Developer ID identity exists in this keychain.
- Full-matrix pass on a notarized build; macOS 15 and 27 VM runs; VoiceOver pass; localizable strings; Sparkle; Xcode project (the app is still the SwiftPM harness).
- Runtime self-audit with `fs_usage` and `nettop` (needs root; commands are in the script header).
- Not checked visually: the new banner, badges, import sheet, export menu and About page were built and unit-tested only.
- The BTM merge on 15 and 27 is unvalidated; unvalidated OS builds carry the flag on every evidence.

## Phase 3 review fixes (seven findings from an external review, each reproduced or confirmed in the code)

- `release.sh` passed a relative bundle path to a script that changes directory, so clean releases built `App/build/...` and could package an old binary. Now absolute paths, a bundle-exists check, and `make-app-bundle.sh` resolves a relative argument against the caller's directory (verified).
- BTM matching: a record whose own path is known and differs from the item's path is rejected even when labels match (a lingering record for an old plist no longer marks its replacement). Relative record URLs are resolved against their parent before comparing.
- BTM matching by domain: GUI items accept only agent and login-item records, system items only daemon records.
- "No record" freshness is checked against every file the item owns (plist, item path, program, executable; bundles also by Info.plist). If none of them can be dated, the answer is Unknown.
- Diff keys use `PermissionItem.id`, so a new or changed Automation target is visible.
- Signing cache fingerprint now includes the main executable (an executable-only update leaves CodeResources unchanged).
- Path redaction runs on decoded values before JSON encoding (a home path with quotes or backslashes used to survive).
- Found while fixing: `PathResolver.real` stalled about 30 ms per call for nonexistent paths under `/home` (an automount point). It now skips `/home` and `/net`, and BTM record paths are resolved once per scan.

Tests: 148 kit tests and 9 app tests pass, with a new test for each finding.
Open: the live `sfltool dumpbtm` read took 9.5 s, 78 s, then timed out at 150 s on this Mac. The fallback (approval Unknown, import offered) worked, but the real-host BTM merge was not re-run after these fixes.
