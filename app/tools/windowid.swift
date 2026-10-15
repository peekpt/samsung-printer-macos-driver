import CoreGraphics
import Foundation

// Print the CGWindow number of the best-matching on-screen window.
//   windowid <owner-substring> [maxHeight]
// Chooses the smallest layer-0 window owned by <owner-substring>.
let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let maxH: Double = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 100000) : 100000

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                            kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

var best = 0
var bestH = Double.greatestFiniteMagnitude

for w in list {
    let o = (w[kCGWindowOwnerName as String] as? String) ?? ""
    let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
    let num = (w[kCGWindowNumber as String] as? Int) ?? 0
    let bounds = (w[kCGWindowBounds as String] as? [String: Any]) ?? [:]
    let h = (bounds["Height"] as? Double) ?? 0
    let wid = (bounds["Width"] as? Double) ?? 0

    guard layer == 0, h > 120, h < maxH, wid > 120 else { continue }
    guard owner.isEmpty || o.localizedCaseInsensitiveContains(owner) else { continue }

    if h < bestH { bestH = h; best = num }
}

if best != 0 { print(best); exit(0) }
exit(2)
