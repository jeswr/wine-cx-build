#!/bin/bash
# Checks the parts of skywalker.sh that need no Wine: save backups, the app
# icon, game detection and the frame summary. Uses a throwaway home folder.
set -euo pipefail

S="$(cd "$(dirname "$0")" && pwd)/skywalker.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/skywalker-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export SKYWALKER_HOME="$HOME/Games/skywalker"
export SKYWALKER_APP="$HOME/Applications/Skywalker Saga.app"
GAME="LEGO Star Wars - The Skywalker Saga"
P="$HOME/Games/skywalker-cx"
STEAM="$P/drive_c/Program Files (x86)/Steam"
SAVES="$P/drive_c/users/crossover/AppData/Roaming/Warner Bros. Interactive Entertainment/$GAME/SAVEDGAMES"
BACKUPS="$HOME/Games/SkywalkerSaga-saves"

fail() { echo "FAIL: $*" >&2; exit 1; }
count_backups() { find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -name '20*' | wc -l | tr -d ' '; }

mkdir -p "$SAVES" "$STEAM/steamapps/common/$GAME" "$STEAM/userdata/123/920210/remote" "$P/drive_c/windows/system32"
echo one > "$SAVES/slot1.dat"
echo cloud > "$STEAM/userdata/123/920210/remote/cloud.dat"
printf '"AppState"\n{\n\t"appid"\t\t"920210"\n\t"installdir"\t\t"%s"\n}\n' "$GAME" > "$STEAM/steamapps/appmanifest_920210.acf"
touch "$STEAM/steam.exe" "$STEAM/steamapps/common/$GAME/GAME_DX11.exe"

bash -n "$S"

echo "-- save backups"
bash "$S" backup
[ "$(count_backups)" = 1 ] || fail "first backup missing"
bash "$S" backup
[ "$(count_backups)" = 1 ] || fail "an unchanged save was backed up twice"
sleep 1
echo two >> "$SAVES/slot1.dat"
bash "$S" backup
[ "$(count_backups)" = 2 ] || fail "a changed save was not backed up"
newest="$(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | tail -n 1)"
grep -q two "$newest/appdata-crossover/Warner Bros. Interactive Entertainment/$GAME/SAVEDGAMES/slot1.dat" || fail "backup content is stale"
[ -f "$newest/steam-userdata-123/920210/remote/cloud.dat" ] || fail "Steam userdata was not backed up"
grep -q two "$SAVES/slot1.dat" || fail "the original save was altered"

echo "-- keeps only SAVE_BACKUPS states"
sed -i.bak 's/^SAVE_BACKUPS=.*/SAVE_BACKUPS=2/' "$SKYWALKER_HOME/config.env"
sleep 1
echo three >> "$SAVES/slot1.dat"
bash "$S" backup
[ "$(count_backups)" = 2 ] || fail "old backups were not pruned to 2"

echo "-- app icon"
bash "$S" app
[ -x "$SKYWALKER_APP/Contents/MacOS/skywalker-launcher" ] || fail "launcher missing from the app"
grep -q "skywalker.sh\" run" "$SKYWALKER_APP/Contents/MacOS/skywalker-launcher" || fail "app does not call run"
if command -v plutil >/dev/null 2>&1; then plutil -lint "$SKYWALKER_APP/Contents/Info.plist"; fi

echo "-- game detection"
bash "$S" doctor | tee "$T/doctor.txt"
grep -q "Game:         $GAME" "$T/doctor.txt" || fail "game folder not found from the Steam manifest"
grep -q "Game running: no" "$T/doctor.txt" || fail "game reported running when it is not"
( exec -a "C:\\Program Files (x86)\\Steam\\steamapps\\common\\$GAME\\game_dx11.EXE" sleep 30 ) &
fake=$!
sleep 1
bash "$S" doctor > "$T/doctor1.txt"
grep -q "Game running: yes" "$T/doctor1.txt" || { kill "$fake"; fail "running game not detected"; }
kill "$fake" 2>/dev/null || true

