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
#   skywalker.sh display auto|keep|off|show|screen
#                                auto (default): fit the game to the screen it opens on (built-in,
#                                monitor, projector, mirrored) at every start, and fit its window
#                                again if the screens change while it runs; keep: always put back
#                                the screen settings the game has now; off: leave them alone;
#                                screen: show what the main screen is and what the game would get
#   skywalker.sh refit           fit the running game's window to the main screen now
#   skywalker.sh app             make the app (with the game's icon) and put it in the Dock,
#                                replacing older or CrossOver game icons there
#   skywalker.sh dock            only the Dock part of that
#   skywalker.sh prewarm [min]   start Steam now, without a window and without the game, so that
#                                the next "run" skips Steam's slow start; it closes again after
#                                PREWARM_MINUTES (or the minutes given) if the game is not played
#   skywalker.sh autostart on|off
#                                on: do that prewarm by itself every time you log in to the Mac
#   skywalker.sh ready on|off    on: keep Steam ready but paused. Steam starts at log-in, signs in
#                                and is then paused (no processor, no battery; its memory stays);
#                                a click on the game resumes it and the game starts in seconds.
#                                After a game Steam is paused again instead of closed.
#   skywalker.sh cpu [seconds]   measure how much processor time Wine's programs use (troubleshooting)
#   skywalker.sh pause           pause the game mid-level: hide it and freeze it (and Steam and Wine)
#                                where it is, using no processor time; survives the Mac sleeping,
#                                not a restart or shutdown
#   skywalker.sh resume          carry on with a paused game (clicking the game's icon does this too)
#   skywalker.sh toggle-pause    pause or resume, whichever fits (what the Pause app runs)
#   skywalker.sh hotkey [keys|off]
#                                the key combination that pauses and resumes while the game runs:
#                                ctrl-option-p unless set otherwise; it opens the game's own pause
#                                menu (Esc) before freezing it. No permission needed.
#   skywalker.sh pause-app       make the Pause app (game icon with a pause sign) and put it in the
#                                Dock next to the game; Spotlight finds it too: Cmd-Space, "pause"
#   skywalker.sh stop            shut down Steam and Wine
#   skywalker.sh doctor          show what is installed and what is missing
#   skywalker.sh wine <args>     run any Wine program with the launcher's settings (troubleshooting)
#   skywalker.sh windows         list the windows Wine has on screen (troubleshooting)
#   skywalker.sh timeline        show where the time went in the last start (troubleshooting)
#   skywalker.sh snapshot        while the game shows something wrong (a black screen, a freeze):
#                                write what can be seen from outside to one file (troubleshooting)
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
die() {
  echo "skywalker: $*" >&2
  if [ -n "${UI_T0:-}" ]; then ui_status failed "$*"; fi
  notify "$*"
  exit 1
}
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
# Options for the game itself: this one skips the logos and the intro film.
# Steam adds them to the Launch Options set for the game in Steam, and the
# game takes a switch given twice as not given, so the launcher leaves out
# any that Steam's Launch Options already hold.
GAME_ARGS="-skipvideos"
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
# 1 = for one run that goes looking for a graphics fault: frame counter on,
# Apple's Metal validation on (it logs wrong Metal calls instead of stopping),
# Wine's error lines on. Slower; not for normal play.
GFX_DEBUG=0

# 1 = while the game runs, notice when the screens change (a monitor or
# projector plugged in or out, mirroring switched) and fit the game's window
# to the new screen. 0 = only fit at the start. See "display".
REFIT=1

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
  : "${GAME_ARGS=-skipvideos}" "${GFX_DEBUG:=0}" "${WARM_WAIT:=45}" "${STEAM_OWN_D3D:=0}"
  : "${PAUSE_AFTER_GAME:=90}" "${PAUSE_AFTER_READY:=30}"
  # which lines of the game's settings file "display keep" looks after (by the first word of the line)
  : "${DISPLAY_KEYS:=^(Screen(Width|Height|RefreshRate|Left|Top)|Window(Width|Height|Left|Top|ed)|BorderlessWindow|Full[Ss]creen(Window|MonitorIndex)?|AspectRatio)\$}"
  : "${REFIT:=1}"
  for k in MSYNC UPSCALE UPSCALE_FACTOR FPS_CAP AVX HUD STEAM_ARGS STEAM_GPU PREFIX PROC_HEADROOM KEEP_STEAM_MINUTES GPTK_DIR D3DMETAL_HOOK DISPLAY_KEYS PREWARM_MINUTES WARM_WAIT STEAM_OWN_D3D GFX_DEBUG REFIT PAUSE_AFTER_GAME PAUSE_AFTER_READY; do
    v="SKY_$k"
    if [ -n "${!v:-}" ]; then eval "$k=\${$v}"; fi
  done
  # an empty SKY_GAME_ARGS means: no options for the game
  if [ -n "${SKY_GAME_ARGS+set}" ]; then GAME_ARGS="$SKY_GAME_ARGS"; fi
}

settings_line() {
  echo "graphics=$(graphics_now) msync=$MSYNC upscale=$UPSCALE factor=$UPSCALE_FACTOR cap=$FPS_CAP avx=$AVX d3dmhook=$D3DMETAL_HOOK steamd3d=$STEAM_OWN_D3D gfxdebug=$GFX_DEBUG"
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

# The Launch Options set for the game in Steam itself (Properties), read from
# the settings file of the Steam user who was active last. Steam keeps them in
# memory while it runs and writes the file when it closes.
steam_launch_options() {
  local f newest="" d
  d="$(steam_dir)/userdata"
  for f in "$d"/*/config/localconfig.vdf; do
    [ -f "$f" ] || continue
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
  done
  [ -n "$newest" ] || return 0
  /usr/bin/awk -v id="\"$APPID\"" '
    { line = $0; gsub(/^[ \t]+|[ \t\r]+$/, "", line) }
    !inapp && line == id { want = 1; next }
    want && line == "{" { inapp = 1; depth = 1; want = 0; next }
    want { want = 0 }
    inapp {
      if (line == "{") depth++
      else if (line == "}") { depth--; if (depth == 0) inapp = 0 }
      else if (depth == 1 && match(line, /^"LaunchOptions"[ \t]+"/)) {
        v = substr(line, RLENGTH + 1); sub(/"$/, "", v)
        gsub(/\\"/, "\"", v); gsub(/\\\\/, "\\", v)
        print v; exit
      }
    }' "$newest"
}

# GAME_ARGS without the options Steam's Launch Options already hold.
game_args() {
  local have w out=""
  have=" $(steam_launch_options | tr 'A-Z\t' 'a-z ') "
  for w in $GAME_ARGS; do
    case "$have" in
      *" $(echo "$w" | tr 'A-Z' 'a-z') "*) ;;
      *) out="${out:+$out }$w" ;;
    esac
  done
  echo "$out"
}

# Says so when an option is left out for that reason.
note_game_args() {
  local eff="$1"
  [ "$eff" = "$GAME_ARGS" ] && return 0
  say "Steam's own Launch Options for the game already have some of the launcher's options ($(steam_launch_options)), so the launcher adds only: ${eff:-nothing}"
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
  resume_wine > /dev/null
  ( limit_processes; exec "$CUR/bin/wine" "$@" )
}

wine_env() {
  export WINEPREFIX="$PREFIX"
  export USER="$WINE_USER"
  if [ "$GFX_DEBUG" = 1 ]; then
    export WINEDEBUG="${WINEDEBUG:-fixme-all}"
  else
    export WINEDEBUG="${WINEDEBUG:--all}"
  fi
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

  if [ "$HUD" = 1 ] || [ "$GFX_DEBUG" = 1 ]; then export MTL_HUD_ENABLED=1; else unset MTL_HUD_ENABLED; fi
  if [ "$GFX_DEBUG" = 1 ]; then
    export MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=nslog MTL_DEBUG_LAYER_WARNING_MODE=nslog
  else
    unset MTL_DEBUG_LAYER MTL_DEBUG_LAYER_ERROR_MODE MTL_DEBUG_LAYER_WARNING_MODE
  fi
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

# The game keeps its settings in PCCONFIG.TXT, one "Name value" per line. Its
# screen and window lines decide the size of the picture. The launcher looks
# after them in one of three ways ("display auto|keep|off", kept in display.mode):
#
#   auto (the default): before every start, the screen the game will open on is
#     measured (the Mac's main screen: the one with the menu bar, or the mirrored
#     picture when screens are mirrored) and the lines are set to fill exactly
#     that screen, borderless. The built-in screen, a monitor and a projector each
#     get their own size. While the game runs, a change of screens (a monitor or
#     projector plugged in or out, mirroring switched, the resolution changed) is
#     noticed within seconds and the game's window is fitted to the new screen.
#   keep: the lines noted by "display keep" are put back before every start.
#   off: the lines are left as the game writes them.
#
# No other line of the file is ever touched, and the file is copied to
# settings-backups before each change.
DISPLAY_KEEP="$HOME_DIR/display.keep"
DISPLAY_MODE_FILE="$HOME_DIR/display.mode"
LAST_FIT="$HOME_DIR/display.last-fit"
SCREEN_WATCH_PID="$HOME_DIR/.screen-watch.pid"
SKYFIT="$HOME_DIR/tools/skyfit.exe"

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

display_mode() {
  local m
  m="$(head -n 1 "$DISPLAY_MODE_FILE" 2>/dev/null | tr -d '[:space:]')"
  case "$m" in
    auto|keep|off) echo "$m" ;;
    # before display.mode existed, "display keep" alone meant keep
    *) if [ -f "$DISPLAY_KEEP" ]; then echo keep; else echo auto; fi ;;
  esac
}

# $1 = a file of "Name value" lines, $2 = what to call them in messages.
# Gives each line of the game's file with the same name the value from $1,
# keeping the file's own spacing and line ends. Copies the file first.
display_apply() {
  local want="$1" why="$2" f tmp changes dir old
  f="$(pcconfig)" || return 0
  tmp="$HOME_DIR/.pcconfig.new"
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
    }' "$want" "$f" > "$tmp" 2> "$tmp.changes" || { rm -f "$tmp" "$tmp.changes"; return 0; }
  changes="$(tr '\n' ',' < "$tmp.changes" | sed 's/,$//; s/,/, /g')"
  if [ -z "$changes" ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp" "$tmp.changes"
    return 0
  fi
  dir="$HOME_DIR/settings-backups"
  mkdir -p "$dir"
  old="$dir/PCCONFIG-$(date +%Y%m%d-%H%M%S).TXT"
  [ ! -e "$old" ] || old="${old%.TXT}-$$.TXT"
  cp -p "$f" "$old"
  ls -1 "$dir"/PCCONFIG-*.TXT 2>/dev/null | sort -r | tail -n +21 | while read -r old; do
    case "$old" in "$dir"/PCCONFIG-*) rm -f "$old" ;; esac
  done
  cat "$tmp" > "$f"
  rm -f "$tmp" "$tmp.changes"
  say "$why: $changes"
}

display_guard() {
  [ -f "$DISPLAY_KEEP" ] || return 0
  display_apply "$DISPLAY_KEEP" "The game's screen settings had changed and were put back" || return 0
}

# Writes the small script that measures the screens, if it is not there or
# differs. JavaScript for Automation ships with every Mac: nothing to install.
screens_js() {
  local f="$HOME_DIR/lib/screens.js"
  mkdir -p "$HOME_DIR/lib"
  cat > "$f.new" <<'EOF'
// The Mac's main screen as Wine sees it. Run with: osascript -l JavaScript screens.js [watch SECS MAXSECS]
// One line: main=ID size=WxH hz=N pixels=WxH builtin=0|1 mirror=0|1 screens=N name=TEXT
// "size" is in points, which is what Wine (without its Retina mode) reports to Windows programs.
// watch: prints that line now and again whenever the main screen changes; stops when its
// parent process has gone or after MAXSECS.
ObjC.import('Foundation');
ObjC.import('CoreGraphics');
ObjC.import('AppKit');
ObjC.bindFunction('getppid', ['int', []]);

function out(s) {
  $.NSFileHandle.fileHandleWithStandardOutput.writeData($(s + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
}

function count() {
  try {
    var n = Ref();
    n[0] = 0;
    if ($.CGGetOnlineDisplayList(0, null, n) !== 0) return 0;
    return n[0];
  } catch (e) { return 0; }
}

function line(withName) {
  var id = $.CGMainDisplayID();
  var mode = $.CGDisplayCopyDisplayMode(id);
  var w = 0, h = 0, pw = 0, ph = 0, hz = 0, name = '';
  if (mode) {
    w = $.CGDisplayModeGetWidth(mode);
    h = $.CGDisplayModeGetHeight(mode);
    pw = $.CGDisplayModeGetPixelWidth(mode);
    ph = $.CGDisplayModeGetPixelHeight(mode);
    hz = Math.round($.CGDisplayModeGetRefreshRate(mode));
    try { $.CGDisplayModeRelease(mode); } catch (e) {}
  }
  if (!w) { w = $.CGDisplayPixelsWide(id); h = $.CGDisplayPixelsHigh(id); }
  if (withName) {
    try {
      var screens = $.NSScreen.screens;
      for (var i = 0; i < screens.count; i++) {
        var s = screens.objectAtIndex(i);
        var num = s.deviceDescription.objectForKey('NSScreenNumber');
        if (num && num.unsignedIntValue == id) {
          if (!hz) { try { hz = s.maximumFramesPerSecond; } catch (e) {} }
          try { name = s.localizedName.js; } catch (e) {}
        }
      }
    } catch (e) {}
  }
  if (!hz) hz = 60;
  return 'main=' + id + ' size=' + w + 'x' + h + ' hz=' + hz + ' pixels=' + pw + 'x' + ph +
    ' builtin=' + ($.CGDisplayIsBuiltin(id) ? 1 : 0) + ' mirror=' + ($.CGDisplayIsInMirrorSet(id) ? 1 : 0) +
    ' screens=' + count() + (name ? ' name=' + name.replace(/[\r\n]/g, ' ') : '');
}

// what decides whether the game has to be fitted again
function key(l) { return l.replace(/ name=.*$/, ''); }

function run(argv) {
  if (argv[0] !== 'watch') { out(line(true)); return; }
  var every = Number(argv[1]) || 2, max = Number(argv[2]) || 43200;
  var parent = $.getppid(), shown = line(true), seen = key(shown), t = 0, pending = '';
  out(shown);
  while (t < max) {
    delay(every);
    t += every;
    var p = $.getppid();
    if (p !== parent || p === 1) return;   // the launcher has gone
    var now = line(false);
    if (key(now) === seen) { pending = ''; continue; }
    // the same new state twice in a row: the change has settled
    if (key(now) !== pending) { pending = key(now); continue; }
    seen = pending;
    pending = '';
    out(now);
  }
}
EOF
  if /usr/bin/cmp -s "$f.new" "$f"; then rm -f "$f.new"; else mv "$f.new" "$f"; fi
  echo "$f"
}

# One line about the main screen (see screens.js), or nothing if it cannot be measured.
# SKY_SCREEN_LINE stands in for the measurement (tests).
screen_now() {
  local js out
  if [ -n "${SKY_SCREEN_LINE:-}" ]; then
    out="$SKY_SCREEN_LINE"
  else
    js="$(screens_js)"
    out="$(bounded_quiet 15 /usr/bin/osascript -l JavaScript "$js" 2>/dev/null | head -n 1)"
  fi
  case "$out" in main=*" size="[1-9]*x[1-9]*) echo "$out" ;; *) return 1 ;; esac
}

# $1 = a screen line, $2 = the field
screen_field() { printf '%s\n' "$1" | sed -n "s/.* $2=\\([^ ]*\\).*/\\1/p; s/^$2=\\([^ ]*\\).*/\\1/p" | head -n 1; }
screen_name() { printf '%s\n' "$1" | sed -n 's/.* name=//p'; }

# "the built-in screen", "an external screen (DELL U2419H)", "mirrored screens", in words
screen_words() {
  local l="$1" n what
  n="$(screen_name "$l")"
  if [ "$(screen_field "$l" mirror)" = 1 ]; then what="mirrored screens"
  elif [ "$(screen_field "$l" builtin)" = 1 ]; then what="the built-in screen"
  else what="an external screen"; fi
  echo "$what${n:+ ($n)}, $(screen_field "$l" size) at $(screen_field "$l" hz) Hz"
}

# The screen and window lines that fill the screen described by $1, borderless.
fit_lines() {
  local l="$1" size w h hz px
  size="$(screen_field "$l" size)"; w="${size%x*}"; h="${size#*x}"
  hz="$(screen_field "$l" hz)"
  case "$hz" in ''|*[!0-9]*|0) hz=60 ;; esac
  # MetalFX upscaling draws at a fraction of the screen's real pixels
  if [ "$UPSCALE" = 1 ]; then
    px="$(screen_field "$l" pixels)"
    case "$px" in [1-9]*x[1-9]*) w=$(( ${px%x*} / UPSCALE_FACTOR )); h=$(( ${px#*x} / UPSCALE_FACTOR )) ;; esac
  fi
  printf '%s %s\n' ScreenWidth "$w" ScreenHeight "$h" WindowWidth "$w" WindowHeight "$h" \
    WindowLeft 0 WindowTop 0 Windowed 0 BorderlessWindow 1 FullscreenWindow 1 \
    FullscreenMonitorIndex 0 ScreenRefreshRate "$hz"
}

# What every start does in "auto": fit the game's settings to the main screen.
display_fit() {
  local l f
  l="$(screen_now)" || { say "Could not measure the screen, so the game's screen settings are left as they are."; return 0; }
  printf '%s\n' "$l" > "$LAST_FIT"
  f="$HOME_DIR/.fit-lines"
  fit_lines "$l" > "$f"
  if ! pcconfig > /dev/null; then
    say "Screen: $(screen_words "$l"). The game has not written its settings yet, so it picks its own size this first time."
    rm -f "$f"
    return 0
  fi
  display_apply "$f" "Fitting the game to $(screen_words "$l")"
  rm -f "$f"
}

# What every start does, by the chosen way.
display_prepare() {
  case "$(display_mode)" in
    auto) display_fit ;;
    keep) display_guard ;;
  esac
}

# Runs a command for at most $1 seconds, without saying so when stopped.
bounded_quiet() {
  local max="$1" pid t=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$t" -ge "$((max * 4))" ]; then kill "$pid" 2>/dev/null; break; fi
    sleep 0.25; t=$((t + 1))
  done
  wait "$pid" 2>/dev/null
}

# ---- while the game runs

# Starts the watcher of the screens: one small process that asks the window
# server every 2 seconds and writes a line to $1 when the main screen changes.
# It ends by itself when the launcher ends or after 12 hours.
screen_watch_start() {
  local ev="$1" js
  screen_watch_stop
  [ "$(display_mode)" = auto ] || return 1
  [ "$REFIT" = 1 ] || return 1
  js="$(screens_js)"
  : > "$ev"
  /usr/bin/osascript -l JavaScript "$js" watch 2 43200 >> "$ev" 2>/dev/null &
  echo $! > "$SCREEN_WATCH_PID"
}

screen_watch_stop() {
  local pid
  pid="$(cat "$SCREEN_WATCH_PID" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) ;; *)
    if /bin/ps -p "$pid" -o command= 2>/dev/null | /usr/bin/grep -q 'screens\.js'; then kill "$pid" 2>/dev/null || true; fi ;;
  esac
  rm -f "$SCREEN_WATCH_PID"
}

# the part of a screen line that decides the fit
screen_key() { printf '%s\n' "$1" | sed 's/ name=.*$//; s/ hz=[^ ]*//; s/ screens=[^ ]*//'; }

# Fits the game's window to the main screen now (Windows' view of it), twice:
# the game reacts to a screen change itself and can undo the first fit.
refit_window() {
  local log="$1" i
  if [ ! -f "$SKYFIT" ]; then
    say "The fitter ($SKYFIT) is missing, so the game keeps its old size until it is started again."
    return 1
  fi
  for i in 2 4; do
    sleep "$i"
    game_running || return 0
    echo "== $(date '+%H:%M:%S') skyfit" >> "$log"
    WINEDEBUG=-all bounded_quiet 30 "$CUR/bin/wine" "$SKYFIT" "${SKYFIT_MATCH:-SKYWALKERSAGA}" >> "$log" 2>&1
  done
  /usr/bin/grep -E '^(monitor|window|result)' "$log" | tail -n 3 | sed 's/^/   /'
}

# Waits for the game to end; in "auto", fits the game again when the screens change.
watch_game() {
  local log="$1" ev="$LOGS/screens.events" seen line
  if screen_watch_start "$ev"; then
    seen="$(screen_key "$(cat "$LAST_FIT" 2>/dev/null)")"
    say "Watching the screens: if they change while you play, the game is fitted to the new one."
  fi
  while game_running; do
    sleep 3
    [ -f "$GAME_PAUSED" ] && continue   # paused: fitted once it is resumed, if the screen changed
    [ -f "$SCREEN_WATCH_PID" ] || continue
    line="$(tail -n 1 "$ev" 2>/dev/null)"
    case "$line" in main=*) ;; *) continue ;; esac
    [ "$(screen_key "$line")" = "$seen" ] && continue
    seen="$(screen_key "$line")"
    printf '%s\n' "$line" > "$LAST_FIT"
    say "$(date '+%H:%M:%S') The screens changed: now $(screen_words "$line"). Fitting the game to it."
    notify "Screen changed: fitting the game to $(screen_field "$line" size)" &
    refit_window "$log"
  done
  screen_watch_stop
}

