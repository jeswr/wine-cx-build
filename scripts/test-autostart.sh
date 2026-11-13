#!/bin/bash
# Checks "skywalker.sh autostart on" on a CI Mac with a real build: macOS must
# accept the log-in item, start "prewarm" from it, and leave what it started
# running after the launcher script has ended. Steam itself is not here, so a
# copy of Wine's Notepad stands in as steam.exe.
# Usage: test-autostart.sh   (SKYWALKER_HOME, SKYWALKER_APP and SKY_PREFIX set,
#        a build installed and the bottle made by the earlier steps)
set -uo pipefail
SKY="$SKYWALKER_HOME/skywalker.sh"
OUT="${AUTOSTART_OUT:-$PWD/selftest-logs}"
LABEL="io.github.jeswr.skywalker.prewarm"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOM="gui/$(id -u)"
STEAM="$SKY_PREFIX/drive_c/Program Files (x86)/Steam"
fail=0
mkdir -p "$OUT"

ok() { echo "  ok: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
standin_running() { /bin/ps -axww -o command= | /usr/bin/grep -F 'Steam\steam.exe' | /usr/bin/grep -v grep > /dev/null; }
wait_for() {  # $1 = seconds, rest = a test command
  local t=0 max="$1"
  shift
  while [ "$t" -lt "$max" ]; do
    if "$@"; then return 0; fi
    sleep 2; t=$((t + 2))
  done
  return 1
}

/bin/bash "$SKY" stop > /dev/null 2>&1 || true
[ -d "$SKY_PREFIX/drive_c/windows" ] || { echo "FAIL: no bottle at $SKY_PREFIX"; exit 1; }
# the log-in item gets no SKY_ settings, so the bottle has to be named in the settings file
/usr/bin/sed -i.bak "s|^PREFIX=.*|PREFIX=\"$SKY_PREFIX\"|" "$SKYWALKER_HOME/config.env"
mkdir -p "$STEAM"
cp "$SKYWALKER_HOME/wine/current/lib/wine/x86_64-windows/notepad.exe" "$STEAM/steam.exe"
# without Wine's own mark, so that Wine runs this copy under this name
if [ "$(/bin/dd if="$STEAM/steam.exe" bs=1 skip=64 count=16 2>/dev/null)" = "Wine builtin DLL" ]; then
  /bin/dd if=/dev/zero of="$STEAM/steam.exe" bs=1 seek=64 count=16 conv=notrunc 2>/dev/null
fi

echo "== autostart on"
/bin/bash "$SKY" autostart on > "$OUT/autostart-on.txt" 2>&1 || bad "autostart on failed"
sed 's/^/    /' "$OUT/autostart-on.txt"
if [ -f "$PLIST" ]; then ok "the log-in item is in the user's Library"; else bad "no log-in item was written"; fi
/usr/bin/plutil -lint "$PLIST" > /dev/null 2>&1 || bad "the log-in item is not a valid property list"
if /bin/launchctl print "$DOM/$LABEL" > "$OUT/autostart-print.txt" 2>&1; then ok "macOS knows the log-in item"; else bad "macOS does not know the log-in item"; fi
if wait_for 120 standin_running; then ok "the log-in item started Steam's stand-in"; else bad "nothing was started within 120 s"; fi
sleep 20
if standin_running; then ok "it is still running 20 s later, after the launcher script ended"; else bad "what the log-in item started did not stay"; fi
/usr/bin/grep -E 'state|last exit|pid' "$OUT/autostart-print.txt" | head -n 6 | sed 's/^/    /'
/bin/launchctl print "$DOM/$LABEL" 2>/dev/null | /usr/bin/grep -E '^[[:space:]]*(state|last exit code|pid) ' | sed 's/^/    now: /'
cat "$SKYWALKER_HOME/logs/autostart.log" 2>/dev/null | cut -c1-200 | sed 's/^/    log: /'
/bin/bash "$SKY" doctor > "$OUT/autostart-doctor.txt" 2>&1
if /usr/bin/grep -q 'Autostart:    on' "$OUT/autostart-doctor.txt"; then ok "doctor shows autostart on"; else bad "doctor does not show autostart on"; fi

echo "== a prewarm by hand finds that Steam"
/bin/bash "$SKY" prewarm > "$OUT/autostart-prewarm.txt" 2>&1
sed 's/^/    /' "$OUT/autostart-prewarm.txt"
if /usr/bin/grep -q 'Steam is already open' "$OUT/autostart-prewarm.txt"; then ok "the open Steam is reused"; else bad "prewarm did not reuse what the log-in item started"; fi
/bin/bash "$SKY" cpu 6 > "$OUT/autostart-cpu.txt" 2>&1
sed 's/^/    /' "$OUT/autostart-cpu.txt"
if /usr/bin/grep -q 'Wine used [0-9.]*% of one processor core over 6 seconds' "$OUT/autostart-cpu.txt"; then ok "cpu reports Wine's use"; else bad "cpu gave no figure"; fi

echo "== autostart off"
/bin/bash "$SKY" autostart off > "$OUT/autostart-off.txt" 2>&1 || bad "autostart off failed"
if [ -f "$PLIST" ]; then bad "the log-in item is still there"; else ok "the log-in item is gone"; fi
if /bin/launchctl print "$DOM/$LABEL" > /dev/null 2>&1; then bad "macOS still knows the log-in item"; else ok "macOS no longer knows it"; fi
if standin_running; then ok "what is open stays open until stop"; else echo "    (the stand-in ended with the log-in item)"; fi
/bin/bash "$SKY" stop > /dev/null 2>&1 || true
if wait_for 30 /bin/bash -c '! /bin/ps -axww -o command= | /usr/bin/grep -F "Steam\\steam.exe" | /usr/bin/grep -v grep > /dev/null'; then ok "stop closed it"; else bad "stop left the stand-in running"; fi
rm -f "$STEAM/steam.exe"

if [ "$fail" = 0 ]; then echo "Autostart check passed."; else echo "Autostart check FAILED."; fi
exit "$fail"
