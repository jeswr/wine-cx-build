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
# a stand-in for the toolkit as it is on the Mac: inside an app whose name has
# spaces, some Unix-side files present as links and some not there at all
GL="$G/Game Porting Toolkit.app/Contents/Resources/wine/lib"
mkdir -p "$GL/external/D3DMetal.framework/Versions/A" "$GL/wine/x86_64-windows" "$GL/wine/x86_64-unix"
echo "apple shared" > "$GL/external/libd3dshared.dylib"
echo "apple framework" > "$GL/external/D3DMetal.framework/Versions/A/D3DMetal"
ln -s Versions/A/D3DMetal "$GL/external/D3DMetal.framework/D3DMetal"
for d in d3d11 dxgi d3d12 d3d10core nvapi64; do echo "apple $d" > "$GL/wine/x86_64-windows/$d.dll"; done
for d in d3d11 dxgi; do ln -s ../../external/libd3dshared.dylib "$GL/wine/x86_64-unix/$d.so"; done
mkdir -p "$W/lib/wine/x86_64-unix"
echo "wine d3d11 unix" > "$W/lib/wine/x86_64-unix/d3d11.so"
bash "$S" doctor > "$T/doctor-d3dm.txt"
grep -q "D3DMetal:     Apple's files found" "$T/doctor-d3dm.txt" || fail "doctor does not find Apple's files"
bash "$S" graphics split
bash "$S" graphics d3dmetal
for d in d3d11 dxgi d3d12 d3d10core; do
  grep -q "apple $d" "$W/lib/wine/x86_64-windows/$d.dll" || fail "d3dmetal did not put Apple's $d.dll into the build"
done
for d in d3d11 dxgi d3d12 d3d10 atidxx64 nvapi64; do
  [ "$(readlink "$W/lib/wine/x86_64-unix/$d.so")" = ../../external/libd3dshared.dylib ] || fail "$d.so is not a link to libd3dshared"
  grep -q "apple shared" "$W/lib/wine/x86_64-unix/$d.so" || fail "$d.so does not reach libd3dshared from the build"
done
[ ! -e "$W/lib/wine/x86_64-windows/nvapi64.dll" ] || fail "d3dmetal copied a DLL outside the set that was proven on the Mac"
grep -q "wine d3d11" "$W/lib/wine/i386-windows/d3d11.dll" || fail "d3dmetal did not leave Wine's 32-bit Direct3D in place"
grep -q "apple framework" "$W/lib/external/D3DMetal.framework/D3DMetal" || fail "the framework was not copied with its links"
[ ! -e "$GDIR/d3d11.dll" ] || fail "d3dmetal left DXMT in the game folder"
bash "$S" doctor > "$T/doctor-d3dm.txt"
grep -q "Graphics:     d3dmetal" "$T/doctor-d3dm.txt" || fail "doctor does not report d3dmetal"
bash "$S" wine cmd > "$T/wine-d3dm.txt"
grep -q "d3dshared=none backend=none" "$T/wine-d3dm.txt" || { cat "$T/wine-d3dm.txt"; fail "d3dmetal should start Wine as the hand-made setup did unless D3DMETAL_HOOK is on"; }
if grep -q 'overrides=.*d3d11' "$T/wine-d3dm.txt"; then fail "d3dmetal changes the DLL order"; fi
SKY_D3DMETAL_HOOK=1 bash "$S" wine cmd > "$T/wine-d3dm1.txt"
grep -q "d3dshared=$SKYWALKER_HOME/wine/current/lib/external/libd3dshared.dylib backend=d3dmetal" "$T/wine-d3dm1.txt" || { cat "$T/wine-d3dm1.txt"; fail "D3DMETAL_HOOK=1 does not tell Wine about D3DMetal"; }
bash "$S" graphics d3dmetal
grep -q "wine d3d11" "$W/d3dmetal-saved/x86_64-windows/d3d11.dll" || fail "applying d3dmetal twice lost Wine's own d3d11.dll"

