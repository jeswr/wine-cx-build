#!/bin/bash
# Checks a built Wine folder away from Homebrew: the bundled libraries load,
# and Wine can create a prefix and run a console program.
#
# Every attempt is time-limited and the number of processes is capped, because
# a broken build can keep starting processes until the machine runs out. When
# an attempt fails, the script says what was running and tries again with
# tracing, so the log explains the failure.
#
# Usage: selftest.sh <wine folder> [seconds per attempt]
# Logs go to $SELFTEST_OUT (default ./selftest-logs).
set -uo pipefail

W="${1:?usage: selftest.sh <wine folder> [seconds per attempt]}"
W="${W%/}"
LIMIT="${2:-180}"
OUT="${SELFTEST_OUT:-$PWD/selftest-logs}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/selftest.XXXXXX")"
mkdir -p "$OUT"
# Only the package's own libraries and the system's: no Homebrew folders.
export DYLD_FALLBACK_LIBRARY_PATH="$W/lib:/usr/lib"

say() { printf '\n== %s\n' "$*"; }
mine() { ps -axo pid=,ppid=,etime=,command= | grep -F "$W/" | grep -v grep; }
count_mine() { mine | wc -l | tr -d ' '; }

kill_all() {
  WINEPREFIX="$1" "$W/bin/wineserver" -k >/dev/null 2>&1 &
  sleep 3
  pkill -9 -f "$W/" 2>/dev/null
  sleep 1
}

snapshot() {
  local name="$1" main="$2" n newest
  mine > "$OUT/$name.ps"
  n=$(wc -l < "$OUT/$name.ps" | tr -d ' ')
  echo "  $n Wine processes. Most common command lines:"
  sed -E 's/^ *[0-9]+ +[0-9]+ +[^ ]+ +//' "$OUT/$name.ps" | cut -c1-200 | sort | uniq -c | sort -rn | head -n 15
  echo "  First ten (pid, parent, age, command):"
  head -n 10 "$OUT/$name.ps" | cut -c1-220
  if command -v sample >/dev/null 2>&1; then
    newest=$(tail -n 1 "$OUT/$name.ps" | awk '{print $1}')
    for p in "$main" "$newest"; do
      [ -n "$p" ] || continue
      sample "$p" 2 -file "$OUT/$name.sample-$p.txt" >/dev/null 2>&1 || continue
      echo "  Where process $p is waiting:"
      grep -A 45 '^Call graph:' "$OUT/$name.sample-$p.txt" | cut -c1-200
    done
  fi
}

