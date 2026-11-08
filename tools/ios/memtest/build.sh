#!/bin/sh
# Builds the stage-1 memory test as an unsigned-for-distribution .ipa
# (ad-hoc signature carrying the entitlements; LiveContainer re-signs it).
#   tools/ios/memtest/build.sh   ->  out/ios/DOD3MemTest.ipa
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
out="$root/out/ios/memtest"
app="$out/Payload/DOD3MemTest.app"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)

rm -rf "$out"; mkdir -p "$app"
xcrun --sdk iphoneos clang -target arm64-apple-ios17.0 -isysroot "$sdk" \
    -fobjc-arc -O2 -Wall -Wno-unused-parameter \
    -framework UIKit -framework Foundation \
    "$here/main.m" -o "$app/DOD3MemTest"
cp "$here/Info.plist" "$app/Info.plist"
plutil -convert binary1 "$app/Info.plist"
codesign --force --sign - --entitlements "$here/memtest.entitlements" --timestamp=none "$app"
(cd "$out" && rm -f ../DOD3MemTest.ipa && zip -qry ../DOD3MemTest.ipa Payload)
echo "$root/out/ios/DOD3MemTest.ipa"
