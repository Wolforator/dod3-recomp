/*
 * The platform layer, iOS: the counterpart of os/macos/setup_mac.mm, with the
 * same four entry points main.cpp's Apple branches call (so main.cpp keeps a
 * single Apple path; the "mac" in their names is historical).
 *
 * The data folder is the app's Documents folder. Info.plist sets
 * UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace, so it shows in
 * the Files app, which is how the player copies an installed game in
 * (game/, elf/EBOOT_101.ELF, gamedata/ from a desktop install). There is no
 * installer or launcher on iOS.
 *
 * The app's default dod3.ini ships as defaults/dod3.ini, not beside the
 * executable: main.cpp reads a dod3.ini beside the executable before the
 * data folder's, and an iOS bundle is flat.
 */
#include "install/install.h"

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string>
#include <thread>
#include <unistd.h>

/* The data folder: the app's Documents (created by the system). */
extern "C" const char* dod3_mac_data_dir(void)
{
    static std::string dir;
    if (dir.empty()) {
        @autoreleasepool {
            NSURL* docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                               inDomains:NSUserDomainMask].firstObject;
            if (!docs) return NULL;
            dir = docs.fileSystemRepresentation;
        }
    }
    return dir.c_str();
}

/* The app bundle (shaders/override, the shipped shader cache, defaults/). */
extern "C" const char* dod3_mac_resources_dir(void)
{
    static std::string dir;
    if (dir.empty()) {
        @autoreleasepool {
            NSString* r = NSBundle.mainBundle.resourcePath;
            if (!r) return NULL;
            dir = r.fileSystemRepresentation;
        }
    }
    return dir.c_str();
}

/* The log goes to Documents/dod3.log (the current directory by now), the
 * run before kept as dod3.prev.log; flushed every 200 ms, as on the Mac. */
extern "C" void dod3_mac_log_to_file(void)
{
    rename("dod3.log", "dod3.prev.log");
    static char buf[1 << 20];
    if (FILE* f = fopen("dod3.log", "w")) fclose(f);
    if (freopen("dod3.log", "a", stderr)) setvbuf(stderr, buf, _IOFBF, sizeof buf);
    freopen("dod3.log", "a", stdout);
    std::thread([] {
        pthread_setname_np("log flush");
        for (;;) { usleep(200 * 1000); fflush(stderr); fflush(stdout); }
    }).detach();
}

/* 0 to start the game: its files are in place under base_dir. Seeds the
 * player's dod3.ini from the app's default first. Nonzero (and a line in the
 * log saying what is missing) when the game is not there yet; the app's
 * screen that explains what to copy where is the UI layer's (src/os/ios). */
extern "C" int dod3_setup_mac(const char* base_dir, int force)
{
    (void)force;   /* no installer to force on iOS */
    using namespace dod3setup;
    const fs::path base(base_dir);
    @autoreleasepool {
        std::error_code ec;
        if (!fs::exists(base / "dod3.ini", ec)) {
            NSString* def = [NSBundle.mainBundle pathForResource:@"dod3" ofType:@"ini" inDirectory:@"defaults"];
            if (def) fs::copy_file(fs::path(def.fileSystemRepresentation), base / "dod3.ini", ec);
        }
        const Status st = installed(base);
        if (!st.ready()) {
            fprintf(stderr, "[ios] the game is not in %s yet (disc %d, EBOOT %d, update %d): "
                            "copy game/, elf/ and gamedata/ from an installed copy\n",
                    base_dir, (int)st.disc, (int)st.eboot, (int)st.update);
            return 1;
        }
    }
    return 0;
}