cmd_refit() {
  load_conf
  need_wine
  wine_env
  game_running || die "The game is not running."
  mkdir -p "$LOGS"
  [ -f "$SKYFIT" ] || die "The fitter is missing: $SKYFIT"
  WINEDEBUG=-all bounded 30 "$CUR/bin/wine" "$SKYFIT" "${SKYFIT_MATCH:-SKYWALKERSAGA}"
}

cmd_display() {
  local f l
  load_conf
  case "${1:-show}" in
    auto)
      echo auto > "$DISPLAY_MODE_FILE"
      say "The game is now fitted to the screen it opens on at every start, and again if the screens change while it runs."
      if l="$(screen_now)"; then say "Right now that is $(screen_words "$l")."; fi
      if ! game_running; then display_fit; fi
      ;;
    keep)
      f="$(pcconfig)" || die "The game has not written its settings file yet. Start the game once, set the picture, quit, then run this again."
      game_running && die "Quit the game first: it writes its settings when it closes."
      display_lines "$f" > "$DISPLAY_KEEP.new"
      [ -s "$DISPLAY_KEEP.new" ] || { rm -f "$DISPLAY_KEEP.new"; die "No screen or window lines found in $f"; }
      mv "$DISPLAY_KEEP.new" "$DISPLAY_KEEP"
      echo keep > "$DISPLAY_MODE_FILE"
      say "These screen settings are now put back before every start (whatever the screen):"
      sed 's/^/   /' "$DISPLAY_KEEP"
      say "(To fit every screen instead: bash $HOME_DIR/skywalker.sh display auto)"
      ;;
    check) display_prepare ;;   # what every start does
    off)
      echo off > "$DISPLAY_MODE_FILE"
      say "Screen settings are left as the game writes them."
      ;;
    screen)
      l="$(screen_now)" || die "Could not measure the screen."
      echo "$l"
      echo "That is $(screen_words "$l"). The game would get:"
      fit_lines "$l" | sed 's/^/   /'
      ;;
    show)
      echo "Way:     $(display_mode)  (auto: fit the screen at every start and when the screens change; keep: put noted lines back; off: leave them)"
      if l="$(screen_now)"; then echo "Screen:  $(screen_words "$l")"; else echo "Screen:  could not be measured"; fi
      if f="$(pcconfig)"; then
        echo "Settings file: $f"
        echo "Now:"
        display_lines "$f" | sed 's/^/   /'
      else
        echo "Settings file: not written by the game yet"
      fi
      if [ -f "$DISPLAY_KEEP" ]; then
        echo "Noted by \"display keep\":"
        sed 's/^/   /' "$DISPLAY_KEEP"
      fi
      if [ -f "$SKYFIT" ]; then echo "Fitter:  $SKYFIT"; else echo "Fitter:  missing ($SKYFIT): screen changes are only caught at the next start"; fi
      ;;
    *) die "Use: skywalker.sh display auto|keep|off|show|screen" ;;
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