echo "-- graphics switch"
W="$SKYWALKER_HOME/wine/fake-1"
GDIR="$STEAM/steamapps/common/$GAME"
# A stand-in for a DXMT DLL: Wine's mark at byte 64 and a mention of winemetal
fake_dxmt() { printf '%064d%s%s' 0 'Wine builtin DLL' "................ winemetal.dll dxmt $1" > "$2"; }
for arch in x86_64-windows i386-windows; do
  mkdir -p "$W/lib/wine/$arch" "$W/orig-dlls/$arch"
  for d in d3d11 dxgi d3d10core; do
    fake_dxmt "$d" "$W/lib/wine/$arch/$d.dll"
    echo "wine $d" > "$W/orig-dlls/$arch/$d.dll"
  done
done
mkdir -p "$W/bin"
printf '#!/bin/bash\necho "fake-wine $* prefix=$WINEPREFIX user=$USER"\necho "limit=$(ulimit -u)"\necho "overrides=$WINEDLLOVERRIDES"\necho "d3dshared=${CX_APPLEGPTK_LIBD3DSHARED_PATH:-none} backend=${CX_ACTIVE_GRAPHICS_BACKEND:-none}"\nexit 0\n' > "$W/bin/wine"
chmod +x "$W/bin/wine"
ln -sfn fake-1 "$SKYWALKER_HOME/wine/current"
bash "$S" graphics wine
grep -q wine "$W/lib/wine/x86_64-windows/d3d11.dll" || fail "switch to Wine's Direct3D did not copy the DLL"
bash "$S" graphics dxmt
grep -q dxmt "$W/lib/wine/i386-windows/d3d11.dll" || fail "switch back to DXMT did not restore the DLL"
bash "$S" doctor > "$T/doctor2.txt"
grep -q "Graphics:     dxmt" "$T/doctor2.txt" || fail "doctor does not report the graphics layer"
bash "$S" wine cmd > "$T/wine-ovr.txt"
if grep -q 'd3d11' "$T/wine-ovr.txt"; then fail "DLL order is changed outside split graphics"; fi

echo "-- split graphics: DXMT for the game only"
bash "$S" graphics split
for arch in x86_64-windows i386-windows; do
  grep -q "wine d3d11" "$W/lib/wine/$arch/d3d11.dll" || fail "split did not put Wine's Direct3D into the build ($arch)"
done
for d in d3d11 dxgi d3d10core; do
  grep -a -q "winemetal.dll dxmt $d" "$GDIR/$d.dll" || fail "split did not give the game DXMT's $d.dll"
  if grep -a -q "Wine builtin DLL" "$GDIR/$d.dll"; then fail "the game's $d.dll still carries Wine's builtin mark"; fi
  [ "$(wc -c < "$GDIR/$d.dll")" = "$(wc -c < "$W/dxmt-dlls/x86_64-windows/$d.dll")" ] || fail "the game's $d.dll changed size"
  grep -a -q "Wine builtin DLL" "$W/dxmt-dlls/x86_64-windows/$d.dll" || fail "the saved DXMT $d.dll was altered"
done
bash "$S" doctor > "$T/doctor3.txt"
grep -q "Graphics:     split" "$T/doctor3.txt" || fail "doctor does not report split graphics"
bash "$S" wine cmd > "$T/wine-ovr.txt"
grep -q 'overrides=.*d3d11,dxgi,d3d10core=n,b' "$T/wine-ovr.txt" || fail "split graphics does not put the game's own DLLs first"
bash "$S" graphics wine
for d in d3d11 dxgi d3d10core; do
  [ ! -e "$GDIR/$d.dll" ] || fail "leaving split graphics left $d.dll in the game folder"
done
[ ! -e "$GDIR/.skywalker-dxmt" ] || fail "leaving split graphics left the note in the game folder"
echo "the game's own" > "$GDIR/dxgi.dll"
if bash "$S" graphics split > "$T/split-foreign.txt" 2>&1; then fail "split replaced a DLL that belongs to the game"; fi
grep -q "the game's own" "$GDIR/dxgi.dll" || fail "the game's own dxgi.dll was overwritten"
rm -f "$GDIR/dxgi.dll"
bash "$S" graphics dxmt
grep -a -q "winemetal.dll dxmt d3d11" "$W/lib/wine/x86_64-windows/d3d11.dll" || fail "DXMT was not restored after split"
[ ! -e "$GDIR/d3d11.dll" ] || fail "a failed split left files in the game folder"

