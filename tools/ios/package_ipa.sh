#!/bin/bash
# Pack the iOS build's app as an unsigned .ipa (Payload/dod3.app, zipped).
# The app gets its default dod3.ini as defaults/dod3.ini (see
# src/os/ios/setup_ios.mm) and an ad-hoc signature carrying the entitlements
# in tools/ios/dod3.entitlements; LiveContainer (or a sideloading tool)
# re-signs it. Nothing of the game's goes in: the player copies the game into
# the app's Documents folder.
#
#   tools/ios/package_ipa.sh [build-ios]   ->  out/ios/dod3-ios.ipa
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
B=${1:-build-ios}
app="$B/dod3.app"
[ -x "$app/dod3" ] || { echo "no $app/dod3: build first (tools/ios/build_ios.sh)"; exit 1; }

stage="$ROOT/out/ios/ipa"
rm -rf "$stage"; mkdir -p "$stage/Payload"
cp -R "$app" "$stage/Payload/"
a="$stage/Payload/dod3.app"
mkdir -p "$a/defaults"
cp dod3.ini "$a/defaults/dod3.ini"
# Refuse anything of the game's (the release scripts do the same).
if find "$a" \( -iname '*.ELF' -o -iname 'EBOOT*' -o -iname '*.prx' -o -iname '*.sprx' -o -iname '*.pkg' \) | grep -q .; then
    echo "package_ipa: game or firmware files in the app; refusing"; exit 1
fi
codesign --force --sign - --entitlements "$ROOT/tools/ios/dod3.entitlements" --timestamp=none "$a"
mkdir -p "$ROOT/out/ios"
(cd "$stage" && rm -f "$ROOT/out/ios/dod3-ios.ipa" && zip -qry "$ROOT/out/ios/dod3-ios.ipa" Payload)
echo "$ROOT/out/ios/dod3-ios.ipa ($(du -h "$ROOT/out/ios/dod3-ios.ipa" | cut -f1))"