# Writes the helper for the app's icon and the Dock (JavaScript for Automation, part of macOS).
appicon_js() {
  local f="$HOME_DIR/lib/appicon.js"
  mkdir -p "$HOME_DIR/lib"
  cat > "$f.new" <<'EOF'
// Helpers for the game's Mac app. Run with: osascript -l JavaScript appicon.js <command> ...
//   extract EXE OUT.ico   copy the largest icon of a Windows program into an .ico file
//   round IN OUT.png      a 1024x1024 Mac app icon: the picture on Apple's rounded square, with margins
//   url PATH              the file URL of PATH, as the Dock stores it
ObjC.import('Foundation');
ObjC.import('AppKit');

var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function fromB64(s) {
  var out = [], buf = 0, bits = 0;
  for (var i = 0; i < s.length; i++) {
    var c = B64.indexOf(s.charAt(i));
    if (c < 0) continue;
    buf = (buf << 6) | c; bits += 6;
    if (bits >= 8) { bits -= 8; out.push((buf >> bits) & 255); }
  }
  return out;
}
function toB64(a) {
  var s = '';
  for (var i = 0; i < a.length; i += 3) {
    var n = (a[i] << 16) | ((a[i + 1] || 0) << 8) | (a[i + 2] || 0);
    s += B64.charAt((n >> 18) & 63) + B64.charAt((n >> 12) & 63) +
      (i + 1 < a.length ? B64.charAt((n >> 6) & 63) : '=') + (i + 2 < a.length ? B64.charAt(n & 63) : '=');
  }
  return s;
}

function extract(exe, dest) {
  var d = $.NSData.dataWithContentsOfFileOptionsError(exe, 1, null);
  if (!d || d.isNil()) throw 'cannot read ' + exe;
  var size = d.length;
  function bytes(o, n) {
    if (o < 0 || o + n > size) throw 'outside the file';
    return fromB64(d.subdataWithRange($.NSMakeRange(o, n)).base64EncodedStringWithOptions(0).js);
  }
  function u16(o) { var b = bytes(o, 2); return b[0] | (b[1] << 8); }
  function u32(o) { var b = bytes(o, 4); return (b[0] | (b[1] << 8) | (b[2] << 16)) + b[3] * 16777216; }
  if (u16(0) !== 0x5a4d) throw 'not a Windows program';
  var pe = u32(0x3c);
  if (u32(pe) !== 0x4550) throw 'not a Windows program';
  var nsec = u16(pe + 6), optsz = u16(pe + 20), opt = pe + 24;
  var ddir = opt + (u16(opt) === 0x10b ? 96 : 112);
  var rsrc = u32(ddir + 16);
  if (!rsrc) throw 'no resources';
  var secs = [];
  for (var i = 0; i < nsec; i++) {
    var s = opt + optsz + 40 * i;
    secs.push([u32(s + 12), Math.max(u32(s + 8), u32(s + 16)), u32(s + 20)]);
  }
  function off(rva) {
    for (var i = 0; i < secs.length; i++)
      if (rva >= secs[i][0] && rva < secs[i][0] + secs[i][1]) return rva - secs[i][0] + secs[i][2];
    throw 'bad address';
  }
  var base = off(rsrc);
  function entries(o) {
    var n = u16(base + o + 12) + u16(base + o + 14), list = [];
    for (var k = 0; k < n && k < 4096; k++) list.push([u32(base + o + 16 + 8 * k), u32(base + o + 20 + 8 * k)]);
    return list;
  }
  function leaf(t) {
    for (var depth = 0; t >= 0x80000000 && depth < 4; depth++) t = entries(t - 0x80000000)[0][1];
    return [off(u32(base + t)), u32(base + t + 4)];
  }
  var icons = {}, groups = [];
  entries(0).forEach(function (e) {
    if ((e[0] === 3 || e[0] === 14) && e[1] >= 0x80000000) {
      entries(e[1] - 0x80000000).forEach(function (f) {
        if (e[0] === 3) icons[f[0]] = leaf(f[1]); else groups.push(leaf(f[1]));
      });
    }
  });
  if (!groups.length) throw 'no icon in ' + exe;
  var g = groups[0][0], n = u16(g + 4), best = null;
  for (var k = 0; k < n; k++) {
    var e = g + 6 + 14 * k, w = bytes(e, 1)[0] || 256, bpp = u16(e + 6), id = u16(e + 12);
    if (!icons[id]) continue;
    if (!best || w > best.w || (w === best.w && bpp > best.bpp)) best = { w: w, bpp: bpp, id: id, e: e };
  }
  if (!best) throw 'no icon in ' + exe;
  var img = icons[best.id];
  // an .ico file holding that one picture: 6-byte header, one 16-byte entry, the picture
  var head = [0, 0, 1, 0, 1, 0].concat(bytes(best.e, 8));
  var len = img[1];
  head.push(len & 255, (len >> 8) & 255, (len >> 16) & 255, (len >>> 24) & 255, 22, 0, 0, 0);
  var file = $.NSMutableData.alloc.initWithBase64EncodedStringOptions(toB64(head), 0);
  file.appendData(d.subdataWithRange($.NSMakeRange(img[0], len)));
  if (!file.writeToFileAtomically(dest, true)) throw 'cannot write ' + dest;
  return best.w + 'x' + best.w;
}

function round(src, dest) {
  var img = $.NSImage.alloc.initWithContentsOfFile(src);
  if (!img || img.isNil()) throw 'cannot read ' + src;
  var S = 1024;
  var rep = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
    null, S, S, 8, 4, true, false, $.NSDeviceRGBColorSpace, 0, 0);
  var ctx = $.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep);
  $.NSGraphicsContext.saveGraphicsState;
  $.NSGraphicsContext.setCurrentContext(ctx);
  ctx.setImageInterpolation($.NSImageInterpolationHigh);
  // Apple's app icon grid: an 824-point rounded square in the middle of 1024
  var r = $.NSMakeRect(100, 100, 824, 824);
  $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius(r, 185, 185).addClip;
  img.drawInRectFromRectOperationFraction(r, $.NSZeroRect, $.NSCompositingOperationSourceOver, 1);
  ctx.flushGraphics;
  $.NSGraphicsContext.restoreGraphicsState;
  // nothing drawn (the middle is see-through): let the caller use the picture as it is
  var mid = rep.colorAtXY(512, 512);
  if (!mid || mid.isNil() || mid.alphaComponent < 0.5) throw 'the rounded icon came out empty';
  var png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
  if (!png.writeToFileAtomically(dest, true)) throw 'cannot write ' + dest;
  return 'ok';
}

function run(argv) {
  try {
    if (argv[0] === 'extract') return extract(argv[1], argv[2]);
    if (argv[0] === 'round') return round(argv[1], argv[2]);
    if (argv[0] === 'url') return $.NSURL.fileURLWithPathIsDirectory(argv[1], true).absoluteString.js;
    return 'unknown command';
  } catch (e) {
    return 'error: ' + e;
  }
}
EOF
  if /usr/bin/cmp -s "$f.new" "$f"; then rm -f "$f.new"; else mv "$f.new" "$f"; fi
  echo "$f"
}

