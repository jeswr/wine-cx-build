#!/bin/bash
# Dry run, on a CI Mac, of the update that moves a Mac from a build that had
# Apple's D3DMetal put in by hand to a new build with "graphics d3dmetal".
# Apple's files cannot be used here, so stand-ins with the same names and
# layout take their place: this checks the launcher's file handling on a real
# build and a real macOS, not D3DMetal itself.
# Usage: test-d3dmetal-install.sh <new tag> [previous tag]
#        (SKYWALKER_HOME, SKYWALKER_APP, SKY_PREFIX and SKY_GPTK_DIR set by the caller)
set -uo pipefail
NEW="$1"
OLD="${2:-wine-cx-26.3.0-patched-6}"
SRC="$(cd "$(dirname "$0")" && pwd)/skywalker.sh"
SKY="$SKYWALKER_HOME/skywalker.sh"
WINES="$SKYWALKER_HOME/wine"
OUT="${D3DM_OUT:-$PWD/selftest-logs}"
fail=0
mkdir -p "$OUT"

ok() { echo "  ok: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
check() {  # $1 = what it means, rest = a test command
  local what="$1"
  shift
  if "$@"; then ok "$what"; else bad "$what"; fi
}
has_line() { /usr/bin/grep -q -F -e "$2" "$1"; }

echo "== stand-in for Apple's toolkit, laid out as on the Mac"
GL="$SKY_GPTK_DIR/Game Porting Toolkit.app/Contents/Resources/wine/lib"
mkdir -p "$GL/external/D3DMetal.framework/Versions/A/Resources" "$GL/wine/x86_64-windows" "$GL/wine/x86_64-unix"
echo "stand-in libd3dshared" > "$GL/external/libd3dshared.dylib"
echo "stand-in framework" > "$GL/external/D3DMetal.framework/Versions/A/D3DMetal"
ln -s A "$GL/external/D3DMetal.framework/Versions/Current"
ln -s Versions/Current/D3DMetal "$GL/external/D3DMetal.framework/D3DMetal"
for d in d3d11 dxgi d3d12 d3d10core nvapi64 atidxx64 nvngx; do echo "stand-in $d" > "$GL/wine/x86_64-windows/$d.dll"; done
for d in d3d11 dxgi d3d12 d3d10 atidxx64 nvapi64 nvngx; do ln -s ../../external/libd3dshared.dylib "$GL/wine/x86_64-unix/$d.so"; done

echo "== the state of the Mac before the update: $OLD, switched to Wine's own graphics, cloned, Apple's files added by hand"
mkdir -p "$SKYWALKER_HOME"
cp "$SRC" "$SKY"
# the old build goes in while Apple's files are out of sight, as it did on the Mac
SKY_GPTK_DIR="$SKY_GPTK_DIR.none" /bin/bash "$SKY" install "$OLD" > "$OUT/d3dm-install-old.txt" 2>&1 || { tail -n 20 "$OUT/d3dm-install-old.txt"; echo "FAIL: installing $OLD"; exit 1; }
SKY_GPTK_DIR="$SKY_GPTK_DIR.none" /bin/bash "$SKY" graphics wine > /dev/null 2>&1
HAND="$OLD-d3dmetal"
/bin/cp -cR "$WINES/$OLD" "$WINES/$HAND" 2>/dev/null || /bin/cp -R "$WINES/$OLD" "$WINES/$HAND"
mkdir -p "$WINES/$HAND/gptk-orig"
/bin/cp -R "$GL/external" "$WINES/$HAND/lib/external"
for d in d3d11 dxgi d3d12 d3d10core; do
  [ -f "$WINES/$HAND/lib/wine/x86_64-windows/$d.dll" ] && mv "$WINES/$HAND/lib/wine/x86_64-windows/$d.dll" "$WINES/$HAND/gptk-orig/"
  cp "$GL/wine/x86_64-windows/$d.dll" "$WINES/$HAND/lib/wine/x86_64-windows/$d.dll"
done
for d in d3d11 dxgi d3d12 d3d10 atidxx64 nvapi64; do
  rm -f "$WINES/$HAND/lib/wine/x86_64-unix/$d.so"
  ln -s ../../external/libd3dshared.dylib "$WINES/$HAND/lib/wine/x86_64-unix/$d.so"
done
ln -sfn "$HAND" "$WINES/current"
# the bottle has been used by that build, as on the Mac
t0="$(date +%s)"
/bin/bash "$SKY" update-bottle > "$OUT/d3dm-bottle-old.txt" 2>&1
sed 's/^/    /' "$OUT/d3dm-bottle-old.txt"
echo "    (bottle brought to the hand-made build in $(( $(date +%s) - t0 )) s)"
/bin/bash "$SKY" doctor > "$OUT/d3dm-doctor-before.txt" 2>&1
/usr/bin/grep -E 'Build in use|Graphics|D3DMetal' "$OUT/d3dm-doctor-before.txt" | sed 's/^/    /'
check "before the update the hand-made build is in use" has_line "$OUT/d3dm-doctor-before.txt" "$HAND"

echo "== the update, as it will be run on the Mac: new script, stop, install $NEW, doctor"
cp "$SRC" "$SKY"
/bin/bash "$SKY" stop > /dev/null 2>&1 || true
/bin/bash "$SKY" install "$NEW" > "$OUT/d3dm-install-new.txt" 2>&1 || { tail -n 20 "$OUT/d3dm-install-new.txt"; bad "installing $NEW"; }
tail -n 6 "$OUT/d3dm-install-new.txt" | sed 's/^/    /'
/bin/bash "$SKY" doctor > "$OUT/d3dm-doctor-after.txt" 2>&1
/usr/bin/grep -E 'Build in use|Graphics|D3DMetal|Windows side|Unix side|Framework|Windows DLLs' "$OUT/d3dm-doctor-after.txt" | cut -c1-220 | sed 's/^/    /'
N="$WINES/$NEW"
check "the new build is in use" has_line "$OUT/d3dm-doctor-after.txt" "Build in use: $NEW"
check "install said that it updates the bottle" has_line "$OUT/d3dm-install-new.txt" "Updating the bottle for $NEW"
check "install finished the bottle update" has_line "$OUT/d3dm-install-new.txt" "The bottle is up to date"
/usr/bin/grep -F "The bottle is up to date" "$OUT/d3dm-install-new.txt" | sed 's/^/    /'
check "the bottle carries the new build's mark" test "$(tr -d '[:space:]' < "$SKY_PREFIX/.update-timestamp")" = "$(/usr/bin/stat -f %m "$N/share/wine/wine.inf")"
if has_line "$OUT/d3dm-doctor-after.txt" "still to be updated"; then bad "doctor says the bottle update is still due"; else ok "doctor sees no bottle update left to do"; fi
check "doctor says Graphics: d3dmetal" has_line "$OUT/d3dm-doctor-after.txt" "Graphics:     d3dmetal"
for d in d3d11 dxgi d3d12 d3d10core; do
  check "Apple's $d.dll is in the new build" has_line "$N/lib/wine/x86_64-windows/$d.dll" "stand-in $d"
done
for d in d3d11 dxgi d3d12 d3d10 atidxx64 nvapi64; do
  check "$d.so is a link that reaches libd3dshared" has_line "$N/lib/wine/x86_64-unix/$d.so" "stand-in libd3dshared"
  [ "$(readlink "$N/lib/wine/x86_64-unix/$d.so")" = ../../external/libd3dshared.dylib ] || bad "$d.so points to $(readlink "$N/lib/wine/x86_64-unix/$d.so")"
done
check "the framework came along with its links" has_line "$N/lib/external/D3DMetal.framework/D3DMetal" "stand-in framework"
check "Wine's own 64-bit d3d11.dll is kept aside" /usr/bin/cmp -s "$N/d3dmetal-saved/x86_64-windows/d3d11.dll" "$N/orig-dlls/x86_64-windows/d3d11.dll"
check "Wine's 32-bit d3d11.dll is untouched" /usr/bin/cmp -s "$N/lib/wine/i386-windows/d3d11.dll" "$N/orig-dlls/i386-windows/d3d11.dll"
if [ -e "$N/lib/wine/x86_64-windows/nvngx.dll" ] && has_line "$N/lib/wine/x86_64-windows/nvngx.dll" "stand-in"; then bad "a file outside the proven set was copied"; else ok "only the proven set of files was copied"; fi
check "the hand-made build is untouched" has_line "$WINES/$HAND/lib/wine/x86_64-windows/d3d11.dll" "stand-in d3d11"
check "the previous build is remembered for rollback" test "$(basename "$(readlink "$WINES/previous")")" = "$HAND"
echo "    files noted as replaced: $(tr '\n' ' ' < "$N/d3dmetal-files")"

echo "== Wine still starts with the files in place (nothing here uses Direct3D)"
/bin/bash "$SKY" wine cmd /c "echo d3dm-wine-ok" > "$OUT/d3dm-wine.txt" 2> "$OUT/d3dm-wine.err" &
pid=$!
t=0
while kill -0 "$pid" 2>/dev/null && [ "$t" -lt 240 ]; do sleep 1; t=$((t + 1)); done
echo "    (the first Wine program after the update took about ${t}s)"
if [ "$t" -gt 60 ]; then bad "the first start after install still paid for a bottle update"; fi
if kill -0 "$pid" 2>/dev/null; then bad "Wine did not finish within ${t}s"; kill -9 "$pid" 2>/dev/null; fi
/bin/bash "$SKY" stop > /dev/null 2>&1 || true
check "Wine ran a console program" has_line "$OUT/d3dm-wine.txt" "d3dm-wine-ok"
tail -n 5 "$OUT/d3dm-wine.err" | cut -c1-200 | sed 's/^/    /'

echo "== rollback goes to the hand-made build and back"
/bin/bash "$SKY" rollback > /dev/null 2>&1
check "rollback returns to the hand-made build" test "$(basename "$(readlink "$WINES/current")")" = "$HAND"
/bin/bash "$SKY" rollback > /dev/null 2>&1
check "a second rollback returns to the new build" test "$(basename "$(readlink "$WINES/current")")" = "$NEW"
/bin/bash "$SKY" doctor > "$OUT/d3dm-doctor-back.txt" 2>&1
check "the new build is still on d3dmetal" has_line "$OUT/d3dm-doctor-back.txt" "Graphics:     d3dmetal"

echo "== installing the same build again changes nothing"
/bin/bash "$SKY" install "$NEW" > "$OUT/d3dm-install-again.txt" 2>&1 || bad "installing $NEW a second time"
check "still d3dmetal" test "$(cat "$N/GRAPHICS")" = d3dmetal
if has_line "$OUT/d3dm-install-again.txt" "Updating the bottle"; then bad "the bottle was updated a second time"; else ok "no second bottle update"; fi
check "Apple's d3d11.dll still in place" has_line "$N/lib/wine/x86_64-windows/d3d11.dll" "stand-in d3d11"

echo "== leaving d3dmetal puts the build back as it was"
/bin/bash "$SKY" graphics split > "$OUT/d3dm-split.txt" 2>&1 || { cat "$OUT/d3dm-split.txt"; bad "graphics split"; }
for d in d3d11 dxgi d3d10core; do
  check "Wine's own $d.dll is back" /usr/bin/cmp -s "$N/lib/wine/x86_64-windows/$d.dll" "$N/orig-dlls/x86_64-windows/$d.dll"
done
for f in lib/external d3dmetal-saved d3dmetal-files lib/wine/x86_64-unix/nvapi64.so lib/wine/x86_64-unix/atidxx64.so; do
  if [ -e "$N/$f" ] || [ -L "$N/$f" ]; then bad "$f is still in the build"; else ok "$f is gone"; fi
done
n="$(find "$N/lib/wine/" -name '*.dll' | wc -l | tr -d ' ')"
echo "    Windows DLLs in the build now: $n"
check "the toolkit folder itself was never changed" has_line "$GL/wine/x86_64-windows/d3d11.dll" "stand-in d3d11"

if [ "$fail" = 0 ]; then echo "D3DMetal install dry run passed."; else echo "D3DMetal install dry run FAILED."; fi
exit "$fail"
