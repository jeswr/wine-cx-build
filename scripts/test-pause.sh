#!/bin/bash
# Checks "skywalker.sh pause" on a CI Mac with a real build: a stand-in game
# (pausegame.exe: Direct3D 11 every frame, a sound playing) is paused, held
# frozen for a while (with a screen change in the middle if the runner allows
# one), resumed, and must carry on drawing and playing. Then: the toggle, the
# Pause app, a quit request arriving while paused (what a restart or log-out
# sends), and "stop" on a paused game, which must not hang.
#
# Usage: test-pause.sh PAUSEGAME.EXE [HOLD_SECONDS] [SKYKEY.EXE]
#   (the launcher installed in ~/Games/skywalker and its bottle made, as on the Mac)
# Every wait is bounded; nothing here can loop.
set -uo pipefail
GAME_SRC="$1"
HOLD="${2:-120}"
SKYKEY_SRC="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SKY="$HOME/Games/skywalker/skywalker.sh"
PREFIX="$HOME/Games/skywalker-cx"
OUT="${PAUSE_OUT:-$PWD/selftest-logs}"
STEAM="$PREFIX/drive_c/Program Files (x86)/Steam"
GAMEDIR="$STEAM/steamapps/common/Fake Game"
HB="$OUT/heartbeat.txt"
EV="$OUT/events.txt"
JS="$HOME/Games/skywalker/lib/pause.js"
fail=0
mkdir -p "$OUT"

ok() { echo "  ok: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
info() { echo "  info: $*"; }
wait_for() {  # $1 = seconds, rest = a test command
  local t=0 max="$1"
  shift
  while [ "$t" -lt "$max" ]; do
    if "$@"; then return 0; fi
    sleep 1; t=$((t + 1))
  done
  return 1
}
with_deadline() {  # $1 = seconds, rest = command; output passes through
  local max="$1" pid t=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$t" -ge "$max" ]; then kill -9 "$pid" 2>/dev/null; echo "(stopped after ${max}s)"; return 124; fi
    sleep 1; t=$((t + 1))
  done
  wait "$pid"
}
hb() { sed -n "s/.*$1=\\([0-9]*\\).*/\\1/p" "$HB" 2>/dev/null | head -n 1; }
frames_over() { [ "$(hb frames)" -gt "$1" ] 2>/dev/null; }
wine_lines() { ps -x -o pid=,stat=,time=,rss=,command= | awk -v w="$HOME/Games/skywalker/wine/" '{ c = $0; sub(/^ *[0-9]+ +[^ ]+ +[^ ]+ +[0-9]+ +/, "", c); if (c ~ /^[A-Za-z]:\\/ || index(c, w) == 1) print }'; }
not_frozen() { wine_lines | awk '$2 !~ /^T/' | wc -l | tr -d ' '; }
cpu_total() { wine_lines | awk '{ split($3, a, ":"); s += a[1] * 60 + a[2] } END { printf "%.2f", s }'; }
game_pid() { ps -x -o pid=,command= | grep -F 'FAKEGAME_DX11' | grep -v grep | head -n 1 | awk '{ print $1 }'; }
winpath() { printf 'Z:%s' "$1" | tr '/' '\\'; }
now() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }

start_game() {
  : > "$EV"; rm -f "$HB"
  /bin/bash "$SKY" wine 'C:\Program Files (x86)\Steam\steamapps\common\Fake Game\FAKEGAME_DX11.exe' \
    "$(winpath "$HB")" "$(winpath "$EV")" 1024 768 >> "$OUT/game.out" 2>&1 &
  if wait_for 180 frames_over 30; then
    ok "the stand-in runs: $(cat "$HB")"
    head -n 3 "$EV" | sed 's/^/  event: /'
  else
    bad "the stand-in did not start drawing"; tail -n 30 "$OUT/game.out"; return 1
  fi
}