# The game's own program: the one in its folder whose name ends in DX11.exe, else the largest.
game_exe() {
  local name dir f best="" size bsize=0
  name="$(game_dir_name || true)"
  [ -n "$name" ] || return 1
  dir="$(steam_dir)/steamapps/common/$name"
  for f in "$dir"/*DX11.exe "$dir"/*.exe; do
    [ -f "$f" ] || continue
    case "$f" in *DX11.exe) echo "$f"; return 0 ;; esac
    size="$(wc -c < "$f" | tr -d ' ')"
    if [ "$size" -gt "$bsize" ]; then best="$f"; bsize="$size"; fi
  done
  [ -n "$best" ] && echo "$best"
}

# Makes $2 (an .icns file) from the icon inside the Windows program $1:
# the largest picture, on Apple's rounded square, at every size macOS asks for.
make_icns() {
  local exe="$1" dest="$2" js tmp got s
  js="$(appicon_js)"
  tmp="$HOME_DIR/cache/icon.$$"
  rm -rf "$tmp"; mkdir -p "$tmp/AppIcon.iconset"
  got="$(bounded_quiet 60 /usr/bin/osascript -l JavaScript "$js" extract "$exe" "$tmp/game.ico" 2>&1)"
  case "$got" in [0-9]*x[0-9]*) ;; *) echo "icon: $got"; rm -rf "$tmp"; return 1 ;; esac
  /usr/bin/sips -s format png "$tmp/game.ico" --out "$tmp/game.png" > /dev/null 2>&1 || { echo "icon: sips could not read it"; rm -rf "$tmp"; return 1; }
  case "$(bounded_quiet 60 /usr/bin/osascript -l JavaScript "$js" round "$tmp/game.png" "$tmp/icon1024.png" 2>&1)" in
    ok) ;; *) /usr/bin/sips -z 1024 1024 "$tmp/game.png" --out "$tmp/icon1024.png" > /dev/null 2>&1 ;;
  esac
  for s in 16 32 128 256 512; do
    /usr/bin/sips -z "$s" "$s" "$tmp/icon1024.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" > /dev/null 2>&1
    /usr/bin/sips -z "$((s * 2))" "$((s * 2))" "$tmp/icon1024.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" > /dev/null 2>&1
  done
  if ! /usr/bin/iconutil -c icns "$tmp/AppIcon.iconset" -o "$dest" 2> "$tmp/err"; then
    echo "icon: iconutil: $(cat "$tmp/err")"; rm -rf "$tmp"; return 1
  fi
  echo "icon: from $(basename "$exe") ($got)"
  rm -rf "$tmp"
}

# The app finds the launcher through the home folder of whoever opens it,
# so it keeps working if the folder is copied to another Mac or user.
app_launcher_path() {
  case "$HOME_DIR" in
    "$HOME"/*) echo "\$HOME${HOME_DIR#$HOME}/skywalker.sh" ;;
    *) echo "$HOME_DIR/skywalker.sh" ;;
  esac
}

OSACOMPILE="${SKY_OSACOMPILE:-/usr/bin/osacompile}"

# Makes the app in the folder $1 (replacing it), keeping the game's icon if
# $1/Contents/Resources/AppIcon.icns is there. $2 = where it looks for the launcher.
# On a Mac the app is the loading window itself, compiled by osacompile: it
# opens at once, under the app's name and icon, and then starts the launcher.
# Without osacompile it is a script that starts the launcher, then the window.
app_files() {
  if [ -x "$OSACOMPILE" ]; then app_applet "$1" "$2"; else app_script "$1" "$2"; fi
}

# $1 = Info.plist, $2 = key, $3 = text
plist_set() {
  /usr/libexec/PlistBuddy -c "Set :$2 $3" "$1" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$2 string $3" "$1"
}

app_applet() {
  local a="$1" t b
  t="$(mktemp -d "${TMPDIR:-/tmp}/skywalker-applet.XXXXXX")" || return 1
  b="$t/Skywalker Saga.app"
  loading_js "$2" > "$t/loading.js"
  if ! "$OSACOMPILE" -l JavaScript -o "$b" "$t/loading.js" > "$t/osacompile.txt" 2>&1; then
    say "The app could not be compiled: $(cat "$t/osacompile.txt")"
    rm -rf "$t"
    return 1
  fi
  cp "$t/loading.js" "$b/Contents/Resources/loading-source.js"
  if [ -s "$a/Contents/Resources/AppIcon.icns" ]; then
    cp "$a/Contents/Resources/AppIcon.icns" "$b/Contents/Resources/AppIcon.icns"
    cp "$a/Contents/Resources/AppIcon.icns" "$b/Contents/Resources/applet.icns"
    rm -f "$b/Contents/Resources/Assets.car"
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$b/Contents/Info.plist" > /dev/null 2>&1 || true
  fi
  plist_set "$b/Contents/Info.plist" CFBundleIdentifier local.skywalker-saga.launcher
  plist_set "$b/Contents/Info.plist" CFBundleName "Skywalker Saga"
  plist_set "$b/Contents/Info.plist" CFBundleDisplayName "Skywalker Saga"
  plist_set "$b/Contents/Info.plist" CFBundleShortVersionString 3.0
  plist_set "$b/Contents/Info.plist" LSApplicationCategoryType public.app-category.action-games
  /usr/libexec/PlistBuddy -c "Delete :LSUIElement" "$b/Contents/Info.plist" > /dev/null 2>&1 || true
  # the changes above break the seal that osacompile put on the app: seal it again
  /usr/bin/codesign --force --deep --sign - "$b" > /dev/null 2>&1 || true
  rm -rf "$a"
  mv "$b" "$a"
  rm -rf "$t"
}

app_script() {
  local a="$1" icon_key=""   # $2 = where the app looks for the launcher
  mkdir -p "$a/Contents/MacOS" "$a/Contents/Resources"
  if [ -f "$a/Contents/Resources/AppIcon.icns" ]; then icon_key="<key>CFBundleIconFile</key><string>AppIcon</string>"; fi
  cat > "$a/Contents/Info.plist.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Skywalker Saga</string>
  <key>CFBundleDisplayName</key><string>Skywalker Saga</string>
  <key>CFBundleIdentifier</key><string>local.skywalker-saga.launcher</string>
  <key>CFBundleExecutable</key><string>skywalker-launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>3.0</string>
  <key>CFBundleVersion</key><string>3</string>
  $icon_key
  <key>LSApplicationCategoryType</key><string>public.app-category.action-games</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
EOF
  cat > "$a/Contents/MacOS/skywalker-launcher.new" <<EOF
#!/bin/bash
# Hands the start to the launcher, then shows the loading window until the
# game's own window is up. Closing that window does not stop the start.
L="\${SKYWALKER_HOME:+\$SKYWALKER_HOME/skywalker.sh}"
L="\${L:-$2}"
if [ ! -f "\$L" ]; then
  /usr/bin/osascript -e 'display notification "The launcher is missing: ~/Games/skywalker/skywalker.sh" with title "Skywalker Saga"'
  exit 1
fi
D="\$(dirname "\$L")"
R="\$(cd "\$(dirname "\$0")/../Resources" && pwd)"
mkdir -p "\$D/logs"
start="\$(date +%s)"
# a copy of the window's script: "launch" may replace this app with a newer one
J="\${TMPDIR:-/tmp}/skywalker-loading.js"
cp "\$R/loading.js" "\$J" 2>/dev/null || J="\$R/loading.js"
# "launch" hands the start to macOS as a job of its own and returns: what an app
# starts is ended with the app, and the game and Steam must outlive this script.
/bin/bash "\$L" launch >> "\$D/logs/launcher.log" 2>&1
if [ -f "\$J" ] && [ -z "\${SKYWALKER_NO_WINDOW:-}" ]; then
  exec /usr/bin/osascript -l JavaScript "\$J" "\$D/logs" "\$start" "\$R/AppIcon.icns" >> "\$D/logs/loading.log" 2>&1
fi
EOF
  chmod +x "$a/Contents/MacOS/skywalker-launcher.new"
  loading_js "$2" > "$a/Contents/Resources/loading.js.new"
  # each file is swapped in whole: the app may be running its script right now
  mv -f "$a/Contents/Info.plist.new" "$a/Contents/Info.plist"
  mv -f "$a/Contents/MacOS/skywalker-launcher.new" "$a/Contents/MacOS/skywalker-launcher"
  mv -f "$a/Contents/Resources/loading.js.new" "$a/Contents/Resources/loading.js"
}

# Brings an app made by an older launcher up to date (the icon and the Dock
# entry stay). Quiet when nothing is needed.
refresh_app() {
  local t want
  [ -d "$APP/Contents/MacOS" ] || return 0
  if [ -x "$OSACOMPILE" ]; then
    want="$(loading_js "$(app_launcher_path)")"
    if [ -f "$APP/Contents/MacOS/applet" ] && [ "$(cat "$APP/Contents/Resources/loading-source.js" 2>/dev/null)" = "$want" ]; then
      return 0
    fi
    rm -rf "$APP.new"
    mkdir -p "$APP.new/Contents/Resources"
    if [ -s "$APP/Contents/Resources/AppIcon.icns" ]; then cp "$APP/Contents/Resources/AppIcon.icns" "$APP.new/Contents/Resources/"; fi
    app_applet "$APP.new" "$(app_launcher_path)" || { rm -rf "$APP.new"; return 1; }
    # swapped in whole (the app may be running): a Dock icon pointing at it stays valid
    rm -rf "$APP.old"
    mv "$APP" "$APP.old" && mv "$APP.new" "$APP"
    rm -rf "$APP.old"
  else
    t="$(mktemp -d "${TMPDIR:-/tmp}/skywalker-app.XXXXXX")" || return 0
    mkdir -p "$t/Contents/Resources"
    if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then : > "$t/Contents/Resources/AppIcon.icns"; fi
    app_script "$t" "$(app_launcher_path)"
    if /usr/bin/cmp -s "$t/Contents/MacOS/skywalker-launcher" "$APP/Contents/MacOS/skywalker-launcher" \
      && /usr/bin/cmp -s "$t/Contents/Resources/loading.js" "$APP/Contents/Resources/loading.js" \
      && /usr/bin/cmp -s "$t/Contents/Info.plist" "$APP/Contents/Info.plist"; then
      rm -rf "$t"
      return 0
    fi
    rm -rf "$t"
    app_script "$APP" "$(app_launcher_path)"
  fi
  touch "$APP"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" > /dev/null 2>&1 || true
  say "The app was brought up to date (loading window)."
}

# The loading window (JavaScript for Automation; see the comments at its top).
# $1 = where the launcher is ("$HOME/..." is taken from the home folder of whoever opens the app)
loading_js() {
  local l="$1"
  # shellcheck disable=SC2088  # a literal "~/" for the JavaScript, which expands it
  case "$l" in '$HOME/'*) l="~/${l#\$HOME/}" ;; esac
  l="$(printf '%s' "$l" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g")"
  printf "const LAUNCHER = '%s';\n" "$l"
  cat <<'EOF'
// The window the app shows from the moment it is clicked until the game's own
// window is up. It follows logs/start-status, which the launcher rewrites at
// every stage of the start, and estimates the time left from earlier starts.
// It is the app itself (compiled with osacompile), or is run by a script with:
//   osascript -l JavaScript loading.js LOGSDIR APPSTART [ICON]
// Closing the window only hides the progress: the start carries on.
ObjC.import('Cocoa');
ObjC.import('CoreGraphics');

function readText(path) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return s.isNil() ? null : ObjC.unwrap(s);
}

function readStatus(dir) {
  const text = readText(dir + '/start-status');
  if (text === null) return null;
  const o = {};
  text.split('\n').forEach(function (l) {
    const i = l.indexOf('=');
    if (i > 0) o[l.slice(0, i)] = l.slice(i + 1);
  });
  o.t0 = Number(o.t0) || 0;
  o.now = Number(o.now) || 0;
  o.expect = Number(o.expect) || 90;
  o.state = o.state || '';
  o.text = o.text || '';
  return o;
}

// The middle of the last few numbers in a file of one number per line.
function median(path, fallback) {
  const text = readText(path);
  if (text === null) return fallback;
  const v = text.split('\n').map(Number).filter(function (n) { return n > 0; }).slice(-5);
  if (!v.length) return fallback;
  v.sort(function (a, b) { return a - b; });
  return v[Math.floor(v.length / 2)];
}

function appendLine(path, line) {
  const old = readText(path) || '';
  $(old + line + '\n').writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}

// Whether a Wine window covers most of the main screen: the game's own window.
// (Steam's windows are smaller; owner names and sizes need no permission.)
function gameWindowUp() {
  const ref = $.CGWindowListCopyWindowInfo(1 | 16, 0);  // on screen only, no desktop
  if (!ref) return false;
  const list = ObjC.castRefToObject(ref);
  const scr = $.NSScreen.mainScreen.frame.size;
  const n = list.count;
  for (let i = 0; i < n; i++) {
    const w = list.objectAtIndex(i);
    const owner = ObjC.unwrap(w.objectForKey('kCGWindowOwnerName')) || '';
    const layer = ObjC.unwrap(w.objectForKey('kCGWindowLayer'));
    const b = w.objectForKey('kCGWindowBounds');
    if (b.isNil()) continue;
    const bw = ObjC.unwrap(b.objectForKey('Width')), bh = ObjC.unwrap(b.objectForKey('Height'));
    if (layer === 0 && /wine|\.exe|skywalker|lego/i.test(owner) && !/osascript/i.test(owner) &&
        bw >= scr.width * 0.5 && bh >= scr.height * 0.5) return true;
  }
  return false;
}

function label(text, size, bold, x, y, w, h) {
  const t = $.NSTextField.alloc.initWithFrame($.NSMakeRect(x, y, w, h));
  t.stringValue = text;
  t.bezeled = false;
  t.drawsBackground = false;
  t.editable = false;
  t.selectable = false;
  t.font = bold ? $.NSFont.boldSystemFontOfSize(size) : $.NSFont.systemFontOfSize(size);
  t.lineBreakMode = 4;  // cut at the end with an ellipsis
  return t;
}

function clock(secs) {
  secs = Math.max(0, Math.round(secs));
  const s = secs % 60;
  return Math.floor(secs / 60) + ':' + (s < 10 ? '0' : '') + s;
}

// Starts the launcher ("launch": it hands the start to macOS as a job of its
// own and returns), with its output added to logs/launcher.log.
function startLauncher(launcher, dir) {
  const fm = $.NSFileManager.defaultManager;
  fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dir, true, $(), null);
  const log = dir + '/launcher.log';
  if (!fm.fileExistsAtPath(log)) fm.createFileAtPathContentsAttributes(log, $(), $());
  const fh = $.NSFileHandle.fileHandleForWritingAtPath(log);
  const task = $.NSTask.alloc.init;
  task.launchPath = '/bin/bash';
  task.arguments = $([launcher, 'launch']);
  if (!fh.isNil()) { fh.seekToEndOfFile; task.standardOutput = fh; task.standardError = fh; }
  task.launch;
}

// As the app itself (no arguments): the launcher path is set when the app is made.
// From a script (LOGSDIR APPSTART [ICON]): that script has started the launcher.
function run(argv) {
  argv = argv || [];
  const appMode = !argv.length || typeof argv[0] !== 'string' || argv[0] === '';
  const app = $.NSApplication.sharedApplication;
  let launcher = '', dir, appStart, iconPath;
  if (appMode) {
    const env = ObjC.deepUnwrap($.NSProcessInfo.processInfo.environment) || {};
    const home = ObjC.unwrap($.NSHomeDirectory());
    launcher = env.SKYWALKER_HOME ? env.SKYWALKER_HOME + '/skywalker.sh' : LAUNCHER.replace(/^~\//, home + '/');
    dir = launcher.replace(/\/[^\/]*$/, '') + '/logs';
    appStart = Date.now() / 1000;
    iconPath = ObjC.unwrap($.NSBundle.mainBundle.pathForResourceOfType('applet', 'icns')) || '';
  } else {
    dir = argv[0];
    appStart = Number(argv[1]) || Date.now() / 1000;
    iconPath = argv[2] || '';
    app.setActivationPolicy(0);  // a normal app: it has its Dock icon and comes to the front
  }
  let img = null;
  if (iconPath && $.NSFileManager.defaultManager.fileExistsAtPath(iconPath)) {
    img = $.NSImage.alloc.initWithContentsOfFile(iconPath);
    if (img.isNil()) img = null; else if (!appMode) app.applicationIconImage = img;
  }
  if (!appMode) app.finishLaunching;

  const W = 470, H = 134;
  const win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, W, H), 1 | 2 | 4, 2, false);  // titled, closable, can be minimised; buffered
  win.title = 'Skywalker Saga';
  win.releasedWhenClosed = false;
  const view = win.contentView;
  const left = img ? 118 : 24;
  if (img) {
    const iv = $.NSImageView.alloc.initWithFrame($.NSMakeRect(22, 27, 80, 80));
    iv.image = img;
    view.addSubview(iv);
  }
  const title = label('Starting LEGO Star Wars: The Skywalker Saga', 13, true, left, 94, W - left - 20, 20);
  const stage = label('Getting ready', 12, false, left, 71, W - left - 20, 18);
  const bar = $.NSProgressIndicator.alloc.initWithFrame($.NSMakeRect(left, 47, W - left - 20, 20));
  bar.style = 0;  // a bar
  bar.indeterminate = false;
  bar.minValue = 0;
  bar.maxValue = 100;
  bar.doubleValue = 1;
  const detail = label('', 11, false, left, 24, W - left - 20, 17);
  detail.textColor = $.NSColor.secondaryLabelColor;
  [title, stage, bar, detail].forEach(function (v) { view.addSubview(v); });
  win.center;
  win.makeKeyAndOrderFront(null);
  app.activateIgnoringOtherApps(true);
  win.displayIfNeeded;
  let problem = '';
  if (appMode) {
    // the window is up first; then the launcher
    if (!$.NSFileManager.defaultManager.fileExistsAtPath(launcher)) {
      problem = 'The launcher is missing: ' + launcher.replace(ObjC.unwrap($.NSHomeDirectory()), '~');
    } else {
      try { startLauncher(launcher, dir); } catch (e) { problem = 'The launcher could not be started: ' + e; }
    }
  }

  const winExpect = median(dir + '/window-times.txt', 25);  // game process to game window
  let runningSince = 0, endAt = 0, lastWindowCheck = 0, failed = false, shown = 1;
  const limit = appStart + 20 * 60;
  while (true) {
    const ev = app.nextEventMatchingMaskUntilDateInModeDequeue(
      4294967295, $.NSDate.dateWithTimeIntervalSinceNow(0.2), $.NSDefaultRunLoopMode, true);
    if (ev && !ev.isNil()) app.sendEvent(ev);
    if (!win.isVisible && !win.isMiniaturized) break;  // closed: the start carries on without it
    const now = Date.now() / 1000;
    if (endAt) { if (now >= endAt) break; continue; }
    if (now > limit) break;
    const st = readStatus(dir);
    const fresh = st && (st.t0 >= appStart - 5 || st.state === 'starting' || st.state === 'running');
    let target = shown;
    if (!fresh) {
      stage.stringValue = 'Getting ready';
      detail.stringValue = clock(now - appStart);
      if (problem || now - appStart > 30) {
        failed = true;
        title.stringValue = 'The game did not start';
        stage.stringValue = problem || 'The launcher did not respond.';
        detail.stringValue = 'Details: ~/Games/skywalker/logs/launcher.log';
        bar.hidden = true;
        endAt = now + 120;
      }
    } else if (st.state === 'starting') {
      const elapsed = now - st.t0;
      target = Math.max(2, Math.min(0.92, elapsed / st.expect) * 85);
      stage.stringValue = st.text;
      const remain = st.expect - elapsed;
      let hint = remain > 7 ? 'About ' + (remain > 60 ? Math.round(remain / 60 * 2) / 2 + ' min' : Math.ceil(remain / 5) * 5 + ' seconds') + ' left'
        : (elapsed > st.expect * 1.4 ? 'Taking longer than usual' : 'Almost there');
      detail.stringValue = hint + '   ·   ' + clock(elapsed);
      if (now - st.now > 90) {
        failed = true;
        title.stringValue = 'The game did not start';
        stage.stringValue = 'The launcher stopped at: ' + st.text;
        detail.stringValue = 'Details: ~/Games/skywalker/logs/launcher.log';
        bar.hidden = true;
        endAt = now + 120;
      }
    } else if (st.state === 'running') {
      if (!runningSince) runningSince = now;
      const t = now - runningSince;
      target = 85 + 15 * Math.min(0.9, t / winExpect);
      stage.stringValue = st.text || 'Loading the game';
      detail.stringValue = (t < winExpect ? 'The game is loading' : 'Almost there') + '   ·   ' + clock(now - (st.t0 || appStart));
      if (now - lastWindowCheck >= 1) {
        lastWindowCheck = now;
        let up = false;
        try { up = gameWindowUp(); } catch (e) { up = false; }
        if (up) appendLine(dir + '/window-times.txt', String(Math.max(1, Math.round(t))));
        if (up || t > Math.max(60, winExpect * 3)) {
          bar.doubleValue = 100;
          stage.stringValue = 'Have fun!';
          endAt = now + 0.8;
        }
      }
    } else if (st.state === 'failed') {
      failed = true;
      title.stringValue = 'The game did not start';
      stage.stringValue = st.text;
      stage.toolTip = st.text;
      detail.stringValue = 'Details: ~/Games/skywalker/logs/launcher.log';
      bar.hidden = true;
      endAt = now + 120;
    } else {  // done: the game has already closed again
      stage.stringValue = st.text || 'The game has closed.';
      detail.stringValue = '';
      endAt = now + 3;
    }
    if (!failed && target > shown) {
      shown = Math.min(target, shown + 4);  // glide rather than jump
      bar.doubleValue = shown;
    }
  }
  win.orderOut(null);
  return failed ? 'failed' : 'ok';
}
EOF
}

create_app() {
  local launcher_path exe note
  launcher_path="$(app_launcher_path)"
  rm -rf "$APP.new"
  mkdir -p "$APP.new/Contents/MacOS" "$APP.new/Contents/Resources" "$LOGS"
  exe="$(game_exe || true)"
  if [ -n "$exe" ] && note="$(make_icns "$exe" "$APP.new/Contents/Resources/AppIcon.icns")"; then
    say "App icon: the game's own ${note#icon: from }"
  else
    say "The game's icon could not be taken from its program (${note:-game not found}); the app gets the plain icon."
  fi
  app_files "$APP.new" "$launcher_path" || app_script "$APP.new" "$launcher_path"
  # swap in the new app in one step, so a Dock icon pointing at it stays valid
  rm -rf "$APP.old"
  if [ -d "$APP" ]; then mv "$APP" "$APP.old"; fi
  mv "$APP.new" "$APP"
  rm -rf "$APP.old"
  touch "$APP"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" > /dev/null 2>&1 || true
  say "App: $APP (Spotlight and Launchpad find it as \"Skywalker Saga\")"
}

# $1 = exported Dock settings, $2 = text: how many Dock icons have it in their address
dock_count() {
  /usr/libexec/PlistBuddy -c 'Print :persistent-apps' "$1" 2>/dev/null | /usr/bin/grep -a '_CFURLString = ' \
    | /usr/bin/grep -a -i -c -F "$2" || true
}

# Puts the app in the Dock, where an older game icon was if there was one,
# and takes out other game icons there: older copies of this app and the icon
# CrossOver made for the game (it starts CrossOver, whose trial has ended).
# The Dock's settings are copied to settings-backups first.
dock_pin() {
  local js url plist dir i u n=0 at="" removed="" keep=0 rm_list=""
  [ -d "$APP" ] || die "The app is missing. Run: bash $HOME_DIR/skywalker.sh app"
  js="$(appicon_js)"
  url="$(/usr/bin/osascript -l JavaScript "$js" url "$APP" 2>/dev/null)"
  case "$url" in file://*) ;; *) die "Could not work out the app's address for the Dock ($url)." ;; esac
  dir="$HOME_DIR/settings-backups"
  mkdir -p "$dir"
  plist="$HOME_DIR/.dock.plist"
  /usr/bin/defaults export com.apple.dock "$plist" 2>/dev/null || die "Could not read the Dock's settings."
  cp "$plist" "$dir/dock-$(date +%Y%m%d-%H%M%S).plist"
  ls -1 "$dir"/dock-*.plist 2>/dev/null | sort -r | tail -n +6 | while read -r i; do
    case "$i" in "$dir"/dock-*) rm -f "$i" ;; esac
  done
  i=0
  while /usr/libexec/PlistBuddy -c "Print :persistent-apps:$i" "$plist" > /dev/null 2>&1; do
    u="$(/usr/libexec/PlistBuddy -c "Print :persistent-apps:$i:tile-data:file-data:_CFURLString" "$plist" 2>/dev/null)" || u=""
    if [ "$u" = "$url" ] && [ "$keep" = 0 ]; then
      keep=1
    elif printf '%s' "$u" | /usr/bin/grep -i 'skywalker' | /usr/bin/grep -qvi 'pause'; then
      rm_list="$i $rm_list"
      [ -n "$at" ] || at="$i"
      removed="$removed, $(printf '%s' "$u" | sed 's|/$||; s|.*/||; s|%20| |g; s|%C2%AE||g; s|%E2%84%A2||g')"
    fi
    i=$((i + 1))
    [ "$i" -lt 500 ] || break
  done
  if [ "$keep" = 1 ] && [ -z "$rm_list" ]; then
    rm -f "$plist"
    say "The Dock already has the game's icon."
    return 0
  fi
  for i in $rm_list; do   # from the last to the first, so the numbers stay right
    /usr/libexec/PlistBuddy -c "Delete :persistent-apps:$i" "$plist"
  done
  if [ "$keep" = 0 ]; then
    if [ -n "$at" ]; then
      # each removed entry before $at moved it; $at was the first, so it is still right
      n="$at"
    else
      n="$(( i - $(echo $rm_list | wc -w) ))"
    fi
    /usr/libexec/PlistBuddy \
      -c "Add :persistent-apps:$n dict" \
      -c "Add :persistent-apps:$n:tile-type string file-tile" \
      -c "Add :persistent-apps:$n:tile-data dict" \
      -c "Add :persistent-apps:$n:tile-data:file-label string Skywalker Saga" \
      -c "Add :persistent-apps:$n:tile-data:file-data dict" \
      -c "Add :persistent-apps:$n:tile-data:file-data:_CFURLString string $url" \
      -c "Add :persistent-apps:$n:tile-data:file-data:_CFURLStringType integer 15" \
      "$plist" || die "Could not add the app to the Dock's settings."
  fi
  # The Dock keeps its own copy while it runs and can write it back over a
  # change made at the wrong moment (while it is starting), so check and retry.
  for i in 1 2 3; do
    /usr/bin/defaults import com.apple.dock "$plist" || die "Could not save the Dock's settings."
    /usr/bin/killall Dock 2>/dev/null || true
    sleep 3
    /usr/bin/defaults export com.apple.dock "$plist.check" 2>/dev/null || true
    if [ "$(( $(dock_count "$plist.check" skywalker) - $(dock_count "$plist.check" 'skywalker%20pause') ))" = 1 ] && dock_count "$plist.check" "$url" | grep -qx 1; then
      at=ok; break
    fi
  done
  rm -f "$plist" "$plist.check"
  [ "$at" = ok ] || die "The Dock did not take the change. Try again: bash $HOME_DIR/skywalker.sh dock"
  say "The game is in the Dock${removed:+ (replaced: ${removed#, })}. To take it out: drag it out of the Dock."
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
  resume_wine > /dev/null
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
  resume_wine all   # a frozen server would never answer -k
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
READY_MARK="$HOME_DIR/steam.ready"   # "ready on": keep Steam paused rather than closed
PAUSED="$HOME_DIR/steam-paused"      # Steam's programs are paused now (since the time inside)
GAME_PAUSED="$HOME_DIR/paused"       # the game itself is paused mid-level ("pause"): leave Wine alone

# ---------------------------------------------------------------- Steam kept ready, paused
#
# A paused program (SIGSTOP) keeps its memory but gets no processor time at
# all, so a signed-in Steam can wait for days at no cost in battery. Resuming
# (SIGCONT) is instant; Steam then reconnects to its servers, as after the Mac
# has slept. Every way into Wine (run_wine, play, stop) resumes first.

pause_wanted() { [ -f "$READY_MARK" ]; }

# Pauses all of this build's Wine programs (Steam, its browser parts, the
# Windows background programs and wineserver). Not while the game runs.
pause_wine() {
  local pids
  game_running && return 1
  [ -f "$GAME_PAUSED" ] && return 1
  pids="$(wine_pids)"
  [ -n "$pids" ] || return 1
  date '+%Y-%m-%d %H:%M:%S' > "$PAUSED"
  # shellcheck disable=SC2086
  kill -STOP $pids 2>/dev/null || true
  return 0
}

# Resumes them (quietly when nothing was paused). Also wakes any Wine program
# left paused by an earlier launcher that did not get to resume it. While the
# game is paused mid-level nothing is woken, unless $1 is "all" (closing Wine).
resume_wine() {
  local pids was=""
  if [ "${1:-}" != all ] && [ -f "$GAME_PAUSED" ]; then return 0; fi
  [ -f "$PAUSED" ] && was="$(cat "$PAUSED" 2>/dev/null)"
  rm -f "$PAUSED"
  pids="$(wine_pids)"
  # shellcheck disable=SC2086
  if [ -n "$pids" ]; then kill -CONT $pids 2>/dev/null || true; fi
  if [ -n "$was" ] && [ -n "$pids" ]; then say "Steam was kept ready (paused since ${was#* }); it is running again."; fi
  return 0
}

wine_paused() {
  local pids
  [ -f "$PAUSED" ] || return 1
  pids="$(wine_pids)"
  [ -n "$pids" ] || { rm -f "$PAUSED"; return 1; }
  # shellcheck disable=SC2086
  /bin/ps -o stat= -p "$(echo $pids | tr ' ' ',')" 2>/dev/null | /usr/bin/grep -q T
}

# Whether Steam has finished starting since the time given: signed in, or
# showing its sign-in window because it cannot sign in by itself.
steam_settled() {
  [ "$(steam_stage "$1" 2>/dev/null)" = ready ] && return 0
  /usr/bin/awk -v s="[$1]" 'substr($0, 1, 21) >= s && /WaitingForCredentials - OK/ { found = 1 } END { exit !found }' \
    "$(steam_dir)/logs/steamui_login.txt" 2>/dev/null
}

# In the background: once Steam has settled (at most 10 minutes), wait
# PAUSE_AFTER_READY seconds more and pause it, unless a game has started or
# another timer has taken over (the same ticket as the idle timer).
# $1 = start time ("2026-11-21 15:42:17")
start_pause_when_ready() {
  local since="$1" ticket
  ticket="$(date +%s)-$$-$RANDOM"
  echo "$ticket" > "$IDLE"
  (
    trap '' HUP
    i=0
    while [ "$i" -lt 600 ]; do
      sleep 5; i=$((i + 5))
      [ "$(cat "$IDLE" 2>/dev/null)" = "$ticket" ] || exit 0
      game_running && exit 0
      steam_settled "$since" && break
    done
    sleep "$PAUSE_AFTER_READY"
    [ "$(cat "$IDLE" 2>/dev/null)" = "$ticket" ] || exit 0
    rm -f "$IDLE"
    pause_wine
  ) </dev/null >/dev/null 2>&1 &
}

cmd_ready() {
  load_conf
  case "${1:-status}" in
    on)
      [ -x "$LAUNCHCTL" ] || die "This needs macOS."
      touch "$READY_MARK"
      cmd_autostart on > /dev/null
      say "Steam is now kept ready: it starts when you log in (and now), signs in, and is then paused."
      say "Paused, it uses no processor or battery; a click on the game resumes it. After a game it is paused again."
      say "To undo: bash $HOME_DIR/skywalker.sh ready off"
      ;;
    off)
      rm -f "$READY_MARK"
      cmd_autostart off > /dev/null
      wine_env
      resume_wine
      rm -f "$IDLE"
      if our_wineserver_running; then start_idle_timer "$(keep_seconds)"; fi
      say "Steam is no longer kept ready. Starts are as before (a Steam open now closes after $KEEP_STEAM_MINUTES minutes)."
      ;;
    status)
      if pause_wanted; then
        if wine_paused; then echo "Ready: on (Steam paused since $(cat "$PAUSED"))"; else echo "Ready: on (Steam is not paused right now)"; fi
      else
        echo "Ready: off"
      fi
      ;;
    *) die "Use: skywalker.sh ready on|off" ;;
  esac
}
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
    if pause_wanted; then pause_wine; else shutdown_wine; fi
  ) </dev/null >/dev/null 2>&1 &
}

