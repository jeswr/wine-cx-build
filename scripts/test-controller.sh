#!/bin/bash
# Cloud check for the PlayStation controller setup (no controller is attached
# to the runner, so this proves the software side only):
#  1. the exact registry command Jesse runs on the Mac works through the launcher,
#  2. Wine's controller driver reads it ("disabling hidraw" for Sony, 054c),
#  3. the SDL controller library loads and starts inside Wine (the SDL2 -> SDL3
#     trap once aborted winedevice.exe),
#  4. Wine's "Game Controllers" panel (joy.cpl) opens a window.
# Every wait has a deadline. Logs go to selftest-logs/.
set -u
L="$SKYWALKER_HOME/skywalker.sh"
OUT="${OUT:-selftest-logs}"
mkdir -p "$OUT"
fail=0

deadline() {   # deadline <seconds> <cmd...>: run, kill if it overruns
  local secs="$1"; shift
  "$@" &
  local p=$! t=0
  while kill -0 "$p" 2>/dev/null && [ "$t" -lt "$secs" ]; do sleep 2; t=$((t + 2)); done
  if kill -0 "$p" 2>/dev/null; then echo "  (still running after ${secs}s; stopped)"; kill -9 "$p" 2>/dev/null; return 124; fi
  wait "$p"
}

echo "== 1. registry setting, exactly as typed on the Mac"
deadline 240 /bin/bash "$L" wine reg add 'HKLM\System\CurrentControlSet\Services\WineBus\Devices\054c' /v Hidraw /t REG_DWORD /d 0 /f > "$OUT/pad-reg.log" 2>&1
cat "$OUT/pad-reg.log"
deadline 60 /bin/bash "$L" wine reg query 'HKLM\System\CurrentControlSet\Services\WineBus\Devices\054c' > "$OUT/pad-query.log" 2>&1
cat "$OUT/pad-query.log"
grep -q 'Hidraw.*REG_DWORD.*0x0' "$OUT/pad-query.log" || { echo "FAIL: the setting is not in the bottle"; fail=1; }
/bin/bash "$L" stop > /dev/null 2>&1

echo "== 2-4. a fresh Wine session opens the Game Controllers panel"
WINEDEBUG=+hid,+plugplay /bin/bash "$L" wine control joy.cpl > "$OUT/pad-joycpl.log" 2>&1 &
found=0; t=0
while [ "$t" -lt 120 ]; do
  sleep 5; t=$((t + 5))
  if /bin/bash "$L" windows > "$OUT/pad-windows.txt" 2>&1 \
     && awk -F '\t' '{ split($2, d, "x"); if (d[1] >= 200 && d[2] >= 100) ok = 1 } END { exit !ok }' "$OUT/pad-windows.txt"; then
    found=1; break
  fi
done
echo "After ${t}s:"; cat "$OUT/pad-windows.txt"
sleep 3
screencapture -x "$OUT/pad-joycpl.png" || echo "screencapture failed"
/bin/bash "$L" stop > /dev/null 2>&1
sleep 2

H="$OUT/pad-joycpl.log"
echo "-- driver lines:"
grep -E 'hidraw|main loop|bus init|could not|SDL|creating|ignoring' "$H" | cut -c1-200 | head -40
grep -q '054c/[0-9a-f]*: disabling hidraw' "$H" || { echo "FAIL: the driver did not read the Sony setting"; fail=1; }
grep -q 'L"SDL" main loop started' "$H" || { echo "FAIL: the SDL bus never started"; fail=1; }
if grep -q -E 'L"SDL" bus init returned|could not load libSDL|could not init SDL|could not find symbol' "$H"; then echo "FAIL: SDL did not load or start"; fail=1; fi
if grep -q -E 'EXCEPTION_WINE_ASSERTION' "$H"; then echo "FAIL: a native library aborted"; fail=1; fi
[ "$found" = 1 ] || { echo "FAIL: the Game Controllers window did not appear"; fail=1; }
[ "$fail" = 0 ] && echo "PASS: controller setup works in Wine on the runner"
exit "$fail"
