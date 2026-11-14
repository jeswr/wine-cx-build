#!/bin/bash
# Launcher for LEGO Star Wars: The Skywalker Saga on an Apple silicon Mac,
# using the Wine builds published by github.com/jeswr/wine-cx-build.
#
#   skywalker.sh install [tag]   download a build (latest, or the given release tag),
#                                copy the CrossOver Steam bottle once, create the app icon
#   skywalker.sh run             back up saves, start Steam and the game, tidy up on exit
#   skywalker.sh steam [options] open Steam's window (to sign in or change settings); extra
#                                options go to Steam, for example -cef-disable-gpu
#   skywalker.sh bench [label]   like run, with the frame counter on and a summary afterwards
#   skywalker.sh summary <log>   summarise a frame log again
#   skywalker.sh backup          back up the save files now
#   skywalker.sh update          install the latest build; the previous one is kept
#   skywalker.sh rollback        switch back to the previous build
#   skywalker.sh graphics split|dxmt|wine|d3dmetal
#                                split (default): DXMT for the game and Wine's own Direct3D for
#                                Steam; dxmt or wine: one of them for everything; d3dmetal: Apple's
#                                D3DMetal from your own copy of the Game Porting Toolkit (GPTK_DIR)
#   skywalker.sh display keep|show|off
#                                keep: remember the game's screen and window settings as they
#                                are now and put them back before each start if something
#                                changed them (an external monitor does); off: stop doing that
#   skywalker.sh prewarm [min]   start Steam now, without a window and without the game, so that
#                                the next "run" skips Steam's slow start; it closes again after
#                                PREWARM_MINUTES (or the minutes given) if the game is not played
#   skywalker.sh autostart on|off
#                                on: do that prewarm by itself every time you log in to the Mac
#   skywalker.sh cpu [seconds]   measure how much processor time Wine's programs use (troubleshooting)
#   skywalker.sh stop            shut down Steam and Wine
#   skywalker.sh doctor          show what is installed and what is missing
#   skywalker.sh wine <args>     run any Wine program with the launcher's settings (troubleshooting)
#   skywalker.sh windows         list the windows Wine has on screen (troubleshooting)
#   skywalker.sh timeline        show where the time went in the last start (troubleshooting)
#   skywalker.sh uninstall       remove the app icon and the launcher's own folder
#
# Settings live in ~/Games/skywalker/config.env. For one run, a setting can be
# overridden from the environment with a SKY_ prefix:  SKY_UPSCALE=1 skywalker.sh bench upscaled
#
# Written for the stock /bin/bash 3.2 on macOS.
set -uo pipefail

REPO="jeswr/wine-cx-build"
HOME_DIR="${SKYWALKER_HOME:-$HOME/Games/skywalker}"
CONF="$HOME_DIR/config.env"
WINES="$HOME_DIR/wine"
CUR="$WINES/current"
LOGS="$HOME_DIR/logs"
BENCH="$HOME_DIR/bench"
APP="${SKYWALKER_APP:-$HOME/Applications/Skywalker Saga.app}"
RELEASES="https://github.com/$REPO/releases"
SELF_URL="https://raw.githubusercontent.com/$REPO/main/scripts/skywalker.sh"
STEAM_EXE='C:\Program Files (x86)\Steam\steam.exe'