shutdown_wine() {
  local i
  resume_wine all > /dev/null
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
# ---------------------------------------------------------------- start progress

# What the app's loading window shows: logs/start-status, rewritten (whole, in
# one step) at every stage of a start and every second while Steam starts.
#   t0= start (epoch seconds)  now= time of writing  state= starting|running|done|failed
#   expect= seconds a start like this took lately  text= what is happening
# Each new text is also noted in logs/start-stages.txt with its second, for "timeline".
# $1 = state, $2 = text
ui_status() {
  local now
  [ -n "${UI_T0:-}" ] || return 0
  now="$(date +%s)"
  printf 't0=%s\nnow=%s\nstate=%s\nexpect=%s\ntext=%s\n' "$UI_T0" "$now" "$1" "${UI_EXPECT:-90}" "$2" \
    > "$LOGS/start-status.new" 2>/dev/null && mv -f "$LOGS/start-status.new" "$LOGS/start-status"
  if [ "$1/$2" != "${UI_LAST:-}" ]; then
    printf '%s\t%s\t%s\n' "$((now - UI_T0))" "$1" "$2" >> "$LOGS/start-stages.txt"
    UI_LAST="$1/$2"
  fi
}

# Seconds until the game was running in the last few starts of the same kind
# (the middle one of the last five, so that one Steam update does not count).
# $1 = cold (Steam starts too) or warm (Steam is open)
expected_start() {
  local d=90
  [ "$1" = warm ] && d=15
  [ -f "$LOGS/startup.tsv" ] || { echo "$d"; return 0; }
  /usr/bin/awk -F'\t' -v w="$1" -v d="$d" '
    (($3 == "open") == (w == "warm")) && $5 ~ /^[0-9]+$/ && $5 > 0 { v[n++] = $5 }
    END {
      if (!n) { print d; exit }
      s = (n > 5) ? n - 5 : 0; m = 0
      for (i = s; i < n; i++) a[m++] = v[i]
      for (i = 1; i < m; i++) { x = a[i]; for (j = i - 1; j >= 0 && a[j] > x; j--) a[j + 1] = a[j]; a[j + 1] = x }
      print a[int(m / 2)]
    }' "$LOGS/startup.tsv"
}

# What Steam is doing for the game since the time given ("2026-11-21 15:42:17"),
# from the end of its console log: "ready" once it has started up, then the
# name of each step of the game's launch (SynchronizingCloud, CreatingProcess...).
steam_stage() {
  local f
  f="$(steam_dir)/logs/console_log.txt"
  [ -f "$f" ] || return 1
  tail -c 8000 "$f" 2>/dev/null | /usr/bin/awk -v s="[$1]" '
    substr($0, 1, 1) == "[" && substr($0, 1, 21) >= s {
      if ($0 ~ /System startup time/) t = "ready"
      if (match($0, /LaunchApp changed task to [A-Za-z]+/)) t = substr($0, RSTART + 26, RLENGTH - 26)
    }
    END { if (t == "") exit 1; print t }'
}

# $1 = what steam_stage printed
steam_stage_words() {
  case "$1" in
    ready) echo "Steam is ready and is starting the game" ;;
    SynchronizingCloud) echo "Steam is syncing your saves with Steam Cloud" ;;
    CreatingProcess | WaitingGameWindow | Completed) echo "Steam is starting the game" ;;
    *) echo "Steam is getting the game ready" ;;
  esac
}

