// Presses a key combination the way a keyboard would (for test-pause.sh on CI Macs):
// the modifier keys go down first, then the key, then all come up again.
// Usage: postkey KEYCODE ctrl,option[,cmd,shift] [session]
import CoreGraphics
import Foundation
import ApplicationServices

let code = CGKeyCode(Int(CommandLine.arguments[1])!)
let names = CommandLine.arguments[2].split(separator: ",").map(String.init)
let tap: CGEventTapLocation = CommandLine.arguments.count > 3 ? .cgSessionEventTap : .cghidEventTap
print("trusted for accessibility: \(AXIsProcessTrusted())")
let mods: [String: (CGKeyCode, CGEventFlags)] = [
    "ctrl": (59, .maskControl), "option": (58, .maskAlternate), "cmd": (55, .maskCommand), "shift": (56, .maskShift)]
let src = CGEventSource(stateID: .hidSystemState)
var flags = CGEventFlags()
func post(_ key: CGKeyCode, _ down: Bool, _ f: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)!
    e.flags = f
    e.post(tap: tap)
    usleep(30000)
}
for n in names { let (k, f) = mods[n]!; flags.insert(f); post(k, true, flags) }
post(code, true, flags)
post(code, false, flags)
for n in names.reversed() { let (k, f) = mods[n]!; flags.remove(f); post(k, false, flags) }
print("posted \(code) with \(names) at \(tap == .cghidEventTap ? "hid" : "session")")