say() { echo "== $*"; }
die() { echo "skywalker: $*" >&2; notify "$*"; exit 1; }
notify() {
  /usr/bin/osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Skywalker Saga"' \
    -e 'end run' "$1" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- settings

write_default_conf() {
  mkdir -p "$HOME_DIR"
  cat > "$CONF" <<'EOF'
# Settings for the Skywalker Saga launcher. Edit, save, and launch again.

# The Wine bottle the game runs in. If it does not exist, "install" makes it
# as a copy of BOTTLE_SRC (an APFS copy: instant, and the original is only read).
PREFIX="$HOME/Games/skywalker-cx"
BOTTLE_SRC="$HOME/Library/Application Support/CrossOver/Bottles/Steam"
WINE_USER=crossover      # the Windows user name inside that bottle

APPID=920210             # the game's Steam ID
# Options for the game itself, added to the ones set for it in Steam (Properties,
# Launch Options). Empty by default: Steam's own setting is the one place for them.
GAME_ARGS=""
STEAM_ARGS="-silent -nofriendsui -nochatui"
# Steam's windows are drawn by a separate graphics process that cannot start
# under this Wine. Steam only gives up on it after four failed tries and a
# restart of its browser part, which costs 20 seconds or more per start.
# 0 = tell Steam not to try (-cef-disable-gpu), 1 = let it try.
STEAM_GPU=0

# With "graphics dxmt" or "graphics d3dmetal" every program in the bottle gets
# that graphics layer, Steam included. 1 = Steam's browser part keeps Wine's
# own Direct3D instead (copies next to steamwebhelper.exe and a setting for
# that one program), so only the game gets the other layer. Worth trying if
# "timeline" shows "GPU process restarts" on every start. 0 = off.
STEAM_OWN_D3D=0

# "graphics d3dmetal" takes Apple's D3DMetal from here: your own copy of the
# lib folder of Apple's Game Porting Toolkit (lib/external and lib/wine).
GPTK_DIR="$HOME/Games/gptk"
# 0 = D3DMetal's files are used as they are, which is how it was first set up
# and measured on the Mac. 1 = Wine is also started the way CrossOver starts
# it for D3DMetal (it loads libd3dshared.dylib itself and reports D3DMetal as
# the graphics layer). Worth one "bench" to compare.
D3DMETAL_HOOK=0

MSYNC=1                  # CrossOver's fast locks
UPSCALE=0                # 1 = draw small and let MetalFX enlarge it. Set the game to 1280x800 first.
UPSCALE_FACTOR=2         # 1280x800 x 2 = the Air's native 2560x1600
FPS_CAP=0                # 0 = leave it to the game. Otherwise 60 or 30.
AVX=0                    # 1 = let Rosetta offer AVX2 to the game
HUD=0                    # 1 = show Apple's frame counter

# Steam stays open this many minutes after the game ends, so that the next
# start skips Steam's own slow start. 0 = close Steam with the game.
KEEP_STEAM_MINUTES=30

# "prewarm" (and "autostart on", which runs it at login) keeps Steam open this
# many minutes while waiting for the first game. 0 = until "stop" or log-out.
PREWARM_MINUTES=120

# Safety net: Wine may start at most this many processes on top of what is
# already running. Steam and the game need well under 100.
PROC_HEADROOM=400

# Kept outside Documents so that macOS does not ask for folder access when the app icon starts the game.
SAVE_BACKUP_DIR="$HOME/Games/SkywalkerSaga-saves"
SAVE_BACKUPS=20          # how many different save states to keep
EOF
}

load_conf() {
  local k v
  [ -f "$CONF" ] || write_default_conf
  # shellcheck disable=SC1090
  . "$CONF"
  : "${PREFIX:=$HOME/Games/skywalker-cx}"
  : "${BOTTLE_SRC:=$HOME/Library/Application Support/CrossOver/Bottles/Steam}"
  : "${WINE_USER:=crossover}" "${APPID:=920210}" "${STEAM_ARGS:=-silent}"
  : "${MSYNC:=1}" "${UPSCALE:=0}" "${UPSCALE_FACTOR:=2}" "${FPS_CAP:=0}" "${AVX:=0}" "${HUD:=0}"
  : "${SAVE_BACKUP_DIR:=$HOME/Games/SkywalkerSaga-saves}" "${SAVE_BACKUPS:=20}"
  : "${PROC_HEADROOM:=400}" "${KEEP_STEAM_MINUTES:=30}" "${STEAM_GPU:=0}"
  : "${GPTK_DIR:=$HOME/Games/gptk}" "${D3DMETAL_HOOK:=0}" "${PREWARM_MINUTES:=120}"
  : "${GAME_ARGS=}" "${WARM_WAIT:=45}" "${STEAM_OWN_D3D:=0}"
  # which lines of the game's settings file "display keep" looks after (by the first word of the line)
  : "${DISPLAY_KEYS:=^(Screen(Width|Height|RefreshRate|Left|Top)|Window(Width|Height|Left|Top|ed)|BorderlessWindow|Full[Ss]creen(Window)?|AspectRatio)\$}"
  for k in MSYNC UPSCALE UPSCALE_FACTOR FPS_CAP AVX HUD STEAM_ARGS STEAM_GPU PREFIX PROC_HEADROOM KEEP_STEAM_MINUTES GPTK_DIR D3DMETAL_HOOK DISPLAY_KEYS PREWARM_MINUTES WARM_WAIT STEAM_OWN_D3D; do
    v="SKY_$k"
    if [ -n "${!v:-}" ]; then eval "$k=\${$v}"; fi
  done
  # an empty SKY_GAME_ARGS means: no options for the game
  if [ -n "${SKY_GAME_ARGS+set}" ]; then GAME_ARGS="$SKY_GAME_ARGS"; fi
}

settings_line() {
  echo "graphics=$(graphics_now) msync=$MSYNC upscale=$UPSCALE factor=$UPSCALE_FACTOR cap=$FPS_CAP avx=$AVX d3dmhook=$D3DMETAL_HOOK steamd3d=$STEAM_OWN_D3D"
}

# ---------------------------------------------------------------- helpers

current_tag() {
  if [ -L "$CUR" ]; then basename "$(readlink "$CUR")"; else echo "none"; fi
}

need_wine() {
  [ -x "$CUR/bin/wine" ] || die "No Wine build is installed. Run: bash $HOME_DIR/skywalker.sh install"
}

steam_dir() { echo "$PREFIX/drive_c/Program Files (x86)/Steam"; }

# The folder name of the game under steamapps/common, from Steam's own record.
game_dir_name() {
  local m
  m="$(steam_dir)/steamapps/appmanifest_$APPID.acf"
  [ -f "$m" ] || return 1
  sed -n 's/^[[:space:]]*"installdir"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$m" | head -n 1
}

our_wineserver_running() {
  /bin/ps -axww -o command= | /usr/bin/grep -F "$WINES/" | /usr/bin/grep -E '/wineserver( |$)' | /usr/bin/grep -v grep >/dev/null
}

other_wine_running() {
  /bin/ps -axww -o command= | /usr/bin/grep -E 'CrossOver\.app/|/wineserver( |$)' | /usr/bin/grep -v -F "$WINES/" | /usr/bin/grep -v grep >/dev/null
}

# Fixed strings that identify the game's process: the name of its folder and
# the names of the programs in that folder.
game_patterns() {
  local name exe
  name="$(game_dir_name || true)"
  [ -n "$name" ] || return 1
  echo "$name"
  for exe in "$(steam_dir)/steamapps/common/$name"/*.exe; do
    if [ -f "$exe" ]; then basename "$exe"; fi
  done
  return 0
}

game_running() {
  local pats
  pats="$(game_patterns)" || return 1
  /bin/ps -axww -o command= | /usr/bin/grep -v -e grep -e 'skywalker\.sh' \
    | /usr/bin/grep -i -F -e "$pats" >/dev/null
}

# The game's own command line, as the system shows it: the proof of which
# options reached it (the launcher's GAME_ARGS and Steam's Launch Options).
game_cmdline() {
  local pats
  pats="$(game_patterns)" || return 1
  /bin/ps -axww -o command= | /usr/bin/grep -v -e grep -e 'skywalker\.sh' \
    | /usr/bin/grep -i -F -e "$pats" | head -n 1
}

# Keeps that command line with the start it belongs to, for "timeline".
note_game_cmdline() {
  local f="$LOGS/game-starts.tsv" line
  line="$(game_cmdline 2>/dev/null || true)"
  [ -n "$line" ] || return 0
  printf '%s\t%s\t%s\t%s\n' "$(cat "$LOGS/last-start" 2>/dev/null || true)" "$(current_tag)" "$(graphics_now)" "$line" >> "$f"
  if [ "$(wc -l < "$f")" -gt 200 ]; then tail -n 100 "$f" > "$f.new" && mv "$f.new" "$f"; fi
}

# The option that keeps Steam from trying its graphics process, unless it is
# wanted or already among the options given.
steam_gpu_opt() {
  if [ "$STEAM_GPU" = 0 ]; then
    case " $* " in *" -cef-disable-gpu "*) ;; *) echo "-cef-disable-gpu" ;; esac
  fi
}
helper_running() {
  /bin/ps -axww -o command= | /usr/bin/grep -i -F 'steamwebhelper.exe' | /usr/bin/grep -v grep >/dev/null
}
# Steam itself: a process whose own program is steam.exe. Steam's browser
# helpers carry "-steampath=...\steam.exe" among their options and can outlive
# Steam, so the name anywhere on the line is not enough.
steam_running() {
  /bin/ps -axww -o command= | /usr/bin/awk '{
    l = tolower($0); sub(/^"/, "", l)
    i = index(l, ".exe"); if (!i) next
    prog = substr(l, 1, i + 3)
    if (substr(prog, 1, 1) != "/" && prog ~ /(^|[\\\/])steam\.exe$/) found = 1
  } END { exit !found }'
}

# Process ids of everything Wine has running for this user. macOS lists a Wine
# program under its Windows path (C:\windows\system32\services.exe), so match
# those as well as anything started from the launcher's own Wine folder.
wine_pids() {
  /bin/ps -x -o pid=,command= | /usr/bin/awk -v w="$WINES/" '{
    pid = $1; rest = $0; sub(/^ *[0-9]+ +/, "", rest)
    if (rest ~ /^[A-Za-z]:\\/ || index(rest, w) == 1) print pid
  }'
}

# A Wine that goes wrong can start programs in a loop, and with no limit that
# fills the Mac's process table until nothing else can start. Cap what
# Wine may reach at "running now + PROC_HEADROOM"; other apps keep the
# system's limit. Lowering the limit needs no special rights.
limit_processes() {
  local now cap cur
  now="$(/bin/ps -x -o pid= | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  cap=$((now + PROC_HEADROOM))
  cur="$(ulimit -u)"
  if [ "$cur" = unlimited ] || [ "$cap" -lt "$cur" ]; then
    ulimit -u "$cap" 2>/dev/null || true
  fi
}

# Starts Wine with that limit on Wine alone, so that the launcher can still
# run its own checks if the limit is ever reached.
run_wine() {
  ( limit_processes; exec "$CUR/bin/wine" "$@" )
}

wine_env() {
  export WINEPREFIX="$PREFIX"
  export USER="$WINE_USER"
  export WINEDEBUG="${WINEDEBUG:--all}"
  # no Wine Mono / Gecko install prompts: neither Steam nor the game needs them.
  # winedbg.exe off: a crashing program must just exit. With the debugger on,
  # a crash loop once spawned hundreds of winedbg/conhost processes and filled
  # the Mac's process table.
  local ovr="mscoree=;mshtml=;winedbg.exe=d"
  # split graphics: the game's own copies of these (DXMT) come before Wine's
  if [ "$(graphics_now)" = split ]; then ovr="$ovr;d3d11,dxgi,d3d10core=n,b"; fi
  export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-$ovr}"
  # the build keeps FreeType, GnuTLS and SDL2 in its own lib folder
  export DYLD_FALLBACK_LIBRARY_PATH="$CUR/lib:/usr/lib"
  # Apple's D3DMetal: its files look for each other in lib/external. With
  # D3DMETAL_HOOK=1 Wine is also started as CrossOver starts it for D3DMetal.
  unset CX_APPLEGPTK_LIBD3DSHARED_PATH CX_ACTIVE_GRAPHICS_BACKEND DYLD_FALLBACK_FRAMEWORK_PATH
  if [ "$(graphics_now)" = d3dmetal ]; then
    export DYLD_FALLBACK_LIBRARY_PATH="$CUR/lib:$CUR/lib/external:/usr/lib"
    if [ "$D3DMETAL_HOOK" = 1 ]; then
      export CX_APPLEGPTK_LIBD3DSHARED_PATH="$CUR/lib/external/libd3dshared.dylib"
      export CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal
    fi
  fi
  if [ "$MSYNC" = 1 ]; then export WINEMSYNC=1; else unset WINEMSYNC; fi
  if [ "$AVX" = 1 ]; then export ROSETTA_ADVERTISE_AVX=1; else unset ROSETTA_ADVERTISE_AVX; fi

  mkdir -p "$HOME_DIR/cache/dxmt"
  export DXMT_SHADER_CACHE_PATH="$HOME_DIR/cache/dxmt"
  local conf=""
  if [ "$UPSCALE" = 1 ]; then
    export DXMT_METALFX_SPATIAL_SWAPCHAIN=1
    conf="d3d11.metalSpatialUpscaleFactor=$UPSCALE_FACTOR"
  else
    unset DXMT_METALFX_SPATIAL_SWAPCHAIN
  fi
  if [ "$FPS_CAP" != 0 ]; then
    conf="${conf:+$conf;}d3d11.preferredMaxFrameRate=$FPS_CAP"
  fi
  if [ -n "$conf" ]; then export DXMT_CONFIG="$conf"; else unset DXMT_CONFIG; fi

  if [ "$HUD" = 1 ]; then export MTL_HUD_ENABLED=1; else unset MTL_HUD_ENABLED; fi
}

# DXMT's guide wants winemetal.dll in the bottle as well as in Wine's own folder.
prepare_prefix() {
  local src dst
  [ -d "$PREFIX/drive_c/windows" ] || die "The bottle at $PREFIX is missing. Run: bash $HOME_DIR/skywalker.sh install"
  src="$CUR/lib/wine/x86_64-windows/winemetal.dll"
  dst="$PREFIX/drive_c/windows/system32/winemetal.dll"
  if [ -f "$src" ] && ! /usr/bin/cmp -s "$src" "$dst" 2>/dev/null; then cp "$src" "$dst"; fi
  src="$CUR/lib/wine/i386-windows/winemetal.dll"
  dst="$PREFIX/drive_c/windows/syswow64/winemetal.dll"
  if [ -f "$src" ] && [ -d "$PREFIX/drive_c/windows/syswow64" ] && ! /usr/bin/cmp -s "$src" "$dst" 2>/dev/null; then
    cp "$src" "$dst"
  fi
  if [ "$(graphics_now)" = split ]; then game_dxmt_on; else game_dxmt_off; fi
  if steam_d3d_wanted; then steam_d3d_on; else steam_d3d_off; fi
}

# ---------------------------------------------------------------- saves

# Copies the save files (and the game's settings file) to a dated folder.
# A new folder is only kept when something changed since the last backup.
backup_saves() {
  local tmp dest last src who n=0 count extra old
  [ -n "$SAVE_BACKUP_DIR" ] || return 0
  [ -d "$PREFIX/drive_c" ] || return 0
  mkdir -p "$SAVE_BACKUP_DIR"
  tmp="$SAVE_BACKUP_DIR/.incoming"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  for src in "$PREFIX"/drive_c/users/*/AppData/Roaming/"Warner Bros. Interactive Entertainment"; do
    [ -d "$src" ] || continue
    who="$(basename "$(dirname "$(dirname "$(dirname "$src")")")")"
    mkdir -p "$tmp/appdata-$who"
    cp -Rp "$src" "$tmp/appdata-$who/" && n=$((n + 1))
  done
  for src in "$(steam_dir)"/userdata/*/"$APPID"; do
    [ -d "$src" ] || continue
    who="$(basename "$(dirname "$src")")"
    mkdir -p "$tmp/steam-userdata-$who"
    cp -Rp "$src" "$tmp/steam-userdata-$who/" && n=$((n + 1))
  done
  if [ "$n" = 0 ]; then
    rm -rf "$tmp"
    say "No save files found yet, so nothing to back up."
    return 0
  fi
  last="$(ls -1d "$SAVE_BACKUP_DIR"/20??-??-??_?????? 2>/dev/null | sort | tail -n 1)"
  if [ -n "$last" ] && /usr/bin/diff -rq "$last" "$tmp" >/dev/null 2>&1; then
    rm -rf "$tmp"
    say "Saves unchanged since the last backup ($(basename "$last"))."
    return 0
  fi
  dest="$SAVE_BACKUP_DIR/$(date +%Y-%m-%d_%H%M%S)"
  mv "$tmp" "$dest"
  say "Saves backed up to $dest"
  count="$(ls -1d "$SAVE_BACKUP_DIR"/20??-??-??_?????? 2>/dev/null | wc -l | tr -d ' ')"
  extra=$((count - SAVE_BACKUPS))
  if [ "$extra" -gt 0 ]; then
    ls -1d "$SAVE_BACKUP_DIR"/20??-??-??_?????? | sort | head -n "$extra" | while read -r old; do
      case "$old" in "$SAVE_BACKUP_DIR"/20*) rm -rf "$old" ;; esac
    done
  fi
}

# ---------------------------------------------------------------- display

# The game keeps its settings in PCCONFIG.TXT, one "Name value" per line. When
# the screens change (an external monitor is plugged in or out) the game
# rewrites the screen and window lines and keeps the new values for good.
# "display keep" notes those lines as they are now, and every start puts them
# back if they differ. No other line of the file is ever touched.
DISPLAY_KEEP="$HOME_DIR/display.keep"

pcconfig() {
  local f
  for f in "$PREFIX"/drive_c/users/*/AppData/Roaming/"Warner Bros. Interactive Entertainment"/*/PCCONFIG.TXT; do
    if [ -f "$f" ]; then echo "$f"; return 0; fi
  done
  return 1
}

# the screen and window lines of a settings file, without line ends
display_lines() {
  /usr/bin/awk -v re="$DISPLAY_KEYS" '{ sub(/\r$/, "") } NF == 2 && $1 ~ re { print $1, $2 }' "$1"
}

display_guard() {
  local f tmp changes dir old
  [ -f "$DISPLAY_KEEP" ] || return 0
  f="$(pcconfig)" || return 0
  tmp="$HOME_DIR/.pcconfig.new"
  # a kept line replaces the value of the same name; the line end is left as it was
  /usr/bin/awk -v re="$DISPLAY_KEYS" '
    NR == FNR { keep[$1] = $2; next }
    {
      cr = ""
      if ($0 ~ /\r$/) cr = "\r"
      line = $0
      sub(/\r$/, "", line)
      n = split(line, w, " ")
      if (n == 2 && w[1] ~ re && (w[1] in keep) && keep[w[1]] != w[2]) {
        sep = " "
        if (match(line, /[ \t]+/)) sep = substr(line, RSTART, RLENGTH)
        printf "%s %s -> %s\n", w[1], w[2], keep[w[1]] > "/dev/stderr"
        printf "%s%s%s%s\n", w[1], sep, keep[w[1]], cr
      } else print $0
    }' "$DISPLAY_KEEP" "$f" > "$tmp" 2> "$tmp.changes" || { rm -f "$tmp" "$tmp.changes"; return 0; }
  changes="$(tr '\n' ',' < "$tmp.changes" | sed 's/,$//; s/,/, /g')"
  if [ -z "$changes" ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp" "$tmp.changes"
    return 0
  fi
  dir="$HOME_DIR/settings-backups"
  mkdir -p "$dir"
  cp -p "$f" "$dir/PCCONFIG-$(date +%Y%m%d-%H%M%S).TXT"
  ls -1 "$dir"/PCCONFIG-*.TXT 2>/dev/null | sort -r | tail -n +11 | while read -r old; do
    case "$old" in "$dir"/PCCONFIG-*) rm -f "$old" ;; esac
  done
  cat "$tmp" > "$f"
  rm -f "$tmp" "$tmp.changes"
  say "The game's screen settings had changed and were put back: $changes"
  say "(To keep new screen settings instead, set them in the game, quit it, then: bash $HOME_DIR/skywalker.sh display keep)"
}

cmd_display() {
  local f
  load_conf
  case "${1:-show}" in
    keep)
      f="$(pcconfig)" || die "The game has not written its settings file yet. Start the game once, set the picture, quit, then run this again."
      game_running && die "Quit the game first: it writes its settings when it closes."
      display_lines "$f" > "$DISPLAY_KEEP.new"
      [ -s "$DISPLAY_KEEP.new" ] || { rm -f "$DISPLAY_KEEP.new"; die "No screen or window lines found in $f"; }
      mv "$DISPLAY_KEEP.new" "$DISPLAY_KEEP"
      say "These screen settings are now put back before every start:"
      sed 's/^/   /' "$DISPLAY_KEEP"
      ;;
    check) display_guard ;;   # what every start does
    off)
      rm -f "$DISPLAY_KEEP"
      say "Screen settings are left as the game writes them."
      ;;
    show)
      if f="$(pcconfig)"; then
        echo "Settings file: $f"
        echo "Now:"
        display_lines "$f" | sed 's/^/   /'
      else
        echo "Settings file: not written by the game yet"
      fi
      if [ -f "$DISPLAY_KEEP" ]; then
        echo "Kept (put back before every start):"
        sed 's/^/   /' "$DISPLAY_KEEP"
      else
        echo "Kept: nothing (bash $HOME_DIR/skywalker.sh display keep)"
      fi
      ;;
    *) die "Use: skywalker.sh display keep|show|off" ;;
  esac
}

# ---------------------------------------------------------------- bottle update

# The first time a build starts anything in a bottle, Wine brings the bottle
# up to that build: it rewrites the Windows files in it, a few thousand of
# them. That takes minutes on this Mac and shows nothing on screen (the build
# has Wine's "updating" window switched off). Wine decides by comparing the
# time of the build's wine.inf with the number in the bottle's
# .update-timestamp, and so does this.
bottle_update_due() {
  local inf="$CUR/share/wine/wine.inf" want have
  [ -f "$inf" ] && [ -d "$PREFIX/drive_c" ] || return 1
  if [ "$(uname -s)" = Darwin ]; then want="$(/usr/bin/stat -f %m "$inf" 2>/dev/null)"; else want="$(stat -c %Y "$inf" 2>/dev/null)"; fi
  [ -n "$want" ] || return 1
  have="$(head -n 1 "$PREFIX/.update-timestamp" 2>/dev/null | tr -d '[:space:]')"
  case "$have" in disable*) return 1 ;; esac
  [ "$want" != "$have" ]
}

# Said by anything that is about to start Wine while the update is still due.
note_bottle_update() {
  bottle_update_due || return 0
  say "First start with this build: Wine updates the bottle before anything else. That takes a few minutes, once, and shows nothing on screen."
  notify "First start with this build: allow a few extra minutes, once." &
}

# Wine's own programs that do the update
boot_running() {
  /bin/ps -axww -o command= | /usr/bin/grep -i -E 'wineboot\.exe|rundll32\.exe' | /usr/bin/grep -v grep >/dev/null
}

# Does the update now, on its own, so that the next start of the game is a
# normal one. Bounded: after BOTTLE_UPDATE_MAX seconds it is left to that start.
# Wine itself waits at most 5 minutes for the update and then carries on while
# the update is still running, so "the program has ended" is not "the update
# has ended": this also waits for Wine's update programs to go.
update_bottle() {
  local pid t=0 t0 max="${SKY_BOTTLE_UPDATE_MAX:-900}" log="$LOGS/bottle-update.log"
  bottle_update_due || return 0
  if our_wineserver_running || other_wine_running; then
    say "The bottle still has to be updated for this build. Wine is running, so that happens at the next start (a few minutes, once)."
    return 0
  fi
  say "Updating the bottle for $(current_tag). This happens once per build and takes a few minutes."
  mkdir -p "$LOGS"
  t0="$(date +%s)"
  wine_env
  start_watchdog "$log"
  # any Wine program will do: Wine runs the update before it
  ( cd "$HOME" 2>/dev/null || true; limit_processes; WINEDEBUG=fixme-all exec "$CUR/bin/wine" cmd /c ver ) > "$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$t" -lt "$max" ]; do sleep 2; t=$((t + 2)); done
  while boot_running && [ "$t" -lt "$max" ]; do sleep 2; t=$((t + 2)); done
  if kill -0 "$pid" 2>/dev/null || boot_running; then
    kill "$pid" 2>/dev/null || true
    shutdown_wine > /dev/null 2>&1
    # stopped half-way: without its mark Wine starts the update again next time
    rm -f "$PREFIX/.update-timestamp"
    say "The update did not finish in $max seconds and was stopped. The next start of the game does it again from the beginning. See $log"
    return 0
  fi
  shutdown_wine > /dev/null 2>&1
  if bottle_update_due; then
    say "Wine did not mark the bottle as updated. The next start of the game will do it. See $log"
  elif /usr/bin/grep -q 'boot event wait timed out' "$log" 2>/dev/null; then
    say "The bottle is up to date ($(( $(date +%s) - t0 )) s). The update took longer than the 5 minutes Wine waits for it, which is why a first start can seem stuck."
  else
    say "The bottle is up to date ($(( $(date +%s) - t0 )) s)."
  fi
}

# ---------------------------------------------------------------- install

manifest_value() { # $1 = file, $2 = key
  sed -n "s/^$2=\\([A-Za-z0-9._-]*\\)\$/\\1/p" "$1" | head -n 1
}

install_self() {
  mkdir -p "$HOME_DIR"
  local me="${BASH_SOURCE[0]:-}"
  if [ -n "$me" ] && [ -f "$me" ]; then
    if [ "$(cd "$(dirname "$me")" && pwd -P)/$(basename "$me")" != "$HOME_DIR/skywalker.sh" ]; then
      cp "$me" "$HOME_DIR/skywalker.sh"
    fi
  else
    /usr/bin/curl -fsSL "$SELF_URL" -o "$HOME_DIR/skywalker.sh" || die "Could not download the launcher script."
  fi
  chmod +x "$HOME_DIR/skywalker.sh"
}

create_app() {
  mkdir -p "$APP/Contents/MacOS" "$LOGS"
  cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Skywalker Saga</string>
  <key>CFBundleDisplayName</key><string>Skywalker Saga</string>
  <key>CFBundleIdentifier</key><string>local.skywalker-saga.launcher</string>
  <key>CFBundleExecutable</key><string>skywalker-launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.action-games</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
  cat > "$APP/Contents/MacOS/skywalker-launcher" <<EOF
#!/bin/bash
# Starts the game in the background and returns at once, so the icon does not sit bouncing.
mkdir -p "$LOGS"
/usr/bin/nohup /bin/bash "$HOME_DIR/skywalker.sh" run >> "$LOGS/launcher.log" 2>&1 &
EOF
  chmod +x "$APP/Contents/MacOS/skywalker-launcher"
  touch "$APP"
  say "App icon: $APP"
}

cmd_install() {
  local want="${1:-}" tmp manifest tag asset sha url n prev
  [ "$(uname -s)" = Darwin ] || die "This runs on macOS only."
  if [ "$(uname -m)" = arm64 ] && ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    die "Rosetta is not installed. Run: softwareupdate --install-rosetta --agree-to-license"
  fi
  load_conf
  install_self
  mkdir -p "$WINES" "$LOGS"
  tmp="$(mktemp -d "$HOME_DIR/.download.XXXXXX")"
  manifest="$tmp/manifest.env"
  if [ -n "$want" ]; then url="$RELEASES/download/$want"; else url="$RELEASES/latest/download"; fi
  say "Checking $url"
  /usr/bin/curl -fsSL --retry 3 -o "$manifest" "$url/manifest.env" \
    || { rm -rf "$tmp"; die "Could not read the release information from $url"; }
  tag="$(manifest_value "$manifest" TAG)"
  asset="$(manifest_value "$manifest" ASSET)"
  sha="$(manifest_value "$manifest" SHA256)"
  if [ -z "$tag" ] || [ -z "$asset" ] || [ -z "$sha" ]; then
    rm -rf "$tmp"
    die "The release information is incomplete."
  fi

  if [ -x "$WINES/$tag/bin/wine" ]; then
    say "$tag is already downloaded."
  else
    say "Downloading $tag"
    /usr/bin/curl -fL --retry 3 -o "$tmp/$asset" "$RELEASES/download/$tag/$asset" \
      || { rm -rf "$tmp"; die "The download failed."; }
    if [ "$(/usr/bin/shasum -a 256 "$tmp/$asset" | awk '{print $1}')" != "$sha" ]; then
      rm -rf "$tmp"
      die "The download does not match its checksum."
    fi
    rm -rf "$WINES/$tag.partial"
    mkdir -p "$WINES/$tag.partial"
    /usr/bin/tar -xJf "$tmp/$asset" -C "$WINES/$tag.partial" || { rm -rf "$tmp"; die "Unpacking failed."; }
    n="$(find "$WINES/$tag.partial/lib/wine" -name '*.dll' | wc -l | tr -d ' ')"
    if [ "$n" -lt 1000 ] || [ ! -e "$WINES/$tag.partial/lib/wine/x86_64-windows/ntdll.dll" ]; then
      rm -rf "$tmp"
      die "Only $n Windows DLLs are present after unpacking. Sophos has probably removed some; an IT exclusion for ~/Games is needed."
    fi
    for n in lib/libfreetype.6.dylib lib/libgnutls.30.dylib lib/wine/x86_64-unix/winemetal.so; do
      [ -e "$WINES/$tag.partial/$n" ] || { rm -rf "$tmp"; die "This build lacks $n; use a newer release."; }
    done
    /usr/bin/xattr -dr com.apple.quarantine "$WINES/$tag.partial" 2>/dev/null || true
    mv "$WINES/$tag.partial" "$WINES/$tag"
  fi
  rm -rf "$tmp"

  prev="$(current_tag)"
  if [ "$prev" != none ] && [ "$prev" != "$tag" ]; then ln -sfn "$prev" "$WINES/previous"; fi
  ln -sfn "$tag" "$CUR"
  say "Using $tag (previous: $prev)"

  if [ ! -d "$PREFIX" ]; then
    if [ -d "$BOTTLE_SRC" ]; then
      if other_wine_running; then
        die "Quit CrossOver and Steam first, then run install again, so the bottle is copied in a settled state."
      fi
      say "Copying the CrossOver Steam bottle to $PREFIX (the original is only read)"
      mkdir -p "$(dirname "$PREFIX")"
      cp -cR "$BOTTLE_SRC" "$PREFIX" || die "Copying the bottle failed."
    else
      echo "No bottle at $PREFIX and none to copy at $BOTTLE_SRC."
      echo "Set PREFIX in $CONF to a bottle that has Steam and the game, then run install again."
    fi
  fi
  create_app
  adopt_graphics "$prev"
  update_bottle
  say "Done. Open \"Skywalker Saga\" from your Applications folder, or run: bash $HOME_DIR/skywalker.sh run"
}

cmd_rollback() {
  local prev cur
  [ -L "$WINES/previous" ] || die "There is no previous build to go back to."
  our_wineserver_running && die "Quit the game first."
  prev="$(basename "$(readlink "$WINES/previous")")"
  cur="$(current_tag)"
  ln -sfn "$prev" "$CUR"
  ln -sfn "$cur" "$WINES/previous"
  say "Now using $prev (was $cur)"
}

# The build ships DXMT in place of Wine's own Direct3D 10/11 DLLs and keeps
# Wine's copies in orig-dlls. This swaps the two sets within the build in use.
graphics_now() { cat "$CUR/GRAPHICS" 2>/dev/null || echo dxmt; }

GAME_DLLS="d3d11.dll dxgi.dll d3d10core.dll"

game_dir() {
  local n
  n="$(game_dir_name)" || return 1
  [ -n "$n" ] || return 1
  echo "$(steam_dir)/steamapps/common/$n"
}

# Puts Wine's own Direct3D ("wine") or DXMT ("dxmt") into the build's DLL folder.
# The build arrives with DXMT there; its copies are kept in dxmt-dlls the first time.
set_build_dlls() {
  local want="$1" w arch f b
  w="$(cd "$CUR" && pwd -P)"
  [ -d "$w/orig-dlls" ] || die "This build has no orig-dlls folder, so there is nothing to switch to."
  for arch in x86_64-windows i386-windows x86_64-unix; do
    [ -d "$w/orig-dlls/$arch" ] || continue
    mkdir -p "$w/dxmt-dlls/$arch"
    for f in "$w/orig-dlls/$arch"/*; do
      [ -f "$f" ] || continue
      b="$(basename "$f")"
      [ -f "$w/dxmt-dlls/$arch/$b" ] || cp "$w/lib/wine/$arch/$b" "$w/dxmt-dlls/$arch/$b"
      if [ "$want" = wine ]; then
        cp "$f" "$w/lib/wine/$arch/$b"
      else
        cp "$w/dxmt-dlls/$arch/$b" "$w/lib/wine/$arch/$b"
      fi
    done
  done
}

# DXMT's DLLs are made to live in Wine's own folder and carry a mark that says
# so. Wine ignores a marked DLL that sits next to a program and loads its own
# instead, so the copy for the game folder has the mark blanked out. Nothing
# else in the file changes.
copy_as_native() {
  cp "$1" "$2" || return 1
  if [ "$(/bin/dd if="$2" bs=1 skip=64 count=16 2>/dev/null)" = "Wine builtin DLL" ]; then
    /bin/dd if=/dev/zero of="$2" bs=1 seek=64 count=16 conv=notrunc 2>/dev/null || return 1
  fi
}

# Gives the game, and only the game, DXMT: copies of its DLLs next to the
# game's program. Steam keeps Wine's own Direct3D, because DXMT cannot draw
# Steam's windows. A note in the game folder records which files are ours.
game_dxmt_on() {
  local dir w b note tag
  dir="$(game_dir)" || dir=""
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo "The game is not installed in Steam yet. DXMT is added to it on the first launch after it is."
    return 0
  fi
  w="$(cd "$CUR" && pwd -P)"
  note="$dir/.skywalker-dxmt"
  tag="$(current_tag)"
  if [ "$(head -n 1 "$note" 2>/dev/null)" = "build=$tag" ]; then
    for b in $GAME_DLLS; do [ -f "$dir/$b" ] || tag=""; done
    [ -n "$tag" ] && return 0
    tag="$(current_tag)"
  fi
  for b in $GAME_DLLS; do
    [ -f "$w/dxmt-dlls/x86_64-windows/$b" ] || die "This build has no DXMT copy of $b."
    if [ -f "$dir/$b" ] && ! /usr/bin/grep -qx "$b" "$note" 2>/dev/null; then
      die "The game folder already has its own $b, which the launcher will not replace."
    fi
  done
  # DXMT's Direct3D 11 is the one that asks for winemetal; Wine's own does not
  /usr/bin/grep -a -q -i 'winemetal' "$w/dxmt-dlls/x86_64-windows/d3d11.dll" \
    || die "The saved DXMT files in $w/dxmt-dlls are not DXMT. Install the build again."
  echo "build=$tag" > "$note"
  for b in $GAME_DLLS; do
    copy_as_native "$w/dxmt-dlls/x86_64-windows/$b" "$dir/$b" || die "Could not copy $b into the game folder."
    echo "$b" >> "$note"
  done
  say "DXMT is set up for the game in $dir"
}

game_dxmt_off() {
  local dir note b
  dir="$(game_dir)" || return 0
  note="$dir/.skywalker-dxmt"
  [ -f "$note" ] || return 0
  for b in $GAME_DLLS; do
    if /usr/bin/grep -qx "$b" "$note"; then rm -f "$dir/$b"; fi
  done
  rm -f "$note"
}

# ---- Wine's own Direct3D for Steam's browser part
# With DXMT or D3DMetal as the bottle's graphics layer, Steam's browser part
# (steamwebhelper.exe, a Chromium) loads it too. STEAM_OWN_D3D=1 keeps that
# program on Wine's own Direct3D, the combination Steam was debugged with:
# copies of Wine's own DLLs next to
# steamwebhelper.exe, without the builtin mark, are what that program then
# loads, once Wine is told that steamwebhelper.exe prefers its own copies.
# That is a setting for that one program in the bottle's registry
# (AppDefaults), so the game and everything else load exactly what they did.
STEAM_D3D_DLLS="d3d11.dll dxgi.dll d3d10core.dll d3d12.dll"

# Sets ($1 = on) or removes (off) that registry setting, through Wine's own
# regedit, once: a note in the bottle records that it is there.
steam_d3d_reg() {
  local mark="$PREFIX/.skywalker-steam-d3d" reg="$PREFIX/drive_c/skywalker-steam-d3d.reg" pid t=0 b rc
  if [ "$1" = on ]; then
    [ "$(cat "$mark" 2>/dev/null)" = "$STEAM_D3D_DLLS" ] && return 0
  else
    [ -f "$mark" ] || return 0
  fi
  {
    printf 'REGEDIT4\r\n\r\n'
    if [ "$1" = on ]; then
      printf '[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\steamwebhelper.exe\\DllOverrides]\r\n'
      for b in $STEAM_D3D_DLLS; do printf '"%s"="native,builtin"\r\n' "${b%.dll}"; done
    else
      printf '[-HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\steamwebhelper.exe]\r\n'
    fi
  } > "$reg"
  mkdir -p "$LOGS"
  wine_env
  ( limit_processes; exec "$CUR/bin/wine" regedit /S 'C:\skywalker-steam-d3d.reg' ) >> "$LOGS/steam-d3d.log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$t" -lt 120 ]; do sleep 1; t=$((t + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    rm -f "$reg"
    say "The setting for Steam's browser part could not be written in 120 s. It is tried again at the next start. See $LOGS/steam-d3d.log"
    return 1
  fi
  wait "$pid"; rc=$?
  rm -f "$reg"
  if [ "$rc" != 0 ]; then
    say "The setting for Steam's browser part could not be written (regedit ended with $rc). It is tried again at the next start."
    return 1
  fi
  if [ "$1" = on ]; then echo "$STEAM_D3D_DLLS" > "$mark"; else rm -f "$mark"; fi
}

steam_d3d_wanted() {
  [ "$STEAM_OWN_D3D" = 1 ] || return 1
  case "$(graphics_now)" in dxmt | d3dmetal) ;; *) return 1 ;; esac
  [ -n "$(steam_helper_dirs)" ]
}

# the folders that hold a steamwebhelper.exe
steam_helper_dirs() {
  local f
  for f in "$(steam_dir)"/bin/cef/*/steamwebhelper.exe; do
    if [ -f "$f" ]; then dirname "$f"; fi
  done
}

# where Wine's own copy of a DLL is while another layer has its place
wine_own_dll() {
  local w="$1" b="$2" f
  for f in "$w/d3dmetal-saved/x86_64-windows/$b" "$w/orig-dlls/x86_64-windows/$b"; do
    if [ -f "$f" ]; then echo "$f"; return 0; fi
  done
  # never displaced in this mode: the build's own
  if [ "$(graphics_now)" = dxmt ] && [ "$b" = d3d12.dll ] && [ -f "$w/lib/wine/x86_64-windows/$b" ]; then
    echo "$w/lib/wine/x86_64-windows/$b"; return 0
  fi
  return 1
}

steam_d3d_on() {
  local w dir note tag b src ok
  w="$(cd "$CUR" && pwd -P)"
  tag="build=$(current_tag) graphics=$(graphics_now)"
  steam_helper_dirs | while read -r dir; do
    note="$dir/.skywalker-wined3d"
    if [ "$(head -n 1 "$note" 2>/dev/null)" = "$tag" ]; then
      ok=1
      for b in $(sed 1d "$note"); do [ -f "$dir/$b" ] || ok=0; done
      [ "$ok" = 1 ] && continue
    fi
    for b in $STEAM_D3D_DLLS; do
      if [ -f "$dir/$b" ] && ! /usr/bin/grep -qx "$b" "$note" 2>/dev/null; then
        echo "Steam's own folder already has a $b, which the launcher will not replace: $dir"
        continue 2
      fi
    done
    echo "$tag" > "$note"
    for b in $STEAM_D3D_DLLS; do
      src="$(wine_own_dll "$w" "$b")" || continue
      if copy_as_native "$src" "$dir/$b"; then echo "$b" >> "$note"; fi
    done
    say "Steam's browser part keeps Wine's own Direct3D ($(sed 1d "$note" | tr '\n' ' ' | sed 's/ $//') in $dir)"
  done
  steam_d3d_reg on || true
}

steam_d3d_off() {
  local dir note b
  steam_helper_dirs | while read -r dir; do
    note="$dir/.skywalker-wined3d"
    [ -f "$note" ] || continue
    for b in $(sed 1d "$note"); do
      case "$b" in *.dll) rm -f "$dir/$b" ;; esac
    done
    rm -f "$note"
  done
  steam_d3d_reg off || true
}

