// Stage 1 memory test for the iOS port (tools/ios/memtest).
//
// Repeats what the port needs from the host before anything else is worth
// building:
//   1. the guest arena exactly as src/main.cpp's alloc_guest_vm() maps it:
//      mmap(nullptr, 0xE0000000, RW, PRIVATE|ANON|NORESERVE);
//   2. pages touched across the whole 3.5 GB (lazy backing must work);
//   3. the texture write-watch's pattern (ps3recomp vm_watch.c): a page made
//      read-only, a store to it caught as SIGBUS/SIGSEGV, the page reopened in
//      the handler and the store retried;
//   4. how much larger a reservation would still fit (headroom);
//   5. on request, committing real memory in 256 MB steps, to find the jetsam
//      limit. Progress goes to Documents/memtest.log before each step, so a
//      kill still leaves the last good figure for the next launch to show.
#import <UIKit/UIKit.h>
#include <sys/mman.h>
#include <signal.h>
#include <setjmp.h>
#include <unistd.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <sys/sysctl.h>

#define GUEST_SIZE 0xE0000000ull

static void* g_arena;   // kept mapped after tests 1-4 for test 5

static NSMutableString* g_out;
static void say(NSString* fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void say(NSString* fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [g_out appendString:s];
    [g_out appendString:@"\n"];
    NSLog(@"[memtest] %@", s);
}

static NSString* docs_path(NSString* name)
{
    NSString* d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [d stringByAppendingPathComponent:name];
}

static uint64_t phys_footprint(void)
{
    task_vm_info_data_t vi; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) != KERN_SUCCESS) return 0;
    return vi.phys_footprint;
}

// --- 3: write-watch ---------------------------------------------------------
static volatile uint8_t* g_watch_page;
static volatile int g_watch_faults;
static size_t g_pg;

static void watch_handler(int sig, siginfo_t* si, void* uc)
{
    (void)uc;
    uintptr_t a = (uintptr_t)si->si_addr, p = (uintptr_t)g_watch_page;
    if (a >= p && a < p + g_pg) {
        g_watch_faults++;
        mprotect((void*)p, g_pg, PROT_READ | PROT_WRITE);   // reopen; the store retries
        return;
    }
    signal(sig, SIG_DFL);   // not ours: crash normally
}