echo "-- setting up the stand-in game"
mkdir -p "$GAMEDIR"
cp "$GAME_SRC" "$GAMEDIR/FAKEGAME_DX11.exe"
printf '"AppState"\n{\n\t"appid"\t\t"920210"\n\t"installdir"\t\t"Fake Game"\n}\n' > "$STEAM/steamapps/appmanifest_920210.acf"
# as with the real game: DXMT (Direct3D 11 on Metal) goes into the game's folder
/bin/bash "$SKY" graphics split > "$OUT/graphics.txt" 2>&1 || true
ls "$GAMEDIR" | sed 's/^/  game folder: /'
SETMODE="$OUT/setmode"
/usr/bin/swiftc -O -o "$SETMODE" "$HERE/setmode.swift" > /dev/null 2>&1 || SETMODE=""
START_MODE=""
if [ -n "$SETMODE" ]; then START_MODE="$("$SETMODE" list | sed -n 's/^now \([0-9]*x[0-9]*\).*/\1/p')"; fi
restore() { if [ -n "$START_MODE" ]; then "$SETMODE" "$START_MODE" > /dev/null 2>&1 || true; fi; }
cleanup() { restore; /bin/bash "$SKY" resume > /dev/null 2>&1; with_deadline 90 /bin/bash "$SKY" stop > /dev/null 2>&1; }
trap cleanup EXIT

start_game || exit 1
GPID="$(game_pid)"
info "game process $GPID; Wine programs: $(wine_lines | wc -l | tr -d ' ')"
wine_lines | sed 's/^/  proc: /'

echo "-- pause"
t0="$(now)"
with_deadline 60 /bin/bash "$SKY" pause > "$OUT/pause1.txt" 2>&1
t1="$(now)"
sed 's/^/  /' "$OUT/pause1.txt"
info "pause took $(perl -e "printf '%.1f', $t1 - $t0") s"
grep -q '^state=paused game=' "$OUT/pause1.txt" && ok "it reports paused" || bad "no paused state"
[ -f "$HOME/Games/skywalker/paused" ] && ok "the note is written: $(tr '\n' ' ' < "$HOME/Games/skywalker/paused")" || bad "no note"
n="$(not_frozen)"
[ "$n" = 0 ] && ok "every Wine program is frozen ($(wine_lines | wc -l | tr -d ' '))" || { bad "$n Wine programs still run"; wine_lines | sed 's/^/  proc: /'; }
/usr/bin/osascript -l JavaScript "$JS" info "$GPID" 2>&1 | sed 's/^/  window: /' | tee "$OUT/info-paused.txt"
grep -q "^  window: $GPID hidden=1" "$OUT/info-paused.txt" && ok "the game is hidden" || info "the game is not reported hidden"
f1="$(hb frames)"; c1="$(cpu_total)"
sleep 10
f2="$(hb frames)"; c2="$(cpu_total)"
[ "$f1" = "$f2" ] && ok "no frames drawn in 10 s (frames=$f2)" || bad "frames went on: $f1 -> $f2"
[ "$c1" = "$c2" ] && ok "no processor time used in 10 s ($c2 s in all)" || bad "processor time went on: $c1 -> $c2"
grep -q 'activateapp 0' "$EV" && ok "the game heard it went to the background before it froze" || info "no background message reached the game"

echo "-- held for $HOLD s"
half=$((HOLD / 2))
sleep "$half"
CHANGED=0
if [ -n "$SETMODE" ] && "$SETMODE" other > "$OUT/setmode.txt" 2>&1; then
  CHANGED=1; info "screen changed while paused: $(cat "$OUT/setmode.txt")"
else
  info "this runner's screen cannot change mode"
fi
with_deadline 30 /bin/bash "$SKY" pause > "$OUT/pause-again.txt" 2>&1
grep -q 'already paused' "$OUT/pause-again.txt" && ok "a second pause says it is already paused" || bad "second pause: $(cat "$OUT/pause-again.txt")"
sleep $((HOLD - half))
[ "$(not_frozen)" = 0 ] && ok "still frozen after $HOLD s" || bad "something thawed during the hold"
wine_lines | awk '{ s += $4 } END { printf "  info: Wine memory while frozen: %d MB\n", s / 1024 }'

