// Changes the main screen's resolution, for the cloud test of the screen watcher.
//   setmode list | other | WxH
import CoreGraphics
import Foundation

let id = CGMainDisplayID()
let args = CommandLine.arguments
let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
guard let cur = CGDisplayCopyDisplayMode(id) else { print("no current mode"); exit(2) }
let what = args.count > 1 ? args[1] : "list"
if what == "list" {
  print("now \(cur.width)x\(cur.height) (pixels \(cur.pixelWidth)x\(cur.pixelHeight), \(cur.refreshRate) Hz)")
  for m in modes {
    print("\(m.width)x\(m.height) pixels \(m.pixelWidth)x\(m.pixelHeight) \(m.refreshRate) Hz usable=\(m.isUsableForDesktopGUI())")
  }
  exit(0)
}
var target: CGDisplayMode?
if what == "other" {
  target = modes.filter { $0.isUsableForDesktopGUI() && ($0.width != cur.width || $0.height != cur.height) }
    .min { abs($0.width * $0.height - cur.width * cur.height) < abs($1.width * $1.height - cur.width * cur.height) }
} else {
  let p = what.split(separator: "x").compactMap { Int($0) }
  if p.count == 2 { target = modes.first { $0.width == p[0] && $0.height == p[1] && $0.isUsableForDesktopGUI() } ?? modes.first { $0.width == p[0] && $0.height == p[1] } }
}
guard let t = target else { print("no such mode"); exit(2) }
var cfg: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&cfg)
CGConfigureDisplayWithDisplayMode(cfg, id, t, nil)
let r = CGCompleteDisplayConfiguration(cfg, .forSession)
print("from \(cur.width)x\(cur.height) to \(t.width)x\(t.height): \(r == .success ? "ok" : "error \(r.rawValue)")")
exit(r == .success ? 0 : 1)
