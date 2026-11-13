#!/bin/bash
# Wine loads a few Homebrew libraries by bare name at run time (dlopen):
#   libfreetype (fonts), libgnutls (TLS and crypto), libSDL2 (controllers),
#   libMoltenVK (Vulkan).
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
ROOTS="libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib libMoltenVK.dylib"

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
  local src="$1" name="$2" dst="$LIB/$2" srcdir dep depbase deppath
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
  otool -L "$src" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    if is_system "$dep"; then continue; fi
    depbase="$(basename "$dep")"
    # the first entry of a dylib is its own id
    if [ "$depbase" = "$name" ] || [ "$depbase" = "$(basename "$src")" ]; then continue; fi
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
