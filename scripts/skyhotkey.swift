// The launcher's pause hotkey, compiled (used when ~/Games/skywalker/tools/skyhotkey exists;
// hotkey.js does the same in JavaScript for Automation).
// Usage: skyhotkey KEYCODE MODS LAUNCHER MAXSECS
// Holds the key combination system-wide through the system's hotkey service (no
// permission needed) and, on each press, runs "LAUNCHER toggle-pause hotkey".
// Prints "registered ..." once and "pressed N" / "done N" per press. Ends when
// its parent process has gone, or after MAXSECS.
import AppKit
import Carbon

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 5, let code = UInt32(args[1]), let mods = UInt32(args[2]), let maxsecs = Double(args[4]) else {
    print("usage: skyhotkey KEYCODE MODS LAUNCHER MAXSECS"); exit(2)
}
let launcher = args[3]
var presses = 0
var quietUntil = Date.distantPast
var busy = false

func toggle() {
    if busy || Date() < quietUntil { return }
    busy = true
    presses += 1
    print("pressed \(presses) at \(ISO8601DateFormatter().string(from: Date()))")
    let t = Process()
    t.executableURL = URL(fileURLWithPath: "/bin/bash")
    t.arguments = [launcher, "toggle-pause", "hotkey"]
    t.terminationHandler = { p in
        DispatchQueue.main.async {
            print("done \(presses) status=\(p.terminationStatus)")
            quietUntil = Date().addingTimeInterval(1.5)   // a held or repeated press counts once
            busy = false
        }
    }
    do { try t.run() } catch { print("could not run the launcher: \(error)"); busy = false }
}

NSApplication.shared.setActivationPolicy(.accessory)
var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
    DispatchQueue.main.async { toggle() }
    return noErr
}, 1, &spec, nil, nil)
var ref: EventHotKeyRef?
let st = RegisterEventHotKey(code, mods, EventHotKeyID(signature: 0x534B5950, id: 1), GetApplicationEventTarget(), 0, &ref)
print("registered status=\(st) code=\(code) mods=\(mods)")
if st != noErr { exit(1) }
let start = Date()
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    if getppid() == 1 { print("parent gone"); exit(0) }
    if Date().timeIntervalSince(start) > maxsecs { print("time up"); exit(0) }
}
NSApplication.shared.run()
