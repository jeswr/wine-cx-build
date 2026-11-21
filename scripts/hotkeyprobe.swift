// For test-pause.sh: holds a hot key the classic Carbon way (an event handler)
// and prints "probe pressed" on each press, to tell whether made-up key presses
// reach hot keys at all on a CI Mac. Usage: hotkeyprobe KEYCODE MODS SECONDS
import AppKit
import Carbon

let code = UInt32(CommandLine.arguments[1])!
let mods = UInt32(CommandLine.arguments[2])!
let secs = Double(CommandLine.arguments[3])!
setvbuf(stdout, nil, _IOLBF, 0)
NSApplication.shared.setActivationPolicy(.accessory)
var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in print("probe pressed"); return noErr }, 1, &spec, nil, nil)
var ref: EventHotKeyRef?
let st = RegisterEventHotKey(code, mods, EventHotKeyID(signature: 0x50524F42, id: 1), GetApplicationEventTarget(), 0, &ref)
print("probe registered status=\(st)")
DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
NSApplication.shared.run()
