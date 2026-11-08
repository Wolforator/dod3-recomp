#!/bin/bash
# The libraries the iOS build links, built static for arm64 iPhoneOS.
# The iOS counterpart of tools/build_mac_deps.sh (same sources, same tags).
#
#   tools/ios/build_ios_deps.sh     -> deps/ios-arm64 (git-ignored, under deps/)
#
#   SDL2          pads and audio (static; on iOS an app may not ship a loose dylib)
#   glslang       HLSL -> SPIR-V for the Metal backend's shader translation,
#                 with SPIRV-Tools for its HLSL legalization passes (static)
#   SPIRV-Cross   SPIR-V -> MSL (static, C API)
#
# zlib is not built: the iOS SDK carries libz (usr/lib/libz.tbd), which CMake's
# FindZLIB finds in the sysroot.
#
# IPHONEOS_DEPLOYMENT_TARGET (default 17.0) is the oldest iOS the build runs on.
# JOBS (default 4) caps the parallel compile.
set -euo pipefail
cd "$(dirname "$0")/../.."

TARGET=${IPHONEOS_DEPLOYMENT_TARGET:-17.0}
JOBS=${JOBS:-4}
PREFIX=$PWD/deps/ios-arm64
SRC=$PWD/deps/src
SDL_TAG=release-2.32.10
KHR_TAG=vulkan-sdk-1.4.363.0      # glslang, SPIRV-Tools, SPIRV-Headers, SPIRV-Cross

fetch() {   # repo dir tag
    [ -d "$2/.git" ] || git clone -q --depth 1 --branch "$3" "https://github.com/$1.git" "$2"
}
mkdir -p "$SRC" "$PREFIX"
fetch libsdl-org/SDL               "$SRC/SDL2"                                            "$SDL_TAG"
fetch KhronosGroup/glslang         "$SRC/glslang"                                         "$KHR_TAG"
fetch KhronosGroup/SPIRV-Tools     "$SRC/glslang/External/spirv-tools"                    "$KHR_TAG"
fetch KhronosGroup/SPIRV-Headers   "$SRC/glslang/External/spirv-tools/external/spirv-headers" "$KHR_TAG"
fetch KhronosGroup/SPIRV-Cross     "$SRC/SPIRV-Cross"                                     "$KHR_TAG"

# CMake's own iOS platform support (CMAKE_SYSTEM_NAME=iOS), no toolchain file.
# Try-compiles build static libraries: an iOS executable would want signing.
common=(-G Ninja -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET" -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX"
        -DCMAKE_FIND_ROOT_PATH="$PREFIX" -DCMAKE_FIND_FRAMEWORK=LAST
        -DCMAKE_C_FLAGS="-ffile-prefix-map=$SRC=." -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$SRC=.")
build() {   # name source-dir cmake-args...
    local name=$1 src=$2; shift 2
    echo "== $name"
    cmake -S "$src" -B "$SRC/build-ios-$name" "${common[@]}" "$@" > "$SRC/build-ios-$name.log"
    cmake --build "$SRC/build-ios-$name" -j "$JOBS" >> "$SRC/build-ios-$name.log"
    cmake --install "$SRC/build-ios-$name" >> "$SRC/build-ios-$name.log"
}

build SDL2 "$SRC/SDL2" -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF -DSDL_TESTS=OFF
build glslang "$SRC/glslang" -DBUILD_SHARED_LIBS=OFF -DENABLE_OPT=ON -DGLSLANG_TESTS=OFF \
      -DENABLE_GLSLANG_BINARIES=OFF -DGLSLANG_ENABLE_INSTALL=ON -DSPIRV_SKIP_TESTS=ON \
      -DSPIRV_SKIP_EXECUTABLES=ON
build SPIRV-Cross "$SRC/SPIRV-Cross" -DSPIRV_CROSS_SHARED=OFF -DSPIRV_CROSS_STATIC=ON \
      -DSPIRV_CROSS_CLI=OFF -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_ENABLE_C_API=ON

echo "deps: $PREFIX (iOS $TARGET, arm64)"
