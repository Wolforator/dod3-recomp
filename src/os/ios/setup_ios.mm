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
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <string>
#include <algorithm>
#include <atomic>
#include <thread>
#include <vector>
#include <unistd.h>

extern "C" {
void rsx_metal_backend_ios_attach(void* layer);      /* ps3recomp: rsx_metal_backend.m */
void rsx_metal_backend_ios_set_active(int active);
void SDL_SetMainReady(void);                         /* SDL2: no SDL_main here */
int dod3_ios_paused(void);                           /* main.cpp: the frame clock has stopped */
void dod3_touch_install(void* view);                 /* touch_ios.mm */
void dod3_ios_thermal(int state);                    /* main.cpp: the frame-rate cap by the phone's heat */
extern volatile int g_audio_reopen;                  /* ps3recomp: cellAudio.c */
}

/* ---- why the game is held -------------------------------------------------
 * The game runs only while nothing holds it: the scene out of the front, the
 * touch controls' settings open, the audio session interrupted (a call, Siri,
 * an alarm), or a pause the player ends with a tap (the headphones taken off,
 * an interruption the system did not end with "resume"). Held, the frame
 * clock stops, and the sound and the guest's clocks with it (main.cpp,
 * unfocused_hold); let go, all go on where they were. Main thread. */
enum { kHoldScene = 1, kHoldSettings = 2, kHoldInterrupted = 4, kHoldTap = 8 };
static unsigned s_hold_bits;
static __weak UIView* s_game_view;
static UIView* s_tap_view;
static void tap_pause_show(const char* why);
extern "C" void dod3_ios_hold(unsigned bit, int on)
{
    const unsigned was = s_hold_bits;
    s_hold_bits = on ? (s_hold_bits | bit) : (s_hold_bits & ~bit);
    if (!was != !s_hold_bits) rsx_metal_backend_ios_set_active(s_hold_bits == 0);
}

/* The sound again after an interruption or a route change: the session
 * active, and the mixer's device reopened on it (it does so before it plays
 * on, so while held it waits for the hold to end). */
static void audio_back(const char* why)
{
    NSError* err = nil;
    const BOOL ok = [AVAudioSession.sharedInstance setActive:YES error:&err];
    g_audio_reopen = 1;
    fprintf(stderr, "[ios] audio: %s -- session active again%s%s\n", why, ok ? "" : ": ",
            ok ? "" : err.localizedDescription.UTF8String);
}

@interface DOD3TapToContinue : UIView
@end
@implementation DOD3TapToContinue
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    [self removeFromSuperview];
    s_tap_view = nil;
    audio_back("tap to continue");
    dod3_ios_hold(kHoldTap, 0);
    fprintf(stderr, "[ios] continued by a tap\n");
}
@end

static void tap_pause_show(const char* why)
{
    fprintf(stderr, "[ios] paused (%s): a tap continues\n", why);
    dod3_ios_hold(kHoldTap, 1);
    UIView* host = s_game_view;
    if (s_tap_view || !host) return;
    DOD3TapToContinue* v = [[DOD3TapToContinue alloc] initWithFrame:host.bounds];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    v.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    UILabel* l = [[UILabel alloc] initWithFrame:v.bounds];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    l.text = @"Paused\nTap to continue";
    l.numberOfLines = 2;
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont boldSystemFontOfSize:26];
    [v addSubview:l];
    [host addSubview:v];
    s_tap_view = v;
}

/* AVAudioSession: interruptions and route changes. */
static void audio_session_watch(void)
{
    NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* n) {
        const NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        if (type == AVAudioSessionInterruptionTypeBegan) {
            fprintf(stderr, "[ios] audio: interrupted (a call, Siri, an alarm...): paused\n");
            dod3_ios_hold(kHoldInterrupted, 1);
            return;
        }
        if (!(s_hold_bits & kHoldInterrupted)) return;
        const NSUInteger opt = [n.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        const bool resume = opt & AVAudioSessionInterruptionOptionShouldResume;
        audio_back(resume ? "the interruption ended" : "the interruption ended without \"resume\"");
        dod3_ios_hold(kHoldInterrupted, 0);
        if (!resume) tap_pause_show("an interruption the system did not resume");
    }];
    [nc addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* n) {
        const NSUInteger why = [n.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
        AVAudioSessionRouteDescription* r = AVAudioSession.sharedInstance.currentRoute;
        NSString* to = r.outputs.firstObject.portName ?: @"none";
        if (why == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
            /* headphones off: paused, as the system's own players do, so the
             * sound does not burst out of the speaker */
            fprintf(stderr, "[ios] audio: the output went away, now %s\n", to.UTF8String);
            g_audio_reopen = 1;
            if (s_game_view) tap_pause_show("the headphones went away");
        } else if (why == AVAudioSessionRouteChangeReasonNewDeviceAvailable) {
            fprintf(stderr, "[ios] audio: a new output, now %s: the sound moves to it\n", to.UTF8String);
            g_audio_reopen = 1;
        }
    }];
}

