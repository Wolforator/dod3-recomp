# Drakengard 3 Recompiled on iOS

An iPhone build of the port: the same lift and runtime as the Mac build, drawn
with Metal, as an unsigned `.ipa` to install through LiveContainer or a
sideloading tool. Nothing of the game is in the app. The player copies their
own installed game into the app's Documents folder.

Tested on: iPhone 17 Pro Max, iOS 27.2, through LiveContainer.

## Build the .ipa (on a Mac)

You need Xcode with its iOS SDK, CMake, Ninja, and the repository's `.venv`
from [docs/BUILDING.md](../../docs/BUILDING.md). You also need the lift
(`recompiled_101/`, `spu/`, `libsre`), which is the same as the Mac build's.

```sh
tools/ios/build_ios_deps.sh     # once: SDL2, glslang, SPIRV-Cross -> deps/ios-arm64
tools/ios/build_ios.sh          # configure into build-ios/, build, pack
# later builds:
ninja -C build-ios && tools/ios/package_ipa.sh
```

- **Output:** `out/ios/dod3-ios.ipa`.
- **`JOBS`** limits the parallel compile (default 2). Each lifted unit takes
  several GB of RAM at -O3.
- **Diagnostic build:** `tools/ios/package_ipa.sh --diag` writes
  `out/ios/dod3-ios-diag.ipa`. This is the same app with `defaults/diag.env`,
  which sets `RSX_PASS_PROF`, `RSX_WAIT_STATS` and `RSX_QUERY_ASYNC=alternate`
  over `dod3.ini`.
- **Signing:** the `.ipa` has an ad-hoc signature with
  `tools/ios/dod3.entitlements` (extended virtual addressing, increased memory
  limit). LiveContainer re-signs it.

## Put the game on the phone

1. Install the `.ipa` (LiveContainer: "+" → the .ipa) and start it once. It
   creates its Documents folder and shows the list of files it expects.
2. In the Files app, open the app's folder (On My iPhone → Drakengard 3, or
   LiveContainer's data folder for the app). Copy in these files from a desktop
   install. On a Mac, that is `~/Library/Application Support/Drakengard 3 Recompiled`.

   ```
   elf/EBOOT_101.ELF
   game/disc/PS3_GAME/
   game/disc/game/BLES00000/      the 1.01 update
   game/disc/game/NPUB31251/      DLC (optional)
   gamedata/                      saves (optional)
   ```

   AirDrop or a cable (Finder → the iPhone → Files) both work. The disc is
   several GB, so the cable is faster.
3. Tap "Check again", or start the app again.

**What the app keeps in that same folder:**

- `dod3.ini`: the settings. Most of them change in the in-game Settings pages.
  The phone's preset (60 fps cap, the screen's aspect, 1.25× resolution) is set
  once from `src/os/ios/preset.ini`.
- `touch_controls.ini`: the on-screen controls. Change them with the gear at
  the top of the screen. Delete the file to get the defaults back.
- `cache/`: the translated shaders and the list of pipelines. The app warms it
  up at launch, so a second launch compiles nothing in play.
- `dod3.log`: the log, and `dod3.prev.log` from the run before it. If something
  goes wrong, send these.

## Controls

- **On-screen pad:** left half is a floating stick. Swiping the right half
  turns the camera, and a double tap there is R3. There is a button diamond,
  R1 beside □, L1 above the stick, and an Intoner button (L3+R3).
- **The gear** opens the settings: opacity, size, camera speed, vibration on
  press, and the game's rumble. The layout editor is there too (drag to move,
  pinch to resize).
- **A real controller:** an MFi, DualSense or Xbox pad works through SDL, with
  its rumble. The on-screen pad hides while the controller is in use. Button
  prompts follow the input you used last.

## The phone's behaviour

- **Leaving the app pauses the game.** This includes the app switcher, a call
  and Siri. The sound and the game's clocks stop with it, and everything goes on
  where it was.
- **Taking the headphones off pauses the game** until you tap the screen.
  Connecting new headphones moves the sound to them.
- **Heat:** at thermal state "serious" the frame rate is held at 40 at most,
  and at "critical" at 30. The setting comes back at "fair" or "nominal". The
  log's `[thermal]` lines record each change.

## Carry the iOS changes to a newer dod3-recomp

The iOS work is not committed. After each stage, `tools/ios/save_patch.sh`
saves it as one patch: `out/patches/этапN.patch`.

- **Contents:** the diff of dod3-recomp and of its ps3recomp submodule against
  their checked-out commits (`ios-port` on both), new files included.
- **Cumulative:** the latest patch holds everything. Apply only that one.
- **Paths:** paths under `ps3recomp/` belong to the submodule. The rest belong
  to dod3-recomp.

```sh
# a fresh checkout of the newer version, with its submodule
git clone --recurse-submodules <dod3-recomp> dod3-new && cd dod3-new
git switch -c ios-port && git -C ps3recomp switch -c ios-port

# see whether it applies, then apply (a 3-way apply: moved code still goes in,
# a real clash is left as a conflict in place for you to resolve)
CHECK=1 /path/to/old/tools/ios/apply_patch.sh /path/to/out/patches/этап8.patch .
/path/to/old/tools/ios/apply_patch.sh /path/to/out/patches/этап8.patch .
git status; git -C ps3recomp status     # resolve anything marked "both modified"
```

Then rebuild everything that depends on the code:

1. Rebuild the lift if the newer version changed it (docs/BUILDING.md).
2. `tools/ios/build_ios.sh` (delete `build-ios/` first if CMake complains).
3. Check the Mac build still works: `ninja -C build dod3`.

Everything iOS-specific is behind `TARGET_OS_IPHONE` or the `DOD3_IOS` CMake
branch. A conflict outside those places is usually a desktop change near ours.
Keep both sides.

**Where the iOS code lives:**

- `src/os/ios/`: the app, its Info.plist and the phone's preset.
- `src/input/touch_pad.*`: the touch controls' model.
- `src/os/ios/touch_ios.mm`: their view.
- `tools/ios/`: these scripts.
- Small, flagged changes in `src/main.cpp`, the Metal backend
  (`ps3recomp/libs/video/rsx_metal_backend.m`), cellPad and cellAudio.

**Never commit the game's files, the ELF, the lifted code or any keys.**
`package_ipa.sh` refuses to pack an ELF or EBOOT.
