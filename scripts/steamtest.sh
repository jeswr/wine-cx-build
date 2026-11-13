#!/bin/bash
# Installs Steam (no sign-in) into a fresh bottle on a CI Mac, starts it through
# the launcher and records what reaches the screen. For finding out why Steam's
# windows stay blank with this build; it is not part of the normal checks.
#
# Usage: steamtest.sh <minutes to watch> [options for Steam...]
# Needs: "skywalker.sh install" done, SKYWALKER_HOME and SKY_PREFIX set.
# Optional: GRAPHICS=split|dxmt|wine (default wine), TRACE=<WINEDEBUG value> (default fixme-all),
#           FIRST_TRACE=<WINEDEBUG value for the first start, which downloads Steam's update>,
#           STEAMTEST_OUT=<folder for logs and screenshots> (default ./steam-logs)
# Written for the stock /bin/bash 3.2 on macOS.
set -uo pipefail

MINUTES="${1:?usage: steamtest.sh <minutes> [steam options]}"
shift
L="$SKYWALKER_HOME/skywalker.sh"
OUT="${STEAMTEST_OUT:-$PWD/steam-logs}"
GRAPHICS="${GRAPHICS:-wine}"
TRACE="${TRACE:-fixme-all}"
FIRST_TRACE="${FIRST_TRACE:-fixme-all}"
STEAM_DIR="$SKY_PREFIX/drive_c/Program Files (x86)/Steam"
mkdir -p "$OUT"

note() { echo "[$(date +%H:%M:%S)] $*"; }

# Runs a command with a deadline. $1 = seconds, rest = command.
with_deadline() {
  local limit="$1" t=0 pid
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$t" -lt "$limit" ]; do sleep 5; t=$((t + 5)); done
  if kill -0 "$pid" 2>/dev/null; then
    note "still running after ${limit}s; stopping it"
    kill -9 "$pid" 2>/dev/null
    return 124
  fi
  wait "$pid"
}

note "machine: $(sw_vers -productVersion) $(uname -m); graphics=$GRAPHICS; trace=$TRACE; steam options: $*"
if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  note "This machine cannot run Intel programs (no Rosetta); nothing to test."
  exit 0
fi

note "downloading Valve's installer"
curl -fL --retry 3 -sS -o "$OUT/SteamSetup.exe" "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe" || exit 1
ls -l "$OUT/SteamSetup.exe"
shasum -a 256 "$OUT/SteamSetup.exe"

note "installing Steam silently (this also creates the bottle)"
WINEDEBUG=fixme-all with_deadline 420 /bin/bash "$L" wine "$OUT/SteamSetup.exe" /S > "$OUT/install.log" 2>&1
note "installer finished with $?"
/bin/bash "$L" stop > /dev/null 2>&1 || true
rm -f "$OUT/SteamSetup.exe"
if [ ! -f "$STEAM_DIR/steam.exe" ] && [ ! -f "$STEAM_DIR/Steam.exe" ]; then
  note "Steam was not installed"
  tail -n 40 "$OUT/install.log"
  ls "$SKY_PREFIX/drive_c/Program Files (x86)" 2>/dev/null
  exit 1
fi

/bin/bash "$L" graphics "$GRAPHICS" || exit 1
/bin/bash "$L" doctor | grep -E 'Steam|Graphics|Processes'

helpers() { /bin/ps -axww -o command= | grep -c -i '[s]teamwebhelper.exe' || true; }

# A thread of Steam sometimes dies inside Wine's fault handler ("nested
# exception on signal stack") while it holds a lock, and Steam then hangs.
# When the newest log shows that, record which code lives at the address and
# what the remaining threads are doing. $1 = name for the files.
hang_report() {
  local tag="$1" log addr pid n=0 f
  log="$(ls -t "$SKYWALKER_HOME"/logs/steam-*.log 2>/dev/null | head -n 1)"
  [ -n "$log" ] || return 0
  addr="$(grep -a -o 'nested exception on signal stack addr 0x[0-9a-f]*' "$log" | head -n 1 | sed 's/.* //')"
  [ -n "$addr" ] || return 0
  note "a thread died in Wine's fault handler at $addr; recording where that is"
  for pid in $(/bin/ps -axww -o pid=,command= | grep -i '[\\]steam\.exe' | awk '{ print $1 }' | head -n 3); do
    n=$((n + 1))
    f="$OUT/hang-$tag-$n"
    /bin/ps -o pid=,etime=,command= -p "$pid" | cut -c1-200 > "$f.txt"
    # shellcheck disable=SC2016
    with_deadline 60 /bin/sh -c 'sudo -n atos -p "$1" "$2" > "$3" 2>&1' sh "$pid" "$addr" "$f.atos.txt" || true
    # shellcheck disable=SC2016
    with_deadline 90 /bin/sh -c 'sudo -n vmmap "$1" > "$2" 2>&1' sh "$pid" "$f.vmmap.txt" || true
    # shellcheck disable=SC2016
    with_deadline 90 /bin/sh -c 'sudo -n sample "$1" 2 -file "$2" > /dev/null 2>&1' sh "$pid" "$f.sample.txt" || true
    note "pid $pid: $(head -n 2 "$f.atos.txt" 2>/dev/null | tr '\n' ' ' | cut -c1-240)"
  done
}

