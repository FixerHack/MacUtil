# MacUtil

**English** · [Українська](README.uk.md)

A free, open-source Mac cleaner, optimizer and security analyzer, in the spirit of
CleanMyMac, OnyX and the Objective-See tools. Native Swift and SwiftUI, no telemetry.

> **Status:** early development. See [PLAN.md](PLAN.md) for the roadmap (in Ukrainian).

## Planned features

- **Cleanup:** system junk, developer junk (Xcode, npm, pip, Homebrew, Docker…), Trash bins, privacy traces
- **Disk space:** Space Lens map, large and old files, duplicates
- **Deep search:** by name, size, date or contents, including hidden and system files
- **Applications:** uninstaller with leftovers, orphaned files, updates
- **Security analyzer:** code signatures and notarization, app permissions, system security settings,
  persistence items, network, VirusTotal hash lookups
- **Optimization:** login items, maintenance scripts, processes, hidden macOS settings

## Safety

- Files go to the Trash by default; nothing is deleted permanently without confirmation.
- Protected locations (system folders, keychains, iCloud Drive, Photos library, `.git`) are never touched.
- Only file hashes are sent to VirusTotal. A file is uploaded only when you explicitly ask.

## Requirements

- macOS 26 Tahoe or later (older versions are planned)
- Swift 6 toolchain: Xcode 26 or just the Command Line Tools

## Build

```bash
scripts/install.sh              # optimized build, installed to /Applications and opened
scripts/build-app.sh            # debug build → build/MacUtil.app
scripts/build-app.sh release    # optimized build
open build/MacUtil.app
```

Other scripts:

| Script | What it does |
|---|---|
| `scripts/test.sh` | Runs the tests (works without Xcode) |
| `scripts/check-strings.sh` | Lists interface strings missing a Ukrainian translation |
| `scripts/snapshot.sh` | Saves a PNG of the app window (debug builds) |
| `swift run mucli` | Command-line interface to the core |

### Full Disk Access

MacUtil needs Full Disk Access to see caches, mail and browser data. On first launch a step-by-step guide
opens it in System Settings, lets you drag the app into the list and notices when access is granted.
Run the copy in /Applications: permissions belong to the app at that location.

If `security find-identity -v -p codesigning` lists your certificate as not valid, the Apple WWDR G3
intermediate certificate is missing. Download https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
and double-click it to add it to the login keychain.
Builds signed ad-hoc get a new signature on every rebuild, so macOS forgets the permission. If you have
an "Apple Development" certificate (free with an Apple ID in Xcode), the build script signs with it and
the permission sticks.

### Running a downloaded build

Release builds are not notarized. After unzipping, either open System Settings → Privacy & Security and
click **Open Anyway**, or run:

```bash
xattr -dr com.apple.quarantine MacUtil.app
```

## License

[GPL-3.0](LICENSE)