# boot <name> <WINEDEBUG> <WINEDLLOVERRIDES>: a fresh prefix, one console command.
boot() {
  local name="$1" dbg="$2" ovr="$3" pfx="$TMP/prefix-$1" t=0 pid rc
  say "Attempt '$name': WINEDEBUG=$dbg WINEDLLOVERRIDES=$ovr"
  (
    ulimit -u "$CAP" 2>/dev/null
    export WINEPREFIX="$pfx" WINEDEBUG="$dbg" WINEDLLOVERRIDES="$ovr"
    exec "$W/bin/wine" cmd /c "echo selftest-ok" </dev/null >"$OUT/$name.out" 2>"$OUT/$name.err"
  ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$t" -lt "$LIMIT" ]; do
    sleep 5
    t=$((t + 5))
    if [ $((t % 30)) = 0 ]; then echo "  ${t}s: $(count_mine) Wine processes"; fi
    # a runaway trace must not fill the disk
    if [ "$(wc -c < "$OUT/$name.err" | tr -d ' ')" -gt 50000000 ]; then
      echo "  Stopping early: over 50 MB of messages."
      break
    fi
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "  Still running after ${t}s."
    snapshot "$name" "$pid"
    kill_all "$pfx"
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rc=124
  else
    wait "$pid"
    rc=$?
    echo "  Finished in about ${t}s with exit code $rc; $(count_mine) Wine processes left."
    kill_all "$pfx"
  fi
  sleep 1
  echo "  Output: $(tr -d '\r' < "$OUT/$name.out" | head -n 5)"
  echo "  Messages: $(wc -l < "$OUT/$name.err" | tr -d ' ') lines"
  if [ "$(wc -l < "$OUT/$name.err" | tr -d ' ')" -gt 140 ]; then
    head -n 80 "$OUT/$name.err" | cut -c1-300
    echo "  [...]"
    tail -n 60 "$OUT/$name.err" | cut -c1-300
  else
    cut -c1-300 "$OUT/$name.err"
  fi
  echo "  Prefix: $(ls "$pfx" 2>/dev/null | tr '\n' ' '); $(ls "$pfx/drive_c/windows/system32" 2>/dev/null | wc -l | tr -d ' ') files in system32"
  [ "$rc" = 0 ] && grep -q 'selftest-ok' "$OUT/$name.out" && [ -f "$pfx/drive_c/windows/system32/ntdll.dll" ]
}

say "Machine"
sw_vers 2>/dev/null | tr '\n' ' '
echo
uname -m
echo "Processes for this user: $(ps -U "$(id -u)" | wc -l | tr -d ' '); limit $(ulimit -u); system limit $(sysctl -n kern.maxprocperuid 2>/dev/null)"
CAP=$(( $(ps -U "$(id -u)" | wc -l | tr -d ' ') + 300 ))
echo "Process cap for the attempts: $CAP"

say "Bundled libraries"
# One process per library, each with a deadline: a library that never finishes
# loading would otherwise stall the whole check without a word.
cat > "$TMP/dl.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv)
{
    void *h;
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("%s: ", argv[1]);
    h = dlopen(argv[1], RTLD_NOW);
    printf("%s\n", h ? "ok" : dlerror());
    _exit(h ? 0 : 1);
}
EOF
/usr/bin/cc -arch x86_64 -o "$TMP/dl" "$TMP/dl.c" || exit 1
libs_ok=1
for lib in libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib libMoltenVK.dylib; do
  "$TMP/dl" "$lib" &
  lp=$!
  t=0
  while kill -0 "$lp" 2>/dev/null && [ "$t" -lt 30 ]; do
    sleep 1
    t=$((t + 1))
  done
  if kill -0 "$lp" 2>/dev/null; then
    echo
    echo "  $lib is still loading after 30s. Where it is waiting:"
    if command -v sample >/dev/null 2>&1; then
      sample "$lp" 2 -file "$OUT/dl-$lib.sample.txt" >/dev/null 2>&1
      grep -A 70 '^Call graph:' "$OUT/dl-$lib.sample.txt" | cut -c1-220
    fi
    kill -9 "$lp" 2>/dev/null
    wait "$lp" 2>/dev/null
    libs_ok=0
  elif ! wait "$lp"; then
    libs_ok=0
  fi
done
if [ "$libs_ok" != 1 ]; then echo "FAILED: a bundled library does not load from $W/lib"; fi

say "Version"
"$W/bin/wine" --version </dev/null &
vp=$!
( sleep 20; kill -9 "$vp" 2>/dev/null ) &
wait "$vp" || echo "wine --version did not finish (exit code $?)"

ok=0
if boot plain "fixme-all" "mscoree,mshtml=d"; then
  ok=1
else
  # Not a pass, whatever these show: they are here to explain the failure.
  boot trace "fixme-all,+process,+loaddll" "mscoree,mshtml=d;winedbg.exe=d" || true
  boot nodriver "fixme-all,+process" "mscoree,mshtml=d;winedbg.exe=d;winemac.drv=d" || true
fi

if [ "$libs_ok" != 1 ]; then ok=0; fi
if [ "$ok" = 1 ] && grep -qi 'cannot find the FreeType' "$OUT/plain.err"; then
  echo "FAILED: Wine could not load FreeType from the bundled libraries"
  ok=0
fi
rm -rf "$TMP"
if [ "$ok" = 1 ]; then
  say "Self-test passed"
  exit 0
fi
say "Self-test FAILED"
exit 1