# ---- Apple's D3DMetal
# It is not part of this project and cannot be downloaded by the launcher: the
# files come from the user's own copy of Apple's Game Porting Toolkit in
# GPTK_DIR. As in CrossOver, D3DMetal then serves every program in the bottle.

# Copies a file, a link or a folder as it is (an instant APFS copy where possible).
copy_tree() { /bin/cp -cR "$1" "$2" 2>/dev/null || /bin/cp -R "$1" "$2"; }

# Finds Apple's files below GPTK_DIR, which may be the toolkit's lib folder or
# a folder that holds "Game Porting Toolkit.app". Prints
# "<folder with x86_64-windows>|<folder with libd3dshared.dylib>".
gptk_find() {
  local shared ext d3d
  [ -d "$GPTK_DIR" ] || return 1
  while IFS= read -r shared; do
    ext="$(dirname "$shared")"
    [ -e "$ext/D3DMetal.framework" ] || continue
    # the toolkit keeps its Wine DLLs in the folder next to "external"
    if [ -f "$(dirname "$ext")/wine/x86_64-windows/d3d11.dll" ]; then
      echo "$(dirname "$ext")/wine|$ext"
      return 0
    fi
    d3d="$(/usr/bin/find "$GPTK_DIR/" -maxdepth 12 -path '*/x86_64-windows/d3d11.dll' 2>/dev/null | head -n 1)"
    if [ -n "$d3d" ]; then
      echo "$(dirname "$(dirname "$d3d")")|$ext"
      return 0
    fi
  done <<FOUND
$(/usr/bin/find "$GPTK_DIR/" -maxdepth 12 -name libd3dshared.dylib 2>/dev/null)
FOUND
  return 1
}

