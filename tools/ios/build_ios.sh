#!/bin/bash
# Configure and build the iOS app (arm64 iPhoneOS) into build-ios/, then pack
# it as an unsigned .ipa (tools/ios/package_ipa.sh).
#
#   tools/ios/build_ios_deps.sh      once: SDL2, glslang, SPIRV-Cross -> deps/ios-arm64
#   tools/ios/build_ios.sh           configure (first time) + build + .ipa
#   tools/ios/build_ios.sh build     build + .ipa only
#
# The lift (recompiled_101/, spu/) and libsre.prx are the same as the Mac's:
# docs/BUILDING.md. JOBS (default 2) caps the compile: each lifted unit takes
# several GB at -O3. IPHONEOS_DEPLOYMENT_TARGET defaults to 17.0.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
B=${BUILD_DIR:-build-ios}
DEPS=$ROOT/deps/ios-arm64
JOBS=${JOBS:-2}
TARGET=${IPHONEOS_DEPLOYMENT_TARGET:-17.0}

[ -f "$DEPS/lib/libSDL2.a" ] || { echo "no iOS deps in $DEPS: run tools/ios/build_ios_deps.sh"; exit 1; }
[ -x .venv/bin/python ] || { echo "no .venv (docs/BUILDING.md)"; exit 1; }

if [ "${1:-}" != build ] || [ ! -f "$B/build.ninja" ]; then
    # The deps' pkg-config files only, never the host's (Homebrew's are macOS builds).
    export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
    unset PKG_CONFIG_PATH
    cmake -S . -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET" \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_PREFIX_PATH="$DEPS" -DCMAKE_FIND_ROOT_PATH="$DEPS" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
        -DPython3_EXECUTABLE="$ROOT/.venv/bin/python" \
        -DSDL2_DIR="$DEPS/lib/cmake/SDL2" -Dglslang_DIR="$DEPS/lib/cmake/glslang" \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
fi
ninja -C "$B" -j "$JOBS"
"$ROOT/tools/ios/package_ipa.sh" "$B"
