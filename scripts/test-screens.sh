#!/bin/bash
# Checks, on a CI Mac with a real build, the parts of the launcher that need
# macOS itself: measuring the main screen, the screen watcher, fitting a
# running "game" window when the resolution changes, the app with the game's
# icon, and the Dock entry.
#
# Usage: test-screens.sh SKYFIT.EXE ICONGAME.EXE
#   SKYFIT.EXE    scripts/skyfit.c built for Windows
#   ICONGAME.EXE  the same with a 256x256 PNG icon inside, standing in for the game
#   (SKYWALKER_HOME, SKY_PREFIX set; a build installed and the bottle made)
set -uo pipefail
SKYFIT_SRC="$1"
ICONGAME="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
SKY="$SKYWALKER_HOME/skywalker.sh"
OUT="${SCREENS_OUT:-$PWD/selftest-logs}"
STEAM="$SKY_PREFIX/drive_c/Program Files (x86)/Steam"
GAMEDIR="$STEAM/steamapps/common/Fake Game"
SETMODE="$OUT/setmode"
fail=0
mkdir -p "$OUT"

ok() { echo "  ok: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
wait_for() {  # $1 = seconds, rest = a test command
  local t=0 max="$1"
  shift
  while [ "$t" -lt "$max" ]; do
    if "$@"; then return 0; fi
    sleep 1; t=$((t + 1))
  done
  return 1
}
field() { printf '%s\n' "$1" | sed -n "s/.* $2=\\([^ ]*\\).*/\\1/p" | head -n 1; }

/usr/bin/swiftc -O -o "$SETMODE" "$HERE/setmode.swift" || { echo "FAIL: setmode did not build"; exit 1; }
"$SETMODE" list | tee "$OUT/modes.txt"
START_MODE="$(sed -n 's/^now \([0-9]*x[0-9]*\).*/\1/p' "$OUT/modes.txt")"
restore() { [ -n "$START_MODE" ] && "$SETMODE" "$START_MODE" > /dev/null 2>&1 || true; }
trap restore EXIT

echo "-- measuring the main screen"
line="$(/bin/bash "$SKY" display screen | head -n 1)"
echo "  $line"
case "$line" in main=*" size="[1-9]*x[1-9]*) ok "measured" ;; *) bad "no measurement: $line" ;; esac
[ "$(field "$line" size)" = "$START_MODE" ] && ok "same size as CoreGraphics' current mode ($START_MODE)" || bad "size $(field "$line" size) is not the current mode $START_MODE"
system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Resolution|UI Looks like|Main Display|Mirror|Connection' | sed 's/^ */  profiler: /'
/bin/bash "$SKY" display show | sed 's/^/  /'
t0=$(perl -MTime::HiRes=time -e 'print time')
/bin/bash "$SKY" display screen > /dev/null
t1=$(perl -MTime::HiRes=time -e 'print time')
echo "  one measurement took $(perl -e "printf '%.2f', $t1 - $t0") s"

echo "-- the watcher sees a resolution change"
js="$SKYWALKER_HOME/lib/screens.js"
/usr/bin/osascript -l JavaScript "$js" watch 1 300 > "$OUT/watch.txt" 2> "$OUT/watch.err" &
wpid=$!
wait_for 20 test -s "$OUT/watch.txt" && ok "first line: $(head -n 1 "$OUT/watch.txt")" || bad "the watcher wrote nothing ($(cat "$OUT/watch.err"))"
sleep 2
CHANGED=0
if "$SETMODE" other | tee "$OUT/setmode1.txt"; then
  CHANGED=1
  NEW_MODE="$(sed -n 's/.* to \([0-9]*x[0-9]*\):.*/\1/p' "$OUT/setmode1.txt")"
  if wait_for 20 grep -q "size=$NEW_MODE " "$OUT/watch.txt"; then ok "the watcher reported $NEW_MODE"; else bad "the watcher did not report $NEW_MODE: $(cat "$OUT/watch.txt")"; fi
  restore
  if wait_for 20 sh -c "tail -n 1 '$OUT/watch.txt' | grep -q 'size=$START_MODE '"; then ok "and the change back"; else bad "the change back was not reported"; fi
else
  echo "  (this runner's screen has no other mode, so the resolution cannot be changed here)"