echo "-- a new build takes over the graphics choice"
# $1 = name of a new stand-in build as it comes out of the archive (DXMT in place)
new_build() {
  local d="$SKYWALKER_HOME/wine/$1" arch x
  mkdir -p "$d/bin"
  cp -R "$W/orig-dlls" "$d/orig-dlls"
  for arch in x86_64-windows i386-windows; do
    mkdir -p "$d/lib/wine/$arch"
    for x in d3d11 dxgi d3d10core; do fake_dxmt "$x" "$d/lib/wine/$arch/$x.dll"; done
  done
  cp "$W/bin/wine" "$d/bin/wine"
  ln -sfn "$1" "$SKYWALKER_HOME/wine/current"
}
W2="$SKYWALKER_HOME/wine/fake-2"
new_build fake-2
bash "$S" adopt-graphics fake-1
[ "$(cat "$W2/GRAPHICS")" = d3dmetal ] || fail "the new build did not take over d3dmetal"
grep -q "apple dxgi" "$W2/lib/wine/x86_64-windows/dxgi.dll" || fail "the new build did not get Apple's files"
grep -q "apple d3d11" "$W/lib/wine/x86_64-windows/d3d11.dll" || fail "the previous build was changed"
bash "$S" adopt-graphics fake-1
# a build that had Apple's files put in by hand counts as d3dmetal too
W3="$SKYWALKER_HOME/wine/fake-3-byhand"
mkdir -p "$W3/lib/external"
echo wine > "$W3/GRAPHICS"
echo "apple shared" > "$W3/lib/external/libd3dshared.dylib"
new_build fake-4
bash "$S" adopt-graphics fake-3-byhand
[ "$(cat "$SKYWALKER_HOME/wine/fake-4/GRAPHICS")" = d3dmetal ] || fail "a build set up by hand for D3DMetal was not recognised"
# a first install uses D3DMetal when Apple's files are there
new_build fake-5
bash "$S" adopt-graphics none
[ "$(cat "$SKYWALKER_HOME/wine/fake-5/GRAPHICS")" = d3dmetal ] || fail "a first install with Apple's files present did not use D3DMetal"
# another choice is kept
echo dxmt > "$W3/GRAPHICS"
rm -rf "$W3/lib/external"
new_build fake-6
bash "$S" adopt-graphics fake-3-byhand
[ "$(cat "$SKYWALKER_HOME/wine/fake-6/GRAPHICS")" = dxmt ] || fail "the previous build's own choice was not kept"
# without Apple's files: a first install is split, and d3dmetal falls back with a word about it
mv "$G" "$G.away"
new_build fake-7
bash "$S" adopt-graphics none
[ "$(cat "$SKYWALKER_HOME/wine/fake-7/GRAPHICS")" = split ] || fail "a first install without Apple's files should be split"
ln -sfn fake-2 "$SKYWALKER_HOME/wine/current"
bash "$S" graphics wine
grep -q "wine dxgi" "$W2/lib/wine/x86_64-windows/dxgi.dll" || fail "leaving d3dmetal needs Apple's folder, which it should not"
new_build fake-8
bash "$S" adopt-graphics fake-1 > "$T/adopt.txt"
[ "$(cat "$SKYWALKER_HOME/wine/fake-8/GRAPHICS")" = split ] || fail "without Apple's files the new build should fall back to split"
grep -q "no longer in" "$T/adopt.txt" || fail "no word about the missing files"
mv "$G.away" "$G"
ln -sfn fake-1 "$SKYWALKER_HOME/wine/current"
bash "$S" graphics split
grep -q "wine d3d11" "$W/lib/wine/x86_64-windows/d3d11.dll" || fail "leaving d3dmetal did not put Wine's d3d11.dll back"
grep -q "wine d3d11 unix" "$W/lib/wine/x86_64-unix/d3d11.so" || fail "leaving d3dmetal did not put Wine's d3d11.so back"
for f in lib/wine/x86_64-windows/d3d12.dll lib/wine/x86_64-unix/dxgi.so lib/wine/x86_64-unix/nvapi64.so lib/external d3dmetal-saved d3dmetal-files; do
  if [ -e "$W/$f" ] || [ -L "$W/$f" ]; then fail "leaving d3dmetal left $f in the build"; fi
done
grep -q "wine d3d10core" "$W/lib/wine/x86_64-windows/d3d10core.dll" || fail "leaving d3dmetal did not put Wine's d3d10core.dll back"
grep -a -q "winemetal.dll dxmt d3d11" "$GDIR/d3d11.dll" || fail "split after d3dmetal did not give the game DXMT"
grep -q "apple d3d11" "$GL/wine/x86_64-windows/d3d11.dll" || fail "the user's own toolkit folder was changed"
bash "$S" graphics dxmt