echo "-- Apple's D3DMetal from the user's own folder"
G="$HOME/Games/gptk"
if bash "$S" graphics d3dmetal > "$T/d3dm-missing.txt" 2>&1; then fail "d3dmetal was accepted without Apple's files"; fi
grep -q "was not found in $G" "$T/d3dm-missing.txt" || fail "no clear message when Apple's files are missing"
grep -a -q "winemetal.dll dxmt d3d11" "$W/lib/wine/x86_64-windows/d3d11.dll" || fail "a refused d3dmetal changed the build"
bash "$S" doctor > "$T/doctor-d3dm.txt"
grep -q "D3DMetal:     Apple's files not found" "$T/doctor-d3dm.txt" || fail "doctor does not say that Apple's files are missing"
# a stand-in for the toolkit's lib folder, with the links its Unix-side files are
mkdir -p "$G/lib/external/D3DMetal.framework/Versions/A" "$G/lib/wine/x86_64-windows" "$G/lib/wine/x86_64-unix"
echo "apple shared" > "$G/lib/external/libd3dshared.dylib"
echo "apple framework" > "$G/lib/external/D3DMetal.framework/Versions/A/D3DMetal"
ln -s Versions/A/D3DMetal "$G/lib/external/D3DMetal.framework/D3DMetal"
for d in d3d11 dxgi d3d12 nvapi64; do
  echo "apple $d" > "$G/lib/wine/x86_64-windows/$d.dll"
  ln -s ../../external/libd3dshared.dylib "$G/lib/wine/x86_64-unix/$d.so"
done
echo "not a dll" > "$G/lib/wine/x86_64-windows/README.txt"
mkdir -p "$W/lib/wine/x86_64-unix"
echo "wine d3d11 unix" > "$W/lib/wine/x86_64-unix/d3d11.so"
bash "$S" doctor > "$T/doctor-d3dm.txt"
grep -q "D3DMetal:     Apple's files found" "$T/doctor-d3dm.txt" || fail "doctor does not find Apple's files"
bash "$S" graphics split
bash "$S" graphics d3dmetal
for d in d3d11 dxgi d3d12 nvapi64; do
  grep -q "apple $d" "$W/lib/wine/x86_64-windows/$d.dll" || fail "d3dmetal did not put Apple's $d.dll into the build"
  [ -L "$W/lib/wine/x86_64-unix/$d.so" ] || fail "Apple's $d.so did not stay a link"
  grep -q "apple shared" "$W/lib/wine/x86_64-unix/$d.so" || fail "Apple's $d.so does not reach libd3dshared from the build"
done
[ ! -e "$W/lib/wine/x86_64-windows/README.txt" ] || fail "d3dmetal copied a file that is not a DLL"
grep -q "wine d3d11" "$W/lib/wine/i386-windows/d3d11.dll" || fail "d3dmetal did not leave Wine's 32-bit Direct3D in place"
grep -q "apple framework" "$W/lib/external/D3DMetal.framework/D3DMetal" || fail "the framework was not copied with its links"
[ ! -e "$GDIR/d3d11.dll" ] || fail "d3dmetal left DXMT in the game folder"
bash "$S" doctor > "$T/doctor-d3dm.txt"
grep -q "Graphics:     d3dmetal" "$T/doctor-d3dm.txt" || fail "doctor does not report d3dmetal"
bash "$S" wine cmd > "$T/wine-d3dm.txt"
grep -q "d3dshared=$SKYWALKER_HOME/wine/current/lib/external/libd3dshared.dylib backend=d3dmetal" "$T/wine-d3dm.txt" || { cat "$T/wine-d3dm.txt"; fail "Wine is not told about D3DMetal"; }
if grep -q 'overrides=.*d3d11' "$T/wine-d3dm.txt"; then fail "d3dmetal changes the DLL order"; fi
SKY_D3DMETAL_HOOK=0 bash "$S" wine cmd > "$T/wine-d3dm0.txt"
grep -q "d3dshared=none backend=d3dmetal" "$T/wine-d3dm0.txt" || fail "D3DMETAL_HOOK=0 still passes libd3dshared to Wine"
bash "$S" graphics d3dmetal
grep -q "wine d3d11" "$W/d3dmetal-saved/x86_64-windows/d3d11.dll" || fail "applying d3dmetal twice lost Wine's own d3d11.dll"
echo "-- a new build takes over the graphics choice"
W2="$SKYWALKER_HOME/wine/fake-2"
mkdir -p "$W2/bin"
cp -R "$W/orig-dlls" "$W2/orig-dlls"
for arch in x86_64-windows i386-windows; do
  mkdir -p "$W2/lib/wine/$arch"
  for d in d3d11 dxgi d3d10core; do fake_dxmt "$d" "$W2/lib/wine/$arch/$d.dll"; done