# The installer leaves only a small starter, which downloads the real Steam on
# its first run and then restarts itself. That restart sometimes hangs, so the
# first run is only for the download, with a deadline, and is then shut down.
note "first start: letting Steam download its update"
WINEDEBUG="$FIRST_TRACE" /bin/bash "$L" steam > /dev/null 2>&1
t=0
while [ "$t" -lt 420 ]; do
  sleep 5; t=$((t + 5))
  if [ "$(helpers)" -gt 0 ]; then break; fi
  if grep -q 'Update complete' "$STEAM_DIR/logs/bootstrap_log.txt" 2>/dev/null; then sleep 15; break; fi
done
note "update phase over after ${t}s: $(tail -n 1 "$STEAM_DIR/logs/bootstrap_log.txt" 2>/dev/null | cut -c1-120)"
hang_report first
/bin/bash "$L" stop > /dev/null 2>&1 || true
mkdir -p "$OUT/first-start"
mv "$SKYWALKER_HOME"/logs/steam-*.log "$OUT/first-start/" 2>/dev/null || true
rm -f "$STEAM_DIR"/logs/cef_log.txt "$STEAM_DIR"/logs/webhelper*.txt

note "starting Steam"
WINEDEBUG="$TRACE" /bin/bash "$L" steam "$@"

end=$(( $(date +%s) + MINUTES * 60 ))
shot=0
tick=0
while [ "$(date +%s)" -lt "$end" ]; do
  sleep 20
  tick=$((tick + 1))
  {
    echo "== $(date +%H:%M:%S)"
    /bin/bash "$L" windows 2>&1
  } > "$OUT/windows-now.txt"
  cat "$OUT/windows-now.txt" >> "$OUT/windows.log"
  if [ $((tick % 2)) = 0 ] && [ "$shot" -lt 30 ]; then
    shot=$((shot + 1))
    n="$(printf '%02d' "$shot")"
    screencapture -x "$OUT/screen-$n.png" 2>/dev/null || true
    # each Wine window on its own, with its transparency kept, so that a
    # see-through window can be told from a black one
    sed -n 's/.*[[:space:]]id \([0-9][0-9]*\)$/\1/p' "$OUT/windows-now.txt" | head -n 4 | while read -r id; do
      screencapture -x -o -l "$id" "$OUT/window-$n-$id.png" 2>/dev/null || true
    done
  fi
  if [ $((tick % 3)) = 0 ]; then
    {
      echo "== $(date +%H:%M:%S)"
      /bin/ps -axww -o pid=,pcpu=,etime=,command= | grep -E ' [A-Za-z]:[\\]' | cut -c1-900
    } >> "$OUT/processes.log"
    note "$(tail -n 4 "$OUT/windows.log" | tr '\n' ' ' | cut -c1-300)"
  fi
done
rm -f "$OUT/windows-now.txt"

hang_report watch
note "last window list:"
tail -n 12 "$OUT/windows.log"
/bin/bash "$L" doctor | grep -E 'Processes|Wine running'

# Steam's own logs and the launcher's, cut down to a sensible size
mkdir -p "$OUT/steam" "$OUT/launcher"
for f in "$STEAM_DIR"/logs/*.txt "$STEAM_DIR"/logs/*.log; do
  [ -f "$f" ] || continue
  if [ "$(wc -c < "$f")" -gt 2000000 ]; then
    { head -c 1000000 "$f"; printf '\n[... cut ...]\n'; tail -c 1000000 "$f"; } > "$OUT/steam/$(basename "$f")"
  else
    cp "$f" "$OUT/steam/"
  fi
done
for f in "$SKYWALKER_HOME"/logs/*; do
  [ -f "$f" ] || continue
  if [ "$(wc -c < "$f")" -gt 6000000 ]; then
    # a trace run: keep the lines about window surfaces and transparency, a
    # count of every traced function, and the whole log compressed
    grep -a -E 'shm|foreign|Flushing|ayered|alpha|dummy|CreateWindowEx|err:' "$f" > "$OUT/launcher/filtered.tmp" || true
    { head -n 8000 "$OUT/launcher/filtered.tmp"; echo '[... cut ...]'; tail -n 4000 "$OUT/launcher/filtered.tmp"; } > "$OUT/launcher/$(basename "$f").filtered.txt"
    rm -f "$OUT/launcher/filtered.tmp"
    grep -a -o -E '(trace|warn|err|fixme):[a-z_0-9]+:[A-Za-z_0-9]+' "$f" | sort | uniq -c | sort -rn | head -n 150 > "$OUT/launcher/$(basename "$f").functions.txt"
    if [ "$(wc -c < "$f")" -lt 1500000000 ]; then gzip -1 -c "$f" > "$OUT/launcher/$(basename "$f").gz"; fi
  else
    cp "$f" "$OUT/launcher/"
  fi
done
grep -h -o 'err:[a-z_0-9]*:[A-Za-z_0-9]*' "$OUT"/launcher/steam-*.log 2>/dev/null | sort | uniq -c | sort -rn | head -n 40 > "$OUT/err-summary.txt"
note "most frequent errors from Wine:"
head -n 25 "$OUT/err-summary.txt"

/bin/bash "$L" stop
exit 0
