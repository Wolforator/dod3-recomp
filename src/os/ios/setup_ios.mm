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
#include <pthread.h>
#include <stdio.h>
#include <string>
#include <thread>
#include <unistd.h>

extern "C" {
void rsx_metal_backend_ios_attach(void* layer);      /* ps3recomp: rsx_metal_backend.m */
void rsx_metal_backend_ios_set_active(int active);
void SDL_SetMainReady(void);                         /* SDL2: no SDL_main here */
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

/* ---- the app ---------------------------------------------------------------
 * UIApplicationMain owns the main thread (and drains the main queue, which
 * the renderer's init dispatch_syncs onto). The scene's one view is backed by
 * a CAMetalLayer the renderer draws into; full screen, landscape, no status
 * bar, the home indicator hidden and the screen kept on. Once the view is up
 * the game's main runs on a thread of its own -- after the check that the
 * game is in Documents, else a screen that says what to copy where. */

static int (*s_game_main)(int, char**);
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
}
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
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
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
    [self.view layoutIfNeeded];
    rsx_metal_backend_ios_attach((__bridge void*)self.view.layer);
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
/* in front or not: the game's "window focus" (dod3.ini's unfocused setting) */
- (void)sceneDidBecomeActive:(UIScene*)scene { rsx_metal_backend_ios_set_active(1); }
- (void)sceneWillResignActive:(UIScene*)scene { rsx_metal_backend_ios_set_active(0); }
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
    SDL_SetMainReady();   /* the pad and audio init SDL subsystems; this is our main, not SDL's */
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([DOD3AppDelegate class]));
    }
}
