import CoreGraphics
import Foundation
// usage: winshot <pid> <output.png>  — captures that process's first window by ID, no focus change
let args = CommandLine.arguments
guard args.count >= 2, let pid = Int(args[1]) else { print("usage: winshot <pid> <out.png>"); exit(2) }
let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let match = list.first { ($0[kCGWindowOwnerPID as String] as? Int) == pid && (($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 200 }
guard let win = match, let num = win[kCGWindowNumber as String] as? Int else { print("no window for pid \(pid)"); exit(1) }
print(num)