done
cp "$W/bin/wine" "$W2/bin/wine"
ln -sfn fake-2 "$SKYWALKER_HOME/wine/current"
bash "$S" adopt-graphics fake-1
[ "$(cat "$W2/GRAPHICS")" = d3dmetal ] || fail "the new build did not take over d3dmetal"
grep -q "apple dxgi" "$W2/lib/wine/x86_64-windows/dxgi.dll" || fail "the new build did not get Apple's files"
grep -q "apple d3d11" "$W/lib/wine/x86_64-windows/d3d11.dll" || fail "the previous build was changed"
bash "$S" adopt-graphics fake-1
mv "$G" "$G.away"
rm -f "$W2/GRAPHICS"
bash "$S" graphics wine
rm -f "$W2/GRAPHICS"
bash "$S" adopt-graphics fake-1 > "$T/adopt.txt"
[ "$(cat "$W2/GRAPHICS")" = split ] || fail "without Apple's files the new build should fall back to split"
grep -q "no longer in" "$T/adopt.txt" || fail "no word about the missing files"
mv "$G.away" "$G"
ln -sfn fake-1 "$SKYWALKER_HOME/wine/current"
bash "$S" graphics split
grep -q "wine d3d11" "$W/lib/wine/x86_64-windows/d3d11.dll" || fail "leaving d3dmetal did not put Wine's d3d11.dll back"
grep -q "wine d3d11 unix" "$W/lib/wine/x86_64-unix/d3d11.so" || fail "leaving d3dmetal did not put Wine's d3d11.so back"
for f in lib/wine/x86_64-windows/d3d12.dll lib/wine/x86_64-windows/nvapi64.dll lib/wine/x86_64-unix/dxgi.so lib/external d3dmetal-saved d3dmetal-files; do
  if [ -e "$W/$f" ] || [ -L "$W/$f" ]; then fail "leaving d3dmetal left $f in the build"; fi
done
grep -a -q "winemetal.dll dxmt d3d11" "$GDIR/d3d11.dll" || fail "split after d3dmetal did not give the game DXMT"
grep -q "apple d3d11" "$G/lib/wine/x86_64-windows/d3d11.dll" || fail "the user's own toolkit folder was changed"
bash "$S" graphics dxmt

echo "-- wine passthrough"
bash "$S" wine cmd /c ver > "$T/wine.txt"
grep -q "fake-wine cmd /c ver prefix=$P user=crossover" "$T/wine.txt" || fail "wine passthrough did not set up the environment"

echo "-- process limit"
before="$(ps -x -o pid= | wc -l | tr -d ' ')"
SKY_PROC_HEADROOM=50 bash "$S" wine cmd /c ver > "$T/wine-limit.txt"
limit="$(sed -n 's/^limit=//p' "$T/wine-limit.txt")"
case "$limit" in ''|*[!0-9]*) fail "Wine was started without a process limit (got '$limit')" ;; esac
[ "$limit" -ge "$before" ] || fail "process limit $limit is below the $before processes already running"
[ "$limit" -le $((before + 150)) ] || fail "process limit $limit is not close to $before + 50"

echo "-- leftover Wine processes"
( exec -a 'C:\windows\system32\stuck.exe' sleep 60 ) &
stray=$!
( exec -a '/Applications/CrossOver.app/Contents/MacOS/CrossOver' sleep 60 ) &
other=$!
sleep 1
grep -q "Processes:    0 from Wine" "$T/doctor2.txt" || { kill "$stray" "$other"; fail "doctor counts Wine processes when there are none"; }
bash "$S" doctor > "$T/doctor3.txt"
grep -q "Processes:    1 from Wine" "$T/doctor3.txt" || { kill "$stray" "$other"; fail "doctor does not count the leftover Wine process"; }
bash "$S" stop
kill -0 "$stray" 2>/dev/null || { kill "$other"; fail "stop ended a Wine process while CrossOver was running"; }
kill "$other"
wait "$other" 2>/dev/null || true
bash "$S" stop
sleep 1
if kill -0 "$stray" 2>/dev/null; then kill "$stray"; fail "stop left a stuck Wine process behind"; fi