extern "C" {
}

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

/* The diagnostic build (tools/ios/package_ipa.sh --diag): the same app with
 * defaults/diag.env in the bundle, KEY=VALUE lines set in the environment
 * before the game's main, so they win over dod3.ini. What it set is said at
 * the top of the log. The everyday .ipa has no such file. */
static std::string s_diag_said;
#include <functional>
static std::function<void()> s_say_power_at_log;   /* dod3_ios_run's: once the log is open */

static void apply_diag_env(void)
{
    @autoreleasepool {
        NSString* p = [NSBundle.mainBundle pathForResource:@"diag" ofType:@"env" inDirectory:@"defaults"];
        if (!p) return;
        FILE* f = fopen(p.fileSystemRepresentation, "r");
        if (!f) return;
        char line[512];
        while (fgets(line, sizeof line, f)) {
            line[strcspn(line, "\r\n")] = 0;
            char* eq = strchr(line, '=');
            if (line[0] == '#' || !eq || eq == line) continue;
            *eq = 0;
            setenv(line, eq + 1, 1);
            s_diag_said += (s_diag_said.empty() ? "" : ", ") + std::string(line) + "=" + (eq + 1);
        }
        fclose(f);
    }
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
    if (!s_diag_said.empty())
        fprintf(stderr, "[ios] DIAGNOSTIC BUILD: set before dod3.ini, over it: %s\n", s_diag_said.c_str());
    if (s_say_power_at_log) s_say_power_at_log();
    std::thread([] {
        pthread_setname_np("log flush");
        for (;;) { usleep(200 * 1000); fflush(stderr); fflush(stdout); }
    }).detach();
}

/* The phone's preset (defaults/preset.ini, src/os/ios/preset.ini) set in a
 * dod3.ini made before it, once -- the preset's first line is its marker
 * ("# ios preset <n>"): each of its keys set where the file sets it, the rest
 * added at the end with the preset's comments, as tools/ios/apply_preset.awk
 * does for a new install's. After that the Settings menu's changes stay. */
