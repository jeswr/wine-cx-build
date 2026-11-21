// Presses a key combination the way a keyboard would (for test-pause.sh on CI Macs).
// Usage: postkey KEYCODE FLAGS   (FLAGS: CGEventFlags, e.g. 786432 = Control + Option)
import CoreGraphics
import Foundation
import ApplicationServices

let code = CGKeyCode(Int(CommandLine.arguments[1])!)
let flags = CGEventFlags(rawValue: UInt64(CommandLine.arguments[2])!)
print("trusted for accessibility: \(AXIsProcessTrusted())")
let src = CGEventSource(stateID: .hidSystemState)
guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
      let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else {
    print("could not make the key events"); exit(1)
}
down.flags = flags
up.flags = flags
down.post(tap: .cghidEventTap)
usleep(60000)
up.post(tap: .cghidEventTap)
print("posted \(code) flags \(flags.rawValue)")
