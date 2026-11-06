# App Inspector

A macOS app that shows what every app on your Mac is allowed to do: its privacy permissions, extensions, and login and background items, in one window. Every state shows where it came from.

Website: [azrapps.com/AppInspector](https://azrapps.com/AppInspector/)

## What it shows

- **Privacy permissions.** Camera, microphone, screen recording, Full Disk Access, Accessibility, automation and more, read from the user and system privacy (TCC) databases. Each state links to the record it came from and to the matching System Settings page.
- **Extensions.** App extensions with their user election, and system extensions with their activation state.
- **Startup and background items.** Login items, launch agents and daemons, matched to the app they belong to, with their Login Items approval from the Background Task Management database.
- **Leftover permissions.** Entries for apps that are no longer installed. System Settings hides these, so they can't be removed there. App Inspector lists them under **Not installed** and can reset them.

## What it never does

States are confirmed only from a macOS record. Anything App Inspector can't read is shown as **Unknown** with the reason, never as denied or off.

App Inspector is read-only, with one exception: resetting privacy permissions with `tccutil reset`, and only after you confirm. Entries in the system database need root, so macOS asks for an administrator password then. For apps that are no longer installed, `tccutil` rejects the bundle ID, so App Inspector registers an empty placeholder bundle for the call and removes it afterwards. It never writes the TCC database directly, and never changes Background Task Management, launchd or extension state.

## Requirements

- macOS 15 Sequoia or later
- Full Disk Access, to read the privacy and Background Task Management databases. Without it, those states show as Unknown and the app offers to open the right settings pane.

## Building

The repository is two Swift packages: `Packages/InspectorKit` (model, parsers, data sources) and `App` (the SwiftUI app).

```bash
cd App && swift run
```

To build an app bundle, signed with your Apple Development or Developer ID identity when one is installed (ad hoc otherwise):

```bash
Tools/make-app-bundle.sh
```

A stable signing identity keeps the Full Disk Access grant across rebuilds. The app icon is drawn in code; regenerate `App/Resources/AppIcon.icns` with `Tools/make-icon.sh`.

Release builds are signed with Developer ID, notarized and packaged as a DMG by `Tools/release.sh`. See the script header for the required environment variables.

## Tests

```bash
cd Packages/InspectorKit && swift test
cd App && swift test
```

Tests that run the real `tccutil` and `lsregister` against a made-up bundle ID are off by default:

```bash
cd Packages/InspectorKit && APPINSPECTOR_LIVE_RESET=1 swift test --filter TCCResetTests
```

`Docs/plan.md` describes the design and the sources, and `Docs/phase0-findings.md` records what was verified on which macOS build.

## License

App Inspector is free software, licensed under the [GNU General Public License v3.0](LICENSE).