play() {
  local log="$1" i started=0 warm=0 keep t0 t_steam="" t_helper="" t_game="" gargs stage words woke=0 wait_s
  mkdir -p "$LOGS"
  t0="$(date +%s)"
  UI_T0="$t0"   # from here on, the loading window hears of every stage and of a failure
  UI_EXPECT="$(expected_start cold)"
  need_wine
  other_wine_running && die "CrossOver or another Wine is running. Quit it first."
  if game_paused; then
    ui_status running "Carrying on with the paused game"
    cmd_resume
    return 0
  fi
  if game_running; then
    ui_status running "The game is already running"
    say "The game is already running."
    return 0
  fi
  : > "$LOGS/start-stages.txt"
  date '+%Y-%m-%d %H:%M:%S' > "$LOGS/last-start"
  rm -f "$IDLE"
  woke=0
  if wine_paused; then
    ui_status starting "Waking Steam"
    resume_wine
    woke=1
    sleep 1
  fi
  ui_status starting "Backing up your saves"
  backup_saves
  ui_status starting "Fitting the game to your screen"
  display_prepare
  wine_env
  if our_wineserver_running && steam_running; then UI_EXPECT="$(expected_start warm)"; fi
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
  ui_status starting "Getting the game's files ready"
  prepare_prefix
  gargs="$(game_args)"
  note_game_args "$gargs"
  cd "$HOME" || true
  if [ "$warm" = 1 ]; then
    ui_status starting "Steam is open: starting the game"
    say "Steam is still open, so the game starts straight away ($(settings_line))"
    # shellcheck disable=SC2086
    run_wine "$STEAM_EXE" -applaunch "$APPID" $gargs >> "$log" 2>&1 &
    # An open Steam starts the game within seconds. If it does not, it is not
    # in a state to do so: start again from nothing. A Steam just woken from
    # its pause first reconnects to Steam's servers, so it gets longer.
    wait_s="$WARM_WAIT"
    if [ "$woke" = 1 ] && [ "$wait_s" -lt 90 ]; then wait_s=90; fi
    for i in $(seq 1 "$wait_s"); do
      sleep 1
      if game_running; then started=1; t_game=$(( $(date +%s) - t0 )); break; fi
      steam_running || break
      if [ "$woke" = 1 ] && [ "$i" = 8 ]; then ui_status starting "Steam is reconnecting after its pause"; fi
    done
    if [ "$started" = 1 ]; then
      t_steam=open; t_helper=open
    else
      say "The open Steam did not start the game, so Steam is started afresh."
      shutdown_wine
      warm=0
      UI_EXPECT="$(expected_start cold)"
    fi
  fi
  if [ "$warm" != 1 ]; then
    say "Starting Steam and the game with $(current_tag) ($(settings_line))"
    ui_status starting "Starting Wine, the layer that runs Windows programs"
    if bottle_update_due; then
      UI_EXPECT=$((UI_EXPECT + 60))
      ui_status starting "Updating the Windows layer for this build (once)"
      note_bottle_update
    elif [ -z "${SKYWALKER_FROM_APP:-}" ]; then
      notify "Starting the game. This can take a minute." &
    fi
    session_sig > "$SESSION"
    start_watchdog "$log"
    # shellcheck disable=SC2086,SC2046
    run_wine "$STEAM_EXE" $STEAM_ARGS $(steam_gpu_opt $STEAM_ARGS) -applaunch "$APPID" $gargs >> "$log" 2>&1 &

    # Wait for the game to appear: 10 minutes covers a Steam self-update.
    # The times of each stage are kept, for "skywalker.sh timeline".
    for i in $(seq 1 540); do
      sleep 1
      if [ -z "$t_steam" ] && steam_running; then t_steam=$(( $(date +%s) - t0 )); fi
      if [ -z "$t_helper" ] && helper_running; then t_helper=$(( $(date +%s) - t0 )); fi
      if game_running; then started=1; t_game=$(( $(date +%s) - t0 )); break; fi
      if [ "$i" = 40 ] && steam_updated_since "$(cat "$LOGS/last-start")"; then
        say "Steam is downloading an update of itself first. This start takes a few minutes longer."
        UI_EXPECT=$((UI_EXPECT + 180))
        words="Steam is updating itself first (a few minutes longer)"
      elif [ "${words:-}" != "Steam is updating itself first (a few minutes longer)" ]; then
        if stage="$(steam_stage "$(cat "$LOGS/last-start")")"; then
          words="$(steam_stage_words "$stage")"
        elif [ -n "$t_helper" ]; then
          words="Steam is starting up and signing in"
        elif [ -n "$t_steam" ]; then
          words="Starting Steam"
        else
          words="Starting Wine, the layer that runs Windows programs"
        fi
      fi
      ui_status starting "$words"
      if [ "$i" -gt 60 ] && ! our_wineserver_running; then break; fi
    done
  fi
  # shellcheck disable=SC2086
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(cat "$LOGS/last-start")" "$(current_tag)" "${t_steam:--}" "${t_helper:--}" "${t_game:--}" "$STEAM_ARGS $(steam_gpu_opt $STEAM_ARGS)" >> "$LOGS/startup.tsv"
  if [ "$started" != 1 ]; then
    if our_wineserver_running; then
      ui_status failed "Steam is open but the game has not started. Sign in or press Play in Steam."
      notify "Steam is open but the game has not started. Sign in or press Play in Steam."
      echo "The game did not start within 10 minutes. Steam is left running; see $log"
      echo "Run 'bash $HOME_DIR/skywalker.sh steam' to open Steam's window, or '... stop' to close it."
    else
      ui_status failed "Steam did not start."
      notify "Steam did not start. See the log in ~/Games/skywalker/logs."
      echo "Steam did not stay running. See $log"
    fi
    return 1
  fi

  ui_status running "The game is loading"
  note_game_cmdline
  if [ "$warm" = 1 ]; then
    say "The game is running. It started ${t_game}s after the launcher."
  else
    say "The game is running. It started ${t_game}s after the launcher (Steam after ${t_steam:-?}s, Steam's browser part after ${t_helper:-?}s)."
    if steam_updated_since "$(cat "$LOGS/last-start")"; then say "Steam updated itself during this start, which is why it took longer than usual."; fi
  fi
  hotkey_start
  watch_game "$log"
  hotkey_stop
  ui_status "done" "The game has closed."
  say "The game has exited."
  keep="$(keep_seconds)"
  if pause_wanted && steam_running; then
    backup_saves
    start_idle_timer "$PAUSE_AFTER_GAME"
    say "Steam is paused in $PAUSE_AFTER_GAME seconds (after it has uploaded your saves), ready for the next start."
    return 0
  fi
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
      if wine_paused; then
        say "Steam is ready (paused), so the next start of the game is quick."
      elif pause_wanted; then
        start_idle_timer "$PAUSE_AFTER_READY"
        say "Steam is already open; it is paused in $PAUSE_AFTER_READY seconds, ready for the game."
      else
        if [ "$secs" -gt 0 ]; then start_idle_timer "$secs"; else rm -f "$IDLE"; fi
        say "Steam is already open, so the next start of the game is quick."
      fi
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
  if pause_wanted; then
    start_pause_when_ready "$(date '+%Y-%m-%d %H:%M:%S')"
    say "Steam is starting in the background; once it has signed in it is paused, ready for the game. To close it: bash $HOME_DIR/skywalker.sh stop"
  elif [ "$secs" -gt 0 ]; then
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

RUN_LABEL="io.github.jeswr.skywalker.run"

# What the app does: starts "run" as a macOS job of its own and returns. An app's
# own process is short-lived here, and macOS ends whatever it started when it
# ends; a job of its own (AbandonProcessGroup) lets the game, Steam and the
# screen watcher carry on. A second click while the job runs changes nothing.
cmd_launch() {
  local dom plist="$HOME_DIR/run-job.plist" me
  load_conf
  mkdir -p "$LOGS"
  refresh_app || true
  me="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  if game_paused; then
    UI_T0="$(date +%s)"   # the loading window hears of it, and closes once the game's window is back
    ui_status running "Carrying on with the paused game"
    cmd_resume
    return 0
  fi
  if [ ! -x "$LAUNCHCTL" ]; then exec /bin/bash "$me" run; fi
  dom="gui/$(id -u)"
  if "$LAUNCHCTL" print "$dom/$RUN_LABEL" 2>/dev/null | /usr/bin/grep -q 'state = running'; then
    say "$(date '+%H:%M:%S') The game is already starting or running."
    return 0
  fi
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$RUN_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml_text "$me")</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SKYWALKER_HOME</key><string>$(xml_text "$HOME_DIR")</string>
    <key>SKYWALKER_APP</key><string>$(xml_text "$APP")</string>
    <key>SKYWALKER_FROM_APP</key><string>1</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>$(xml_text "$LOGS/launcher.log")</string>
  <key>StandardErrorPath</key><string>$(xml_text "$LOGS/launcher.log")</string>
</dict>
</plist>
EOF
  "$LAUNCHCTL" bootout "$dom/$RUN_LABEL" >/dev/null 2>&1 || true
  if ! "$LAUNCHCTL" bootstrap "$dom" "$plist"; then
    say "macOS did not take the start as a job, so it runs here."
    exec /bin/bash "$me" run
  fi
  say "$(date '+%H:%M:%S') Started (as macOS job $RUN_LABEL)."
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
  screen_watch_stop
  hotkey_stop
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
  if [ -s "$LOGS/start-stages.txt" ]; then
    echo "The launcher's stages (second: what the loading window said):"
    /usr/bin/awk -F'\t' '{ printf "  %4s  %s\n", $1, $3 }' "$LOGS/start-stages.txt"
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
  echo "Game options: from the launcher: $(game_args | sed 's/^$/none/'); from Steam's Launch Options: $(steam_launch_options | sed 's/^$/none/')"
  case "$(display_mode)" in
    auto) echo "Display:      auto (fitted to the main screen at every start$( [ "$REFIT" = 1 ] && [ -f "$SKYFIT" ] && echo ' and when the screens change'))" ;;
    keep) echo "Display:      kept ($(tr '\n' ',' < "$DISPLAY_KEEP" 2>/dev/null | sed 's/,$//; s/,/, /g'))" ;;
    off) echo "Display:      as the game writes it" ;;
  esac
  if [ -d "$APP" ]; then echo "App:          $APP$( [ -f "$APP/Contents/Resources/AppIcon.icns" ] && echo ' (with the game icon)')"; else echo "App:          missing (skywalker.sh app)"; fi
  echo "Save backups: $(ls -1d "$SAVE_BACKUP_DIR"/20??-??-??_?????? 2>/dev/null | wc -l | tr -d ' ') in $SAVE_BACKUP_DIR"
  if pause_wanted; then
    if wine_paused; then echo "Ready:        on (Steam paused since $(cat "$PAUSED"))"; else echo "Ready:        on (Steam started at log-in and paused once signed in)"; fi
  elif [ -f "$AGENT" ]; then echo "Autostart:    on (Steam is started at log-in for $PREWARM_MINUTES minutes)"; else echo "Autostart:    off"; fi
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

# Runs a command for at most $1 seconds.
bounded() {
  local max="$1" pid t=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$t" -ge "$max" ]; then kill "$pid" 2>/dev/null; echo "(stopped after ${max}s)"; break; fi
    sleep 1; t=$((t + 1))
  done
  wait "$pid" 2>/dev/null || true
}

game_pid() {
  local pats
  pats="$(game_patterns)" || return 1
  /bin/ps -axww -o pid=,command= | /usr/bin/grep -v -e grep -e 'skywalker\.sh' \
    | /usr/bin/grep -i -F -e "$pats" | head -n 1 | /usr/bin/awk '{ print $1 }'
}

# For the moment something is wrong on screen (a black picture, a freeze):
# everything that can be seen from outside the game, in one file. Reads only.
cmd_snapshot() {
  local out pid f secs="${SKY_SNAPSHOT_SECONDS:-5}"
  load_conf
  mkdir -p "$LOGS"
  out="$LOGS/snapshot-$(date +%Y%m%d-%H%M%S).txt"
  pid="$(game_pid || true)"
  {
    echo "== Snapshot $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Build: $(current_tag)   Settings: $(settings_line) hud=$HUD"
    echo "Launcher started: $(cat "$LOGS/last-start" 2>/dev/null || echo unknown)"
    echo "Game process: ${pid:-not running}"
    echo "The game was started as: $(game_cmdline 2>/dev/null || true)"
    echo
    echo "== Windows on screen"
    cmd_windows 2>&1 || true
    echo
    echo "== Processor use over $secs seconds"
    cmd_cpu "$secs" 2>&1 || true
    echo
    echo "== The game's screen and window settings"
    if f="$(pcconfig)"; then display_lines "$f"; else echo "(settings file not found)"; fi
    echo
    echo "== Last lines of the run log"
    f="$(ls -1t "$LOGS"/run-*.log "$LOGS"/bench-*.log 2>/dev/null | head -n 1)"
    if [ -n "$f" ]; then echo "$f"; tail -n 60 "$f"; else echo "(none)"; fi
    echo
    echo "== What the game's threads are doing (3 seconds)"
    if [ -n "$pid" ] && [ -x /usr/bin/sample ]; then
      bounded 30 /usr/bin/sample "$pid" 3 -file "$out.sample" > /dev/null 2>&1
      if [ -f "$out.sample" ]; then head -n 400 "$out.sample"; rm -f "$out.sample"; else echo "(no sample could be taken)"; fi
    else
      echo "(not available)"
    fi
    echo
    echo "== The system log of the last 3 minutes, graphics lines of Wine's programs"
    if [ -x /usr/bin/log ]; then
      bounded 60 /usr/bin/log show --last 3m --style compact --predicate '(processImagePath CONTAINS[c] "wine") AND (eventMessage CONTAINS[c] "metal" OR eventMessage CONTAINS[c] "D3DM" OR eventMessage CONTAINS[c] "error" OR eventMessage CONTAINS[c] "fail")' 2>&1 | tail -n 200
    else
      echo "(not available)"
    fi
  } > "$out" 2>&1
  echo "Written to $out"
  sed -n '1,5p' "$out"
  /usr/bin/awk '/^== Windows on screen/ { on = 1 } /^== The game.s screen/ { on = 0 } on && NF' "$out" | head -n 20
}