echo "-- resume"
f_before="$(hb frames)"; p_before="$(hb presents_ok)"; a_before="$(hb audio)"
t0="$(now)"
with_deadline 60 /bin/bash "$SKY" resume > "$OUT/resume1.txt" 2>&1
t1="$(now)"
sed 's/^/  /' "$OUT/resume1.txt"
info "resume took $(perl -e "printf '%.1f', $t1 - $t0") s"
grep -q '^state=resumed' "$OUT/resume1.txt" && ok "it reports resumed" || bad "no resumed state"
[ ! -f "$HOME/Games/skywalker/paused" ] && ok "the note is gone" || bad "the note is still there"
if wait_for 30 frames_over $((f_before + 60)); then ok "drawing again: $(cat "$HB")"; else bad "no new frames after resume: $(cat "$HB")"; fi
sleep 3
[ "$(hb presents_ok)" -gt "${p_before:-0}" ] && ok "Direct3D presents again (d3d=$(hb d3d))" || info "no Direct3D presents (d3d=$(hb d3d))"
if grep -q 'audio open' "$EV"; then
  [ "$(hb audio)" -gt "${a_before:-0}" ] && ok "the sound plays again (buffers ${a_before} -> $(hb audio))" || bad "the sound stopped (buffers ${a_before} -> $(hb audio))"
else
  info "no sound device on this runner"
fi
info "longest gap the game saw between two frames: $(hb maxgap) ms (it sees the pause as one long frame)"
[ "$(not_frozen)" = "$(wine_lines | wc -l | tr -d ' ')" ] && ok "every Wine program runs again" || bad "some Wine programs are still frozen"
/usr/bin/osascript -l JavaScript "$JS" info "$GPID" 2>&1 | sed 's/^/  window: /' | tee "$OUT/info-resumed.txt"
grep -q "^  window: $GPID hidden=0" "$OUT/info-resumed.txt" && ok "the game is shown again" || bad "the game is still hidden"
grep -q "front=$GPID" "$OUT/info-resumed.txt" && ok "and it is in front" || info "it is not the front app (CI has no user to hand it over)"
echo "  events so far:"; sed 's/^/    /' "$EV"
out="$(with_deadline 90 /bin/bash "$SKY" wine cmd /c "echo wine-alive" 2>&1)"
case "$out" in *wine-alive*) ok "Wine's server answers new programs after the pause" ;; *) bad "Wine does not start a new program: $out" ;; esac
if [ "$CHANGED" = 1 ]; then
  grep -q displaychange "$EV" && ok "the game heard of the screen change after resuming" || info "the game got no display-change message"
  restore
fi

echo "-- toggle twice"
with_deadline 60 /bin/bash "$SKY" toggle-pause > "$OUT/toggle1.txt" 2>&1
[ "$(not_frozen)" = 0 ] && grep -q state=paused "$OUT/toggle1.txt" && ok "toggle paused it" || bad "toggle did not pause: $(tail -n 3 "$OUT/toggle1.txt")"
with_deadline 60 /bin/bash "$SKY" toggle-pause > "$OUT/toggle2.txt" 2>&1
f="$(hb frames)"
grep -q state=resumed "$OUT/toggle2.txt" && wait_for 20 frames_over $((f + 30)) && ok "toggle resumed it" || bad "toggle did not resume: $(tail -n 3 "$OUT/toggle2.txt")"

