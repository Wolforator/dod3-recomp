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
# uncapped, the GPU's time per pass logged (RSX_PASS_PROF), 540p (RSX_SCALE 0.75),
# the own-target copies once a frame and per draw by turns, 10 s each
# (RSX_SNAP_REUSE=alternate: a before/after in the same scenes).
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
cp dod3.ini "$a/defaults/dod3.ini"
if [ -n "$DIAG" ]; then
    printf '%s\n' "# the diagnostic build's settings, over dod3.ini" \
        DOD3_FPS=uncapped RSX_SCALE=0.75 RSX_PASS_PROF=60 RSX_SNAP_REUSE=alternate > "$a/defaults/diag.env"
fi
# Refuse anything of the game's (the release scripts do the same).
if find "$a" \( -iname '*.ELF' -o -iname 'EBOOT*' -o -iname '*.prx' -o -iname '*.sprx' -o -iname '*.pkg' \) | grep -q .; then
    echo "package_ipa: game or firmware files in the app; refusing"; exit 1
fi
codesign --force --sign - --entitlements "$ROOT/tools/ios/dod3.entitlements" --timestamp=none "$a"
mkdir -p "$ROOT/out/ios"
(cd "$stage" && rm -f "$ROOT/out/ios/$NAME.ipa" && zip -qry "$ROOT/out/ios/$NAME.ipa" Payload)
echo "$ROOT/out/ios/$NAME.ipa ($(du -h "$ROOT/out/ios/$NAME.ipa" | cut -f1))"