# ---------------------------------------------------------------- pause in the middle of a level
# The game saves only at its own checkpoints. "pause" keeps it exactly where it
# is: the game's windows are hidden, then macOS freezes every Wine program (the
# game, Steam and Wine's own server) with SIGSTOP. A frozen program uses no
# processor and no battery; its memory stays, and macOS compresses it or moves
# it to disk if other apps need the room. "resume", the Pause app or the game's
# icon thaws them in one go and brings the game back. A paused game survives
# the Mac sleeping (closing the lid), but not a restart, a shutdown or a
# log-out: those end every program, frozen or not.
PAUSE_APP="${SKYWALKER_PAUSE_APP:-$(dirname "$APP")/Skywalker Pause.app}"
PAUSE_ID=local.skywalker-saga.pause

pause_js() {
  local f="$HOME_DIR/lib/pause.js"
  mkdir -p "$HOME_DIR/lib"
  cat > "$f.new" <<'EOF'
// Hides and shows Wine's programs for "skywalker.sh pause".
// Run with: osascript -l JavaScript pause.js <command> ...
//   hide PID...          hide each of these that has windows; one line "hidden PID" each
//   show PID...          show them again and bring the first to the front; last line front=yes|no
//   info PID...          "PID hidden=0|1 active=0|1" for each that has windows, then front=PID
//   badge IN.icns OUT    OUT = a 1024x1024 PNG: the icon IN with a pause sign on it
ObjC.import('Foundation');
ObjC.import('AppKit');

function out(s) {
  $.NSFileHandle.fileHandleWithStandardOutput.writeData($(s + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
}
// lets AppKit hear about changes (hidden, frontmost) for a moment
function settle(secs) {
  $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(secs));
}
function apps(pids) {
  var r = [];
  pids.forEach(function (p) {
    var a = $.NSRunningApplication.runningApplicationWithProcessIdentifier(parseInt(p, 10));
    if (a && !a.isNil()) r.push({ pid: p, app: a });
  });
  return r;
}
function frontPid() {
  var f = $.NSWorkspace.sharedWorkspace.frontmostApplication;
  return (f && !f.isNil()) ? f.processIdentifier : 0;
}

function hide(pids) {
  apps(pids).forEach(function (x) {
    if (x.app.hide) out('hidden ' + x.pid);
  });
  settle(0.5);
}

function show(pids) {
  var list = apps(pids), i, first = null;
  list.forEach(function (x) { x.app.unhide; });
  for (i = 0; i < list.length; i++) if (String(list[i].pid) === String(pids[0])) first = list[i].app;
  if (!first) { out('front=no (no window)'); return; }
  var me = $.NSApplication.sharedApplication;
  if (me.respondsToSelector('yieldActivationToApplication:')) me.yieldActivationToApplication(first);
  // 1 = all windows, 2 = ignoring other apps (older macOS needs it; newer ignores it)
  first.activateWithOptions(3);
  for (i = 0; i < 20; i++) {
    settle(0.1);
    if (String(frontPid()) === String(pids[0])) { out('front=yes'); return; }
  }
  out('front=no (frontmost: ' + frontPid() + ')');
}

function info(pids) {
  settle(0.2);
  apps(pids).forEach(function (x) {
    out(x.pid + ' hidden=' + (x.app.hidden ? 1 : 0) + ' active=' + (x.app.active ? 1 : 0));
  });
  out('front=' + frontPid());
}

function badge(src, dest) {
  var img = $.NSImage.alloc.initWithContentsOfFile(src);
  var S = 1024;
  var rep = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
    null, S, S, 8, 4, true, false, $.NSDeviceRGBColorSpace, 0, 0);
  var ctx = $.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep);
  $.NSGraphicsContext.saveGraphicsState;
  $.NSGraphicsContext.setCurrentContext(ctx);
  ctx.setImageInterpolation($.NSImageInterpolationHigh);
  if (img && !img.isNil()) {
    img.drawInRectFromRectOperationFraction($.NSMakeRect(0, 0, S, S), $.NSZeroRect, $.NSCompositingOperationSourceOver, 1);
  } else {
    $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.15, 0.17, 0.22, 1).setFill;
    $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius($.NSMakeRect(100, 100, 824, 824), 185, 185).fill;
  }
  // the pause sign: a dark disc with two white bars, lower right
  $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.05, 0.05, 0.08, 0.92).setFill;
  $.NSBezierPath.bezierPathWithOvalInRect($.NSMakeRect(540, 90, 400, 400)).fill;
  $.NSColor.whiteColor.setFill;
  $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius($.NSMakeRect(655, 190, 60, 200), 18, 18).fill;
  $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius($.NSMakeRect(765, 190, 60, 200), 18, 18).fill;
  ctx.flushGraphics;
  $.NSGraphicsContext.restoreGraphicsState;
  var png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
  if (!png.writeToFileAtomically(dest, true)) throw 'cannot write ' + dest;
  return 'ok';
}

function run(argv) {
  try {
    var cmd = argv[0], rest = argv.slice(1);
    if (cmd === 'hide') return hide(rest);
    if (cmd === 'show') return show(rest);
    if (cmd === 'info') return info(rest);
    if (cmd === 'badge') return badge(rest[0], rest[1]);
    return 'unknown command';
  } catch (e) {
    return 'error: ' + e;
  }
}
EOF
  if /usr/bin/cmp -s "$f.new" "$f"; then rm -f "$f.new"; else mv "$f.new" "$f"; fi
  echo "$f"
}

# Whether the game is paused now. A note left by a game that has gone since
# (the Mac restarted, or the game was ended from the Dock) is cleared.
game_paused() {
  [ -f "$GAME_PAUSED" ] || return 1
  if game_running; then return 0; fi
  rm -f "$GAME_PAUSED"
  return 1
}

pause_field() { sed -n "s/^$1=//p" "$GAME_PAUSED" 2>/dev/null | head -n 1; }

# "2 h 5 min" for a number of seconds
pause_words() {
  local s="${1:-0}"
  if [ "$s" -ge 3600 ]; then echo "$((s / 3600)) h $(((s % 3600) / 60)) min"
  elif [ "$s" -ge 60 ]; then echo "$((s / 60)) min"
  else echo "$s s"; fi
}

# Wine's programs in the order they are frozen: the game first, Wine's server
# last, so that the game stops between two of its own frames and not while it
# waits for an answer from a server that is already frozen.
pause_order() {
  local pids pats pid cmd g="" r="" s=""
  pids=" $(wine_pids | tr '\n' ' ') "
  pats="$(game_patterns || true)"
  while read -r pid cmd; do
    case "$pids" in *" $pid "*) ;; *) continue ;; esac
    if [ -n "$pats" ] && printf '%s\n' "$cmd" | /usr/bin/grep -qiF -e "$pats"; then g="$g $pid"
    elif printf '%s\n' "$cmd" | /usr/bin/grep -qE '/wineserver( |$)'; then s="$s $pid"
    else r="$r $pid"; fi
  done < <(/bin/ps -x -o pid=,command=)
  echo $g $r $s
}

# How many of the processes given are not frozen.
pids_running() {
  local p n=0 st
  for p in "$@"; do
    st="$(/bin/ps -o stat= -p "$p" 2>/dev/null)" || continue
    case "$st" in T*) ;; *) n=$((n + 1)) ;; esac
  done
  echo "$n"
}

# $1 = "app" when the Pause app asked (it shows the game itself, and wants a last line it can read),
# "hotkey" when the hotkey did (the game is in front: its own pause menu is opened first)
cmd_pause() {
  local from="${1:-}" gpid order js left=0 i
  load_conf
  need_wine
  mkdir -p "$LOGS"
  if game_paused; then
    say "The game is already paused (for $(pause_words $(( $(date +%s) - $(pause_field since) )))). To carry on: bash $HOME_DIR/skywalker.sh resume"
    echo "state=paused game=$(pause_field game)"
    return 0
  fi
  other_wine_running && die "CrossOver or another Wine is running, and its programs look like the game's. Quit it first."
  game_running || die "The game is not running, so there is nothing to pause."
  gpid="$(game_pid)"
  order="$(pause_order)"
  [ -n "$order" ] || die "Could not find the game's processes."
  # the last checkpoint is copied now, in case the paused game is lost (a restart)
  backup_saves > /dev/null 2>&1 || true
  # from the hotkey, the game is in front and in play: open its own pause menu first
  if [ "$from" = hotkey ]; then pause_menu_key; fi
  # Hidden first, while the game can still answer: the desktop comes back, and
  # the game hears that it went to the background (games tend to pause themselves there).
  js="$(pause_js)"
  # shellcheck disable=SC2086
  bounded_quiet 10 /usr/bin/osascript -l JavaScript "$js" hide $gpid $order > "$LOGS/pause-hide.txt" 2>&1
  sleep "${PAUSE_SETTLE:-2}"
  {
    echo "since=$(date +%s)"
    echo "game=$gpid"
    echo "screen=$(screen_key "$(screen_now 2>/dev/null || true)")"
  } > "$GAME_PAUSED"
  for i in 1 2 3; do
    order="$(pause_order)"   # again: a program may have started meanwhile
    # shellcheck disable=SC2086
    kill -STOP $order 2>/dev/null
    sleep 0.3
    # shellcheck disable=SC2086
    left="$(pids_running $order)"
    [ "$left" = 0 ] && break
  done
  echo "$(date '+%Y-%m-%d %H:%M:%S') paused: game $gpid, $(echo $order | wc -w | tr -d ' ') programs, $left not frozen" >> "$LOGS/pauses.log"
  [ "$left" = 0 ] || say "Warning: $left of Wine's programs did not freeze."
  say "Paused: the game is frozen where it is and uses no processor time. Closing the lid is fine; a restart or shutdown would lose it."
  say "To carry on: click Skywalker Pause or the game's icon, or run: bash $HOME_DIR/skywalker.sh resume"
  [ -n "$from" ] || notify "Paused. Click Skywalker Pause or the game's icon to carry on."
  echo "state=paused game=$gpid"
}

cmd_resume() {
  local from="${1:-}" gpid since secs js front=""
  load_conf
  need_wine
  mkdir -p "$LOGS"
  if ! game_paused; then
    say "The game is not paused."
    echo "state=running game=$(game_pid 2>/dev/null || true)"
    return 0
  fi
  since="$(pause_field since)"
  resume_wine all
  rm -f "$GAME_PAUSED"
  gpid="$(game_pid)"
  secs=$(( $(date +%s) - ${since:-$(date +%s)} ))
  if [ "$from" != app ]; then
    js="$(pause_js)"
    # shellcheck disable=SC2046
    front="$(bounded_quiet 10 /usr/bin/osascript -l JavaScript "$js" show $gpid $(pause_order) 2>&1 | tail -n 1)"
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') resumed after $(pause_words "$secs"): game $gpid ${front}" >> "$LOGS/pauses.log"
  say "Resumed after $(pause_words "$secs")."
  # a screen change while paused is picked up by the launcher's screen watcher, which fits the game again now
  echo "state=resumed game=$gpid"
}

# What the Pause app runs: pause a running game, resume a paused one.
cmd_toggle_pause() {
  load_conf
  if game_paused; then cmd_resume "${1:-}"
  elif game_running; then cmd_pause "${1:-}"
  else
    notify "The game is not running."
    say "The game is not running."
    echo "state=none"
  fi
}