echo "-- Steam's browser part keeps Wine's own Direct3D"
NOW="$(cd "$SKYWALKER_HOME/wine/current" && pwd -P)"
CEF="$STEAM/bin/cef/cef.win64"
bash "$S" wine cmd > "$T/own0.txt"
if grep -q 'overrides=.*d3d11' "$T/own0.txt"; then fail "the DLL order is changed although Steam has no browser part here"; fi
mkdir -p "$CEF"
touch "$CEF/steamwebhelper.exe"
bash "$S" steam > /dev/null
[ ! -e "$CEF/d3d11.dll" ] || fail "copies were put into Steam's folder although STEAM_OWN_D3D is off by default"
export SKY_STEAM_OWN_D3D=1
# the stand-in Wine keeps what regedit is given
cp "$NOW/bin/wine" "$T/wine.simple"
printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$REG_CALLS"' 'case "$1" in regedit) cp "$WINEPREFIX/drive_c/skywalker-steam-d3d.reg" "$REG_COPY" ;; esac' 'echo "overrides=$WINEDLLOVERRIDES"' 'exit 0' > "$NOW/bin/wine"
export REG_CALLS="$T/reg-calls.txt" REG_COPY="$T/last.reg"
: > "$REG_CALLS"
bash "$S" wine cmd > "$T/own1.txt"
if grep -q 'overrides=.*d3d11' "$T/own1.txt"; then cat "$T/own1.txt"; fail "the DLL order of every program is changed for the sake of Steam's browser part"; fi
bash "$S" steam > "$T/own-steam.txt"
grep -q -x 'regedit /S C:\\skywalker-steam-d3d.reg' "$REG_CALLS" || { cat "$REG_CALLS"; fail "the setting for steamwebhelper.exe was not written through regedit"; }
tr -d '\r' < "$REG_COPY" > "$T/last-reg.txt"
grep -q -x -F '[HKEY_CURRENT_USER\Software\Wine\AppDefaults\steamwebhelper.exe\DllOverrides]' "$T/last-reg.txt" || { cat "$T/last-reg.txt"; fail "the registry setting is not for steamwebhelper.exe alone"; }
grep -q -x -F '"d3d11"="native,builtin"' "$T/last-reg.txt" || fail "the registry setting does not prefer the local d3d11"
grep -q -x -F '"d3d12"="native,builtin"' "$T/last-reg.txt" || fail "the registry setting does not prefer the local d3d12"
[ -f "$P/.skywalker-steam-d3d" ] || fail "the bottle has no note that the setting is there"
[ ! -e "$P/drive_c/skywalker-steam-d3d.reg" ] || fail "the registry file was left in the bottle"
grep -q "Steam's browser part keeps Wine's own Direct3D" "$T/own-steam.txt" || { cat "$T/own-steam.txt"; fail "nothing was said about Steam's own Direct3D"; }
for d in d3d11 dxgi d3d10core; do
  grep -q "wine $d" "$CEF/$d.dll" || fail "Steam's browser part did not get Wine's own $d.dll"
done
bash "$S" steam > "$T/own-steam2.txt"
if grep -q "keeps Wine's own Direct3D" "$T/own-steam2.txt"; then fail "the copies for Steam were made a second time"; fi
[ "$(grep -c '^regedit' "$REG_CALLS")" = 1 ] || fail "the registry setting was written a second time"
SKY_STEAM_OWN_D3D=0 bash "$S" steam > /dev/null
[ ! -e "$CEF/d3d11.dll" ] || fail "STEAM_OWN_D3D=0 left the copies in Steam's folder"
[ ! -e "$CEF/.skywalker-wined3d" ] || fail "STEAM_OWN_D3D=0 left the note in Steam's folder"
[ "$(grep -c '^regedit' "$REG_CALLS")" = 2 ] || fail "STEAM_OWN_D3D=0 did not take the registry setting out"
grep -q -F '[-HKEY_CURRENT_USER\Software\Wine\AppDefaults\steamwebhelper.exe]' "$REG_COPY" || fail "the registry setting was not removed"
[ ! -e "$P/.skywalker-steam-d3d" ] || fail "the note about the registry setting was left behind"
echo "steam's own" > "$CEF/dxgi.dll"
bash "$S" steam > "$T/own-foreign.txt"
grep -q "steam's own" "$CEF/dxgi.dll" || fail "a DLL that belongs to Steam was overwritten"
[ ! -e "$CEF/d3d11.dll" ] || fail "copies were made next to a DLL that belongs to Steam"
rm -f "$CEF/dxgi.dll"
# with D3DMetal the copies come from what D3DMetal displaced, Direct3D 12 included
echo "wine d3d12" > "$NOW/lib/wine/x86_64-windows/d3d12.dll"
bash "$S" graphics d3dmetal > /dev/null
bash "$S" steam > /dev/null
for d in d3d11 dxgi d3d10core d3d12; do
  grep -q "wine $d" "$CEF/$d.dll" || fail "under d3dmetal Steam's browser part did not get Wine's own $d.dll"