echo "-- frame summary"
: > "$T/wine.log"
: > "$T/sys.log"
frame=0
sec=0
while [ "$sec" -lt 130 ]; do
  # 59 frames at 16 ms and one at 56 ms every second: 60 fps on average, slowest 1% at 17.9 fps
  line="metal-HUD: $frame,512.0,2048.0"
  i=0
  while [ "$i" -lt 59 ]; do line="$line,16.00,8.00"; i=$((i + 1)); done
  line="$line,56.00,8.00"
  echo "2026-11-13 03:00:00.000 Df game.exe[4242:1a2b] [com.apple.Metal] $line" >> "$T/sys.log"
  if [ $((sec % 3)) = 0 ]; then
    echo "2026-11-13 03:00:00.000 Df steamwebhelper.exe[99:77] [x] metal-HUD: $sec,1,1,33.3,1.0,33.3,1.0" >> "$T/sys.log"
  fi
  frame=$((frame + 60))
  sec=$((sec + 1))
done
bash "$S" summary "$T/wine.log" "$T/sys.log" | tee "$T/summary.txt"
grep -q 'source=game.exe\[4242\]' "$T/summary.txt" || fail "summary picked the wrong process"
grep -q 'frames=7800 seconds=130 avg_fps=60.0 low1_fps=17.9 avg_gpu_ms=8.00' "$T/summary.txt" || fail "summary numbers are wrong"
grep -q 'minute  1:  60.0 fps, slowest 1%  17.9 fps' "$T/summary.txt" || fail "per-minute numbers are wrong"
if bash "$S" summary /dev/null >/dev/null; then fail "empty log should not summarise"; fi

echo "-- start-up stopwatch and timeline"
# A stand-in Wine: "steam.exe ... -applaunch" starts Steam (unless it is open)
# and, two seconds later, the game, which plays for four seconds.
cat > "$W/bin/wine" <<'FAKE'
#!/bin/bash
echo "$*" >> "$FAKE_DIR/calls.txt"
case "$*" in
  *-shutdown*)
    kill "$(cat "$FAKE_DIR/steam.pid" 2>/dev/null)" "$(cat "$FAKE_DIR/server.pid" 2>/dev/null)" 2>/dev/null
    rm -f "$FAKE_DIR/steam.pid" "$FAKE_DIR/server.pid"
    ;;
  *-applaunch*)
    if ! kill -0 "$(cat "$FAKE_DIR/steam.pid" 2>/dev/null)" 2>/dev/null; then
      ( exec -a 'C:\Program Files (x86)\Steam\steam.exe' sleep 300 ) &
      echo $! > "$FAKE_DIR/steam.pid"
      ( exec -a "$(dirname "$0")/wineserver" sleep 300 ) &
      echo $! > "$FAKE_DIR/server.pid"
    fi
    ( sleep 2; exec -a "C:\\Program Files (x86)\\Steam\\steamapps\\common\\$FAKE_GAME\\game_dx11.EXE" sleep 4 ) &
    ;;