echo "-- the Pause app"
with_deadline 120 /bin/bash "$SKY" pause-app > "$OUT/pause-app.txt" 2>&1
sed 's/^/  /' "$OUT/pause-app.txt"
PA="$HOME/Applications/Skywalker Pause.app"
if [ -x "$PA/Contents/MacOS/applet" ]; then
  ok "the Pause app is made"
  sips -s format png "$PA/Contents/Resources/applet.icns" --out "$OUT/pause-icon.png" > /dev/null 2>&1 && ok "it has an icon" || info "no icon could be read"
  defaults export com.apple.dock - 2>/dev/null | grep -c 'Skywalker%20Pause' | grep -qx 1 && ok "it is in the Dock once" || info "not found in the Dock"
  with_deadline 60 open -W "$PA"
  if wait_for 15 test -f "$HOME/Games/skywalker/paused" && [ "$(not_frozen)" = 0 ]; then ok "a click on the Pause app paused the game"; else bad "the Pause app did not pause"; tail -n 5 "$HOME/Games/skywalker/logs/pauses.log" 2>/dev/null; fi
  f="$(hb frames)"
  with_deadline 60 open -W "$PA"
  if wait_for 20 frames_over $((f + 30)); then ok "a second click brought it back"; else bad "the second click did not resume"; fi
  /usr/bin/osascript -l JavaScript "$JS" info "$GPID" 2>&1 | sed 's/^/  window: /'
else
  bad "the Pause app was not made"
fi

echo "-- the hotkey (Ctrl-Option-P): opens the game's menu (Esc), then pauses; again: resumes"
if [ -n "$SKYKEY_SRC" ]; then mkdir -p "$HOME/Games/skywalker/tools"; cp "$SKYKEY_SRC" "$HOME/Games/skywalker/tools/skykey.exe"; fi
/bin/bash "$SKY" hotkey show | sed 's/^/  /'
lines_before="$(wc -l < "$EV" | tr -d ' ')"
with_deadline 60 /bin/bash "$SKY" toggle-pause hotkey > "$OUT/hotkey-toggle1.txt" 2>&1
tail -n +"$((lines_before + 1))" "$EV" | grep -q 'keydown 0x1b' && ok "the game got Esc (its pause menu) before it froze" || bad "no Esc reached the game: $(cat "$HOME/Games/skywalker/logs/pause-hide.txt" 2>/dev/null | tail -n 3)"
[ "$(not_frozen)" = 0 ] && ok "and it is paused" || bad "toggle-pause hotkey did not pause"
with_deadline 60 /bin/bash "$SKY" toggle-pause hotkey > "$OUT/hotkey-toggle2.txt" 2>&1
grep -q state=resumed "$OUT/hotkey-toggle2.txt" && ok "the second press resumes" || bad "the second press did not resume"
SKY_HOTKEY_DEBUG=1 /bin/bash "$SKY" hotkey listen 240 > "$OUT/hotkey-listen.txt" 2>&1 &
HK=$!
if wait_for 20 grep -q '^registered' "$OUT/hotkey-listen.txt"; then
  sed 's/^/  listener: /' "$OUT/hotkey-listen.txt"
  grep -q 'registered status=0' "$OUT/hotkey-listen.txt" && ok "the system took the hotkey (no permission asked)" || bad "the hotkey was refused"
else
  bad "the listener did not start: $(cat "$OUT/hotkey-listen.txt")"
fi
POSTKEY="$OUT/postkey"
if /usr/bin/swiftc -O -o "$POSTKEY" "$HERE/postkey.swift" > "$OUT/postkey-build.txt" 2>&1; then
  "$POSTKEY" 35 ctrl,option 2>&1 | sed 's/^/  postkey: /'
  if ! wait_for 15 grep -q '^done 1' "$OUT/hotkey-listen.txt"; then
    "$POSTKEY" 35 ctrl,option session 2>&1 | sed 's/^/  postkey: /'
  fi
  if wait_for 20 grep -q '^done 1' "$OUT/hotkey-listen.txt"; then
    ok "a key press reached the listener"
    [ "$(not_frozen)" = 0 ] && ok "the hotkey paused the game" || bad "the hotkey ran but the game is not frozen"
    sleep 3
    "$POSTKEY" 35 ctrl,option > /dev/null 2>&1
    f="$(hb frames)"
    if wait_for 20 grep -q '^done 2' "$OUT/hotkey-listen.txt" && wait_for 20 frames_over $((f + 30)); then ok "the second press brought it back"; else bad "the second press did not resume"; fi
  else
    info "the pressed keys did not reach the listener (CI may not allow made-up key presses): $(tail -n 2 "$OUT/hotkey-listen.txt" | tr '\n' ' ')"
  fi
