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
bash "$S" doctor | grep -q "Game running: yes" || { kill "$fake"; fail "running game not detected"; }
kill "$fake" 2>/dev/null || true

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
grep -q 'source=game.exe\[4242:1a2b\]' "$T/summary.txt" || fail "summary picked the wrong process"
grep -q 'frames=7800 seconds=130 avg_fps=60.0 low1_fps=17.9 avg_gpu_ms=8.00' "$T/summary.txt" || fail "summary numbers are wrong"
grep -q 'minute  1:  60.0 fps, slowest 1%  17.9 fps' "$T/summary.txt" || fail "per-minute numbers are wrong"
if bash "$S" summary /dev/null >/dev/null; then fail "empty log should not summarise"; fi

echo "All launcher checks passed."