esac
exit 0
FAKE
export FAKE_GAME="$GAME" FAKE_DIR="$T/fake"
mkdir -p "$FAKE_DIR"
steam_alive() { kill -0 "$(cat "$FAKE_DIR/steam.pid" 2>/dev/null)" 2>/dev/null; }
if bash "$S" timeline > /dev/null 2>&1; then fail "timeline should say that no start was recorded"; fi
SKY_KEEP_STEAM_MINUTES=0 SKY_STEAM_ARGS="-silent -testflag" bash "$S" run | tee "$T/run.txt"
grep -q 'The game is running. It started [0-9]*s after the launcher' "$T/run.txt" || fail "run did not report the start-up time"
grep -q 'The game has exited' "$T/run.txt" || fail "run did not notice the game ending"
[ "$(wc -l < "$SKYWALKER_HOME/logs/startup.tsv" | tr -d ' ')" = 1 ] || fail "start-up time was not recorded"
if steam_alive; then fail "Steam was left open although KEEP_STEAM_MINUTES is 0"; fi
since="$(cat "$SKYWALKER_HOME/logs/last-start")"
mkdir -p "$STEAM/logs"
{
  echo "[2020-01-01 00:00:00] Startup - updater built long ago"
  echo "[$since] Startup - updater built Nov  9 2026 14:39:29"
  echo "[$since] Verification complete"
  echo "[$since] Downloading update (1 of 2 KB)..."
} > "$STEAM/logs/bootstrap_log.txt"
echo "[$since] Applying workarounds due to GPU process restarts: browser:0 gpu:3 uptime:27.9" > "$STEAM/logs/webhelper.txt"
echo "[$since] AppID 920210 state changed : Fully Installed,App Running," > "$STEAM/logs/content_log.txt"
bash "$S" timeline | tee "$T/timeline.txt"
grep -q 'Steam options: -silent -testflag -cef-disable-gpu' "$T/timeline.txt" || fail "timeline lost the Steam options"
grep -q 'bootstrap_log: Verification complete' "$T/timeline.txt" || fail "timeline misses Steam's starter"
grep -q 'webhelper: Applying workarounds due to GPU process restarts' "$T/timeline.txt" || fail "timeline misses the graphics process restarts"
grep -q 'content_log: AppID 920210 state changed' "$T/timeline.txt" || fail "timeline misses the game's lines"
if grep -q 'long ago\|1 of 2 KB' "$T/timeline.txt"; then fail "timeline shows lines it should leave out"; fi

echo "-- Steam stays open between games"
: > "$FAKE_DIR/calls.txt"
SKY_KEEP_STEAM_MINUTES=0.2 bash "$S" run | tee "$T/keep1.txt"
grep -q 'Steam stays open for 0.2 minutes' "$T/keep1.txt" || fail "Steam was not kept open"
steam_alive || fail "Steam is gone although it should stay open"
SKY_KEEP_STEAM_MINUTES=0.2 bash "$S" run | tee "$T/keep2.txt"
grep -q 'Steam is still open, so the game starts straight away' "$T/keep2.txt" || fail "the open Steam was not reused"
[ "$(grep -c -e '-applaunch 920210' "$FAKE_DIR/calls.txt")" = 2 ] || fail "expected two game launches"
[ "$(grep -c -e '-silent' "$FAKE_DIR/calls.txt")" = 1 ] || fail "Steam was started twice"
grep -q -e '-silent -nofriendsui -nochatui -cef-disable-gpu -applaunch 920210' "$FAKE_DIR/calls.txt" || fail "Steam was not told to skip its graphics process"
if grep -q -e '-shutdown' "$FAKE_DIR/calls.txt"; then fail "Steam was closed between the two games"; fi
# other settings: the open Steam cannot pass them on, so it has to be restarted
SKY_KEEP_STEAM_MINUTES=0.2 SKY_FPS_CAP=30 bash "$S" run | tee "$T/keep3.txt"
grep -q 'Steam is open with other settings, so it is restarted' "$T/keep3.txt" || fail "changed settings did not restart Steam"
steam_alive || fail "Steam is gone right after the third game"
sleep 16
if steam_alive; then fail "the idle timer did not close Steam"; fi
[ ! -f "$SKYWALKER_HOME/steam-session" ] || fail "the session note was left behind"
# stop cancels a pending timer and closes Steam at once
SKY_KEEP_STEAM_MINUTES=5 bash "$S" run > "$T/keep4.txt"
steam_alive || fail "Steam is gone although it should stay open for 5 minutes"
bash "$S" stop
if steam_alive; then fail "stop left Steam open"; fi
: > "$FAKE_DIR/calls.txt"
SKY_STEAM_GPU=1 bash "$S" steam > /dev/null
bash "$S" steam -cef-disable-gpu -foo > /dev/null
bash "$S" steam -foo > /dev/null
sleep 2   # Steam is started in the background
[ "$(cat "$FAKE_DIR/calls.txt")" = "C:\\Program Files (x86)\\Steam\\steam.exe
C:\\Program Files (x86)\\Steam\\steam.exe -cef-disable-gpu -foo
C:\\Program Files (x86)\\Steam\\steam.exe -foo -cef-disable-gpu" ] || { cat "$FAKE_DIR/calls.txt"; fail "the graphics process option was not handled as intended"; }
[ ! -f "$SKYWALKER_HOME/steam-idle" ] || fail "stop left the idle ticket behind"

echo "All launcher checks passed."
