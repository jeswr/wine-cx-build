#!/bin/bash
# Checks "skywalker.sh graphics split" on a CI Mac, after "skywalker.sh install":
# a program in the game's folder must get DXMT's Direct3D 11, and a program
# anywhere else must get Wine's own.
# Usage: test-split.sh <d3dtest.exe>   (built from scripts/d3dtest.c;
#        SKYWALKER_HOME and SKY_PREFIX set as for the install)
set -uo pipefail
SKY="$SKYWALKER_HOME/skywalker.sh"
EXE="$1"
OUT="${SPLIT_OUT:-$PWD/selftest-logs}"
STEAM="$SKY_PREFIX/drive_c/Program Files (x86)/Steam"
GAME="Fake Game"
fail=0
mkdir -p "$OUT"

# Runs Wine with a deadline, so a hang cannot hold the job. $1 = output file.
run() {
  local out="$1" t=0 pid
  shift
  WINEDEBUG="${TRACE:-fixme-all}" /bin/bash "$SKY" wine "$@" > "$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$t" -lt 180 ]; do sleep 2; t=$((t + 2)); done
  if kill -0 "$pid" 2>/dev/null; then
    echo "FAIL: still running after 180 s: $*"
    kill -9 "$pid" 2>/dev/null
    /bin/bash "$SKY" stop > /dev/null 2>&1
    fail=1
  fi
  /usr/bin/tr -d '\r' < "$out" > "$out.tmp" && mv "$out.tmp" "$out"
  /usr/bin/grep -E '^(d3d11|dxgi|winemetal|wined3d)\.dll: |^device: ' "$out" | sed 's/^/    /'
}
expect() {  # $1 = file, $2 = fixed text that must be there, $3 = what it means
  if /usr/bin/grep -q -i -F -e "$2" "$1"; then echo "  ok: $3"; else echo "FAIL: $3"; fail=1; fi
}

/bin/bash "$SKY" stop > /dev/null 2>&1 || true
if [ ! -d "$SKY_PREFIX/drive_c/windows" ]; then
  echo "== making the bottle"
  run "$OUT/split-boot.txt" wineboot -u
  /bin/bash "$SKY" stop > /dev/null 2>&1 || true
fi
mkdir -p "$STEAM/steamapps/common/$GAME" "$SKY_PREFIX/drive_c/other"
[ -f "$STEAM/steam.exe" ] || touch "$STEAM/steam.exe"
printf '"AppState"\n{\n\t"appid"\t\t"920210"\n\t"installdir"\t\t"%s"\n}\n' "$GAME" > "$STEAM/steamapps/appmanifest_920210.acf"
cp "$EXE" "$STEAM/steamapps/common/$GAME/d3dtest.exe"
cp "$EXE" "$SKY_PREFIX/drive_c/other/d3dtest.exe"
IN_GAME='C:\Program Files (x86)\Steam\steamapps\common\Fake Game\d3dtest.exe'
ELSEWHERE='C:\other\d3dtest.exe'

echo "== split graphics"
/bin/bash "$SKY" graphics split || fail=1
ls -l "$STEAM/steamapps/common/$GAME"
echo "  a program in the game's folder:"
run "$OUT/split-game.txt" "$IN_GAME"
expect "$OUT/split-game.txt" 'd3d11.dll: C:\Program Files (x86)\Steam\steamapps\common\Fake Game\d3d11.dll' "the game loads the d3d11.dll in its own folder"
expect "$OUT/split-game.txt" 'dxgi.dll: C:\Program Files (x86)\Steam\steamapps\common\Fake Game\dxgi.dll' "the game loads the dxgi.dll in its own folder"
expect "$OUT/split-game.txt" 'winemetal.dll: C:\windows\system32\winemetal.dll' "the game's Direct3D is DXMT (winemetal came with it)"
expect "$OUT/split-game.txt" 'wined3d.dll: (not loaded)' "Wine's own renderer stays out of the game"
echo "  a program anywhere else:"
run "$OUT/split-other.txt" "$ELSEWHERE"
expect "$OUT/split-other.txt" 'd3d11.dll: C:\windows\system32\d3d11.dll' "other programs load Wine's d3d11.dll"
expect "$OUT/split-other.txt" 'wined3d.dll: C:\windows\system32\wined3d.dll' "other programs get Wine's own renderer"
expect "$OUT/split-other.txt" 'winemetal.dll: (not loaded)' "DXMT stays out of other programs"

echo "== for information: creating a Direct3D 11 device each way (the CI Mac's graphics may not allow it)"
run "$OUT/split-game-device.txt" "$IN_GAME" device
run "$OUT/split-other-device.txt" "$ELSEWHERE" device

echo "== wine graphics: nothing of DXMT is left with the game"
/bin/bash "$SKY" stop > /dev/null 2>&1 || true
/bin/bash "$SKY" graphics wine || fail=1
run "$OUT/split-off.txt" "$IN_GAME"
expect "$OUT/split-off.txt" 'd3d11.dll: C:\windows\system32\d3d11.dll' "after leaving split, the game loads Wine's d3d11.dll"
expect "$OUT/split-off.txt" 'winemetal.dll: (not loaded)' "after leaving split, DXMT is gone from the game"

/bin/bash "$SKY" stop > /dev/null 2>&1 || true
/bin/bash "$SKY" graphics split || fail=1
/bin/bash "$SKY" doctor | /usr/bin/grep -E 'Graphics|Processes'
if [ "$fail" = 0 ]; then echo "Split graphics checks passed."; else echo "Split graphics checks FAILED."; fi
exit "$fail"