fi
ps -o pid=,pcpu=,time= -p "$wpid" | sed 's/^/  watcher cpu: /'
kill "$wpid" 2>/dev/null
cat "$OUT/watch.txt" | sed 's/^/  watch: /'
# the watcher ends by itself when the process that started it has gone
( /usr/bin/osascript -l JavaScript "$js" watch 1 300 > /dev/null 2>&1 & echo $! > "$OUT/orphan.pid" )
sleep 4
if /bin/ps -p "$(cat "$OUT/orphan.pid")" > /dev/null 2>&1; then bad "the watcher outlived its parent"; kill "$(cat "$OUT/orphan.pid")" 2>/dev/null; else ok "the watcher ended with its parent"; fi

echo "-- a running game is fitted when the screen changes"
mkdir -p "$GAMEDIR" "$SKYWALKER_HOME/tools"
printf '"AppState"\n{\n\t"appid"\t\t"920210"\n\t"installdir"\t\t"Fake Game"\n}\n' > "$STEAM/steamapps/appmanifest_920210.acf"
cp "$ICONGAME" "$GAMEDIR/FAKEGAME_DX11.exe"
cp "$SKYFIT_SRC" "$SKYWALKER_HOME/tools/skyfit.exe"
/bin/bash "$SKY" display auto > /dev/null
WINEDEBUG=-all /bin/bash "$SKY" wine "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Fake Game\\FAKEGAME_DX11.exe" --test-window 200 > "$OUT/game.txt" 2>&1 &
wait_for 90 grep -q 'test-window: monitor' "$OUT/game.txt" && ok "stand-in game is up: $(grep 'test-window: monitor' "$OUT/game.txt")" || bad "the stand-in game did not start: $(tail -n 5 "$OUT/game.txt")"
/bin/bash "$SKY" doctor | grep -q 'Game running: yes' && ok "the launcher sees it as the game" || bad "the launcher does not see the stand-in as the game"
SKY_REFIT=1 SKYFIT_MATCH=FAKEGAME /bin/bash "$SKY" watch-game > "$OUT/watch-game.txt" 2>&1 &
gpid=$!
sleep 6
if [ "$CHANGED" = 1 ]; then
  "$SETMODE" other > /dev/null
  if wait_for 40 grep -q "result: now $NEW_MODE" "$SKYWALKER_HOME/logs/watch-game.log" 2>/dev/null \
     || wait_for 1 grep -q "already fits" "$SKYWALKER_HOME/logs/watch-game.log" 2>/dev/null; then
    ok "the game's window was fitted to $NEW_MODE"
  else
    bad "the game's window was not fitted to $NEW_MODE"
  fi
  if wait_for 10 grep -q "WM_SIZE ${NEW_MODE}" "$OUT/game.txt"; then ok "the game was told its new size (WM_SIZE $NEW_MODE)"; else bad "the game got no WM_SIZE $NEW_MODE"; fi
  restore
  if wait_for 40 sh -c "grep -c 'The screens changed' '$OUT/watch-game.txt' | grep -q 2"; then ok "and fitted back after the change back"; else bad "the change back was not handled"; fi
  sleep 8
  wait_for 10 sh -c "tail -n 3 '$OUT/game.txt' | grep -q 'WM_SIZE ${START_MODE}'" && ok "WM_SIZE $START_MODE after the change back" || bad "no WM_SIZE $START_MODE after the change back"
fi
/bin/bash "$SKY" refit > "$OUT/refit.txt" 2>&1 || true
SKYFIT_MATCH=FAKEGAME /bin/bash "$SKY" refit | sed 's/^/  refit: /'
/bin/bash "$SKY" stop > /dev/null 2>&1
wait_for 30 sh -c "! kill -0 $gpid 2>/dev/null" && ok "the watch ended with the game" || { bad "the watch did not end with the game"; kill "$gpid" 2>/dev/null; }
if /bin/ps -axww -o command= | grep -v grep | grep -q 'screens\.js watch'; then bad "a screen watcher was left running"; else ok "no screen watcher left"; fi
sed 's/^/  launcher: /' "$OUT/watch-game.txt"
sed 's/^/  skyfit: /' "$SKYWALKER_HOME/logs/watch-game.log" 2>/dev/null | tail -n 20
grep 'test-window' "$OUT/game.txt" | sed 's/^/  game: /'

