#!/bin/bash
# Checks the launcher's crash-loop guards on a CI Mac, after "skywalker.sh install".
#  1. a crashing Windows program exits without starting winedbg, and leaves no pile of processes
#  2. the watchdog stops Wine when its process count passes the limit
# Usage: test-guards.sh <crash.exe>    (SKYWALKER_HOME etc. set as for the install)
set -uo pipefail
SKY="$SKYWALKER_HOME/skywalker.sh"
CRASH="$1"
fail=0
count() { /bin/ps -axww -o command= | /usr/bin/grep -c -E -e '^[A-Za-z]:\\' -e "^$SKYWALKER_HOME/wine/" || true; }
dbg()   { /bin/ps -axww -o command= | /usr/bin/grep -c -i -e 'winedbg' -e 'conhost' | tr -d ' ' || true; }
wait_for_zero() { local t=0; while [ "$(count)" != 0 ] && [ "$t" -lt "$1" ]; do sleep 2; t=$((t + 2)); done; [ "$(count)" = 0 ]; }

echo "== 1. crash test (5 crashes)"
max=0
for i in 1 2 3 4 5; do
  /bin/bash "$SKY" wine "$CRASH" > /dev/null 2>&1 &
  pid=$!
  t=0
  while kill -0 "$pid" 2>/dev/null && [ "$t" -lt 120 ]; do
    sleep 2; t=$((t + 2))
    n="$(count)"; [ "$n" -gt "$max" ] && max="$n"
    d="$(dbg)"; if [ "$d" -gt 0 ]; then echo "FAIL: winedbg/conhost running after crash $i ($d)"; fail=1; fi
  done
  if kill -0 "$pid" 2>/dev/null; then echo "FAIL: crash $i did not exit within 120 s"; fail=1; kill -9 "$pid"; fi
done
echo "most Wine processes seen during crash test: $max"
[ "$max" -le 40 ] || { echo "FAIL: too many Wine processes during crash test"; fail=1; }
/bin/bash "$SKY" stop > /dev/null 2>&1 || true
wait_for_zero 60 || { echo "FAIL: Wine processes left after stop: $(count)"; /bin/ps -axww -o pid=,command= | grep -E '^ *[0-9]+ ([A-Za-z]:\\|'"$SKYWALKER_HOME"')' ; fail=1; }

echo "== 2. watchdog test (limit 3)"
rm -f "$SKYWALKER_HOME/logs/watchdog.log"
SKY_MAX_WINE_PROCS=3 /bin/bash "$SKY" wine cmd /c "ping -n 120 127.0.0.1" > /dev/null 2>&1 &
pid=$!
if wait_for_zero 90 && [ "$(sleep 5; count)" = 0 ]; then
  echo "watchdog stopped Wine"
else
  echo "FAIL: watchdog did not stop Wine: $(count) processes"; fail=1
  /bin/bash "$SKY" stop > /dev/null 2>&1 || true
fi
cat "$SKYWALKER_HOME/logs/watchdog.log" 2>/dev/null || { echo "FAIL: no watchdog log"; fail=1; }
kill -9 "$pid" 2>/dev/null || true

[ "$fail" = 0 ] && echo "== guards OK"
exit "$fail"
