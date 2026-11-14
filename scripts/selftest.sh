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
# Every process started from this Wine folder: pid, parent, cpu, age, command.
# Wine renames its child processes after the Windows program (C:\windows\...),
# and on a build machine nothing else is Wine, so count those there too.
mine_pids() {
  { ps -axo pid=,comm=; ps -axo pid=,command=; } | awk -v w="$W/" -v ci="${CI:-}" \
    'index($0, w) || (ci != "" && $2 ~ /^[A-Za-z]:\\/) {print $1}' | sort -un
}
mine() {
  local p
  for p in $(mine_pids); do ps -p "$p" -o pid=,ppid=,pcpu=,etime=,command= 2>/dev/null; done
}
count_mine() { mine_pids | wc -l | tr -d ' '; }

kill_all() {
  local p
  WINEPREFIX="$1" "$W/bin/wineserver" -k >/dev/null 2>&1 &
  sleep 3
  for p in $(mine_pids); do kill -9 "$p" 2>/dev/null; done
  # On a build machine nothing else is Wine, so sweep up by name as well.
  if [ -n "${CI:-}" ]; then
    pkill -9 -x wine 2>/dev/null
    pkill -9 -x wine-preloader 2>/dev/null
    pkill -9 -x wineserver 2>/dev/null
  fi
  sleep 1
}

snapshot() {
  local name="$1" n p shown=0
  mine > "$OUT/$name.ps"
  n=$(wc -l < "$OUT/$name.ps" | tr -d ' ')
  echo "  $n Wine processes (pid, parent, cpu, age, command):"
  head -n 25 "$OUT/$name.ps" | cut -c1-220
  if [ "$n" -lt 3 ]; then
    echo "  Everything that looks like Wine:"
    ps -axo pid=,ppid=,pcpu=,comm= | grep -iE 'wine|\.exe' | grep -v grep | head -n 25 | cut -c1-220
  fi
  command -v sample >/dev/null 2>&1 || return 0
  # busiest first; the idle ones are usually just waiting for the busy one
  for p in $(sort -k3,3 -rn "$OUT/$name.ps" | grep -v wineserver | awk '{print $1}' | head -n 6); do
    sample "$p" 1 -file "$OUT/$name.sample-$p.txt" >/dev/null 2>&1 || continue
    vmmap "$p" > "$OUT/$name.vmmap-$p.txt" 2>&1 || true
    if [ "$shown" -lt 3 ]; then
      echo "  Where process $p is ($(awk -v p="$p" '$1 == p {print $5, $6, $7}' "$OUT/$name.ps")):"
      grep -A 40 '^Call graph:' "$OUT/$name.sample-$p.txt" | cut -c1-200
      shown=$((shown + 1))
    fi
  done
}

# The interesting part of a long trace: what led up to the first error.
excerpt() {
  local f="$1" first
  first=$(grep -n -m 1 'err:' "$f" | cut -d: -f1)
  if [ -z "$first" ]; then
    head -n 3000 "$f" | uniq -f 1 | tail -n 60 | cut -c1-300
    return
  fi
  if [ "$first" -gt 70 ]; then echo "  [... $((first - 70)) lines before this]"; fi
  sed -n "$((first > 70 ? first - 70 : 1)),$((first + 40))p" "$f" | uniq -c -f 1 | sed -E 's/^ +1 //' | cut -c1-300
}

# boot <name> <WINEDEBUG> <WINEDLLOVERRIDES> [library path]: a fresh prefix, one console command.
boot() {
  local name="$1" dbg="$2" ovr="$3" libs="${4:-$DYLD_FALLBACK_LIBRARY_PATH}" pfx="$TMP/prefix-$1" t=0 pid rc
  say "Attempt '$name': WINEDEBUG=$dbg WINEDLLOVERRIDES=$ovr libraries=$libs"
  (
    ulimit -u "$CAP" 2>/dev/null
    export WINEPREFIX="$pfx" WINEDEBUG="$dbg" WINEDLLOVERRIDES="$ovr" DYLD_FALLBACK_LIBRARY_PATH="$libs"
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
    snapshot "$name"
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
    excerpt "$OUT/$name.err"
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
for lib in libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib; do
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

OVR="mscoree,mshtml=d"
ok=0
if boot plain "fixme-all" "$OVR"; then
  ok=1
else
  # Not a pass, whatever these show: they are here to explain the failure.
  # The second one tells a fault in Wine from a fault in a bundled library.
  boot trace "fixme-all,+seh,+process,+loaddll" "$OVR;winedbg.exe=d" || true
  boot nolibs "fixme-all" "$OVR;winedbg.exe=d" "/nonexistent:/usr/lib" || true
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
