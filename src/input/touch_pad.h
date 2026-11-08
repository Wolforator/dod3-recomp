/*
 * The touch screen as the pad (iOS): the model behind the on-screen
 * controls, src/input/touch_pad.cpp. No UIKit here -- the view
 * (src/os/ios/touch_ios.mm) hands it touches in points and draws what it
 * says; the pad library reads its state from any thread.
 */
#pragma once

#include <stdint.h>
#include <string>

namespace touchpad {

/* The on-screen buttons. */
enum Id {
    kSquare, kTriangle, kCross, kCircle, kR1, kIntoner, kR2,
    kL1, kL2, kUp, kDown, kStart, kSelect, kMenu,
    kButtons
};

/* What a touch is doing. */
enum Role { kNone = -1, kStick = -2, kCamera = -3 };

struct Rect { float x, y, w, h; };

struct Config {
    float opacity = 0.45f;   /* of a button at rest */
    float size = 1.0f;       /* every button's and the stick's */
    float camera = 1.0f;     /* the swipe's turn per point */
    bool haptics = true;
    float x[kButtons], y[kButtons], scale[kButtons];   /* in the safe area, 0..1; each button's own size */
    Config();
    void reset_layout();
};

/* The pad's state as cellPad takes it (CELL_PAD_CTRL_* buttons, sticks 0-255,
 * 128 the centre). */
struct Out {
    uint16_t buttons;
    uint8_t lx, ly, rx, ry;
    int active;   /* a finger is down, or was a moment ago */
};

/* Where the swipe's motion goes while the camera's bridge is live
 * (src/input/camera.cpp), and whether it is: set by the platform. */
extern void (*g_camera_motion)(float dx_points, float dy_points);
extern bool (*g_camera_bridge_live)();

class Pad {
public:
    Pad();
    Config cfg;

    /* The view's size and its safe area, in points. */
    void set_area(float view_w, float view_h, Rect safe);

    /* Touches: an id per finger (UITouch's address), points, seconds. The
     * return of began: the button it pressed (Id), kStick or kCamera. */
    int began(uintptr_t id, float x, float y, double t);
    void moved(uintptr_t id, float x, float y, double t);
    /* The button let go of (Id), or kNone: the menu button opens the
     * settings on release. */
    int ended(uintptr_t id, double t);
    void cancel_all();

    /* Any thread. */
    Out out(double now) const;

    /* For drawing. */
    float bx(int b) const;   /* centre, points */
    float by(int b) const;
    float br(int b) const;   /* radius, points */
    bool held(int b) const { return (held_mask_ >> b) & 1u; }
    bool stick_shown(float* bx, float* by, float* kx, float* ky, float* r) const;
    int button_at(float x, float y, float slack) const;

    /* The layout editor: a finger drags the button it lands on; a second
     * finger, anywhere, pinches that button's size. */
    bool editing = false;
    int edit_selected = kNone;

    /* The masks a button presses. */
    static uint16_t mask(int b);
    static const char* key(int b);     /* in the settings file */
    static const char* label(int b);   /* on screen (UTF-8) */

    /* The settings file (Documents/touch_controls.ini). */
    bool load(const std::string& path);
    bool save(const std::string& path) const;

private:
    struct Touch {
        uintptr_t id;
        int role;        /* Id, kStick, kCamera */
        float x0, y0;    /* where it came down */
        float x, y;      /* where it is */
        double t0, t;
        /* the editor's */
        float ex, ey, es;   /* the button's position and scale when it was taken */
    };
    enum { kMaxTouches = 11 };
    Touch touches_[kMaxTouches];
    int ntouches_ = 0;
    float vw_ = 0, vh_ = 0;
    Rect safe_{ 0, 0, 0, 0 };
    uint32_t held_mask_ = 0;

    /* the camera's swipe as a stick (where the bridge is not live) */
    float cam_vx_ = 0, cam_vy_ = 0;
    /* the last camera tap, for the double tap that is R3 */
    double tap_t_ = -1;
    float tap_x_ = 0, tap_y_ = 0;
    double r3_until_ = 0;
    double last_touch_ = -10;
    /* the editor's pinch */
    float pinch_d0_ = 0, pinch_s0_ = 1;

    /* published for out() */
    struct Shared;
    Shared* sh_;

    Touch* find(uintptr_t id);
    void publish(double t);
    float stick_radius() const;
    void edit_began(Touch& tc);
    void edit_moved(double t);
};

}  // namespace touchpad