done
grep -q "apple d3d11" "$NOW/lib/wine/x86_64-windows/d3d11.dll" || fail "the build lost Apple's d3d11.dll"
bash "$S" graphics split > /dev/null
bash "$S" steam > /dev/null
[ ! -e "$CEF/d3d11.dll" ] || fail "split graphics left the copies in Steam's folder"
grep -q "wine d3d12" "$NOW/lib/wine/x86_64-windows/d3d12.dll" || fail "Wine's own d3d12.dll did not come back"
bash "$S" graphics dxmt > /dev/null
[ ! -e "$P/.skywalker-steam-d3d" ] || fail "split graphics left the registry setting for Steam's browser part"
unset SKY_STEAM_OWN_D3D
cp "$T/wine.simple" "$NOW/bin/wine"
rm -rf "${STEAM:?}/bin" "$NOW/lib/wine/x86_64-windows/d3d12.dll"
rm -f "$SKYWALKER_HOME/steam-session"

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
  *steam.exe*)
    if ! kill -0 "$(cat "$FAKE_DIR/steam.pid" 2>/dev/null)" 2>/dev/null; then
      ( exec -a 'C:\Program Files (x86)\Steam\steam.exe' sleep 300 ) &
      echo $! > "$FAKE_DIR/steam.pid"
      ( exec -a "$(dirname "$0")/wineserver" sleep 300 ) &
      echo $! > "$FAKE_DIR/server.pid"
    fi
    case "$*" in *-applaunch*)
      if [ -f "$FAKE_DIR/deaf" ]; then rm -f "$FAKE_DIR/deaf"; exit 0; fi
      ( sleep 2; exec -a "C:\\Program Files (x86)\\Steam\\steamapps\\common\\$FAKE_GAME\\game_dx11.EXE" sleep 4 ) &
      ;;
    esac
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
bash "$S" stop > /dev/null
[ ! -f "$SKYWALKER_HOME/steam-idle" ] || fail "stop left the idle ticket behind"

