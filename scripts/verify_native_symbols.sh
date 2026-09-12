#!/usr/bin/env bash
#
# Prove the C decryptor is actually inside the built app.
#
# A green Xcode build is not enough. If the podspec's source glob ever stops
# matching the .c files, the app still links and installs, and the failure only
# shows up when a student presses play. This check fails the build instead.
#
# Usage: verify_native_symbols.sh <path to a directory containing the .app>

set -uo pipefail

ROOT="${1:?usage: verify_native_symbols.sh <build output dir>}"

REQUIRED_SYMBOLS="_amo_register_protocol _amo_open _amo_set_credentials"

if [ ! -d "$ROOT" ]; then
  echo "build output directory does not exist: $ROOT" >&2
  exit 1
fi

# The plugin lands either in the app binary or in its own framework depending
# on how CocoaPods linked it, so look at every binary in the bundle.
MACHO=$(find "$ROOT" -type f -exec sh -c 'file -b "$1" | grep -q Mach-O && echo "$1"' _ {} \;)

if [ -z "$MACHO" ]; then
  echo "no Mach-O binaries found — the check is wrong, not the build" >&2
  find "$ROOT" -maxdepth 4 | head -40 >&2
  exit 1
fi

echo "── binaries scanned: $(printf '%s\n' "$MACHO" | wc -l | tr -d ' ') ──"

# -gU is deliberate: global (exported) symbols that this binary DEFINES.
# Plain `nm -a` also emits debug stabs naming every source path, and since every
# path here contains "amoclass" that buries the real symbols in noise.
DEFINED=$(printf '%s\n' "$MACHO" | while IFS= read -r f; do
  nm -gU "$f" 2>/dev/null | sed "s|^|$(basename "$f") |"
done)

echo "── defined symbols starting with _amo ──"
FOUND=$(printf '%s\n' "$DEFINED" | grep -E ' _amo[a-z_]*$' | sort -u)
if [ -n "$FOUND" ]; then
  printf '%s\n' "$FOUND" | sed 's|^|  |'
else
  echo "  (none)"
fi

echo "── required symbols ──"
rc=0
for sym in $REQUIRED_SYMBOLS; do
  owner=$(printf '%s\n' "$DEFINED" | grep -E " ${sym}\$" | awk '{print $1}' | head -1)
  if [ -n "$owner" ]; then
    echo "  ok       $sym  (in $owner)"
  else
    echo "  MISSING  $sym" >&2
    rc=1
  fi
done

if [ "$rc" -ne 0 ]; then
  echo >&2
  echo "The C decryptor did not make it into the binary. Check that" >&2
  echo "amo_platform_apple.podspec still matches Classes/**/*.{h,m,c}, and that" >&2
  echo "the symbols are not being hidden by -fvisibility=hidden." >&2
fi

exit "$rc"