# The Pause app: one click pauses the game (it is hidden and frozen), the next
# brings it back. Made next to the game's app, with the game's icon and a pause sign.
pause_app_js() {
  cat <<EOF
// Skywalker Pause: pauses the game, or brings back a paused one (skywalker.sh toggle-pause).
ObjC.import('AppKit');
var LAUNCHER = '$(app_launcher_path)';
function run() {
  var app = Application.currentApplication();
  app.includeStandardAdditions = true;
  var L = LAUNCHER.replace(/^\\\$HOME/, \$.NSHomeDirectory().js);
  var out = '';
  try {
    out = app.doShellScript("/bin/bash '" + L.replace(/'/g, "'\\\\''") + "' toggle-pause app 2>&1");
  } catch (e) {
    app.displayNotification(String(e).slice(0, 180), { withTitle: 'Skywalker Saga' });
    return;
  }
  var m = /state=resumed game=(\\d+)/.exec(out);
  if (!m) return;
  // this app was just clicked, so it is the one that may hand the front over to the game
  var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier(parseInt(m[1], 10));
  if (!a || a.isNil()) return;
  a.unhide;
  var me = \$.NSApplication.sharedApplication;
  if (me.respondsToSelector('yieldActivationToApplication:')) me.yieldActivationToApplication(a);
  a.activateWithOptions(3);
}
EOF
}

create_pause_app() {
  local t b js icon=""
  [ -x "$OSACOMPILE" ] || die "The Pause app needs macOS (osacompile)."
  t="$(mktemp -d "${TMPDIR:-/tmp}/skywalker-pause.XXXXXX")" || return 1
  b="$t/Skywalker Pause.app"
  pause_app_js > "$t/pause-app.js"
  if ! "$OSACOMPILE" -l JavaScript -o "$b" "$t/pause-app.js" > "$t/osacompile.txt" 2>&1; then
    say "The Pause app could not be compiled: $(cat "$t/osacompile.txt")"
    rm -rf "$t"
    return 1
  fi
  js="$(pause_js)"
  if [ -s "$APP/Contents/Resources/AppIcon.icns" ]; then icon="$APP/Contents/Resources/AppIcon.icns"; fi
  if [ "$(bounded_quiet 60 /usr/bin/osascript -l JavaScript "$js" badge "${icon:-none}" "$t/icon1024.png" 2>&1)" = ok ]; then
    mkdir -p "$t/AppIcon.iconset"
    for s in 16 32 128 256 512; do
      /usr/bin/sips -z "$s" "$s" "$t/icon1024.png" --out "$t/AppIcon.iconset/icon_${s}x${s}.png" > /dev/null 2>&1
      /usr/bin/sips -z "$((s * 2))" "$((s * 2))" "$t/icon1024.png" --out "$t/AppIcon.iconset/icon_${s}x${s}@2x.png" > /dev/null 2>&1
    done
    if /usr/bin/iconutil -c icns "$t/AppIcon.iconset" -o "$b/Contents/Resources/applet.icns" 2>/dev/null; then
      rm -f "$b/Contents/Resources/Assets.car"
      /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$b/Contents/Info.plist" > /dev/null 2>&1 || true
    fi
  fi
  plist_set "$b/Contents/Info.plist" CFBundleIdentifier "$PAUSE_ID"
  plist_set "$b/Contents/Info.plist" CFBundleName "Skywalker Pause"
  plist_set "$b/Contents/Info.plist" CFBundleDisplayName "Skywalker Pause"
  /usr/bin/codesign --force --deep --sign - "$b" > /dev/null 2>&1 || true
  mkdir -p "$(dirname "$PAUSE_APP")"
  rm -rf "$PAUSE_APP.old"
  if [ -d "$PAUSE_APP" ]; then mv "$PAUSE_APP" "$PAUSE_APP.old"; fi
  mv "$b" "$PAUSE_APP"
  rm -rf "$PAUSE_APP.old" "$t"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PAUSE_APP" > /dev/null 2>&1 || true
  say "Pause app: $PAUSE_APP (Spotlight finds it as \"Skywalker Pause\": Cmd-Space, type pause, Return)"
}

# Puts the Pause app in the Dock just after the game's icon (or at the end).
dock_pin_pause() {
  local js url game_url plist i u n="" have=0
  [ -d "$PAUSE_APP" ] || die "The Pause app is missing. Run: bash $HOME_DIR/skywalker.sh pause-app"
  js="$(appicon_js)"
  url="$(/usr/bin/osascript -l JavaScript "$js" url "$PAUSE_APP" 2>/dev/null)"
  game_url="$(/usr/bin/osascript -l JavaScript "$js" url "$APP" 2>/dev/null)"
  case "$url" in file://*) ;; *) die "Could not work out the Pause app's address for the Dock ($url)." ;; esac
  plist="$HOME_DIR/.dock-pause.plist"
  mkdir -p "$HOME_DIR/settings-backups"
  /usr/bin/defaults export com.apple.dock "$plist" 2>/dev/null || die "Could not read the Dock's settings."
  cp "$plist" "$HOME_DIR/settings-backups/dock-$(date +%Y%m%d-%H%M%S).plist"
  i=0
  while /usr/libexec/PlistBuddy -c "Print :persistent-apps:$i" "$plist" > /dev/null 2>&1; do
    u="$(/usr/libexec/PlistBuddy -c "Print :persistent-apps:$i:tile-data:file-data:_CFURLString" "$plist" 2>/dev/null)" || u=""
    [ "$u" = "$url" ] && have=1
    [ "$u" = "$game_url" ] && n=$((i + 1))
    i=$((i + 1))
    [ "$i" -lt 500 ] || break
  done
  if [ "$have" = 1 ]; then rm -f "$plist"; say "The Dock already has the Pause app."; return 0; fi
  n="${n:-$i}"
  /usr/libexec/PlistBuddy \
    -c "Add :persistent-apps:$n dict" \
    -c "Add :persistent-apps:$n:tile-type string file-tile" \
    -c "Add :persistent-apps:$n:tile-data dict" \
    -c "Add :persistent-apps:$n:tile-data:file-label string Skywalker Pause" \
    -c "Add :persistent-apps:$n:tile-data:file-data dict" \
    -c "Add :persistent-apps:$n:tile-data:file-data:_CFURLString string $url" \
    -c "Add :persistent-apps:$n:tile-data:file-data:_CFURLStringType integer 15" \
    "$plist" || die "Could not add the Pause app to the Dock's settings."
  for i in 1 2 3; do
    /usr/bin/defaults import com.apple.dock "$plist" || die "Could not save the Dock's settings."
    /usr/bin/killall Dock 2>/dev/null || true
    sleep 3
    /usr/bin/defaults export com.apple.dock "$plist.check" 2>/dev/null || true
    if dock_count "$plist.check" "$url" | grep -qx 1; then have=1; break; fi
  done
  rm -f "$plist" "$plist.check"
  [ "$have" = 1 ] || die "The Dock did not take the change. Try again: bash $HOME_DIR/skywalker.sh pause-app"
  say "The Pause app is in the Dock, next to the game."
}

# ---- the pause hotkey
# While the game runs, a small listener (tools/skyhotkey) holds a system-wide
# keyboard shortcut, Ctrl-Option-P unless set otherwise with "hotkey". A press
# pauses the game (after opening its own pause menu), the next press brings it
# back. It uses the system's hotkey service, which needs no permission in
# System Settings, and the key never reaches the game.
HOTKEY_FILE="$HOME_DIR/pause-hotkey"   # ctrl-option-p (default), another combination, or off
HOTKEY_PID="$HOME_DIR/.hotkey.pid"
SKYKEY="$HOME_DIR/tools/skykey.exe"   # presses a key for the game, inside Wine (scripts/skykey.c)
SKYHOTKEY="$HOME_DIR/tools/skyhotkey"   # holds the hotkey (scripts/skyhotkey.swift)

hotkey_spec() {
  local s
  s="$(cat "$HOTKEY_FILE" 2>/dev/null | tr -d ' \n')"
  echo "${s:-ctrl-option-p}"
}

# "ctrl-option-p" -> "Ctrl-Option-P"
hotkey_words() { echo "$1" | awk -F- '{ for (i = 1; i <= NF; i++) { w = toupper(substr($i, 1, 1)) substr($i, 2); printf "%s%s", (i > 1 ? "-" : ""), w } print "" }'; }


# The system's numbers for the keys of a combination like ctrl-option-p: "KEYCODE MODS".
hotkey_codes() {
  local spec part key mods=0 code=""
  spec="$(echo "$1" | tr 'A-Z' 'a-z')"
  key="${spec##*-}"
  for part in $(echo "${spec%-*}" | tr '-' ' '); do
    case "$part" in
      cmd|command) mods=$((mods | 256)) ;;
      shift) mods=$((mods | 512)) ;;
      option|opt|alt) mods=$((mods | 2048)) ;;
      ctrl|control) mods=$((mods | 4096)) ;;
      *) return 1 ;;
    esac
  done
  case "$key" in
    a) code=0 ;; s) code=1 ;; d) code=2 ;; f) code=3 ;; h) code=4 ;; g) code=5 ;; z) code=6 ;; x) code=7 ;;
    c) code=8 ;; v) code=9 ;; b) code=11 ;; q) code=12 ;; w) code=13 ;; e) code=14 ;; r) code=15 ;; y) code=16 ;;
    t) code=17 ;; 1) code=18 ;; 2) code=19 ;; 3) code=20 ;; 4) code=21 ;; 6) code=22 ;; 5) code=23 ;; 9) code=25 ;;
    7) code=26 ;; 8) code=28 ;; 0) code=29 ;; o) code=31 ;; u) code=32 ;; i) code=34 ;; p) code=35 ;; l) code=37 ;;
    j) code=38 ;; k) code=40 ;; n) code=45 ;; m) code=46 ;;
    f1) code=122 ;; f2) code=120 ;; f3) code=99 ;; f4) code=118 ;; f5) code=96 ;; f6) code=97 ;; f7) code=98 ;;
    f8) code=100 ;; f9) code=101 ;; f10) code=109 ;; f11) code=103 ;; f12) code=111 ;;
    *) return 1 ;;
  esac
  [ "$mods" -gt 0 ] || return 1
  echo "$code $mods"
}

# Starts the listener for as long as the game runs (play() stops it).
hotkey_start() {
  local spec codes me
  spec="$(hotkey_spec)"
  [ "$spec" = off ] && return 0
  if ! codes="$(hotkey_codes "$spec")"; then
    say "The pause hotkey \"$spec\" is not a key combination I know; set another with: bash $HOME_DIR/skywalker.sh hotkey ctrl-option-p"
    return 0
  fi
  if [ ! -x "$SKYHOTKEY" ]; then
    say "The hotkey helper ($SKYHOTKEY) is missing, so there is no pause hotkey this time. The Pause app still works."
    return 0
  fi
  hotkey_stop
  me="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  mkdir -p "$LOGS"
  echo "== $(date '+%Y-%m-%d %H:%M:%S') listening for $spec" >> "$LOGS/hotkey.log"
  # shellcheck disable=SC2086
  "$SKYHOTKEY" $codes "$me" 43200 >> "$LOGS/hotkey.log" 2>&1 &
  echo $! > "$HOTKEY_PID"
  say "Pause hotkey: $(hotkey_words "$spec") pauses the game and brings it back."
}

hotkey_stop() {
  local pid
  pid="$(cat "$HOTKEY_PID" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) ;; *)
    if /bin/ps -p "$pid" -o command= 2>/dev/null | /usr/bin/grep -q 'skyhotkey'; then kill "$pid" 2>/dev/null || true; fi ;;
  esac
  rm -f "$HOTKEY_PID"
}

# Opens the game's own pause menu (a press of Esc, PAUSE_MENU_KEY) so that it
# is paused in the game too, and stays paused when it is brought back.
pause_menu_key() {
  local key="${PAUSE_MENU_KEY:-esc}"
  [ "$key" = off ] && return 0
  if [ ! -f "$SKYKEY" ]; then
    echo "skykey.exe is missing: the game's menu was not opened first" >> "$LOGS/pause-hide.txt"
    return 0
  fi
  wine_env
  WINEDEBUG=-all bounded_quiet 15 "$CUR/bin/wine" "$SKYKEY" "$key" >> "$LOGS/pause-hide.txt" 2>&1
  sleep "${PAUSE_MENU_WAIT:-1}"
}

cmd_hotkey() {
  local a="${1:-show}"
  load_conf
  case "$a" in
    show)
      echo "Pause hotkey: $(hotkey_words "$(hotkey_spec)") (works while the game runs; set another with: hotkey ctrl-option-p, or hotkey off)"
      if [ -f "$SKYKEY" ]; then echo "Before pausing, it opens the game's menu with: ${PAUSE_MENU_KEY:-esc}"; else echo "The key helper is missing ($SKYKEY), so the game's menu is not opened first."; fi
      [ -x "$SKYHOTKEY" ] || echo "The hotkey helper is missing ($SKYHOTKEY), so there is no hotkey yet." ;;
    off) echo off > "$HOTKEY_FILE"; hotkey_stop; say "No pause hotkey. The Pause app and the game's icon still work." ;;
    listen)   # for tests: the listener in front, for $2 seconds
      [ -x "$SKYHOTKEY" ] || die "The hotkey helper is missing: $SKYHOTKEY"
      # shellcheck disable=SC2046
      exec "$SKYHOTKEY" $(hotkey_codes "$(hotkey_spec)") "$HOME_DIR/skywalker.sh" "${2:-43200}" ;;
    *)
      hotkey_codes "$a" > /dev/null || die "Not a key combination I know: $a (for example ctrl-option-p, cmd-shift-f9)"
      echo "$a" | tr 'A-Z' 'a-z' > "$HOTKEY_FILE"
      say "Pause hotkey: $(hotkey_words "$(hotkey_spec)"). It is used from the next start of the game." ;;
  esac
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
  if [ -x "$LAUNCHCTL" ]; then "$LAUNCHCTL" bootout "gui/$(id -u)/$RUN_LABEL" >/dev/null 2>&1 || true; fi
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
  launch) cmd_launch ;;   # what the app runs
  ready) shift; cmd_ready "${1:-status}" ;;
  pause-steam) load_conf; wine_env; if pause_wine; then say "Steam is paused."; else say "Nothing to pause."; fi ;;
  steam) shift; cmd_steam "$@" ;;
  stop) cmd_stop ;;
  pause) cmd_pause ;;
  resume) cmd_resume ;;
  toggle-pause) shift; cmd_toggle_pause "${1:-}" ;;   # what the Pause app runs
  hotkey) shift; cmd_hotkey "$@" ;;
  pause-app) load_conf; create_pause_app && { [ -n "${SKYWALKER_NO_DOCK:-}" ] || dock_pin_pause; } ;;
  prewarm) shift; cmd_prewarm "${1:-}" ;;
  autostart) shift; cmd_autostart "${1:-status}" ;;
  cpu) shift; cmd_cpu "${1:-30}" ;;
  display) shift; cmd_display "${1:-show}" ;;
  refit) cmd_refit ;;
  watch-game) load_conf; need_wine; wine_env; mkdir -p "$LOGS"; watch_game "$LOGS/watch-game.log" ;;   # used by the tests
  bench) shift; cmd_bench "${1:-test}" ;;
  summary) shift; summarise "$@" ;;
  backup) load_conf; backup_saves ;;
  app) load_conf; create_app && { [ -n "${SKYWALKER_NO_DOCK:-}" ] || dock_pin; } ;;
  dock) load_conf; dock_pin ;;
  doctor) cmd_doctor ;;
  windows) cmd_windows ;;
  timeline) cmd_timeline ;;
  snapshot) cmd_snapshot ;;
  wine) shift; load_conf; need_wine; wine_env; resume_wine > /dev/null; mkdir -p "$LOGS"; start_watchdog "$LOGS/watchdog.log"; limit_processes; exec "$CUR/bin/wine" "$@" ;;
  uninstall) cmd_uninstall ;;
  *) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