echo "-- an open Steam that cannot start the game, and leftovers of a Steam that has gone"
: > "$FAKE_DIR/calls.txt"
SKY_KEEP_STEAM_MINUTES=0 bash "$S" run > /dev/null
grep -q -e '-applaunch 920210 -skipvideos$' "$FAKE_DIR/calls.txt" || { cat "$FAKE_DIR/calls.txt"; fail "the game was not told to skip its films"; }
: > "$FAKE_DIR/calls.txt"
SKY_GAME_ARGS="" SKY_KEEP_STEAM_MINUTES=0.5 bash "$S" run > "$T/deaf0.txt"
grep -q -e '-applaunch 920210$' "$FAKE_DIR/calls.txt" || { cat "$FAKE_DIR/calls.txt"; fail "an empty GAME_ARGS still passed options to the game"; }
steam_alive || fail "Steam is gone although it should stay open"
touch "$FAKE_DIR/deaf"
SKY_GAME_ARGS="" SKY_WARM_WAIT=3 SKY_KEEP_STEAM_MINUTES=0 bash "$S" run > "$T/deaf1.txt"
grep -q 'Steam is still open, so the game starts straight away' "$T/deaf1.txt" || fail "the open Steam was not tried first"
grep -q 'The open Steam did not start the game, so Steam is started afresh' "$T/deaf1.txt" || { cat "$T/deaf1.txt"; fail "a failed hand-over to the open Steam was not noticed"; }
grep -q 'The game is running' "$T/deaf1.txt" || fail "the game did not start after falling back to a fresh Steam"
if steam_alive; then fail "Steam was left open although KEEP_STEAM_MINUTES is 0"; fi
# Steam has gone, one of its helpers has not: that is not an open Steam
( exec -a "$W/bin/wineserver" sleep 300 ) &
orphan_server=$!
( exec -a 'C:\Program Files (x86)\Steam\bin\cef\cef.win7x64\steamwebhelper.exe -lang=en_US -steampath=C:\Program Files (x86)\Steam\steam.exe -clientui' sleep 300 ) &
orphan_helper=$!
sleep 1
bash "$S" doctor > "$T/orphan-doctor.txt"
grep -q 'Wine running: yes' "$T/orphan-doctor.txt" || fail "the leftover Wine was not seen"
SKY_KEEP_STEAM_MINUTES=0 bash "$S" run > "$T/orphan1.txt"
if grep -q 'Steam is still open' "$T/orphan1.txt"; then cat "$T/orphan1.txt"; fail "a leftover helper was taken for an open Steam"; fi
grep -q 'Steam has gone but parts of it were left running' "$T/orphan1.txt" || { cat "$T/orphan1.txt"; fail "the leftovers of Steam were not tidied up"; }
grep -q 'The game is running' "$T/orphan1.txt" || fail "the game did not start after the tidy-up"
if kill -0 "$orphan_helper" 2>/dev/null; then fail "the leftover helper is still running"; fi
kill "$orphan_server" 2>/dev/null || true

echo "-- Steam updating itself is named"
since="$(cat "$SKYWALKER_HOME/logs/last-start")"
echo "[$since] Downloading update (1,024 of 31,823 KB)..." >> "$STEAM/logs/bootstrap_log.txt"
bash "$S" timeline > "$T/selfupdate.txt"
grep -q 'Steam downloaded and installed an update of itself during this start' "$T/selfupdate.txt" || fail "timeline does not name Steam's self-update"
sed -i.bak '$d' "$STEAM/logs/bootstrap_log.txt"
bash "$S" timeline > "$T/selfupdate2.txt"
if grep -q 'update of itself' "$T/selfupdate2.txt"; then fail "timeline names a self-update that did not happen"; fi

echo "-- Steam started ahead of the game"
: > "$FAKE_DIR/calls.txt"
bash "$S" cpu 1 > "$T/cpu0.txt"
grep -q 'Wine is not running' "$T/cpu0.txt" || fail "cpu did not say that Wine is not running"
if bash "$S" prewarm soon > /dev/null 2>&1; then fail "prewarm took a time that is not a number"; fi
bash "$S" prewarm 0.2 > "$T/pre1.txt"
grep -q 'Steam is starting in the background. It closes again in 0.2 minutes' "$T/pre1.txt" || fail "prewarm did not say what it does"
sleep 2
steam_alive || fail "prewarm did not start Steam"
grep -q -e '-silent -nofriendsui -nochatui -cef-disable-gpu$' "$FAKE_DIR/calls.txt" || { cat "$FAKE_DIR/calls.txt"; fail "prewarm did not start Steam alone with the usual options"; }
if grep -q -e '-applaunch' "$FAKE_DIR/calls.txt"; then fail "prewarm started the game"; fi
bash "$S" cpu 1 > "$T/cpu1.txt"
grep -q 'Wine used [0-9.]*% of one processor core over 1 seconds (2 programs)' "$T/cpu1.txt" || { cat "$T/cpu1.txt"; fail "cpu gave no figure for the open Steam"; }
bash "$S" prewarm 0.2 > "$T/pre2.txt"
grep -q 'Steam is already open' "$T/pre2.txt" || fail "a second prewarm did not notice the open Steam"
SKY_KEEP_STEAM_MINUTES=0 bash "$S" run > "$T/pre3.txt"
grep -q 'Steam is still open, so the game starts straight away' "$T/pre3.txt" || fail "run did not use the Steam that prewarm started"
[ "$(grep -c -e '-silent' "$FAKE_DIR/calls.txt")" = 1 ] || fail "Steam was started again for the game"
if steam_alive; then fail "Steam was left open after the game although KEEP_STEAM_MINUTES is 0"; fi
bash "$S" prewarm 0.1 > /dev/null
sleep 2
steam_alive || fail "the second prewarm did not start Steam"
sleep 14
if steam_alive; then fail "an unused prewarmed Steam was not closed after its time"; fi
bash "$S" prewarm 0 > "$T/pre4.txt"
grep -q 'stays open' "$T/pre4.txt" || fail "prewarm 0 did not say that Steam stays open"
[ ! -f "$SKYWALKER_HOME/steam-idle" ] || fail "prewarm 0 set a timer"
bash "$S" stop > /dev/null

