/*
 * The touch screen as the pad: the model behind the on-screen controls.
 *
 * Every finger is given a job when it comes down and keeps it until it is
 * lifted, so any number of them work at once -- the stick, a held button and
 * the camera's swipe together (the dragon's flight: Square held to take
 * aim while the left stick steers). A finger that lands
 *
 *   on a button (its circle and a little around it) holds that button; one
 *     on Square, Triangle, Cross, Circle or R1 may slide to another of them;
 *   elsewhere in the left part of the screen is the left stick, centred
 *     where it landed (it follows a finger dragged past its rim);
 *   elsewhere in the right part is the camera: its motion turns the view as
 *     the mouse does on a desktop (src/input/camera.cpp) while the game's
 *     camera bridge is live, and is a right stick by its speed elsewhere
 *     (menus, cutscenes) or with DOD3_TOUCH_CAMERA=stick; a double tap
 *     there is R3 (the camera centred behind Zero).
 *
 * The Intoner button presses L3 and R3 together. The menu button (a gear)
 * presses nothing: the view opens the settings when it is let go.
 *
 * The view (src/os/ios/touch_ios.mm) feeds it touches on the main thread;
 * cellPad's sweep reads out() from its own, what it needs published in
 * atomics after every touch.
 *
 * Layout: each button's centre in fractions of the safe area (the screen
 * less the Dynamic Island's side and the home indicator's strip), its
 * radius a default in points times the global size and its own scale.
 * Saved in Documents/touch_controls.ini.
 */
#include "input/touch_pad.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <atomic>

