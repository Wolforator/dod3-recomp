/*
 * The on-screen controls (iOS): a transparent UIKit view over the game's
 * Metal view -- nothing of them is drawn into the game's frame -- with the
 * model behind them in src/input/touch_pad.cpp (the layout, what each finger
 * does).
 *
 * Into the pad: cellPad_set_host_input, the hook the desktop's keyboard and
 * mouse use (src/input/kbm.cpp; on iOS there is no keyboard, so the hook is
 * the touch screen's). cellPad asks it at every sweep of the host's pads
 * (every 4 ms at most, when the game reads the pad) and merges what it says
 * with a real pad on port 0: buttons together, a stick off its centre over
 * the pad's. The touches write their state at once, on the main thread, as
 * they arrive; the sweep only reads it -- no frame in between.
 *
 * While a finger is on the screen the hook says it is in use, and cellPad
 * then reports port 0 as no pad of a known family (cellPad_host_kind), so
 * the button prompts are the PS3's (src/patches/prompts.cpp). A real pad
 * used after that turns them to its own, and the controls hide; they come
 * back when it is disconnected or the screen is touched.
 *
 * The controls keep inside the safe area (the Dynamic Island's side, the
 * home indicator's strip), and the bottom edge is left to the system's
 * swipe home (setup_ios.mm).
 *
 * The gear at the top opens the settings: opacity, size, the camera swipe's
 * speed, vibration on a press, and the layout editor (drag a button; a
 * second finger anywhere pinches its size; Reset for the defaults). The game
 * is paused meanwhile. Saved to Documents/touch_controls.ini.
 *
 *   DOD3_TOUCH=0               no on-screen controls
 *   DOD3_TOUCH_CAMERA=stick    the swipe is always the right stick (by its
 *                              speed), never the camera bridge's direct turn
 *   DOD3_TOUCH_LOG=1           a line for each finger's job and release
 */
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>
#include <stdlib.h>
#include <string>
#include "input/camera.h"
#include "input/touch_pad.h"

extern "C" {
/* ps3recomp/libs/input/cellPad.h */
typedef struct CellPadHostInput {
    uint16_t buttons;
    uint8_t lx, ly, rx, ry;
    uint8_t l2, r2;
} CellPadHostInput;
typedef int (*cellPad_host_input_fn)(void* user, int focused, CellPadHostInput* out);
void cellPad_set_host_input(cellPad_host_input_fn fn, void* user);
int cellPad_host_kind(uint32_t port);
void rsx_metal_backend_ios_set_active(int active);
const char* dod3_mac_data_dir(void);   /* setup_ios.mm */
}

using touchpad::Pad;

static Pad s_pad;
static bool s_log;

static double now_s(void) { return CACurrentMediaTime(); }

static std::string settings_path(void)
{
    const char* d = dod3_mac_data_dir();
    return std::string(d ? d : ".") + "/touch_controls.ini";
}

static int touch_host_input(void* user, int focused, CellPadHostInput* in)
{
    (void)user; (void)focused;
    const touchpad::Out o = s_pad.out(now_s());
    in->buttons = o.buttons;
    in->lx = o.lx; in->ly = o.ly; in->rx = o.rx; in->ry = o.ry;
    in->l2 = (o.buttons & (1 << 8)) ? 255 : 0;
    in->r2 = (o.buttons & (1 << 9)) ? 255 : 0;
    return o.active;
}

/* ---- the view ---- */

@interface DOD3TouchView : UIView
- (void)refresh;
@end

@interface DOD3TouchSettings : UIView
@property(weak, nonatomic) DOD3TouchView* owner;
@end

@implementation DOD3TouchView {
    CAShapeLayer* _ring[touchpad::kButtons];
    CATextLayer* _text[touchpad::kButtons];
    CAShapeLayer* _stickBase;
    CAShapeLayer* _stickKnob;
    UIImpactFeedbackGenerator* _haptic;
    NSTimer* _watch;
    BOOL _shown;
    DOD3TouchSettings* _settings;
    UIView* _editBar;
}

