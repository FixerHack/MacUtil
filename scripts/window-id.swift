// Prints the CGWindowID of MacCleaner's main window, for `screencapture -l`.
import CoreGraphics

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
if let window = windows.first(where: {
    $0[kCGWindowOwnerName as String] as? String == "MacCleaner" && $0[kCGWindowLayer as String] as? Int == 0
}) {
    print(window[kCGWindowNumber as String] as? Int ?? 0)
}
