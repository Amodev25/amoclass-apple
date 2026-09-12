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

echo "── Mach-O binaries under $ROOT ──"
# The plugin lands either in the app binary or in its own framework depending
# on how CocoaPods linked it, so look at every binary in the bundle.
MACHO=$(find "$ROOT" -type f -exec sh -c 'file -b "$1" | grep -q Mach-O && echo "$1"' _ {} \;)

if [ -z "$MACHO" ]; then
  echo "no Mach-O binaries found — the check is wrong, not the build" >&2
  find "$ROOT" -maxdepth 4 | head -40 >&2
  exit 1
fi
printf '%s\n' "$MACHO" | sed 's|^|  |'

# Dump every symbol once; searching a variable beats re-running nm per symbol.
SYMS=$(printf '%s\n' "$MACHO" | while IFS= read -r f; do nm -a "$f" 2>/dev/null; done)

echo "── symbols containing 'amo' ──"
printf '%s\n' "$SYMS" | grep -i 'amo' | sort -u | head -30 | sed 's|^|  |'

echo "── required symbols ──"
rc=0
for sym in $REQUIRED_SYMBOLS; do
  if printf '%s\n' "$SYMS" | grep -q -- "$sym"; then
    echo "  ok       $sym"
  else
    echo "  MISSING  $sym" >&2
    rc=1
  fi
done

if [ "$rc" -ne 0 ]; then
  echo >&2
  echo "The C decryptor did not make it into the binary. Check that" >&2
  echo "amo_platform_apple.podspec still matches Classes/**/*.{h,m,c}." >&2
fi

exit "$rc"