- (instancetype)initWithFrame:(CGRect)f
{
    if (!(self = [super initWithFrame:f])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.multipleTouchEnabled = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    for (int b = 0; b < touchpad::kButtons; b++) {
        CAShapeLayer* r = [CAShapeLayer layer];
        r.lineWidth = 2;
        [self.layer addSublayer:r];
        _ring[b] = r;
        CATextLayer* t = [CATextLayer layer];
        t.string = @(Pad::label(b));
        t.alignmentMode = kCAAlignmentCenter;
        t.contentsScale = UIScreen.mainScreen.scale;
        t.foregroundColor = UIColor.whiteColor.CGColor;
        [self.layer addSublayer:t];
        _text[b] = t;
    }
    _stickBase = [CAShapeLayer layer];
    _stickBase.lineWidth = 2;
    _stickKnob = [CAShapeLayer layer];
    [self.layer addSublayer:_stickBase];
    [self.layer addSublayer:_stickKnob];
    _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    _shown = YES;
    /* a real pad in use hides the controls; ten looks a second */
    __weak DOD3TouchView* weak = self;
    _watch = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer*) { [weak watchPad]; }];
    return self;
}

- (void)watchPad
{
    const bool pad = cellPad_host_kind(0) != 0;   /* CELL_PAD_HOST_NONE: the touch screen, or nothing */
    const BOOL want = !pad || s_pad.editing || _settings != nil;
    if (want == _shown) return;
    _shown = want;
    if (s_log) fprintf(stderr, "[touch] controls %s\n", want ? "shown" : "hidden (a pad is in use)");
    [self refresh];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    const CGRect b = self.bounds;
    const UIEdgeInsets in = self.safeAreaInsets;
    /* a little air inside the safe area */
    const float m = 6;
    s_pad.set_area(b.size.width, b.size.height,
                   touchpad::Rect{ (float)(in.left + m), (float)(in.top + m),
                                   (float)(b.size.width - in.left - in.right - 2 * m),
                                   (float)(b.size.height - in.top - in.bottom - 2 * m) });
    [self refresh];
}

- (void)refresh
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    const float op = s_pad.cfg.opacity;
    for (int b = 0; b < touchpad::kButtons; b++) {
        const CGFloat x = s_pad.bx(b), y = s_pad.by(b), r = s_pad.br(b);
        const bool held = s_pad.held(b);
        const bool sel = s_pad.editing && s_pad.edit_selected == b;
        _ring[b].path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(x - r, y - r, 2 * r, 2 * r)].CGPath;
        _ring[b].fillColor = [UIColor colorWithWhite:held ? 0.85 : 0.1 alpha:(held ? 0.55 : 0.30) * op / 0.45].CGColor;
        _ring[b].strokeColor = sel ? UIColor.systemYellowColor.CGColor
                                   : [UIColor colorWithWhite:1 alpha:MIN(1.0, op * 1.6)].CGColor;
        const CGFloat fs = b <= touchpad::kCircle || b == touchpad::kUp || b == touchpad::kDown || b == touchpad::kMenu
                               ? r * 0.95 : (b == touchpad::kIntoner || b == touchpad::kStart || b == touchpad::kSelect ? r * 0.42 : r * 0.62);
        _text[b].fontSize = fs;
        _text[b].frame = CGRectMake(x - r, y - fs * 0.62, 2 * r, fs * 1.3);
        _text[b].opacity = _shown ? MIN(1.0f, op * 2.0f) : 0;
        _ring[b].opacity = _shown ? 1 : 0;
    }
    float bx, by, kx, ky, r;
    if (!s_pad.editing && s_pad.stick_shown(&bx, &by, &kx, &ky, &r)) {
        _stickBase.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(bx - r, by - r, 2 * r, 2 * r)].CGPath;
        _stickBase.fillColor = [UIColor colorWithWhite:0.1 alpha:0.25 * op / 0.45].CGColor;
        _stickBase.strokeColor = [UIColor colorWithWhite:1 alpha:MIN(1.0, op * 1.6)].CGColor;
        const CGFloat kr = r * 0.45;
        _stickKnob.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(kx - kr, ky - kr, 2 * kr, 2 * kr)].CGPath;
        _stickKnob.fillColor = [UIColor colorWithWhite:0.9 alpha:0.5 * op / 0.45].CGColor;
        _stickBase.hidden = _stickKnob.hidden = NO;
    } else {
        _stickBase.hidden = _stickKnob.hidden = YES;
    }
    [CATransaction commit];
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    _shown = YES;   /* a touch brings them back (if hidden for a pad) */
    if (_settings) return;
    bool press = false;
    for (UITouch* t in touches) {
        const CGPoint p = [t locationInView:self];
        const int role = s_pad.began((uintptr_t)(__bridge void*)t, p.x, p.y, now_s());
        if (role >= 0 && role != touchpad::kMenu) press = true;
        if (s_log) fprintf(stderr, "[touch] down %.0f,%.0f: %s\n", p.x, p.y,
                           role >= 0 ? Pad::key(role) : role == touchpad::kStick ? "stick" : role == touchpad::kCamera ? "camera" : "-");
    }
    if (press && s_pad.cfg.haptics && !s_pad.editing) [_haptic impactOccurred];
    [self refresh];
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    const uint32_t before = [self heldMask];
    for (UITouch* t in touches) {
        const CGPoint p = [t locationInView:self];
        s_pad.moved((uintptr_t)(__bridge void*)t, p.x, p.y, now_s());
    }
    /* a slide onto another button is a press too */
    if (s_pad.cfg.haptics && !s_pad.editing && ([self heldMask] & ~before)) [_haptic impactOccurred];
    [self refresh];
}