namespace touchpad {

void (*g_camera_motion)(float, float);
bool (*g_camera_bridge_live)();

namespace {

/* CELL_PAD_CTRL_* (ps3recomp/libs/input/cellPad.h) */
enum : uint16_t {
    kSel = 1 << 0, kL3 = 1 << 1, kR3 = 1 << 2, kSta = 1 << 3, kUpM = 1 << 4, kDownM = 1 << 6,
    kL2M = 1 << 8, kR2M = 1 << 9, kL1M = 1 << 10, kR1M = 1 << 11,
    kTri = 1 << 12, kCir = 1 << 13, kCro = 1 << 14, kSqu = 1 << 15,
};

const struct Def {
    const char* key;
    const char* label;
    uint16_t mask;
    float x, y, r;   /* default centre (safe area, 0..1) and radius (points) */
} kDef[kButtons] = {
    /* the right thumb's diamond: Square the biggest, in the middle */
    { "square",   "\xE2\x96\xA1", kSqu, 0.795f, 0.600f, 40 },   /* light attack */
    { "triangle", "\xE2\x96\xB3", kTri, 0.795f, 0.375f, 29 },   /* heavy attack, above */
    { "cross",    "\xE2\x9C\x95", kCro, 0.795f, 0.825f, 29 },   /* jump, below */
    { "circle",   "\xE2\x97\x8B", kCir, 0.905f, 0.600f, 29 },   /* block / counter, right */
    { "r1",       "R1",           kR1M, 0.665f, 0.700f, 35 },   /* evade: left of Square, big */
    { "intoner",  "Intoner",      kL3 | kR3, 0.660f, 0.170f, 27 },   /* out of the diamond's way */
    { "r2",       "R2",           kR2M, 0.960f, 0.200f, 21 },   /* weapon swap, the right edge */
    /* the left thumb's */
    { "l1",       "L1",           kL1M, 0.175f, 0.330f, 34 },   /* lock on: above the stick */
    { "l2",       "L2",           kL2M, 0.030f, 0.200f, 21 },   /* weapon swap, the left edge */
    { "up",       "\xE2\x96\xB2", kUpM, 0.030f, 0.440f, 20 },   /* combo list */
    { "down",     "\xE2\x96\xBC", kDownM, 0.030f, 0.610f, 20 }, /* items */
    /* top centre */
    { "start",    "START",        kSta, 0.570f, 0.055f, 19 },
    { "select",   "SELECT",       kSel, 0.430f, 0.055f, 19 },
    { "menu",     "\xE2\x9A\x99", 0,    0.500f, 0.055f, 16 },   /* the settings */
};

const float kStickR = 58.0f;          /* the stick's reach, points */
const float kStickDead = 0.10f;
const float kStickSplit = 0.45f;      /* left of this (of the view) is the stick's */
const float kCamFull = 1100.0f;       /* points a second for a full right stick */
const double kCamHold = 0.06;         /* the swipe's stick lets go after this still */
const double kTapTime = 0.25, kDoubleTap = 0.32, kR3Time = 0.12;
const float kTapMove = 14.0f, kDoubleTapDist = 48.0f;
const float kSlack = 1.18f;           /* a button's touch target past its circle */

bool slides(int b) { return b == kSquare || b == kTriangle || b == kCross || b == kCircle || b == kR1; }
bool camera_as_stick()
{
    static int v = -1;
    if (v < 0) { const char* e = getenv("DOD3_TOUCH_CAMERA"); v = e && !strcmp(e, "stick"); }
    return v || !g_camera_motion || !g_camera_bridge_live || !g_camera_bridge_live();
}
uint8_t axis(float v)
{
    if (v > 1) v = 1;
    if (v < -1) v = -1;
    const int a = 128 + (int)lrintf(v * 127.0f);
    return (uint8_t)(a < 0 ? 0 : a > 255 ? 255 : a);
}

}  // namespace

struct Pad::Shared {
    std::atomic<uint32_t> buttons{ 0 };
    std::atomic<uint32_t> lstick{ 0x8080 };
    std::atomic<uint32_t> rstick{ 0x8080 };
    std::atomic<double> cam_t{ -10 };      /* when the swipe's stick was last set */
    std::atomic<double> r3_until{ 0 };
    std::atomic<double> last_touch{ -10 };
    std::atomic<int> down{ 0 };
};

Config::Config() { reset_layout(); }
void Config::reset_layout()
{
    for (int b = 0; b < kButtons; b++) { x[b] = kDef[b].x; y[b] = kDef[b].y; scale[b] = 1.0f; }
}

Pad::Pad() : sh_(new Shared) {}

uint16_t Pad::mask(int b) { return b >= 0 && b < kButtons ? kDef[b].mask : 0; }
const char* Pad::key(int b) { return b >= 0 && b < kButtons ? kDef[b].key : ""; }
const char* Pad::label(int b) { return b >= 0 && b < kButtons ? kDef[b].label : ""; }

void Pad::set_area(float w, float h, Rect safe) { vw_ = w; vh_ = h; safe_ = safe; }

float Pad::bx(int b) const { return safe_.x + cfg.x[b] * safe_.w; }
float Pad::by(int b) const { return safe_.y + cfg.y[b] * safe_.h; }
float Pad::br(int b) const { return kDef[b].r * cfg.size * cfg.scale[b]; }
float Pad::stick_radius() const { return kStickR * cfg.size; }

int Pad::button_at(float x, float y, float slack) const
{
    int best = kNone;
    float bd = 1e30f;
    for (int b = 0; b < kButtons; b++) {
        const float dx = x - bx(b), dy = y - by(b), r = br(b) * slack;
        const float d = dx * dx + dy * dy;
        /* the nearest by its own size, where targets overlap */
        if (d <= r * r && d / (r * r) < bd) { bd = d / (r * r); best = b; }
    }
    return best;
}

Pad::Touch* Pad::find(uintptr_t id)
{
    for (int i = 0; i < ntouches_; i++) if (touches_[i].id == id) return &touches_[i];
    return nullptr;
}

bool Pad::stick_shown(float* bx_, float* by_, float* kx, float* ky, float* r) const
{
    for (int i = 0; i < ntouches_; i++) {
        const Touch& tc = touches_[i];
        if (tc.role != kStick) continue;
        *bx_ = tc.x0; *by_ = tc.y0; *r = stick_radius();
        float dx = tc.x - tc.x0, dy = tc.y - tc.y0;
        const float d = sqrtf(dx * dx + dy * dy);
        if (d > *r) { dx *= *r / d; dy *= *r / d; }
        *kx = tc.x0 + dx; *ky = tc.y0 + dy;
        return true;
    }
    return false;
}

void Pad::publish(double t)
{
    uint32_t held = 0;
    float lx = 0, ly = 0;
    for (int i = 0; i < ntouches_; i++) {
        const Touch& tc = touches_[i];
        if (tc.role >= 0) held |= 1u << tc.role;
        if (tc.role == kStick) {
            const float r = stick_radius();
            float dx = (tc.x - tc.x0) / r, dy = (tc.y - tc.y0) / r;
            const float d = sqrtf(dx * dx + dy * dy);
            if (d < kStickDead) dx = dy = 0;
            else if (d > 1) { dx /= d; dy /= d; }
            lx = dx; ly = dy;
        }
    }
    if (editing) held = 0;
    held_mask_ = held;
    uint32_t m = 0;
    for (int b = 0; b < kButtons; b++) if (held >> b & 1u) m |= kDef[b].mask;
    sh_->buttons.store(m, std::memory_order_relaxed);
    sh_->lstick.store(editing ? 0x8080u : (uint32_t)axis(lx) << 8 | axis(ly), std::memory_order_relaxed);
    sh_->down.store(ntouches_, std::memory_order_relaxed);
    sh_->last_touch.store(t, std::memory_order_release);
}

int Pad::began(uintptr_t id, float x, float y, double t)
{
    if (ntouches_ >= kMaxTouches || find(id)) return kNone;
    Touch& tc = touches_[ntouches_++];
    tc = Touch{};
    tc.id = id; tc.x0 = tc.x = x; tc.y0 = tc.y = y; tc.t0 = tc.t = t;
    last_touch_ = t;
    if (editing) {
        edit_began(tc);
        publish(t);
        return tc.role;
    }
    const int b = button_at(x, y, kSlack);
    if (b != kNone) {
        tc.role = b;
    } else if (x < vw_ * kStickSplit) {
        tc.role = kStick;
    } else {
        tc.role = kCamera;
        if (tap_t_ >= 0 && t - tap_t_ < kDoubleTap &&
            fabsf(x - tap_x_) < kDoubleTapDist && fabsf(y - tap_y_) < kDoubleTapDist) {
            r3_until_ = t + kR3Time;
            sh_->r3_until.store(r3_until_, std::memory_order_relaxed);
            tap_t_ = -1;
        }
    }
    publish(t);
    return tc.role;
}

void Pad::moved(uintptr_t id, float x, float y, double t)
{
    Touch* tc = find(id);
    if (!tc) return;
    const float px = tc->x, py = tc->y;
    const double pt = tc->t;
    tc->x = x; tc->y = y; tc->t = t;
    last_touch_ = t;
    if (editing) { edit_moved(t); return; }
    if (tc->role == kStick) {
        /* past the rim the base follows, so turning back answers at once */
        const float r = stick_radius();
        const float dx = x - tc->x0, dy = y - tc->y0, d = sqrtf(dx * dx + dy * dy);
        if (d > r * 1.4f) { tc->x0 = x - dx * (r * 1.4f / d); tc->y0 = y - dy * (r * 1.4f / d); }
    } else if (tc->role == kCamera) {
        const float dx = x - px, dy = y - py;
        if (!camera_as_stick()) {
            g_camera_motion(dx * cfg.camera, dy * cfg.camera);
            sh_->rstick.store(0x8080u, std::memory_order_relaxed);
        } else {
            const double dt = t - pt;
            if (dt > 0.0005) {
                /* a little smoothing: touches come at the screen's rate, unevenly */
                const float a = 0.5f;
                cam_vx_ = cam_vx_ * (1 - a) + a * (float)(dx / dt);
                cam_vy_ = cam_vy_ * (1 - a) + a * (float)(dy / dt);
                const float full = kCamFull / (cfg.camera > 0.05f ? cfg.camera : 0.05f);
                sh_->rstick.store((uint32_t)axis(cam_vx_ / full) << 8 | axis(cam_vy_ / full), std::memory_order_relaxed);
                sh_->cam_t.store(t, std::memory_order_relaxed);
            }
        }
    } else if (tc->role >= 0 && slides(tc->role)) {
        const int b = button_at(x, y, 1.0f);
        if (b != kNone && b != tc->role && slides(b)) tc->role = b;
    }
    publish(t);
}

int Pad::ended(uintptr_t id, double t)
{
    Touch* tc = find(id);
    if (!tc) return kNone;
    const int role = tc->role;
    if (!editing && role == kCamera) {
        const float mv = fabsf(tc->x - tc->x0) + fabsf(tc->y - tc->y0);
        if (t - tc->t0 < kTapTime && mv < kTapMove) { tap_t_ = t; tap_x_ = tc->x; tap_y_ = tc->y; }
        else tap_t_ = -1;
        cam_vx_ = cam_vy_ = 0;
        sh_->rstick.store(0x8080u, std::memory_order_relaxed);
    }
    *tc = touches_[--ntouches_];
    last_touch_ = t;
    if (editing) pinch_d0_ = 0;
    publish(t);
    return role >= 0 ? role : kNone;
}

void Pad::cancel_all()
{
    ntouches_ = 0;
    cam_vx_ = cam_vy_ = 0;
    pinch_d0_ = 0;
    sh_->rstick.store(0x8080u, std::memory_order_relaxed);
    publish(last_touch_);
}

Out Pad::out(double now) const
{
    Out o;
    uint32_t b = sh_->buttons.load(std::memory_order_relaxed);
    if (now < sh_->r3_until.load(std::memory_order_relaxed)) b |= kR3;
    o.buttons = (uint16_t)b;
    const uint32_t l = sh_->lstick.load(std::memory_order_relaxed);
    uint32_t r = sh_->rstick.load(std::memory_order_relaxed);
    if (now - sh_->cam_t.load(std::memory_order_relaxed) > kCamHold) r = 0x8080u;   /* the finger stopped */
    o.lx = (uint8_t)(l >> 8); o.ly = (uint8_t)l;
    o.rx = (uint8_t)(r >> 8); o.ry = (uint8_t)r;
    o.active = sh_->down.load(std::memory_order_relaxed) > 0 ||
               now - sh_->last_touch.load(std::memory_order_acquire) < 0.25 || o.buttons;
    return o;
}

/* ---- the layout editor ---- */

void Pad::edit_began(Touch& tc)
{
    if (ntouches_ == 1) {
        tc.role = button_at(tc.x, tc.y, kSlack);
        if (tc.role != kNone) {
            edit_selected = tc.role;
            tc.ex = cfg.x[tc.role]; tc.ey = cfg.y[tc.role]; tc.es = cfg.scale[tc.role];
        }
    } else {
        tc.role = kNone;   /* a second finger: the pinch */
        pinch_d0_ = 0;
    }
}

void Pad::edit_moved(double t)
{
    (void)t;
    if (ntouches_ >= 2 && edit_selected != kNone) {
        const float dx = touches_[0].x - touches_[1].x, dy = touches_[0].y - touches_[1].y;
        const float d = sqrtf(dx * dx + dy * dy);
        if (pinch_d0_ <= 0) { pinch_d0_ = d; pinch_s0_ = cfg.scale[edit_selected]; return; }
        float s = pinch_s0_ * d / (pinch_d0_ > 1 ? pinch_d0_ : 1);
        cfg.scale[edit_selected] = s < 0.5f ? 0.5f : s > 2.5f ? 2.5f : s;
        return;
    }
    if (ntouches_ == 1 && touches_[0].role >= 0 && safe_.w > 0 && safe_.h > 0) {
        Touch& tc = touches_[0];
        float nx = tc.ex + (tc.x - tc.x0) / safe_.w, ny = tc.ey + (tc.y - tc.y0) / safe_.h;
        nx = nx < 0 ? 0 : nx > 1 ? 1 : nx;
        ny = ny < 0 ? 0 : ny > 1 ? 1 : ny;
        cfg.x[tc.role] = nx; cfg.y[tc.role] = ny;
    }
}

/* ---- the settings file ---- */

bool Pad::load(const std::string& path)
{
    FILE* f = fopen(path.c_str(), "r");
    if (!f) return false;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char k[64];
        float a, b, c;
        if (line[0] == '#' || sscanf(line, " %63[a-z0-9_] =", k) != 1) continue;
        const char* v = strchr(line, '=');
        if (!v) continue;
        v++;
        if (!strcmp(k, "opacity") && sscanf(v, "%f", &a) == 1) cfg.opacity = a < 0.05f ? 0.05f : a > 1 ? 1 : a;
        else if (!strcmp(k, "size") && sscanf(v, "%f", &a) == 1) cfg.size = a < 0.5f ? 0.5f : a > 2 ? 2 : a;
        else if (!strcmp(k, "camera") && sscanf(v, "%f", &a) == 1) cfg.camera = a < 0.1f ? 0.1f : a > 5 ? 5 : a;
        else if (!strcmp(k, "haptics") && sscanf(v, "%f", &a) == 1) cfg.haptics = a != 0;
        else for (int i = 0; i < kButtons; i++)
            if (!strcmp(k, kDef[i].key) && sscanf(v, "%f %f %f", &a, &b, &c) == 3) {
                cfg.x[i] = a < 0 ? 0 : a > 1 ? 1 : a;
                cfg.y[i] = b < 0 ? 0 : b > 1 ? 1 : b;
                cfg.scale[i] = c < 0.5f ? 0.5f : c > 2.5f ? 2.5f : c;
            }
    }
    fclose(f);
    return true;
}

bool Pad::save(const std::string& path) const
{
    const std::string tmp = path + ".new";
    FILE* f = fopen(tmp.c_str(), "w");
    if (!f) return false;
    fprintf(f, "# Drakengard 3 Recompiled: the touch controls (the gear at the top of the screen)\n"
               "# opacity 0.05-1, size 0.5-2, camera (the swipe's speed) 0.1-5, haptics 0/1;\n"
               "# each button: x y (0-1 across and down the safe area) and its own scale.\n"
               "# Delete the file for the defaults.\n");
    fprintf(f, "opacity = %.2f\nsize = %.2f\ncamera = %.2f\nhaptics = %d\n", cfg.opacity, cfg.size, cfg.camera,
            cfg.haptics ? 1 : 0);
    for (int i = 0; i < kButtons; i++)
        fprintf(f, "%s = %.4f %.4f %.2f\n", kDef[i].key, cfg.x[i], cfg.y[i], cfg.scale[i]);
    fclose(f);
    return rename(tmp.c_str(), path.c_str()) == 0;
}

}  // namespace touchpad