# Takes Apple's files out of the build again and puts back what they replaced.
d3dmetal_off() {
  local w rel
  w="$(cd "$CUR" && pwd -P)"
  [ -f "$w/d3dmetal-files" ] || return 0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    rm -f "$w/lib/wine/$rel"
    if [ -e "$w/d3dmetal-saved/$rel" ] || [ -L "$w/d3dmetal-saved/$rel" ]; then
      mv "$w/d3dmetal-saved/$rel" "$w/lib/wine/$rel"
    fi
  done < "$w/d3dmetal-files"
  # only a folder this launcher made is removed
  if [ -f "$w/lib/external/.skywalker-d3dmetal" ]; then rm -rf "$w/lib/external"; fi
  rm -rf "$w/d3dmetal-saved" "$w/d3dmetal-files"
}

# The files of Apple's that go into the build. This is the set that was put
# together by hand on the Mac and shown to work there with the game.
D3DM_WIN="d3d11.dll dxgi.dll d3d12.dll d3d10core.dll"
D3DM_UNIX="d3d11.so dxgi.so d3d12.so d3d10.so atidxx64.so nvapi64.so"

# Puts Apple's D3DMetal into the build in use: its Windows-side DLLs take the
# place of Wine's (which are kept in d3dmetal-saved), their Unix-side partners
# are links to libd3dshared.dylib, and that library and the framework go to
# lib/external, where the links point.
d3dmetal_on() {
  local w found wdir ext b n=0
  w="$(cd "$CUR" && pwd -P)"
  found="$(gptk_find)" || die "$(gptk_missing)"
  wdir="${found%%|*}"
  ext="${found#*|}"
  for b in d3d11.dll dxgi.dll; do
    [ -f "$wdir/x86_64-windows/$b" ] || die "Apple's $b is missing from $wdir/x86_64-windows."
  done
  if [ -e "$w/lib/external" ] && [ ! -f "$w/lib/external/.skywalker-d3dmetal" ]; then
    die "The build already has a lib/external folder that the launcher did not make. Install the build again."
  fi
  d3dmetal_off
  : > "$w/d3dmetal-files"
  mkdir -p "$w/d3dmetal-saved/x86_64-windows" "$w/d3dmetal-saved/x86_64-unix" "$w/lib/wine/x86_64-windows" "$w/lib/wine/x86_64-unix"
  copy_tree "$ext" "$w/lib/external" || { rm -rf "$w/lib/external"; d3dmetal_off; die "Could not copy $ext."; }
  : > "$w/lib/external/.skywalker-d3dmetal"
  /usr/bin/xattr -dr com.apple.quarantine "$w/lib/external" 2>/dev/null || true
  for b in $D3DM_WIN; do
    [ -f "$wdir/x86_64-windows/$b" ] || continue
    d3dmetal_put "$w" "x86_64-windows/$b"
    copy_tree "$wdir/x86_64-windows/$b" "$w/lib/wine/x86_64-windows/$b" || { d3dmetal_off; die "Could not copy $b from $wdir."; }
    n=$((n + 1))
  done
  for b in $D3DM_UNIX; do
    d3dmetal_put "$w" "x86_64-unix/$b"
    if [ -e "$wdir/x86_64-unix/$b" ] || [ -L "$wdir/x86_64-unix/$b" ]; then
      copy_tree "$wdir/x86_64-unix/$b" "$w/lib/wine/x86_64-unix/$b" || { d3dmetal_off; die "Could not copy $b from $wdir."; }
    else
      ln -s ../../external/libd3dshared.dylib "$w/lib/wine/x86_64-unix/$b" || { d3dmetal_off; die "Could not link $b."; }
    fi
    # every one of them must lead to a real file from inside the build
    [ -e "$w/lib/wine/x86_64-unix/$b" ] || { d3dmetal_off; die "Apple's $b does not lead to libd3dshared.dylib from inside the build."; }
    n=$((n + 1))
  done
  say "Apple's D3DMetal is in place ($n files from $wdir, and $ext)"
}