// --- tests -------------------------------------------------------------------
static void run_tests(void)
{
    g_pg = (size_t)getpagesize();
    say(@"device: %@ iOS %@", [UIDevice currentDevice].model, [UIDevice currentDevice].systemVersion);
    uint64_t ram = 0; size_t rl = sizeof ram; sysctlbyname("hw.memsize", &ram, &rl, NULL, 0);
    say(@"RAM %.2f GB, page %zu, available to app %.0f MB, footprint %.0f MB",
        ram / 1073741824.0, g_pg, os_proc_available_memory() / 1048576.0, phys_footprint() / 1048576.0);
    say(@"bundle: %@", [NSBundle mainBundle].bundlePath);

    // 1
    void* m = mmap(NULL, GUEST_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (m == MAP_FAILED) {
        say(@"FAIL 1: mmap(0xE0000000) -> errno %d (%s)", errno, strerror(errno));
        // How much does fit? Halve down to find the largest.
        for (uint64_t sz = GUEST_SIZE / 2; sz >= (64ull << 20); sz /= 2) {
            void* t = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
            if (t != MAP_FAILED) { say(@"  largest that fits (power of two): %llu MB", sz >> 20); munmap(t, sz); break; }
        }
        return;
    }
    say(@"OK 1: mmap(0xE0000000) at %p .. %p", m, (uint8_t*)m + GUEST_SIZE);

    // 2: touch pages across the arena (the regions the title uses, and the ends)
    static const uint64_t offs[] = { 0x00010000, 0x00800000, 0x10000000, 0x20000000, 0x30000000,
                                     0x40000000, 0x80000000, 0xC0000000, 0xD0000000, GUEST_SIZE - 0x1000 };
    uint64_t before = phys_footprint();
    int bad = 0;
    for (size_t i = 0; i < sizeof offs / sizeof offs[0]; i++) {
        volatile uint32_t* p = (volatile uint32_t*)((uint8_t*)m + offs[i]);
        *p = 0xC0DE0000u + (uint32_t)i;
        if (*p != 0xC0DE0000u + (uint32_t)i) bad++;
    }
    // and 64 MB contiguous, as a level load would
    memset((uint8_t*)m + 0x30000000, 0x5A, 64u << 20);
    say(@"%@ 2: %zu scattered pages + 64 MB written, %d mismatches, footprint +%.0f MB",
        bad ? @"FAIL" : @"OK", sizeof offs / sizeof offs[0], bad, (phys_footprint() - before) / 1048576.0);
    madvise((uint8_t*)m + 0x30000000, 64u << 20, MADV_FREE);

    // 3: write-watch
    struct sigaction sa = {0}, old_segv, old_bus;
    sa.sa_sigaction = watch_handler; sa.sa_flags = SA_SIGINFO; sigemptyset(&sa.sa_mask);
    sigaction(SIGBUS, &sa, &old_bus); sigaction(SIGSEGV, &sa, &old_segv);
    g_watch_page = (uint8_t*)m + 0x40000000;
    g_watch_page[0] = 1;
    int prc = mprotect((void*)g_watch_page, g_pg, PROT_READ);
    g_watch_page[8] = 0x42;                       // faults, handler reopens, store retries
    g_watch_page[16] = 0x43;                      // no fault: already open
    sigaction(SIGBUS, &old_bus, NULL); sigaction(SIGSEGV, &old_segv, NULL);
    BOOL wok = prc == 0 && g_watch_faults == 1 && g_watch_page[8] == 0x42 && g_watch_page[16] == 0x43;
    say(@"%@ 3: mprotect=%d, faults caught %d (want 1), store landed %s",
        wok ? @"OK" : @"FAIL", prc, g_watch_faults, g_watch_page[8] == 0x42 ? "yes" : "no");

    // 4: headroom beyond the arena
    uint64_t extra = 0;
    for (uint64_t sz = 16ull << 30; sz >= (256ull << 20); sz /= 2) {
        void* t = mmap(NULL, sz, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
        if (t != MAP_FAILED) { extra = sz; munmap(t, sz); break; }
    }
    say(@"info 4: with the arena mapped, a further %llu MB reservation still fits", extra >> 20);
    say(@"footprint now %.0f MB, available %.0f MB", phys_footprint() / 1048576.0, os_proc_available_memory() / 1048576.0);
    // the arena stays mapped for test 5
    g_arena = m;
}

// 5: commit real memory until jetsam (or 6 GB)
static void commit_test(void (^progress)(NSString*))
{
    NSString* logp = docs_path(@"memtest.log");
    if (!g_arena) { progress(@"no arena"); return; }
    for (uint64_t mb = 256; mb <= 6144 && mb * 1048576ull <= GUEST_SIZE; mb += 256) {
        NSString* line = [NSString stringWithFormat:@"committing %llu MB (avail before %.0f MB)\n",
                          mb, os_proc_available_memory() / 1048576.0];
        [line writeToFile:logp atomically:YES encoding:NSUTF8StringEncoding error:nil];
        uint8_t* base = (uint8_t*)g_arena + (mb - 256) * 1048576ull;
        for (size_t o = 0; o < (256u << 20); o += g_pg) base[o] = (uint8_t)o | 1;
        NSString* ok = [NSString stringWithFormat:@"OK 5: %llu MB committed, footprint %.0f MB, avail %.0f MB\n",
                        mb, phys_footprint() / 1048576.0, os_proc_available_memory() / 1048576.0];
        [ok writeToFile:logp atomically:YES encoding:NSUTF8StringEncoding error:nil];
        progress(ok);
    }
    progress(@"5: reached the end without being killed");
}

// --- UI ----------------------------------------------------------------------
@interface VC : UIViewController
@property(nonatomic, strong) UITextView* text;
@end

@implementation VC
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:@"Test 5: commit memory until killed" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [b addTarget:self action:@selector(commit) forControlEvents:UIControlEventTouchUpInside];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    UITextView* t = [[UITextView alloc] init];
    t.editable = NO;
    t.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    t.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:b]; [self.view addSubview:t];
    UILayoutGuide* g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [b.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [b.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
        [t.topAnchor constraintEqualToAnchor:b.bottomAnchor constant:8],
        [t.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [t.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [t.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
    ]];
    self.text = t;

    g_out = [NSMutableString string];
    NSString* prev = [NSString stringWithContentsOfFile:docs_path(@"memtest.log") encoding:NSUTF8StringEncoding error:nil];
    if (prev.length) say(@"previous test 5 run, last line:\n  %@", prev);
    run_tests();
    [g_out writeToFile:docs_path(@"memtest_result.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    t.text = g_out;
}

- (void)commit
{
    __weak VC* w = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        commit_test(^(NSString* s) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [g_out appendString:s];
                w.text.text = g_out;
                [w.text scrollRangeToVisible:NSMakeRange(g_out.length, 0)];
            });
        });
    });
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation SceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)opts
{
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    self.window.rootViewController = [VC new];
    [self.window makeKeyAndVisible];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AppDelegate
- (UISceneConfiguration*)application:(UIApplication*)app configurationForConnectingSceneSession:(UISceneSession*)s
                             options:(UISceneConnectionOptions*)o
{
    UISceneConfiguration* c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = [SceneDelegate class];
    return c;
}
@end

int main(int argc, char* argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
