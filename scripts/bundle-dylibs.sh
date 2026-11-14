#!/bin/bash
# Wine loads a few Homebrew libraries by bare name at run time (dlopen):
#   libfreetype (fonts), libgnutls (TLS and crypto), libSDL2 (controllers).
#
# MoltenVK (Vulkan) is left out on purpose. Wine creates a Vulkan instance as
# soon as its desktop starts, and Homebrew's MoltenVK aborts in vkCreateInstance
# on the build runner, which takes Wine's desktop down with it. Nothing here
# needs Vulkan (DXMT and D3DMetal talk to Metal directly), and without the
# library Wine just logs that Vulkan is unavailable.
# On the build runner they resolve from /usr/local/lib. On another Mac they do
# not exist, so copy them and everything they depend on into <prefix>/lib and
# make the copies relocatable. The launcher then points
# DYLD_FALLBACK_LIBRARY_PATH at that folder.
#
# Usage: bundle-dylibs.sh <install-prefix>
# Written for the stock /bin/bash 3.2 on macOS.
set -euo pipefail

PREFIX="${1:?usage: bundle-dylibs.sh <install-prefix>}"
LIB="$PREFIX/lib"
BREW="$(brew --prefix)"
ROOTS="libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib"

is_system() {
  case "$1" in /usr/lib/*|/System/*) return 0 ;; esac
  return 1
}

# Print the file a dependency reference points at.
# $1 = reference as recorded in the library, $2 = folder of that library
resolve() {
  local ref="$1" from="$2" base d found
  base="$(basename "$ref")"
  case "$ref" in
    /*)
      echo "$ref"
      return 0
      ;;
  esac
  for d in "$from" "$BREW/lib"; do
    if [ -e "$d/$base" ]; then
      echo "$d/$base"
      return 0
    fi
  done
  found="$(find -L "$BREW/opt" -maxdepth 3 -name "$base" -type f 2>/dev/null | head -n 1)"
  if [ -n "$found" ]; then
    echo "$found"
    return 0
  fi
  echo "bundle-dylibs: cannot find $ref (needed from $from)" >&2
  return 1
}

# $1 = source file, $2 = file name to install it under
bundle() {
  local src="$1" name="$2" dst="$LIB/$2" srcdir dep depbase deppath self
  if [ -e "$dst" ]; then return 0; fi
  if [ ! -e "$src" ]; then
    echo "bundle-dylibs: $src does not exist" >&2
    return 1
  fi
  echo "  $name  <-  $src"
  cp -L "$src" "$dst"
  chmod 644 "$dst"
  install_name_tool -id "@rpath/$name" "$dst"
  srcdir="$(cd "$(dirname "$src")" && pwd -P)"
  # a library lists its own id first, sometimes under another name (libSDL3.0 for libSDL3)
  self="$(otool -D "$src" | tail -n +2 | head -n 1)"
  otool -L "$src" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    if is_system "$dep"; then continue; fi
    depbase="$(basename "$dep")"
    if [ "$dep" = "$self" ] || [ "$depbase" = "$name" ] || [ "$depbase" = "$(basename "$src")" ]; then continue; fi
    deppath="$(resolve "$dep" "$srcdir")"
    install_name_tool -change "$dep" "@loader_path/$depbase" "$dst"
    bundle "$deppath" "$depbase"
  done
}

mkdir -p "$LIB"
echo "Bundling run-time libraries into $LIB"
for root in $ROOTS; do
  bundle "$BREW/lib/$root" "$root"
done

# Homebrew's SDL2 is now a thin layer over SDL3. It loads "libSDL3.dylib" by
# name when it starts, looking next to itself first, and if that fails it puts
# up an error window and aborts, which kills Wine's device service. otool does
# not list that kind of dependency, so add it by hand under that exact name.
if grep -aq 'libSDL3' "$BREW/lib/libSDL2-2.0.0.dylib"; then
  ROOTS="$ROOTS libSDL3.dylib"
  bundle "$BREW/lib/libSDL3.dylib" "libSDL3.dylib"
fi

# Changing install names invalidates any existing signature; sign ad hoc again.
bad=0
for f in "$LIB"/*.dylib; do
  codesign --force --sign - "$f" 2>/dev/null
  if otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -E "^($BREW|/opt/|/usr/local/)" ; then
    echo "bundle-dylibs: $f still refers to a build-machine path" >&2
    bad=1
  fi
done
for root in $ROOTS; do
  if [ ! -f "$LIB/$root" ]; then
    echo "bundle-dylibs: $root is missing from the bundle" >&2
    bad=1
  fi
done
ls -l "$LIB"/*.dylib
exit "$bad"