# Notes one file of the build as replaced and moves Wine's own copy aside. $1 = build, $2 = arch/name.
d3dmetal_put() {
  echo "$2" >> "$1/d3dmetal-files"
  if [ -e "$1/lib/wine/$2" ] || [ -L "$1/lib/wine/$2" ]; then mv "$1/lib/wine/$2" "$1/d3dmetal-saved/$2"; fi
}

gptk_missing() {
  echo "Apple's D3DMetal was not found in $GPTK_DIR. That folder needs Apple's Game Porting Toolkit (the app, or its lib folder: external/D3DMetal.framework, external/libd3dshared.dylib and wine/x86_64-windows/d3d11.dll). GPTK_DIR in $CONF names the folder."
}

# A build that has no graphics choice yet (newly unpacked) takes over the
# choice of the build before it, so that an update does not change the picture.
# A first install uses Apple's D3DMetal when its files are there, and split
# graphics otherwise. $1 = tag of the previous build, or "none".
adopt_graphics() {
  local prev="$1" mode="split"
  if [ -f "$CUR/GRAPHICS" ] || [ ! -d "$CUR/orig-dlls" ]; then return 0; fi
  if [ "$prev" = none ] || [ ! -d "$WINES/$prev" ]; then
    if gptk_find > /dev/null; then mode="d3dmetal"; fi
  elif [ -f "$WINES/$prev/lib/external/libd3dshared.dylib" ]; then
    # Apple's files are in the previous build, whether this launcher put them there or not
    mode="d3dmetal"
  elif [ -f "$WINES/$prev/GRAPHICS" ]; then
    mode="$(cat "$WINES/$prev/GRAPHICS")"
  fi
  case "$mode" in
    split|dxmt|wine) ;;
    d3dmetal)
      if ! gptk_find > /dev/null; then
        echo "The previous build used Apple's D3DMetal, but its files are no longer in $GPTK_DIR. Using split graphics."
        mode="split"
      fi ;;
    *) mode="split" ;;
  esac
  apply_graphics "$mode"
}

# split: DXMT for the game, Wine's own Direct3D for Steam and everything else
# dxmt:  DXMT for everything (Steam cannot show its windows)
# wine:  Wine's own Direct3D for everything
# d3dmetal: Apple's D3DMetal for everything
apply_graphics() {
  local want="$1" w
  w="$(cd "$CUR" && pwd -P)"
  # check before anything is changed
  if [ "$want" = d3dmetal ]; then
    gptk_find > /dev/null || die "$(gptk_missing)"
  fi
  d3dmetal_off
  case "$want" in
    split) set_build_dlls wine; game_dxmt_on ;;
    wine) set_build_dlls wine; game_dxmt_off ;;
    dxmt) set_build_dlls dxmt; game_dxmt_off ;;
    d3dmetal) set_build_dlls wine; game_dxmt_off; d3dmetal_on ;;
  esac
  echo "$want" > "$w/GRAPHICS"
  say "Graphics for $(current_tag): $want"
}