echo "-- the app, with the game's icon"
APPDIR="$HOME/Applications"
export SKYWALKER_APP="$APPDIR/Skywalker Saga.app"
# what the Dock may already hold: an older copy of the app, and CrossOver's icon for the game
OLD="$APPDIR/Old/Skywalker Saga.app"
CXAPP="$APPDIR/CrossOver/Steam/LEGO® Star Wars™ The Skywalker Saga.app"
mkdir -p "$OLD/Contents/MacOS" "$CXAPP/Contents/MacOS"
for a in "$OLD" "$CXAPP"; do printf '#!/bin/sh\n' > "$a/Contents/MacOS/x"; chmod +x "$a/Contents/MacOS/x"; done
defaults export com.apple.dock "$OUT/dock-before-seed.plist"
before=$(/usr/libexec/PlistBuddy -c 'Print :persistent-apps' "$OUT/dock-before-seed.plist" | grep -a -c '_CFURLString"* *=' || true)
for a in "$OLD" "$CXAPP"; do
  u="$(/usr/bin/osascript -l JavaScript -e 'function run(a){ return $.NSURL.fileURLWithPathIsDirectory(a[0], true).absoluteString.js }' "$a")"
  defaults write com.apple.dock persistent-apps -array-add "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$u</string><key>_CFURLStringType</key><integer>15</integer></dict></dict><key>tile-type</key><string>file-tile</string></dict>"
done
killall Dock 2>/dev/null; sleep 6
defaults export com.apple.dock "$OUT/dock-seeded.plist"
/bin/bash "$SKY" app > "$OUT/app.txt" 2>&1
cat "$OUT/app.txt" | sed 's/^/  /'
[ -f "$SKYWALKER_APP/Contents/Resources/AppIcon.icns" ] && ok "the app has an icon" || bad "the app has no icon"
grep -q 'App icon: the game' "$OUT/app.txt" && ok "taken from the game's program" || bad "the icon was not taken from the game"
plutil -lint "$SKYWALKER_APP/Contents/Info.plist" > /dev/null && ok "Info.plist is valid" || bad "Info.plist is broken"
sips -s format png "$SKYWALKER_APP/Contents/Resources/AppIcon.icns" --out "$OUT/app-icon.png" > /dev/null 2>&1
sips -g pixelWidth "$OUT/app-icon.png" | grep -q 'pixelWidth: 1024' && ok "1024-pixel icon inside" || bad "the icon is not 1024 pixels: $(sips -g pixelWidth "$OUT/app-icon.png" 2>&1)"
# the middle of the icon must show the picture, the corners must be see-through
alpha_at() { /usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); function run(a){ var r = $.NSBitmapImageRep.imageRepWithData($.NSData.dataWithContentsOfFile(a[0])); var c = r.colorAtXY(Number(a[1]), Number(a[2])); return Math.round(c.alphaComponent * 100) }' "$OUT/app-icon.png" "$1" "$2"; }
mid_a="$(alpha_at 512 512)"; corner_a="$(alpha_at 110 110)"; edge_a="$(alpha_at 20 512)"
echo "  icon alpha: middle $mid_a, rounded corner $corner_a, margin $edge_a (of 100)"
[ "${mid_a:-0}" -ge 90 ] && ok "the icon shows the picture" || bad "the icon is see-through in the middle"
[ "${corner_a:-100}" -le 10 ] && [ "${edge_a:-100}" -le 10 ] && ok "rounded with margins, as macOS draws app icons" || bad "the icon is not rounded"
defaults export com.apple.dock "$OUT/dock-after.plist"
url="$(/usr/bin/osascript -l JavaScript -e 'function run(a){ return $.NSURL.fileURLWithPathIsDirectory(a[0], true).absoluteString.js }' "$SKYWALKER_APP")"
/usr/libexec/PlistBuddy -c 'Print :persistent-apps' "$OUT/dock-after.plist" | grep -a '_CFURLString' | sed 's/^ */  dock: /'
n_sky=$(/usr/libexec/PlistBuddy -c 'Print :persistent-apps' "$OUT/dock-after.plist" | grep -a '_CFURLString ' | grep -ci 'skywalker' || true)
n_ours=$(/usr/libexec/PlistBuddy -c 'Print :persistent-apps' "$OUT/dock-after.plist" | grep -a '_CFURLString ' | grep -c -F "$url" || true)
[ "$n_sky" = 1 ] && [ "$n_ours" = 1 ] && ok "the Dock holds the app once, and no other game icon" || bad "Dock game icons: $n_sky, ours: $n_ours"
after=$(/usr/libexec/PlistBuddy -c 'Print :persistent-apps' "$OUT/dock-after.plist" | grep -a -c '_CFURLString"* *=' || true)
[ "$after" = $((before + 1)) ] && ok "the other Dock icons are all still there ($before + 1)" || bad "the Dock had $before other icons and now has $after entries"
pos=$(/usr/libexec/PlistBuddy -c 'Print :persistent-apps' "$OUT/dock-after.plist" | grep -a '_CFURLString ' | grep -n -F "$url" | cut -d: -f1)
[ "$pos" = $((before + 1)) ] && ok "in the place of the old icon (position $pos)" || bad "at position $pos, not $((before + 1))"
/bin/bash "$SKY" dock | grep -q 'already has' && ok "a second run leaves the Dock alone" || bad "a second run changed the Dock again"
ls "$SKYWALKER_HOME/settings-backups"/dock-*.plist > /dev/null 2>&1 && ok "the Dock's settings were backed up" || bad "no Dock backup"
sleep 3
screencapture -x "$OUT/dock.png" || true
# the app starts the launcher through the home folder, as it would on another Mac
mkdir -p "$HOME/Games/skywalker"
if [ ! -e "$HOME/Games/skywalker/skywalker.sh" ]; then
  # the real launcher, with "run" standing in: it goes through the stages of a
  # start as the real one tells them to the loading window, and, like the real
  # one, leaves something running (Steam) after it returns
  cat > "$OUT/standin-run.sh" <<EOF