- (uint32_t)heldMask
{
    uint32_t m = 0;
    for (int b = 0; b < touchpad::kButtons; b++) if (s_pad.held(b)) m |= 1u << b;
    return m;
}

- (void)lift:(NSSet<UITouch*>*)touches
{
    int menu = 0;
    for (UITouch* t in touches) {
        const int role = s_pad.ended((uintptr_t)(__bridge void*)t, now_s());
        if (role == touchpad::kMenu && !s_pad.editing) menu = 1;
    }
    if (s_pad.editing) s_pad.save(settings_path());
    [self refresh];
    if (menu) [self openSettings];
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { [self lift:touches]; }
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { [self lift:touches]; }

/* ---- the settings and the editor ---- */

- (void)openSettings
{
    if (_settings) return;
    s_pad.cancel_all();
    rsx_metal_backend_ios_set_active(0);   /* the game waits */
    DOD3TouchSettings* s = [[DOD3TouchSettings alloc] initWithFrame:self.bounds];
    s.owner = self;
    [self addSubview:s];
    _settings = s;
    [self refresh];
}

- (void)closeSettings
{
    [_settings removeFromSuperview];
    _settings = nil;
    s_pad.save(settings_path());
    if (!s_pad.editing) rsx_metal_backend_ios_set_active(1);
    [self refresh];
}

- (void)startEditing
{
    [_settings removeFromSuperview];
    _settings = nil;
    s_pad.editing = true;
    s_pad.edit_selected = touchpad::kNone;
    UIView* bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel* l = [[UILabel alloc] init];
    l.text = @"Drag to move, pinch to resize";
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:14];
    UIButton* reset = [self barButton:@"Reset" action:@selector(resetLayout)];
    UIButton* done = [self barButton:@"Done" action:@selector(stopEditing)];
    UIStackView* st = [[UIStackView alloc] initWithArrangedSubviews:@[ l, reset, done ]];
    st.spacing = 16;
    st.alignment = UIStackViewAlignmentCenter;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    bar.layer.cornerRadius = 10;
    [bar addSubview:st];
    [self addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [st.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:14],
        [st.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-14],
        [st.topAnchor constraintEqualToAnchor:bar.topAnchor constant:6],
        [st.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-6],
        [bar.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        /* bottom centre, between the thumbs' buttons, above the home strip */
        [bar.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-8],
    ]];
    _editBar = bar;
    [self refresh];
}

- (UIButton*)barButton:(NSString*)title action:(SEL)sel
{
    UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)resetLayout
{
    s_pad.cfg.reset_layout();
    s_pad.save(settings_path());
    [self refresh];
}

- (void)stopEditing
{
    [_editBar removeFromSuperview];
    _editBar = nil;
    s_pad.cancel_all();
    s_pad.editing = false;
    s_pad.edit_selected = touchpad::kNone;
    s_pad.save(settings_path());
    rsx_metal_backend_ios_set_active(1);
    [self refresh];
}
@end

@implementation DOD3TouchSettings {
    UILabel* _vals[3];
}