cmd_graphics() {
  local want="${1:-}"
  need_wine
  case "$want" in
    split|dxmt|wine|d3dmetal) ;;
    *) echo "Graphics in use: $(graphics_now). Switch with: skywalker.sh graphics split|dxmt|wine|d3dmetal"; return 0 ;;
  esac
  our_wineserver_running && die "Quit the game and Steam first."
  apply_graphics "$want"
}

# ---------------------------------------------------------------- running

count_wine_procs() { wine_pids | /usr/bin/wc -l | /usr/bin/tr -d ' '; }

# The watchdog's way of stopping Wine: everything, at once.
kill_all_wine() {
  "$CUR/bin/wineserver" -k >/dev/null 2>&1 || true
  sleep 1
  /usr/bin/pkill -9 -f '^[A-Za-z]:\\' 2>/dev/null || true
  /usr/bin/pkill -9 -f "^$WINES/" 2>/dev/null || true
}

# Runs in the background for as long as our Wine runs. If Wine's process count
# passes MAX_WINE_PROCS (a crash loop; Steam plus the game use a few dozen),
# it kills every Wine process and says so. Ends by itself once Wine is gone.
start_watchdog() {
  local max="${SKY_MAX_WINE_PROCS:-150}" log="${1:-/dev/null}"
  (
    trap '' HUP
    local n gone=0 t=0
    while :; do
      sleep 2; t=$((t + 2))
      n="$(count_wine_procs)"; n="${n:-0}"
      if [ "$n" -gt "$max" ]; then
        echo "skywalker watchdog: $n Wine processes (limit $max); stopping Wine" >> "$log"
        kill_all_wine
        notify "Wine got stuck in a loop, so it was stopped. Nothing was lost."
        exit 1
      fi
      if [ "$n" -eq 0 ] && [ "$t" -gt 30 ]; then
        gone=$((gone + 1)); [ "$gone" -ge 3 ] && exit 0
      else
        gone=0
      fi
    done
  ) </dev/null >/dev/null 2>&1 &
}

# A game started by a Steam that is already open gets that Steam's settings,
# not the ones of this run. SESSION records what the open Steam was started
# with, so that a start with other settings restarts Steam first.
SESSION="$HOME_DIR/steam-session"
IDLE="$HOME_DIR/steam-idle"
session_sig() {
  echo "$(current_tag) $(settings_line) hud=$HUD hudlog=${MTL_HUD_LOG_ENABLED:-0} debug=${WINEDEBUG:-}"
}
keep_seconds() {
  /usr/bin/awk -v m="${KEEP_STEAM_MINUTES:-0}" 'BEGIN { printf "%d", m * 60 }'
}
# Closes Steam once it has sat unused for the time given. Any later start or
# stop replaces the ticket in $IDLE, and a timer with an old ticket does nothing.
start_idle_timer() {
  local secs="$1" ticket
  ticket="$(date +%s)-$$-$RANDOM"
  echo "$ticket" > "$IDLE"
  (
    trap '' HUP
    sleep "$secs"
    [ "$(cat "$IDLE" 2>/dev/null)" = "$ticket" ] || exit 0
    game_running && exit 0
    rm -f "$IDLE"
    shutdown_wine
  ) </dev/null >/dev/null 2>&1 &
}

shutdown_wine() {
  local i
  rm -f "$SESSION" "$IDLE"
  if steam_running; then
    say "Closing Steam"
    run_wine "$STEAM_EXE" -shutdown >/dev/null 2>&1 &
    for i in $(seq 1 20); do steam_running || break; sleep 2; done
  fi
  "$CUR/bin/wineserver" -k >/dev/null 2>&1 || true
  for i in $(seq 1 10); do our_wineserver_running || break; sleep 1; done
  kill_strays
}

# Whatever Wine left behind after its server was told to stop (a program stuck
# before it reached the server, for one). Left alone while CrossOver or another
# Wine is running, because its programs look the same in the process list.
kill_strays() {
  local pids
  if other_wine_running; then return 0; fi
  pids="$(wine_pids)"
  [ -n "$pids" ] || return 0
  say "Ending leftover Wine processes: $(echo "$pids" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  sleep 2
  pids="$(wine_pids)"
  # shellcheck disable=SC2086
  if [ -n "$pids" ]; then kill -9 $pids 2>/dev/null || true; fi
}

# Whether Steam fetched a new version of itself since the time given
# ("2026-11-13 22:00:00"), going by its starter's log.
steam_updated_since() {
  local f
  f="$(steam_dir)/logs/bootstrap_log.txt"
  [ -f "$f" ] || return 1
  /usr/bin/awk -v s="[$1]" '
    substr($0, 1, 1) == "[" && substr($0, 1, 21) >= s && tolower($0) ~ /downloading update|installing update|extracting package/ { found = 1 }
    END { exit !found }' "$f"
}

# $1 = log file for Wine's output
play() {
  local log="$1" i started=0 warm=0 keep t0 t_steam="" t_helper="" t_game=""
  need_wine
  other_wine_running && die "CrossOver or another Wine is running. Quit it first."
  if game_running; then
    say "The game is already running."
    return 0
  fi
  mkdir -p "$LOGS"
  t0="$(date +%s)"
  date '+%Y-%m-%d %H:%M:%S' > "$LOGS/last-start"
  rm -f "$IDLE"
  backup_saves
  display_guard
  wine_env
  if our_wineserver_running; then
    if steam_running; then
      if [ "$(cat "$SESSION" 2>/dev/null)" = "$(session_sig)" ]; then
        warm=1
      else
        say "Steam is open with other settings, so it is restarted."
        shutdown_wine
      fi
    elif helper_running; then
      say "Steam has gone but parts of it were left running. Tidying up before the start."
      shutdown_wine
    fi
  fi
  prepare_prefix
  cd "$HOME" || true
  if [ "$warm" = 1 ]; then
    say "Steam is still open, so the game starts straight away ($(settings_line))"
    # shellcheck disable=SC2086
    run_wine "$STEAM_EXE" -applaunch "$APPID" $GAME_ARGS >> "$log" 2>&1 &
    # An open Steam starts the game within seconds. If it does not, it is not
    # in a state to do so: start again from nothing.
    for i in $(seq 1 "$WARM_WAIT"); do
      sleep 1
      if game_running; then started=1; t_game=$(( $(date +%s) - t0 )); break; fi
      steam_running || break
    done
    if [ "$started" = 1 ]; then
      t_steam=open; t_helper=open
    else
      say "The open Steam did not start the game, so Steam is started afresh."
      shutdown_wine
      warm=0
    fi
  fi
  if [ "$warm" != 1 ]; then
    say "Starting Steam and the game with $(current_tag) ($(settings_line))"
    if bottle_update_due; then note_bottle_update; else notify "Starting the game. This can take a minute." & fi
    session_sig > "$SESSION"
    start_watchdog "$log"
    # shellcheck disable=SC2086,SC2046
    run_wine "$STEAM_EXE" $STEAM_ARGS $(steam_gpu_opt $STEAM_ARGS) -applaunch "$APPID" $GAME_ARGS >> "$log" 2>&1 &

    # Wait for the game to appear: 10 minutes covers a Steam self-update.
    # The times of each stage are kept, for "skywalker.sh timeline".
    for i in $(seq 1 540); do
      sleep 1
      if [ -z "$t_steam" ] && steam_running; then t_steam=$(( $(date +%s) - t0 )); fi
      if [ -z "$t_helper" ] && helper_running; then t_helper=$(( $(date +%s) - t0 )); fi
      if game_running; then started=1; t_game=$(( $(date +%s) - t0 )); break; fi
      if [ "$i" = 40 ] && steam_updated_since "$(cat "$LOGS/last-start")"; then
        say "Steam is downloading an update of itself first. This start takes a few minutes longer."
      fi
      if [ "$i" -gt 60 ] && ! our_wineserver_running; then break; fi
    done
  fi
  # shellcheck disable=SC2086
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(cat "$LOGS/last-start")" "$(current_tag)" "${t_steam:--}" "${t_helper:--}" "${t_game:--}" "$STEAM_ARGS $(steam_gpu_opt $STEAM_ARGS)" >> "$LOGS/startup.tsv"
  if [ "$started" != 1 ]; then
    if our_wineserver_running; then
      notify "Steam is open but the game has not started. Sign in or press Play in Steam."
      echo "The game did not start within 10 minutes. Steam is left running; see $log"
      echo "Run 'bash $HOME_DIR/skywalker.sh steam' to open Steam's window, or '... stop' to close it."
    else
      notify "Steam did not start. See the log in ~/Games/skywalker/logs."
      echo "Steam did not stay running. See $log"
    fi
    return 1
  fi

  note_game_cmdline
  if [ "$warm" = 1 ]; then
    say "The game is running. It started ${t_game}s after the launcher."
  else
    say "The game is running. It started ${t_game}s after the launcher (Steam after ${t_steam:-?}s, Steam's browser part after ${t_helper:-?}s)."
    if steam_updated_since "$(cat "$LOGS/last-start")"; then say "Steam updated itself during this start, which is why it took longer than usual."; fi
  fi
  while game_running; do sleep 5; done
  say "The game has exited."
  keep="$(keep_seconds)"
  if [ "$keep" -gt 0 ] && steam_running; then
    backup_saves
    start_idle_timer "$keep"
    say "Steam stays open for $KEEP_STEAM_MINUTES minutes so that the next start is quick. To close it now: bash $HOME_DIR/skywalker.sh stop"
    return 0
  fi
  sleep 10   # give Steam a moment to upload the saves to Steam Cloud
  shutdown_wine
  backup_saves
  return 0
}

cmd_run() {
  load_conf
  mkdir -p "$LOGS"
  play "$LOGS/run-$(date +%Y%m%d-%H%M%S).log"
}

cmd_steam() {
  load_conf
  need_wine
  other_wine_running && die "CrossOver or another Wine is running. Quit it first."
  mkdir -p "$LOGS"
  prepare_prefix
  wine_env
  cd "$HOME" || true
  local log
  log="$LOGS/steam-$(date +%Y%m%d-%H%M%S).log"
  rm -f "$IDLE"
  if our_wineserver_running && steam_running; then
    say "Steam is already open; showing its window."
  else
    note_bottle_update
    session_sig > "$SESSION"
    start_watchdog "$log"
  fi
  if [ "$#" -gt 0 ]; then say "Extra Steam options: $*"; fi
  # shellcheck disable=SC2046
  run_wine "$STEAM_EXE" "$@" $(steam_gpu_opt "$@") >> "$log" 2>&1 &
  say "Steam is starting. Close it with: bash $HOME_DIR/skywalker.sh stop"
}

