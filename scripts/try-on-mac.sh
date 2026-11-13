#!/bin/bash
# Install a wine-cx-build release plus DXMT under ~/Games, make a fresh APFS
# clone of the CrossOver "Steam" bottle (instant, no extra disk space; the
# original bottle is only read), and start Steam in it.
#
# Usage: bash try-on-mac.sh [release-tag] [package-name]
# Re-running skips the download and the clone if they already exist.
set -euo pipefail

TAG="${1:-wine-cx-26.3.0-2}"
PKG="${2:-wine-cx-26.3.0}"
DXMT_VER=v0.80
G="$HOME/Games"
WINEDIR="$G/$TAG"
PREFIX="$G/skywalker-cx"
BOTTLE="$HOME/Library/Application Support/CrossOver/Bottles/Steam"
REL="https://github.com/jeswr/wine-cx-build/releases/download/$TAG"

if pgrep -f 'wineserver|CrossOver.app/' >/dev/null; then
  echo "Please quit Steam, CrossOver and any other Wine program first, then run this again."
  exit 1
fi

mkdir -p "$G"
if [ ! -x "$WINEDIR/bin/wine" ]; then
  tmp=$(mktemp -d "$G/.download.XXXX")
  echo "== Downloading $PKG ($TAG)"
  curl -fL --retry 3 -o "$tmp/$PKG.tar.xz" "$REL/$PKG.tar.xz"
  curl -fsSL -o "$tmp/$PKG.tar.xz.sha256" "$REL/$PKG.tar.xz.sha256"
  (cd "$tmp" && shasum -a 256 -c "$PKG.tar.xz.sha256")
  rm -rf "$WINEDIR.partial" && mkdir -p "$WINEDIR.partial"
  tar -xJf "$tmp/$PKG.tar.xz" -C "$WINEDIR.partial"

  echo "== Adding DXMT $DXMT_VER (Wine's own copies kept in orig-dlls)"
  curl -fL --retry 3 -o "$tmp/dxmt.tar.gz" \
    "https://github.com/3Shain/dxmt/releases/download/$DXMT_VER/dxmt-$DXMT_VER-builtin.tar.gz"
  tar -xzf "$tmp/dxmt.tar.gz" -C "$tmp"
  for arch in x86_64-windows i386-windows x86_64-unix; do
    mkdir -p "$WINEDIR.partial/orig-dlls/$arch"
    for f in "$tmp/$DXMT_VER/$arch"/*; do
      b=$(basename "$f")
      dst="$WINEDIR.partial/lib/wine/$arch/$b"
      [ -e "$dst" ] && cp "$dst" "$WINEDIR.partial/orig-dlls/$arch/"
      cp "$f" "$dst"
    done
  done

  n=$(find "$WINEDIR.partial/lib/wine" -name '*.dll' | wc -l | tr -d ' ')
  if [ "$n" -lt 1000 ] || [ ! -e "$WINEDIR.partial/lib/wine/x86_64-windows/ntdll.dll" ]; then
    echo "Only $n Windows DLLs are present after unpacking. Sophos has probably removed some; an IT exclusion for ~/Games is needed."
    exit 1
  fi
  mv "$WINEDIR.partial" "$WINEDIR"
  rm -rf "$tmp"
fi

if [ ! -d "$PREFIX" ]; then
  echo "== Cloning the CrossOver Steam bottle to $PREFIX"
  cp -cR "$BOTTLE" "$PREFIX"
fi

echo "== Starting Steam (log: $G/skywalker-cx-steam.log)"
cd "$HOME"
WINEPREFIX="$PREFIX" USER=crossover WINEMSYNC=1 MTL_HUD_ENABLED=1 \
  "$WINEDIR/bin/wine" 'C:\Program Files (x86)\Steam\steam.exe' \
  >"$G/skywalker-cx-steam.log" 2>&1 &
echo "Started. Steam's window should appear within a minute or two."