else
  info "postkey did not build: $(tail -n 3 "$OUT/postkey-build.txt")"
fi
kill "$HK" 2>/dev/null
/bin/bash "$SKY" resume > /dev/null 2>&1
echo "  for information: the same with a compiled Carbon listener (Ctrl-Option-O)"
if /usr/bin/swiftc -O -o "$OUT/hotkeyprobe" "$HERE/hotkeyprobe.swift" > "$OUT/probe-build.txt" 2>&1; then
  "$OUT/hotkeyprobe" 31 6144 40 > "$OUT/probe.txt" 2>&1 &
  wait_for 10 grep -q registered "$OUT/probe.txt"
  "$POSTKEY" 31 ctrl,option > /dev/null 2>&1
  sleep 3
  grep -q 'probe pressed' "$OUT/probe.txt" || "$POSTKEY" 31 ctrl,option session > /dev/null 2>&1
  sleep 3
  sed 's/^/  probe: /' "$OUT/probe.txt"
else
  info "the probe did not build: $(tail -n 3 "$OUT/probe-build.txt")"
fi
sed 's/^/  listener: /' "$OUT/hotkey-listen.txt" | tail -n 6

echo "-- a quit request while paused (what a restart or log-out sends)"
with_deadline 60 /bin/bash "$SKY" pause > /dev/null 2>&1
lines_before="$(wc -l < "$EV" | tr -d ' ')"
quit="$(/usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); function run(a) { var x = $.NSRunningApplication.runningApplicationWithProcessIdentifier(parseInt(a[0])); return (x && !x.isNil()) ? String(x.terminate) : "no app" }' "$GPID" 2>&1)"
info "quit request sent to the frozen game: $quit"
sleep 5
with_deadline 60 /bin/bash "$SKY" resume > /dev/null 2>&1
sleep 15
tail -n +"$((lines_before + 1))" "$EV" | sed 's/^/    after resume: /'
if game_pid > /dev/null && [ -n "$(game_pid)" ]; then
  info "the game survived a quit request that arrived while it was paused"
else
  info "the game QUIT when resumed after a quit request (a cancelled restart would end it)"
  start_game || exit 1
  GPID="$(game_pid)"
fi

echo "-- stop while paused must not hang"
with_deadline 60 /bin/bash "$SKY" pause > /dev/null 2>&1
t0="$(now)"
with_deadline 120 /bin/bash "$SKY" stop > "$OUT/stop.txt" 2>&1
t1="$(now)"
sed 's/^/  /' "$OUT/stop.txt"
if wait_for 30 sh -c "[ -z \"\$(ps -x -o command= | grep -F '$HOME/Games/skywalker/wine/' | grep -v grep)\" ]"; then
  ok "stop ended Wine in $(perl -e "printf '%.1f', $t1 - $t0") s"
else
  bad "Wine programs left after stop"; wine_lines | sed 's/^/  proc: /'
fi
with_deadline 30 /bin/bash "$SKY" resume > "$OUT/resume-none.txt" 2>&1
grep -q 'not paused' "$OUT/resume-none.txt" && ok "the old note was cleared" || bad "resume after stop: $(cat "$OUT/resume-none.txt")"

cp "$HOME/Games/skywalker/logs/pauses.log" "$OUT/" 2>/dev/null || true
echo
[ "$fail" = 0 ] && echo "PASS" || echo "SOME CHECKS FAILED"
exit "$fail"