static void apply_preset(const dod3setup::fs::path& ini)
{
    NSString* pp = [NSBundle.mainBundle pathForResource:@"preset" ofType:@"ini" inDirectory:@"defaults"];
    if (!pp) return;
    auto lines = [](const char* path) {
        std::vector<std::string> v;
        if (FILE* f = fopen(path, "r")) {
            char b[1024];
            while (fgets(b, sizeof b, f)) { std::string l(b); while (!l.empty() && (l.back() == '\n' || l.back() == '\r')) l.pop_back(); v.push_back(l); }
            fclose(f);
        }
        return v;
    };
    const std::vector<std::string> preset = lines(pp.fileSystemRepresentation), have = lines(ini.c_str());
    if (preset.empty() || have.empty()) return;
    for (const std::string& l : have) if (l == preset[0]) return;   /* set before */
    auto key_of = [](const std::string& l) -> std::string {
        size_t a = l.find_first_not_of(" \t");
        if (a == std::string::npos || l[a] == '#' || l[a] == ';') return "";
        size_t eq = l.find('=', a);
        if (eq == std::string::npos || eq == a) return "";
        size_t e = l.find_last_not_of(" \t", eq - 1);
        return e == std::string::npos || e < a ? "" : l.substr(a, e - a + 1);
    };
    std::vector<std::string> out;
    std::vector<std::string> done;
    int keys = 0;
    for (const std::string& l : have) {
        const std::string k = key_of(l);
        const std::string* repl = nullptr;
        if (!k.empty()) for (const std::string& p : preset) if (key_of(p) == k) repl = &p;
        if (!repl) { out.push_back(l); continue; }
        if (std::find(done.begin(), done.end(), k) != done.end()) continue;   /* a second line of it */
        out.push_back(*repl);
        done.push_back(k);
        keys++;
    }
    out.push_back("");
    for (const std::string& p : preset) {
        const std::string k = key_of(p);
        if (!k.empty() && std::find(done.begin(), done.end(), k) != done.end()) continue;
        out.push_back(p);
        keys += !k.empty();
    }
    const std::string tmp = ini.string() + ".new";
    if (FILE* f = fopen(tmp.c_str(), "w")) {
        for (const std::string& l : out) { fputs(l.c_str(), f); fputc('\n', f); }
        fclose(f);
        if (rename(tmp.c_str(), ini.c_str()) == 0)
            fprintf(stderr, "[ios] the phone's preset set in %s (%d setting%s)\n", ini.c_str(), keys, keys == 1 ? "" : "s");
    }
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
        } else {
            apply_preset(base / "dod3.ini");
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

/* ---- the app ---------------------------------------------------------------
 * UIApplicationMain owns the main thread (and drains the main queue, which
 * the renderer's init dispatch_syncs onto). The scene's one view is backed by
 * a CAMetalLayer the renderer draws into; full screen, landscape, no status
 * bar, the home indicator hidden and the screen kept on. Once the view is up
 * the game's main runs on a thread of its own -- after the check that the
 * game is in Documents, else a screen that says what to copy where. */

static int (*s_game_main)(int, char**);
static std::atomic<bool> s_game_running;   /* the game's thread is started */
static int s_argc;
static char** s_argv;

/* Is the game in place? The same check dod3_setup_mac makes, without its
 * side effects on the log. */
static bool game_ready(void)
{
    const char* d = dod3_mac_data_dir();
    if (!d) return false;
    return dod3setup::installed(dod3setup::fs::path(d)).ready();
}

@interface DOD3MetalView : UIView
@end
@implementation DOD3MetalView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (void)layoutSubviews
{
    [super layoutSubviews];
    /* every pixel of the screen: the renderer letterboxes the 16:9 picture */
    const CGFloat sc = self.window.screen.nativeScale ?: UIScreen.mainScreen.nativeScale;
    self.contentScaleFactor = sc;
    CAMetalLayer* l = (CAMetalLayer*)self.layer;
    l.drawableSize = CGSizeMake(self.bounds.size.width * sc, self.bounds.size.height * sc);
}
@end

@interface DOD3ViewController : UIViewController
@end
@implementation DOD3ViewController {
    UIView* _help;
    BOOL _started;
    CADisplayLink* _hz;   /* keeps a ProMotion screen at 120 Hz while the game runs */
}
/* The display link does nothing but ask for the refresh rate. Without it iOS
 * runs a CAMetalLayer that presents on its own at what it judges enough --
 * 60 Hz -- and 40 fps (a frame up 25 ms) then waits for the second 60 Hz
 * refresh: 30 fps. At 120 Hz 40 is every third refresh, 60 every second. */
- (void)tick:(CADisplayLink*)link { (void)link; }
- (void)loadView
{
    DOD3MetalView* v = [[DOD3MetalView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    v.backgroundColor = UIColor.blackColor;
    v.opaque = YES;
    ((CAMetalLayer*)v.layer).opaque = YES;
    self.view = v;
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
/* Not the bottom: the swipe home stays the system's at the first try (the
 * controls keep out of its strip, touch_ios.mm). The top's pull-down waits
 * for a second swipe -- START and SELECT are up there. */
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeTop | UIRectEdgeLeft | UIRectEdgeRight; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self startOrExplain];
}
- (void)startOrExplain
{
    if (_started) return;
    if (!game_ready()) { [self showHelp]; return; }
    [_help removeFromSuperview];
    _help = nil;
    _started = YES;
    s_game_running = true;
    [self.view layoutIfNeeded];
    s_game_view = self.view;
    rsx_metal_backend_ios_attach((__bridge void*)self.view.layer);
    dod3_touch_install((__bridge void*)self.view);   /* the on-screen controls, over it */
    if (@available(iOS 15.0, *)) {
        _hz = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        _hz.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
        [_hz addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setstacksize(&a, 16u << 20);   /* the frame clock runs guest vblank handlers */
    pthread_attr_set_qos_class_np(&a, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_t t;
    pthread_create(&t, &a, [](void*) -> void* {
        pthread_setname_np("dod3 main");
        const int rc = s_game_main(s_argc, s_argv);
        /* the game ended before its window did: it could not start */
        fprintf(stderr, "[ios] the game's main returned %d\n", rc);
        fflush(stderr);
        exit(rc);
    }, NULL);
    pthread_attr_destroy(&a);
}
- (void)showHelp
{
    if (_help) return;
    const char* d = dod3_mac_data_dir();
    NSString* path = d ? @(d) : @"(Documents)";
    UIScrollView* sv = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UILabel* l = [[UILabel alloc] init];
    l.numberOfLines = 0;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:15];
    l.text = [NSString stringWithFormat:
        @"Drakengard 3 Recompiled\n\n"
         "The game is not in this app's Documents folder yet. From a desktop install "
         "(~/Library/Application Support/Drakengard 3 Recompiled on a Mac), copy in with the Files app:\n\n"
         "  elf/EBOOT_101.ELF\n"
         "  game/disc/PS3_GAME/\n"
         "  game/disc/game/BLES00000/   (the 1.01 update)\n"
         "  game/disc/game/NPUB31251/   (DLC, optional)\n"
         "  gamedata/   (saves, optional)\n\n"
         "The folder (the app's Documents):\n%@\n\n"
         "The log is dod3.log there.", path];
    UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:@"Check again" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [b addTarget:self action:@selector(startOrExplain) forControlEvents:UIControlEventTouchUpInside];
    UIStackView* st = [[UIStackView alloc] initWithArrangedSubviews:@[ l, b ]];
    st.axis = UILayoutConstraintAxisVertical;
    st.alignment = UIStackViewAlignmentLeading;
    st.spacing = 16;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [sv addSubview:st];
    /* in the view first: the constraints below tie the stack to the view's
     * safe area, and need the two in one hierarchy when activated */
    [self.view addSubview:sv];
    UILayoutGuide* g = sv.contentLayoutGuide;
    UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [st.topAnchor constraintEqualToAnchor:g.topAnchor constant:24],
        [st.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-24],
        [st.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [st.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
    ]];
    _help = sv;
}
@end

@interface DOD3SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(strong, nonatomic) UIWindow* window;
@end
@implementation DOD3SceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)opts
{
    UIWindow* w = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    w.rootViewController = [[DOD3ViewController alloc] init];
    w.backgroundColor = UIColor.blackColor;
    [w makeKeyAndVisible];
    self.window = w;
    UIApplication.sharedApplication.idleTimerDisabled = YES;   /* no auto-lock in play */
}
/* In front or not: the game's "window focus". Out of it the game pauses --
 * the frame clock, the guest's clock, the renderer and the sound (main.cpp,
 * unfocused_hold) -- and goes on where it was when it is back. */
- (void)sceneDidBecomeActive:(UIScene*)scene
{
    if (s_hold_bits & kHoldInterrupted) {
        /* back in front with no "interruption ended" from the system (a call
         * taken, the app left meanwhile): the sound back, the player's tap
         * to go on */
        audio_back("back in front after an interruption");
        dod3_ios_hold(kHoldInterrupted, 0);
        tap_pause_show("back after an interruption");
    }
    dod3_ios_hold(kHoldScene, 0);
}
- (void)sceneWillResignActive:(UIScene*)scene { dod3_ios_hold(kHoldScene, 1); }
/* Into the background: not before the pause has taken hold, so no frame is
 * sent to the GPU from there. The frame clock looks 20 times a second; a
 * second at most, then iOS's own deadline is the limit. */
- (void)sceneDidEnterBackground:(UIScene*)scene
{
    dod3_ios_hold(kHoldScene, 1);
    if (!s_game_running) return;
    for (int i = 0; i < 100 && !dod3_ios_paused(); i++) usleep(10 * 1000);
    fprintf(stderr, "[ios] in the background: %s\n", dod3_ios_paused() ? "paused" : "not paused after 1 s");
    fflush(stderr);
}
@end

@interface DOD3AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation DOD3AppDelegate
- (UISceneConfiguration*)application:(UIApplication*)app
    configurationForConnectingSceneSession:(UISceneSession*)session
                                   options:(UISceneConnectionOptions*)opts
{
    UISceneConfiguration* c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    c.delegateClass = [DOD3SceneDelegate class];
    return c;
}
@end

/* main.cpp's main on iOS: the app, which runs game_main once its view is up. */
extern "C" int dod3_ios_run(int argc, char** argv, int (*game_main)(int, char**))
{
    s_game_main = game_main;
    /* the game sees no arguments -- the release layout -- whatever a loader
     * (LiveContainer) passes the app */
    static char* game_argv[2] = { argc > 0 ? argv[0] : (char*)"dod3", NULL };
    s_argc = 1;
    s_argv = game_argv;
    apply_diag_env();     /* the diagnostic build only: before anything reads dod3.ini */
    SDL_SetMainReady();   /* the pad and audio init SDL subsystems; this is our main, not SDL's */
    /* The device's heat and Low Power Mode in the log, at the start and as
     * they change: a GPU that takes twice as long in the same scene is the
     * first thing they explain (iOS lowers the clocks from "serious" on). */
    static const char* const kThermal[] = { "nominal", "fair", "serious", "critical" };
    auto say_power = [](const char* why) {
        NSProcessInfo* pi = NSProcessInfo.processInfo;
        const long t = (long)pi.thermalState;
        fprintf(stderr, "[ios] %s: thermal state %s, Low Power Mode %s\n", why,
                t >= 0 && t < 4 ? kThermal[t] : "?", pi.lowPowerModeEnabled ? "on" : "off");
        dod3_ios_thermal((int)t);   /* the frame clock logs and applies the cap */
    };
    for (NSNotificationName n in @[ NSProcessInfoThermalStateDidChangeNotification,
                                    NSProcessInfoPowerStateDidChangeNotification ])
        [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:nil
                                                    usingBlock:^(NSNotification*) { say_power("now"); }];
    s_say_power_at_log = [=] { say_power("at the start"); };
    audio_session_watch();
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([DOD3AppDelegate class]));
    }
}
