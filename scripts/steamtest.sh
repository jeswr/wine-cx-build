#!/bin/bash
# Installs Steam (no sign-in) into a fresh bottle on a CI Mac, starts it through
# the launcher and records what reaches the screen. For finding out why Steam's
# windows stay blank with this build; it is not part of the normal checks.
#
# Usage: steamtest.sh <minutes to watch> [options for Steam...]
# Needs: "skywalker.sh install" done, SKYWALKER_HOME and SKY_PREFIX set.
# Optional: GRAPHICS=dxmt|wine (default wine), TRACE=<WINEDEBUG value> (default fixme-all),
#           STEAMTEST_OUT=<folder for logs and screenshots> (default ./steam-logs)
# Written for the stock /bin/bash 3.2 on macOS.
set -uo pipefail

MINUTES="${1:?usage: steamtest.sh <minutes> [steam options]}"
shift
L="$SKYWALKER_HOME/skywalker.sh"
OUT="${STEAMTEST_OUT:-$PWD/steam-logs}"
GRAPHICS="${GRAPHICS:-wine}"
TRACE="${TRACE:-fixme-all}"
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
  } >> "$OUT/windows.log"
  if [ $((tick % 2)) = 0 ] && [ "$shot" -lt 30 ]; then
    shot=$((shot + 1))
    screencapture -x "$OUT/screen-$(printf '%02d' "$shot").png" 2>/dev/null || true
  fi
  if [ $((tick % 3)) = 0 ]; then
    {
      echo "== $(date +%H:%M:%S)"
      /bin/ps -axww -o pid=,pcpu=,etime=,command= | grep -E ' [A-Za-z]:[\\]' | cut -c1-900
    } >> "$OUT/processes.log"
    note "$(tail -n 4 "$OUT/windows.log" | tr '\n' ' ' | cut -c1-300)"
  fi
done

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
    { head -c 3000000 "$f"; printf '\n[... cut ...]\n'; tail -c 3000000 "$f"; } > "$OUT/launcher/$(basename "$f")"
  else
    cp "$f" "$OUT/launcher/"
  fi
done
grep -h -o 'err:[a-z_0-9]*:[A-Za-z_0-9]*' "$OUT"/launcher/steam-*.log 2>/dev/null | sort | uniq -c | sort -rn | head -n 40 > "$OUT/err-summary.txt"
note "most frequent errors from Wine:"
head -n 25 "$OUT/err-summary.txt"

/bin/bash "$L" stop
exit 0
