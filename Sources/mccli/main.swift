import CleanerCore
import Foundation

// Command-line front end for testing the core without the UI.
// Full Disk Access here is the terminal's, not MacCleaner.app's.

let usage = """
USAGE: mccli <command>

COMMANDS:
  version   Print the MacCleaner version
  fda       Check Full Disk Access for this terminal
  disk      Show startup disk usage
"""

func formatBytes(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file))
}

switch CommandLine.arguments.dropFirst().first {
case "version", "--version", "-v":
    print("mccli \(MacCleanerInfo.version)")

case "fda":
    switch FullDiskAccess.status() {
    case .granted:
        print("Full Disk Access: granted")
    case .denied:
        print("Full Disk Access: NOT granted")
        print("Add your terminal app in System Settings → Privacy & Security → Full Disk Access.")
        exit(1)
    case .unknown:
        print("Full Disk Access: unknown (no protected files found to probe)")
    }

case "disk":
    do {
        let volume = try VolumeInfo.forVolume()
        print("\(volume.name): \(formatBytes(volume.usedCapacity)) used of \(formatBytes(volume.totalCapacity)), "
            + "\(formatBytes(volume.availableCapacity)) available")
    } catch {
        print("error: \(error.localizedDescription)")
        exit(1)
    }

case nil, "help", "--help", "-h":
    print(usage)

case let command?:
    print("error: unknown command '\(command)'\n")
    print(usage)
    exit(64)
}