# Starts Steam alone, so that it is already up when the game is wanted. What
# "run" then does is the same as after a game within KEEP_STEAM_MINUTES.
cmd_prewarm() {
  load_conf
  local mins="${1:-$PREWARM_MINUTES}" secs log
  case "$mins" in '' | *[!0-9.]*) die "Use: skywalker.sh prewarm [minutes]" ;; esac
  need_wine
  other_wine_running && die "CrossOver or another Wine is running. Quit it first."
  if game_running; then
    say "The game is running, so there is nothing to prepare."
    return 0
  fi
  [ -f "$(steam_dir)/steam.exe" ] || die "Steam is not in the bottle yet ($PREFIX)."
  mkdir -p "$LOGS"
  wine_env
  secs="$(/usr/bin/awk -v m="$mins" 'BEGIN { printf "%d", m * 60 }')"
  if our_wineserver_running && steam_running; then
    if [ "$(cat "$SESSION" 2>/dev/null)" = "$(session_sig)" ]; then
      if [ "$secs" -gt 0 ]; then start_idle_timer "$secs"; else rm -f "$IDLE"; fi
      say "Steam is already open, so the next start of the game is quick."
      return 0
    fi
    say "Steam is open with other settings, so it is restarted."
    shutdown_wine
  fi
  prepare_prefix
  cd "$HOME" || true
  log="$LOGS/prewarm.log"
  : > "$log"
  note_bottle_update
  session_sig > "$SESSION"
  start_watchdog "$log"
  # shellcheck disable=SC2086,SC2046
  run_wine "$STEAM_EXE" $STEAM_ARGS $(steam_gpu_opt $STEAM_ARGS) >> "$log" 2>&1 &
  if [ "$secs" -gt 0 ]; then
    start_idle_timer "$secs"
    say "Steam is starting in the background. It closes again in $mins minutes if the game is not played. To close it now: bash $HOME_DIR/skywalker.sh stop"
  else
    rm -f "$IDLE"
    say "Steam is starting in the background and stays open. To close it: bash $HOME_DIR/skywalker.sh stop"
  fi
}

# "autostart on" asks macOS to run "prewarm" at every log-in (a launch agent
# in the user's own Library; nothing system-wide and no administrator rights).
AGENT_LABEL="io.github.jeswr.skywalker.prewarm"
AGENT="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LAUNCHCTL="${SKY_LAUNCHCTL:-/bin/launchctl}"
xml_text() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

cmd_autostart() {
  load_conf
  local dom
  dom="gui/$(id -u)"
  case "${1:-status}" in
    on)
      [ -x "$LAUNCHCTL" ] || die "This needs macOS."
      [ -f "$HOME_DIR/skywalker.sh" ] || die "Run 'install' first: the launcher is not in $HOME_DIR."
      mkdir -p "$(dirname "$AGENT")" "$LOGS"
      # Interactive: no background throttling for Steam, or for the game it starts.
      # AbandonProcessGroup: Steam stays when the launcher script itself has ended.
      cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml_text "$HOME_DIR/skywalker.sh")</string>
    <string>prewarm</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SKYWALKER_HOME</key><string>$(xml_text "$HOME_DIR")</string>
    <key>SKYWALKER_APP</key><string>$(xml_text "$APP")</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>$(xml_text "$LOGS/autostart.log")</string>
  <key>StandardErrorPath</key><string>$(xml_text "$LOGS/autostart.log")</string>
</dict>
</plist>
EOF
      "$LAUNCHCTL" bootout "$dom/$AGENT_LABEL" >/dev/null 2>&1 || true
      "$LAUNCHCTL" bootstrap "$dom" "$AGENT" || { rm -f "$AGENT"; die "macOS did not accept the log-in item."; }
      say "Steam is now started in the background at every log-in (and right now), for $PREWARM_MINUTES minutes each time."
      say "To undo: bash $HOME_DIR/skywalker.sh autostart off"
      ;;
    off)
      if [ -x "$LAUNCHCTL" ]; then "$LAUNCHCTL" bootout "$dom/$AGENT_LABEL" >/dev/null 2>&1 || true; fi
      rm -f "$AGENT"
      say "Steam is no longer started at log-in. (A Steam that is open now stays until 'stop' or its timer.)"
      ;;
    status)
      if [ -f "$AGENT" ]; then echo "Autostart: on ($AGENT)"; else echo "Autostart: off"; fi
      ;;
    *) die "Use: skywalker.sh autostart on|off" ;;
  esac
}

# One line per Wine program: process id, processor seconds used so far, name.
cpu_snapshot() {
  /bin/ps -x -o pid=,time=,command= | /usr/bin/awk -v w="$WINES/" '{
    pid = $1; t = $2; rest = $0; sub(/^ *[0-9]+ +[0-9:.-]+ +/, "", rest)
    if (!(rest ~ /^[A-Za-z]:\\/ || index(rest, w) == 1)) next
    n = split(t, a, /[:-]/)
    if (n == 4) s = ((a[1] * 24 + a[2]) * 60 + a[3]) * 60 + a[4]
    else { s = 0; for (i = 1; i <= n; i++) s = s * 60 + a[i] }
    name = rest
    if (match(rest, /[^\\\/]*\.[Ee][Xx][Ee]/)) name = substr(rest, RSTART, RLENGTH)
    else { sub(/ .*/, "", name); sub(/.*\//, "", name) }
    if (match(rest, /--type=[a-z-]+/)) name = name " " substr(rest, RSTART + 7, RLENGTH - 7)
    printf "%s\t%.2f\t%s\n", pid, s, name
  }'
}

# How busy Wine is: for an idle Steam this is what keeping it open costs.
cmd_cpu() {
  load_conf
  local secs="${1:-30}" a b
  case "$secs" in '' | *[!0-9]*) die "Use: skywalker.sh cpu [seconds]" ;; esac
  [ "$secs" -gt 0 ] || secs=30
  a="$(cpu_snapshot)"
  [ -n "$a" ] || { echo "Wine is not running."; return 0; }
  sleep "$secs"
  b="$(cpu_snapshot)"
  printf '%s\n=\n%s\n' "$a" "$b" | /usr/bin/awk -F '\t' -v secs="$secs" '
    $0 == "=" { second = 1; next }
    !second { before[$1] = $2; next }
    ($1 in before) { d = $2 - before[$1]; if (d < 0) d = 0; total += d; n++; use[n] = d; name[n] = $3 }
    END {
      printf "Wine used %.1f%% of one processor core over %d seconds (%d programs).\n", 100 * total / secs, secs, n
      for (k = 1; k <= 5; k++) {
        best = 0
        for (i = 1; i <= n; i++) if (use[i] > 0 && (best == 0 || use[i] > use[best])) best = i
        if (best == 0) break
        printf "  %5.1f%%  %s\n", 100 * use[best] / secs, name[best]
        use[best] = 0
      }
    }'
}

cmd_stop() {
  load_conf
  need_wine
  wine_env
  shutdown_wine
  say "Stopped."
}

# Shows where the time went in the last start: the launcher's own stopwatch,
# then the lines of Steam's logs that mark each stage.
cmd_timeline() {
  local since logs f
  load_conf
  since="$(cat "$LOGS/last-start" 2>/dev/null || true)"
  [ -n "$since" ] || die "No start has been recorded yet. Start the game once with this launcher first."
  logs="$(steam_dir)/logs"
  echo "Launcher started: $since"
  if [ -f "$LOGS/startup.tsv" ]; then
    tail -n 1 "$LOGS/startup.tsv" | /usr/bin/awk -F'\t' '{
      printf "Seconds until: Steam running %s, Steam browser part running %s, game running %s\n", $3, $4, $5
      printf "Build: %s   Steam options: %s\n", $2, $6 }'
  fi
  if steam_updated_since "$since"; then echo "Steam downloaded and installed an update of itself during this start; that is extra time a normal start does not have."; fi
  if [ -f "$LOGS/game-starts.tsv" ]; then
    /usr/bin/awk -F'\t' -v s="$since" '$1 == s { printf "Graphics: %s\nThe game was started as: %s\n", $3, $4 }' "$LOGS/game-starts.tsv" | tail -n 2
  fi
  echo "Steam's logs from then on:"
  for f in bootstrap_log.txt steamui_html.txt webhelper.txt connection_log.txt console_log.txt content_log.txt gameprocess_log.txt cloud_log.txt; do
    [ -f "$logs/$f" ] || continue
    /usr/bin/awk -v s="[$since]" -v f="${f%.txt}" -v id="$APPID" '
      substr($0, 1, 1) == "[" && substr($0, 1, 21) >= s {
        if ($0 ~ /Startup - updater built|Verification complete|Downloading update\.\.\.|Download complete|Download skipped|Update complete|Started webhelper|Restart webhelper|BrowserReady|GPU process restarts|Startup - webhelper launched|LogOnResponse|Logged On|logged on|Game process|App Running|Console Log Start/ || index($0, id))
          print substr($0, 13, 8), f ": " substr($0, 23, (f == "gameprocess_log") ? 400 : 140)
      }' "$logs/$f"
  done | sort -s -k1,1 | head -n 80
}

# ---------------------------------------------------------------- benchmark