load_conf; mkdir -p "\$LOGS"; UI_T0=\$(date +%s); UI_EXPECT=14
echo run > '$OUT/app-ran.txt'
ui_status starting "Starting Steam"; sleep 4
ui_status starting "Steam is syncing your saves with Steam Cloud"; sleep 4
ui_status running "The game is loading"
( sleep 8; echo alive > '$OUT/app-child.txt' ) &
EOF
  sed "s|^  run) cmd_run ;;|  run) source '$OUT/standin-run.sh' ;;|" "$SKY" > "$HOME/Games/skywalker/skywalker.sh"
  grep -q 'standin-run' "$HOME/Games/skywalker/skywalker.sh" || bad "the stand-in run was not put in"
  # The app made above points at this runner's launcher folder; make the app as
  # it is made on the Mac, from a launcher in ~/Games/skywalker with no test
  # settings ("open" also passes its environment on to the app, so clear them)
  HOMEAPP="$HOME/Applications/Skywalker Saga.app"
  env -u SKYWALKER_HOME -u SKYWALKER_APP -u SKY_PREFIX SKYWALKER_NO_DOCK=1 /bin/bash "$HOME/Games/skywalker/skywalker.sh" app > "$OUT/homeapp.txt" 2>&1 || bad "making the app from ~/Games/skywalker failed: $(tail -n 3 "$OUT/homeapp.txt")"
  grep -a -q 'Games/skywalker/skywalker.sh' "$HOMEAPP/Contents/MacOS/skywalker-launcher" && ok "the app looks for the launcher in ~/Games/skywalker" || bad "the app does not point at ~/Games/skywalker: $(grep -a 'L=' "$HOMEAPP/Contents/MacOS/skywalker-launcher")"
  # windows of a process: owner name and size (no permission needed for these)
  windows_of() {
    /usr/bin/osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); ObjC.import("Foundation");
      function run(a) { const pid = Number(a[0]); const l = ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1 | 16, 0)); const out = [];
        for (let i = 0; i < l.count; i++) { const w = l.objectAtIndex(i); const p = ObjC.unwrap(w.objectForKey("kCGWindowOwnerPID"));
          if (pid && p !== pid) continue; const b = w.objectForKey("kCGWindowBounds");
          out.push(ObjC.unwrap(w.objectForKey("kCGWindowOwnerName")) + " " + ObjC.unwrap(b.objectForKey("Width")) + "x" + ObjC.unwrap(b.objectForKey("Height")) + " layer " + ObjC.unwrap(w.objectForKey("kCGWindowLayer"))); }
        return out.join("; "); }' "$1" 2>&1
  }
  t_open=$(perl -MTime::HiRes=time -e 'print time')
  env -u SKYWALKER_HOME -u SKYWALKER_APP -u SKY_PREFIX open "$HOMEAPP" > "$OUT/open.txt" 2>&1; echo "  open: exit $? $(cat "$OUT/open.txt")"
  lpid=""
  for _ in $(seq 1 40); do
    lpid="$(pgrep -f 'Resources/loading.js' | head -n 1)"
    if [ -n "$lpid" ] && windows_of "$lpid" | grep -q '[0-9]x[0-9]'; then break; fi
    sleep 0.25
  done
  t_win=$(perl -MTime::HiRes=time -e 'print time')
  if [ -n "$lpid" ] && windows_of "$lpid" | grep -q '[0-9]x[0-9]'; then
    ok "the loading window is up $(perl -e "printf '%.1f', $t_win - $t_open") s after the click: $(windows_of "$lpid")"
  else
    bad "no loading window within 10 s (process: ${lpid:-none})"
  fi
  sleep 2
  screencapture -x "$OUT/loading-1.png" || true
  wait_for 20 test -s "$OUT/app-ran.txt" && ok "opening the app runs: skywalker.sh $(cat "$OUT/app-ran.txt")" || bad "opening the app did not run the launcher"
  wait_for 20 test -s "$OUT/app-child.txt" && ok "what the launcher leaves running outlives the app" || bad "macOS ended what the launcher left running"
  if wait_for 20 grep -q '^state=running' "$HOME/Games/skywalker/logs/start-status"; then
    sleep 1
    screencapture -x "$OUT/loading-2.png" || true
    [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null && ok "the window waits for the game's own window" || bad "the loading window closed before the game's window was up"
    # the game's window: the stand-in game fills the screen
    WINEDEBUG=-all /bin/bash "$SKY" wine "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Fake Game\\FAKEGAME_DX11.exe" --test-window 60 > "$OUT/game2.txt" 2>&1 &
    if wait_for 90 sh -c "! kill -0 $lpid 2>/dev/null"; then
      ok "the loading window closed once the game's window was up"
      [ -s "$HOME/Games/skywalker/logs/window-times.txt" ] && ok "it saw the game's window ($(tail -n 1 "$HOME/Games/skywalker/logs/window-times.txt") s after the game started)" || bad "it closed on its time limit, not on the game's window"
    else
      bad "the loading window stayed after the game's window was up"
    fi
    windows_of 0 | tr ';' '\n' | grep -v ' layer [1-9]' | sed 's/^ */  window: /' | head -n 12
    /bin/bash "$SKY" stop > /dev/null 2>&1 || true
  else
    bad "the stand-in start never reached the game stage: $(cat "$HOME/Games/skywalker/logs/start-status" 2>/dev/null)"
  fi
  sed 's/^/  stages: /' "$HOME/Games/skywalker/logs/start-stages.txt" 2>/dev/null
  sed 's/^/  loading.log: /' "$HOME/Games/skywalker/logs/loading.log" 2>/dev/null | tail -n 10
  cat "$HOME/Games/skywalker/logs/launcher.log" 2>/dev/null | sed 's/^/  launcher.log: /'
  pkill -f 'Resources/loading.js' 2>/dev/null || true
  launchctl print "gui/$(id -u)/io.github.jeswr.skywalker.run" 2>/dev/null | grep -E 'state|last exit' | sed 's/^/  job: /'
  launchctl bootout "gui/$(id -u)/io.github.jeswr.skywalker.run" 2>/dev/null || true
  rm -f "$HOME/Games/skywalker/skywalker.sh"
fi
defaults import com.apple.dock "$OUT/dock-before-seed.plist"; killall Dock 2>/dev/null || true

if [ "$fail" = 0 ]; then echo "Screen and app checks passed."; else echo "Some screen or app checks failed."; fi
exit "$fail"