echo "-- start at log-in"
printf '#!/bin/bash\necho "$*" >> "$FAKE_DIR/launchctl.txt"\n' > "$T/launchctl"
chmod +x "$T/launchctl"
export SKY_LAUNCHCTL="$T/launchctl"
PL="$HOME/Library/LaunchAgents/io.github.jeswr.skywalker.prewarm.plist"
bash "$S" autostart status | grep -q 'Autostart: off' || fail "autostart is not off to begin with"
if bash "$S" autostart on > /dev/null 2>&1; then fail "autostart on worked without an installed launcher"; fi
cp "$S" "$SKYWALKER_HOME/skywalker.sh"
bash "$S" autostart on > "$T/auto1.txt"
[ -f "$PL" ] || fail "autostart on wrote no log-in item"
grep -q "<string>$SKYWALKER_HOME/skywalker.sh</string>" "$PL" || fail "the log-in item does not run the installed launcher"
grep -q '<string>prewarm</string>' "$PL" || fail "the log-in item does not run prewarm"
grep -q '<key>AbandonProcessGroup</key><true/>' "$PL" || fail "the log-in item would take Steam down with it"
grep -q '<string>Interactive</string>' "$PL" || fail "the log-in item would run Steam throttled"
if command -v plutil >/dev/null 2>&1; then plutil -lint "$PL"; fi
grep -q "bootstrap gui/$(id -u) $PL" "$FAKE_DIR/launchctl.txt" || fail "macOS was not told about the log-in item"
bash "$S" doctor > "$T/auto-doctor.txt"
grep -q 'Autostart:    on' "$T/auto-doctor.txt" || fail "doctor does not show autostart on"
bash "$S" autostart off > /dev/null
[ ! -f "$PL" ] || fail "autostart off left the log-in item"
grep -q "bootout gui/$(id -u)/io.github.jeswr.skywalker.prewarm" "$FAKE_DIR/launchctl.txt" || fail "macOS was not told to drop the log-in item"
rm -f "$SKYWALKER_HOME/skywalker.sh"

