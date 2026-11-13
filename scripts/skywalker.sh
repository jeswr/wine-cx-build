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
#   skywalker.sh graphics split|dxmt|wine   split (default): DXMT for the game and Wine's own
#                                Direct3D for Steam; dxmt or wine: one of them for everything
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
STEAM_ARGS="-silent -nofriendsui -nochatui"

MSYNC=1                  # CrossOver's fast locks
UPSCALE=0                # 1 = draw small and let MetalFX enlarge it. Set the game to 1280x800 first.
UPSCALE_FACTOR=2         # 1280x800 x 2 = the Air's native 2560x1600
FPS_CAP=0                # 0 = leave it to the game. Otherwise 60 or 30.
AVX=0                    # 1 = let Rosetta offer AVX2 to the game
HUD=0                    # 1 = show Apple's frame counter

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
  : "${PROC_HEADROOM:=400}"
  for k in MSYNC UPSCALE UPSCALE_FACTOR FPS_CAP AVX HUD STEAM_ARGS PREFIX PROC_HEADROOM; do
    v="SKY_$k"
    if [ -n "${!v:-}" ]; then eval "$k=\${$v}"; fi
  done
}

settings_line() {
  echo "graphics=$(graphics_now) msync=$MSYNC upscale=$UPSCALE factor=$UPSCALE_FACTOR cap=$FPS_CAP avx=$AVX"
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

helper_running() {
  /bin/ps -axww -o command= | /usr/bin/grep -i -F 'steamwebhelper.exe' | /usr/bin/grep -v grep >/dev/null
}
steam_running() {
  /bin/ps -axww -o command= | /usr/bin/grep -i -F 'steam.exe' | /usr/bin/grep -v grep >/dev/null
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
  if [ ! -f "$CUR/GRAPHICS" ] && [ -d "$CUR/orig-dlls" ]; then apply_graphics split; fi
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

# split: DXMT for the game, Wine's own Direct3D for Steam and everything else
# dxmt:  DXMT for everything (Steam cannot show its windows)
# wine:  Wine's own Direct3D for everything
apply_graphics() {
  local want="$1" w
  w="$(cd "$CUR" && pwd -P)"
  case "$want" in
    split) set_build_dlls wine; game_dxmt_on ;;
    wine) set_build_dlls wine; game_dxmt_off ;;
    dxmt) set_build_dlls dxmt; game_dxmt_off ;;
  esac
  echo "$want" > "$w/GRAPHICS"
  say "Graphics for $(current_tag): $want"
}

cmd_graphics() {
  local want="${1:-}"
  need_wine
  case "$want" in
    split|dxmt|wine) ;;
    *) echo "Graphics in use: $(graphics_now). Switch with: skywalker.sh graphics split|dxmt|wine"; return 0 ;;
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

shutdown_wine() {
  local i
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

# $1 = log file for Wine's output
play() {
  local log="$1" i started=0 t0 t_steam="" t_helper="" t_game=""
  need_wine
  other_wine_running && die "CrossOver or another Wine is running. Quit it first."
  if game_running; then
    say "The game is already running."
    return 0
  fi
  mkdir -p "$LOGS"
  t0="$(date +%s)"
  date '+%Y-%m-%d %H:%M:%S' > "$LOGS/last-start"
  backup_saves
  prepare_prefix
  wine_env
  say "Starting Steam and the game with $(current_tag) ($(settings_line))"
  notify "Starting the game. This can take a minute." &
  cd "$HOME" || true
  start_watchdog "$log"
  # shellcheck disable=SC2086
  run_wine "$STEAM_EXE" $STEAM_ARGS -applaunch "$APPID" >> "$log" 2>&1 &

  # Wait for the game to appear: 10 minutes covers a Steam self-update.
  # The times of each stage are kept, for "skywalker.sh timeline".
  for i in $(seq 1 540); do
    sleep 1
    if [ -z "$t_steam" ] && steam_running; then t_steam=$(( $(date +%s) - t0 )); fi
    if [ -z "$t_helper" ] && helper_running; then t_helper=$(( $(date +%s) - t0 )); fi
    if game_running; then started=1; t_game=$(( $(date +%s) - t0 )); break; fi
    if [ "$i" -gt 60 ] && ! our_wineserver_running; then break; fi
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(cat "$LOGS/last-start")" "$(current_tag)" "${t_steam:--}" "${t_helper:--}" "${t_game:--}" "$STEAM_ARGS" >> "$LOGS/startup.tsv"
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

  say "The game is running. It started ${t_game}s after the launcher (Steam after ${t_steam:-?}s, Steam's browser part after ${t_helper:-?}s)."
  while game_running; do sleep 5; done
  say "The game has exited."
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
  start_watchdog "$log"
  if [ "$#" -gt 0 ]; then say "Extra Steam options: $*"; fi
  run_wine "$STEAM_EXE" "$@" >> "$log" 2>&1 &
  say "Steam is starting. Close it with: bash $HOME_DIR/skywalker.sh stop"
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
  echo "Steam's logs from then on:"
  for f in bootstrap_log.txt steamui_html.txt webhelper.txt connection_log.txt console_log.txt content_log.txt gameprocess_log.txt cloud_log.txt; do
    [ -f "$logs/$f" ] || continue
    /usr/bin/awk -v s="[$since]" -v f="${f%.txt}" -v id="$APPID" '
      substr($0, 1, 1) == "[" && substr($0, 1, 21) >= s {
        if ($0 ~ /Startup - updater built|Verification complete|Downloading update\.\.\.|Download complete|Download skipped|Update complete|Started webhelper|Restart webhelper|BrowserReady|GPU process restarts|Startup - webhelper launched|LogOnResponse|Logged On|logged on|Game process|App Running|Console Log Start/ || index($0, id))
          print substr($0, 13, 8), f ": " substr($0, 23, 140)
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
  # that logged it (system log) or "output" (the game's own output), because
  # Steam's windows can log frames too.
  cat "$@" 2>/dev/null | awk '
    {
      i = index($0, "metal-HUD:")
      if (!i) next
      key = "output"
      if (match(substr($0, 1, i), /[^ ]+\[[0-9]+:[0-9a-fA-Fx]+\]/)) key = substr($0, RSTART, RLENGTH)
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
  echo "Settings:     $(settings_line) hud=$HUD"
  echo "Save backups: $(ls -1d "$SAVE_BACKUP_DIR"/20??-??-??_?????? 2>/dev/null | wc -l | tr -d ' ') in $SAVE_BACKUP_DIR"
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
  case "$APP" in */"Skywalker Saga.app") rm -rf "$APP" ;; esac
  case "$HOME_DIR" in */skywalker) rm -rf "$HOME_DIR" ;; esac
  echo "Removed."
}

case "${1:-run}" in
  install) shift; cmd_install "${1:-}" ;;
  update) cmd_install "" ;;
  rollback) cmd_rollback ;;
  graphics) shift; load_conf; cmd_graphics "${1:-}" ;;
  run) cmd_run ;;
  steam) shift; cmd_steam "$@" ;;
  stop) cmd_stop ;;
  bench) shift; cmd_bench "${1:-test}" ;;
  summary) shift; summarise "$@" ;;
  backup) load_conf; backup_saves ;;
  app) load_conf; create_app ;;
  doctor) cmd_doctor ;;
  windows) cmd_windows ;;
  timeline) cmd_timeline ;;
  wine) shift; load_conf; need_wine; wine_env; mkdir -p "$LOGS"; start_watchdog "$LOGS/watchdog.log"; limit_processes; exec "$CUR/bin/wine" "$@" ;;
  uninstall) cmd_uninstall ;;
  *) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
