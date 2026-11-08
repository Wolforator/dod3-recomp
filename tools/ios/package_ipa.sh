#!/bin/bash
# Pack the iOS build's app as an unsigned .ipa (Payload/dod3.app, zipped).
# The app gets its default dod3.ini as defaults/dod3.ini (see
# src/os/ios/setup_ios.mm) and an ad-hoc signature carrying the entitlements
# in tools/ios/dod3.entitlements; LiveContainer (or a sideloading tool)
# re-signs it. Nothing of the game's goes in: the player copies the game into
# the app's Documents folder.
#
#   tools/ios/package_ipa.sh [build-ios]          ->  out/ios/dod3-ios.ipa
#   tools/ios/package_ipa.sh --diag [build-ios]   ->  out/ios/dod3-ios-diag.ipa
#
# --diag: the same app (bundle ID, Documents) with defaults/diag.env, which
# the app sets in the environment over dod3.ini (src/os/ios/setup_ios.mm):
# the phone's own settings (dod3.ini) with the GPU's time per pass
# (RSX_PASS_PROF) and the walker's waits for the GPU (RSX_WAIT_STATS) logged,
# the occlusion-query fence waited for and asynchronous by turns, 10 s each
# (RSX_QUERY_ASYNC=alternate).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
DIAG=
if [ "${1:-}" = --diag ]; then DIAG=1; shift; fi
B=${1:-build-ios}
NAME=dod3-ios${DIAG:+-diag}
app="$B/dod3.app"
[ -x "$app/dod3" ] || { echo "no $app/dod3: build first (tools/ios/build_ios.sh)"; exit 1; }

stage="$ROOT/out/ios/ipa"
rm -rf "$stage"; mkdir -p "$stage/Payload"
cp -R "$app" "$stage/Payload/"
a="$stage/Payload/dod3.app"
mkdir -p "$a/defaults"
# The phone's preset (src/os/ios/preset.ini) set in the default dod3.ini (a new
# install's), and on its own for an install whose dod3.ini predates it
# (src/os/ios/setup_ios.mm sets it there once).
awk -v preset=src/os/ios/preset.ini -f tools/ios/apply_preset.awk dod3.ini > "$a/defaults/dod3.ini"
cp src/os/ios/preset.ini "$a/defaults/preset.ini"
if [ -n "$DIAG" ]; then
    printf '%s\n' "# the diagnostic build's settings, over dod3.ini" \
        RSX_PASS_PROF=60 RSX_WAIT_STATS=1 RSX_QUERY_ASYNC=alternate > "$a/defaults/diag.env"
fi
# Refuse anything of the game's (the release scripts do the same).
if find "$a" \( -iname '*.ELF' -o -iname 'EBOOT*' -o -iname '*.prx' -o -iname '*.sprx' -o -iname '*.pkg' \) | grep -q .; then
    echo "package_ipa: game or firmware files in the app; refusing"; exit 1
fi
codesign --force --sign - --entitlements "$ROOT/tools/ios/dod3.entitlements" --timestamp=none "$a"
mkdir -p "$ROOT/out/ios"
(cd "$stage" && rm -f "$ROOT/out/ios/$NAME.ipa" && zip -qry "$ROOT/out/ios/$NAME.ipa" Payload)
echo "$ROOT/out/ios/$NAME.ipa ($(du -h "$ROOT/out/ios/$NAME.ipa" | cut -f1))"