echo "-- the game's screen settings are held"
CFG="$(dirname "$SAVES")/PCCONFIG.TXT"
printf 'ScreenWidth 1440\r\nScreenHeight 900\r\nWindowWidth\t1440\r\nWindowHeight\t900\r\nBorderlessWindow 1\r\nScreenSpaceReflections 0\r\nDoFEnabled 0\r\nLanguage en gb\r\n' > "$CFG"
cp "$CFG" "$T/good.txt"
bash "$S" display show > "$T/disp0.txt"
grep -q 'Kept: nothing' "$T/disp0.txt" || fail "display show reports kept settings before any were kept"
bash "$S" display check
cmp -s "$CFG" "$T/good.txt" || fail "the settings file was changed although nothing is kept"
bash "$S" display keep > "$T/disp1.txt"
grep -q '   ScreenWidth 1440' "$T/disp1.txt" || fail "display keep did not list the screen width"
grep -q '   WindowWidth 1440' "$T/disp1.txt" || fail "display keep did not list the window width"
if grep -q 'ScreenSpaceReflections\|DoFEnabled\|Language' "$T/disp1.txt"; then fail "display keep took lines that are not about the screen"; fi
bash "$S" display check > "$T/disp2.txt"
[ ! -s "$T/disp2.txt" ] || fail "an unchanged settings file was reported as changed"
cmp -s "$CFG" "$T/good.txt" || fail "an unchanged settings file was rewritten"
# what an external monitor did on the Mac, plus a graphics line the player changed on purpose
printf 'ScreenWidth 1280\r\nScreenHeight 800\r\nWindowWidth\t1280\r\nWindowHeight\t720\r\nBorderlessWindow 0\r\nScreenSpaceReflections 1\r\nDoFEnabled 0\r\nLanguage en gb\r\n' > "$CFG"
cp "$CFG" "$T/drift.txt"
bash "$S" display check > "$T/disp3.txt"
grep -q 'ScreenWidth 1280 -> 1440' "$T/disp3.txt" || fail "the reset did not say what it changed"
printf 'ScreenWidth 1440\r\nScreenHeight 900\r\nWindowWidth\t1440\r\nWindowHeight\t900\r\nBorderlessWindow 1\r\nScreenSpaceReflections 1\r\nDoFEnabled 0\r\nLanguage en gb\r\n' > "$T/want.txt"
cmp -s "$CFG" "$T/want.txt" || { od -c "$CFG" | head -n 20; fail "the screen lines were not put back exactly (or another line was touched)"; }
[ "$(find "$SKYWALKER_HOME/settings-backups" -name 'PCCONFIG-*.TXT' | wc -l | tr -d ' ')" = 1 ] || fail "no backup was made before the reset"
cmp -s "$(find "$SKYWALKER_HOME/settings-backups" -name 'PCCONFIG-*.TXT')" "$T/drift.txt" || fail "the backup is not the file as it was"
bash "$S" doctor > "$T/disp-doctor.txt"
grep -q 'Display:      kept (ScreenWidth 1440, ScreenHeight 900' "$T/disp-doctor.txt" || fail "doctor does not show the kept screen settings"
# a start does the same check
cp "$T/drift.txt" "$CFG"
sleep 1
SKY_KEEP_STEAM_MINUTES=0 bash "$S" run > "$T/disp-run.txt"
grep -q "screen settings had changed and were put back" "$T/disp-run.txt" || fail "run did not put the screen settings back"
cmp -s "$CFG" "$T/want.txt" || fail "run left the drifted screen settings"
bash "$S" display off > /dev/null
cp "$T/drift.txt" "$CFG"
bash "$S" display check
cmp -s "$CFG" "$T/drift.txt" || fail "display off did not stop the reset"

echo "-- the bottle update that Wine does once per build"
bash "$S" stop > /dev/null
: > "$FAKE_DIR/calls.txt"
bash "$S" update-bottle > "$T/upd0.txt"
[ ! -s "$T/upd0.txt" ] || fail "a bottle update was announced for a build without wine.inf"
mkdir -p "$W/share/wine"
echo inf > "$W/share/wine/wine.inf"
if [ "$(uname -s)" = Darwin ]; then stamp="$(/usr/bin/stat -f %m "$W/share/wine/wine.inf")"; else stamp="$(stat -c %Y "$W/share/wine/wine.inf")"; fi
echo "$stamp" > "$P/.update-timestamp"
bash "$S" update-bottle > "$T/upd1.txt"
[ ! -s "$T/upd1.txt" ] || fail "a bottle update was announced although the bottle matches the build"
[ ! -s "$FAKE_DIR/calls.txt" ] || fail "Wine was started although the bottle matches the build"
echo 12345 > "$P/.update-timestamp"
bash "$S" doctor > "$T/upd-doctor.txt"
grep -q 'Bottle:       still to be updated for this build' "$T/upd-doctor.txt" || fail "doctor does not say that the bottle update is due"
bash "$S" update-bottle > "$T/upd2.txt"
grep -q 'Updating the bottle for fake-1' "$T/upd2.txt" || fail "the bottle update was not announced"
grep -q -x 'cmd /c ver' "$FAKE_DIR/calls.txt" || { cat "$FAKE_DIR/calls.txt"; fail "the bottle update did not start Wine"; }
grep -q 'Wine did not mark the bottle as updated' "$T/upd2.txt" || fail "an update that did not happen was reported as done"
SKY_KEEP_STEAM_MINUTES=0 bash "$S" run > "$T/upd3.txt"
grep -q 'First start with this build: Wine updates the bottle' "$T/upd3.txt" || fail "run did not warn about the bottle update"
echo disable > "$P/.update-timestamp"
bash "$S" update-bottle > "$T/upd4.txt"
[ ! -s "$T/upd4.txt" ] || fail "a bottle with updates switched off was updated"
rm -rf "$W/share" "$P/.update-timestamp"

echo "All launcher checks passed."