# Apple's frame counter writes, once a second:
#   metal-HUD: <first frame>,<graphics MB>,<process MB>,<interval ms>,<gpu ms>,<interval ms>,<gpu ms>,...
# Reads such lines from the files given and prints a summary.
summarise() {
  local all frames best
  all="$(mktemp "${TMPDIR:-/tmp}/skywalker-frames.XXXXXX")"
  frames="$all.best"
  # One line per frame: <source> <interval ms> <gpu ms>. The source is the process
  # that logged it or "output" (lines without a process name), because
  # Steam's windows can log frames too.
  cat "$@" 2>/dev/null | awk '
    {
      i = index($0, "metal-HUD:")
      if (!i) next
      key = "output"
      if (match(substr($0, 1, i), /[^ ]+\[[0-9]+:[0-9a-fA-Fx]+\]/)) {
        # name[process:thread]: the thread is dropped, a game draws from several
        key = substr($0, RSTART, RLENGTH)
        sub(/:[0-9a-fA-Fx]+\]$/, "]", key)
      }
      s = substr($0, i + 10)
      gsub(/[ \t\r]/, "", s)
      n = split(s, f, ",")
      if (n < 5) next
      for (j = 4; j + 1 <= n; j += 2)
        if (f[j] + 0 > 0) printf "%s %.3f %.3f\n", key, f[j], f[j + 1]
    }' > "$all"
  best="$(awk '{ c[$1]++ } END { for (k in c) if (c[k] > m) { m = c[k]; b = k } print b }' "$all")"
  if [ -z "$best" ]; then
    rm -f "$all"
    echo "No frame data found."
    return 1
  fi
  awk -v k="$best" '$1 == k { print $2, $3 }' "$all" > "$frames"
  echo "source=$best"
  # whole run
  sort -n -r "$frames" | awk '
    { iv[NR] = $1; t += $1; g += $2 }
    END {
      k = int(NR / 100); if (k < 1) k = 1
      for (i = 1; i <= k; i++) w += iv[i]
      printf "frames=%d seconds=%.0f avg_fps=%.1f low1_fps=%.1f avg_gpu_ms=%.2f\n", NR, t / 1000, NR * 1000 / t, k * 1000 / w, g / NR
    }'
  # minute by minute, to pick out the steady part
  awk '
    function worst1(   i, j, k, c, w) {
      # average of the slowest 1% of intervals in this minute
      k = int(n / 100); if (k < 1) k = 1
      w = 0
      for (c = 1; c <= k; c++) {
        j = 1
        for (i = 2; i <= n; i++) if (v[i] > v[j]) j = i
        w += v[j]; v[j] = -1
      }
      return w / k
    }
    function report() {
      if (!n) return
      printf "  minute %2d: %5.1f fps, slowest 1%% %5.1f fps\n", minute + 1, n * 1000 / t, 1000 / worst1()
    }
    { if (t + $1 > 60000) { report(); minute++; n = 0; t = 0 } n++; v[n] = $1; t += $1 }
    END { report() }' "$frames"
  rm -f "$all" "$frames"
}

cmd_bench() {
  local label="${1:-test}" stamp base log sys pid line
  load_conf
  mkdir -p "$BENCH"
  label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_')"
  stamp="$(date +%Y%m%d-%H%M%S)"
  base="$BENCH/$stamp-$label"
  log="$base.wine.log"
  sys="$base.system.log"
  HUD=1
  export MTL_HUD_LOG_ENABLED=1
  mkdir -p "$BENCH/reports"
  export MTL_HUD_REPORT_URL="$BENCH/reports"
  # The counter may write to the system log instead of the game's output, so record both.
  /usr/bin/log stream --style compact --predicate 'eventMessage CONTAINS "metal-HUD:"' > "$sys" 2>/dev/null &
  pid=$!
  play "$log"
  kill "$pid" 2>/dev/null || true
  {
    echo "label=$label build=$(current_tag) $(settings_line)"
    echo "macos=$(/usr/bin/sw_vers -productVersion 2>/dev/null) date=$stamp"
    summarise "$log" "$sys"
  } | tee "$base.summary.txt"
  line="$(grep '^frames=' "$base.summary.txt" | head -n 1)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$stamp" "$label" "$(current_tag)" "$(settings_line)" "$line" >> "$BENCH/results.tsv"
  say "Summary saved to $base.summary.txt"
}

# ---------------------------------------------------------------- upkeep

# which of the named files a folder has: "d3d11.dll dxgi.dll" or "d3d11.dll, not in the toolkit: dxgi.dll"
d3dm_have() {
  local dir="$1" f have="" miss=""
  shift
  for f in "$@"; do
    if [ -e "$dir/$f" ]; then have="$have $f"; else miss="$miss $f"; fi
  done
  if [ -n "$miss" ]; then echo "${have# }, not in the toolkit:$miss"; else echo "${have# }"; fi
}

cmd_doctor() {
  load_conf
  local name n
  echo "macOS:        $(/usr/bin/sw_vers -productVersion 2>/dev/null) ($(uname -m))"
  if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then echo "Rosetta:      installed"; else echo "Rosetta:      MISSING"; fi
  echo "Build in use: $(current_tag)"
  if [ -f "$CUR/BUILD-INFO" ]; then sed 's/^/              /' "$CUR/BUILD-INFO"; fi
  if [ -d "$CUR/lib/wine" ]; then
    n="$(find "$CUR/lib/wine/" -name '*.dll' | wc -l | tr -d ' ')"
    echo "Windows DLLs: $n (well under 1000 means Sophos removed some)"
    for name in libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib; do
      if [ -f "$CUR/lib/$name" ]; then echo "Library:      $name ok"; else echo "Library:      $name MISSING"; fi
    done
  fi
  if [ -d "$PREFIX/drive_c" ]; then echo "Bottle:       $PREFIX"; else echo "Bottle:       MISSING ($PREFIX)"; fi
  if [ -f "$(steam_dir)/steam.exe" ]; then echo "Steam:        installed"; else echo "Steam:        MISSING from the bottle"; fi
  name="$(game_dir_name || true)"
  if [ -n "$name" ]; then echo "Game:         $name"; else echo "Game:         not installed in Steam (ID $APPID)"; fi
  echo "Graphics:     $(graphics_now)"
  if name="$(gptk_find)"; then
    echo "D3DMetal:     Apple's files found in $GPTK_DIR"
    echo "              Windows side: ${name%%|*}/x86_64-windows ($(d3dm_have "${name%%|*}/x86_64-windows" $D3DM_WIN))"
    echo "              Unix side:    ${name%%|*}/x86_64-unix ($(d3dm_have "${name%%|*}/x86_64-unix" $D3DM_UNIX))"
    echo "              Framework:    ${name#*|} ($(d3dm_have "${name#*|}" libd3dshared.dylib D3DMetal.framework))"
  else
    echo "D3DMetal:     Apple's files not found in $GPTK_DIR (only needed for: graphics d3dmetal)"
  fi
  if bottle_update_due; then echo "Bottle:       still to be updated for this build (the next start does it and takes a few minutes longer, once; or: skywalker.sh update-bottle)"; fi
  echo "Settings:     $(settings_line) hud=$HUD"
  if [ -f "$DISPLAY_KEEP" ]; then echo "Display:      kept ($(tr '\n' ',' < "$DISPLAY_KEEP" | sed 's/,$//; s/,/, /g'))"; else echo "Display:      as the game writes it (display keep holds it)"; fi
  echo "Save backups: $(ls -1d "$SAVE_BACKUP_DIR"/20??-??-??_?????? 2>/dev/null | wc -l | tr -d ' ') in $SAVE_BACKUP_DIR"
  if [ -f "$AGENT" ]; then echo "Autostart:    on (Steam is started at log-in for $PREWARM_MINUTES minutes)"; else echo "Autostart:    off"; fi
  if our_wineserver_running; then echo "Wine running: yes"; else echo "Wine running: no"; fi
  echo "Processes:    $(count_wine_procs) from Wine, $(/bin/ps -x -o pid= | /usr/bin/wc -l | /usr/bin/tr -d ' ') in all, limit $(ulimit -u) (Wine is held to $PROC_HEADROOM more than are running)"
  if game_running; then echo "Game running: yes"; else echo "Game running: no"; fi
  if other_wine_running; then echo "Other Wine:   CrossOver or another Wine is running"; fi
}

# Asks the Mac's window server which windows Wine has on screen. This tells
# "Wine is running but shows nothing" apart from "the window is just hidden
# behind something". Titles only appear if the terminal may record the screen.
cmd_windows() {
  local pids js out
  load_conf
  pids="$(wine_pids | /usr/bin/tr '\n' ',')"
  if [ -z "$pids" ]; then echo "Wine is not running."; return 1; fi
  mkdir -p "$HOME_DIR/cache"
  js="$HOME_DIR/cache/windows.js"
  cat > "$js" <<'EOF'
function run(argv) {
  ObjC.import('CoreGraphics');
  var want = {};
  argv[0].split(',').forEach(function (p) { if (p) want[p] = true; });
  var ref = $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0);
  var list = ObjC.deepUnwrap(ObjC.castRefToObject(ref)) || [];
  var out = [];
  list.forEach(function (w) {
    if (!want[String(w.kCGWindowOwnerPID)]) return;
    var b = w.kCGWindowBounds || {};
    out.push([w.kCGWindowOwnerPID, Math.round(b.Width) + 'x' + Math.round(b.Height),
      'layer ' + w.kCGWindowLayer, w.kCGWindowOwnerName || '?', w.kCGWindowName || '',
      'at ' + Math.round(b.X) + ',' + Math.round(b.Y), 'alpha ' + w.kCGWindowAlpha,
      'id ' + w.kCGWindowNumber].join('\t'));
  });
  return out.join('\n');
}
EOF
  out="$(/usr/bin/osascript -l JavaScript "$js" "$pids")" || { echo "Could not read the window list."; return 2; }
  if [ -z "$out" ]; then
    echo "Wine is running ($(count_wine_procs) processes) but has no window on screen."
    return 1
  fi
  echo "$out"
}

cmd_uninstall() {
  local answer
  load_conf
  our_wineserver_running && die "Quit the game first."
  echo "This removes $APP and $HOME_DIR (downloaded builds, logs, benchmark results)."
  echo "It keeps the bottle at $PREFIX and the save backups in $SAVE_BACKUP_DIR."
  printf 'Type yes to continue: '
  read -r answer
  [ "$answer" = yes ] || { echo "Nothing removed."; return 0; }
  if [ -f "$AGENT" ]; then cmd_autostart off; fi
  case "$APP" in */"Skywalker Saga.app") rm -rf "$APP" ;; esac
  case "$HOME_DIR" in */skywalker) rm -rf "$HOME_DIR" ;; esac
  echo "Removed."
}

case "${1:-run}" in
  install) shift; cmd_install "${1:-}" ;;
  update) cmd_install "" ;;
  rollback) cmd_rollback ;;
  graphics) shift; load_conf; cmd_graphics "${1:-}" ;;
  adopt-graphics) shift; load_conf; need_wine; adopt_graphics "${1:-none}" ;;   # used by the tests
  update-bottle) load_conf; need_wine; update_bottle ;;   # what install does after switching builds
  run) cmd_run ;;
  steam) shift; cmd_steam "$@" ;;
  stop) cmd_stop ;;
  prewarm) shift; cmd_prewarm "${1:-}" ;;
  autostart) shift; cmd_autostart "${1:-status}" ;;
  cpu) shift; cmd_cpu "${1:-30}" ;;
  display) shift; cmd_display "${1:-show}" ;;
  bench) shift; cmd_bench "${1:-test}" ;;
  summary) shift; summarise "$@" ;;
  backup) load_conf; backup_saves ;;
  app) load_conf; create_app ;;
  doctor) cmd_doctor ;;
  windows) cmd_windows ;;
  timeline) cmd_timeline ;;
  wine) shift; load_conf; need_wine; wine_env; mkdir -p "$LOGS"; start_watchdog "$LOGS/watchdog.log"; limit_processes; exec "$CUR/bin/wine" "$@" ;;
  uninstall) cmd_uninstall ;;
  *) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
