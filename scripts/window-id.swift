import CoreGraphics
import Foundation
// usage: winshot <pid> [title-substring|--list]  — captures that process's
// real content window by ID, no focus change. A CEF-backed Browser process
// owns several other windows too (helper/GPU surfaces, off-screen anchor
// views) that can also be >200pt tall, so a bare "tallest-ish window" filter
// can grab the wrong one (confirmed: one such surface was matched instead of
// the real, on-screen, titled window in testing) -- must also require
// onscreen==true.
//
// A single process can also own more than one *real* titled window at once
// -- e.g. the main browser window plus the separate Settings window -- and
// with no further filter this only ever returns the first one found, which
// isn't necessarily the one you want to screenshot. Pass a case-insensitive
// substring of the window's title (e.g. "Settings") as a third argument to
// pick a specific one; omit it to keep the original first-match behavior.
// Pass "--list" instead to print every onscreen candidate window for that
// pid (number, height, title) instead of picking one, for figuring out what
// titles/ids are actually available.
let args = CommandLine.arguments
guard args.count >= 2, let pid = Int(args[1]) else {
    print("usage: window-id <pid> [title-substring|--list]")
    exit(2)
}

let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let candidates = list.filter {
    ($0[kCGWindowOwnerPID as String] as? Int) == pid
        && ($0[kCGWindowIsOnscreen as String] as? Bool) == true
        && (($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 200
}

let modeArg = args.count >= 3 ? args[2] : nil

if modeArg == "--list" {
    if candidates.isEmpty { print("no candidate windows for pid \(pid)") }
    for window in candidates {
        let number = window[kCGWindowNumber as String] as? Int ?? -1
        let height = (window[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0
        let title = window[kCGWindowName as String] as? String ?? "(untitled)"
        print("\(number)\theight=\(Int(height))\t\(title)")
    }
    exit(0)
}

let match: [String: Any]?
if let titleSubstring = modeArg {
    match = candidates.first {
        (($0[kCGWindowName as String] as? String) ?? "").localizedCaseInsensitiveContains(titleSubstring)
    }
} else {
    match = candidates.first
}

guard let win = match, let num = win[kCGWindowNumber as String] as? Int else {
    print("no window for pid \(pid)" + (modeArg.map { " matching \"\($0)\"" } ?? ""))
    exit(1)
}
print(num)