- (instancetype)initWithFrame:(CGRect)f
{
    if (!(self = [super initWithFrame:f])) return nil;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    UIView* panel = [[UIView alloc] init];
    panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    panel.layer.cornerRadius = 14;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel* title = [[UILabel alloc] init];
    title.text = @"Touch controls";
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = UIColor.whiteColor;
    UIStackView* st = [[UIStackView alloc] init];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 10;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [st addArrangedSubview:title];
    [st addArrangedSubview:[self slider:0 name:@"Opacity" min:0.1 max:1.0 value:s_pad.cfg.opacity]];
    [st addArrangedSubview:[self slider:1 name:@"Size" min:0.6 max:1.6 value:s_pad.cfg.size]];
    [st addArrangedSubview:[self slider:2 name:@"Camera sensitivity" min:0.3 max:3.0 value:s_pad.cfg.camera]];
    UISwitch* sw = [[UISwitch alloc] init];
    sw.on = s_pad.cfg.haptics;
    [sw addTarget:self action:@selector(haptics:) forControlEvents:UIControlEventValueChanged];
    [st addArrangedSubview:[self row:@"Vibration on press" control:sw value:nil]];
    UIStackView* buttons = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self button:@"Edit layout" action:@selector(edit)],
        [self button:@"Reset layout" action:@selector(reset)],
        [self button:@"Close" action:@selector(close)],
    ]];
    buttons.spacing = 22;
    buttons.distribution = UIStackViewDistributionEqualSpacing;
    [st addArrangedSubview:buttons];
    [panel addSubview:st];
    [self addSubview:panel];
    [NSLayoutConstraint activateConstraints:@[
        [st.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:20],
        [st.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-20],
        [st.topAnchor constraintEqualToAnchor:panel.topAnchor constant:14],
        [st.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-14],
        [panel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [panel.widthAnchor constraintEqualToConstant:440],
    ]];
    return self;
}

- (UIView*)row:(NSString*)name control:(UIView*)c value:(UILabel*)v
{
    UILabel* l = [[UILabel alloc] init];
    l.text = name;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:15];
    [l.widthAnchor constraintEqualToConstant:150].active = YES;
    NSMutableArray* views = [NSMutableArray arrayWithObjects:l, c, nil];
    if (v) [views addObject:v];
    UIStackView* r = [[UIStackView alloc] initWithArrangedSubviews:views];
    r.spacing = 10;
    r.alignment = UIStackViewAlignmentCenter;
    return r;
}

- (UIView*)slider:(int)k name:(NSString*)name min:(float)lo max:(float)hi value:(float)v
{
    UISlider* s = [[UISlider alloc] init];
    s.minimumValue = lo;
    s.maximumValue = hi;
    s.value = v;
    s.tag = k;
    [s addTarget:self action:@selector(slid:) forControlEvents:UIControlEventValueChanged];
    UILabel* val = [[UILabel alloc] init];
    val.textColor = UIColor.lightGrayColor;
    val.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    [val.widthAnchor constraintEqualToConstant:44].active = YES;
    val.text = [NSString stringWithFormat:@"%.2f", v];
    _vals[k] = val;
    return [self row:name control:s value:val];
}

- (UIButton*)button:(NSString*)title action:(SEL)sel
{
    UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)slid:(UISlider*)s
{
    const float v = s.value;
    if (s.tag == 0) s_pad.cfg.opacity = v;
    else if (s.tag == 1) s_pad.cfg.size = v;
    else s_pad.cfg.camera = v;
    _vals[s.tag].text = [NSString stringWithFormat:@"%.2f", v];
    [self.owner refresh];
}
- (void)haptics:(UISwitch*)sw { s_pad.cfg.haptics = sw.on; }
- (void)edit { [self.owner startEditing]; }
- (void)reset { s_pad.cfg.reset_layout(); [self.owner refresh]; }
- (void)close { [self.owner closeSettings]; }
@end

/* setup_ios.mm, once the game's view is up: the controls over it. */
extern "C" void dod3_touch_install(void* view)
{
    if (const char* e = getenv("DOD3_TOUCH"); e && !strcmp(e, "0")) {
        fprintf(stderr, "[touch] DOD3_TOUCH=0: no on-screen controls\n");
        return;
    }
    s_log = getenv("DOD3_TOUCH_LOG") != nullptr;
    const std::string path = settings_path();
    const bool loaded = s_pad.load(path);
    touchpad::g_camera_motion = dod3_camera_touch_motion;
    touchpad::g_camera_bridge_live = dod3_camera_bridge_live;
    cellPad_set_host_input(touch_host_input, nullptr);
    UIView* host = (__bridge UIView*)view;
    DOD3TouchView* v = [[DOD3TouchView alloc] initWithFrame:host.bounds];
    [host addSubview:v];
    fprintf(stderr, "[touch] on-screen controls: %s (opacity %.2f, size %.2f, camera %.2f, vibration %s)\n",
            loaded ? path.c_str() : "the default layout", s_pad.cfg.opacity, s_pad.cfg.size, s_pad.cfg.camera,
            s_pad.cfg.haptics ? "on" : "off");
}
