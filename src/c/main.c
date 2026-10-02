// Parallax Weather watch face: Pebble glue. Drawing rules live in the portable modules
// (engine, sky, moon, face); this file owns resources, services, timers and the frame buffer.
#include <pebble.h>

#include "face.h"
#include "moon.h"
#include "sky.h"

// ---------------------------------------------------------------- build switches
// SHOT > 0: emulator harness. Seeds weather, sun and moon so each look can be checked without the
// phone; an accelerometer tap (pebble emu-tap) steps to the next look.
#ifndef SHOT
#define SHOT 0
#endif
// PERF_LOG: logs heap and render timings over APP_LOG.
#ifndef PERF_LOG
#define PERF_LOG 0
#endif
#define SINGLE_HOUR_12H 0  // 12 hour mode: 1 = hours 1-9 as one centred digit, 0 = leading zero (chosen)
#define TILT_SIGN_X 1      // direction the texture slides for a given tilt; confirm on the wrist
#define TILT_SIGN_Y 1

#define SCREEN_W PBL_DISPLAY_WIDTH
#define SCREEN_H PBL_DISPLAY_HEIGHT
#define GEOM (&GEOMETRY[PBL_IF_ROUND_ELSE(SCREEN_ROUND2, SCREEN_PT2)])  // must match SCREEN_W x SCREEN_H
#define PLANE_W (SCREEN_W + 2 * TILT_MARGIN)
#define PLANE_H (SCREEN_H + 2 * TILT_MARGIN)
#define STALE_AFTER_S (3 * 3600)
#define SYNODIC_S 2551443  // mean lunar month, seconds

// HOLD_LIGHT: harness only. Keeps the backlight on and the tilt running so the emulator's slow
// accelerometer commands can be tested (with SHOT).
#ifndef HOLD_LIGHT
#define HOLD_LIGHT 0
#endif

#define ANIM_CHECK_MS 6000  // the tilt checks the light this long after it starts, then every second
#define ANIM_MAX_MS (HOLD_LIGHT ? 600000 : 30000)  // hard stop for the tilt, even if light-off never comes
#define TILT_FULL_MG 300   // tilt away from the origin (milli-g) that gives the full offset, about 17 degrees
#define HYSTERESIS_16 10   // an offset moves only when the tilt is 10/16 px past it: no 1 px flicker
#define GLOW_STEP_MS 60    // the night glow ramps 1/4 -> full over three steps
#define LIGHT_SETTLE_MS 50 // light-on waits this long: a notification that lit the screen has taken focus by then
#define BRIDGE_MS 100      // the stand-in accelerometer session after the tilt stops (see anim_stop)
#define BRIDGE_SAMPLES 25  // its batch: 2.5 s at 10 Hz, so it never delivers within BRIDGE_MS
_Static_assert(BRIDGE_MS * 10 <= BRIDGE_SAMPLES * 100, "the bridge must not fill a batch before it is dropped");

static const uint32_t TEX_RES[TEX_COUNT] = {
  RESOURCE_ID_TEX_SUNNY, RESOURCE_ID_TEX_PARTLY, RESOURCE_ID_TEX_CLOUDY, RESOURCE_ID_TEX_RAIN,
  RESOURCE_ID_TEX_SNOW, RESOURCE_ID_TEX_STORM, RESOURCE_ID_TEX_FOG, RESOURCE_ID_TEX_PARTLY_NIGHT,
  RESOURCE_ID_TEX_CLOUDY_NIGHT,
};
static const uint32_t DIGIT_RES[10] = {
  RESOURCE_ID_DIGIT_0, RESOURCE_ID_DIGIT_1, RESOURCE_ID_DIGIT_2, RESOURCE_ID_DIGIT_3, RESOURCE_ID_DIGIT_4,
  RESOURCE_ID_DIGIT_5, RESOURCE_ID_DIGIT_6, RESOURCE_ID_DIGIT_7, RESOURCE_ID_DIGIT_8, RESOURCE_ID_DIGIT_9,
};

// ---------------------------------------------------------------- state
static Window *s_window;
static Layer *s_layer;
static Face s_face;
static FaceState s_state;
static Layout *s_layout;
static SkyTables s_sky;
static uint8_t *s_sky_blob;
static bool s_ready;  // every buffer allocated and loaded

// inputs from the phone, persisted so a relaunch (every return from an app) needs no messages
#define STORE_KEY 1
#define STORE_VERSION 3
typedef struct {
  uint8_t version;
  int8_t wx;                    // Weather, WX_STALE until the phone sends one
  int8_t hemisphere;            // +1 north, -1 south
  uint8_t border, solid, tilt;  // settings: day digit border on, solid sky, tilt effect
  uint8_t refresh_min;          // weather refresh interval
  uint8_t bg;                   // weather as the background: BG_DAY, BG_NIGHT
  int16_t moon_phase;           // degrees at moon_time, -1 = unknown
  int32_t wx_time;              // observation time
  int32_t wx_fetched;           // when the watch last received weather
  int32_t sky_fetched;          // when the watch last received sun and moon
  int32_t moon_time;
  int32_t last_request;
  uint8_t last_need;            // what that request asked for
  SunTimes sun;
} Store;
#define BG_DAY 1
#define BG_NIGHT 2
static Store s_in = {
  .version = STORE_VERSION, .wx = WX_STALE, .hemisphere = 1, .border = 1, .solid = 0, .tilt = 1,
  .refresh_min = 30, .bg = BG_DAY, .moon_phase = -1,  // the phone's defaults (src/pkjs/config.js)
};

// what the buffers currently hold
static TextureId s_tex_loaded = TEX_NONE;
static bool s_tex_valid;
static int s_hour_shown = -1, s_min_shown = -1, s_single_shown = -1;
static struct {
  bool valid, night;
  int moon_phase, hemisphere;               // night
  DayPhase phase;                           // day
  int8_t ramp_n;
  uint8_t ramp[4];
  bool glow;
  int sun_x, sun_y;
} s_plate;

// animation
static AppTimer *s_anim_timer;  // light check and hard stop
static uint32_t s_anim_start;
static AppTimer *s_glow_timer;
static AppTimer *s_light_timer;  // light-on, waiting to see whether the face is covered
static AppTimer *s_bridge_timer;
static bool s_anim;
static bool s_bridge;  // the stand-in accelerometer session is subscribed
static bool s_focused = true;  // false while a notification or other modal covers the face
static bool s_accel_first;
static int32_t s_fx, s_fy, s_bx, s_by;  // filtered accel and the parallax origin, milli-g << 4

static uint32_t now_ms(void) {
  time_t s;
  uint16_t ms;
  time_ms(&s, &ms);
  return (uint32_t)s * 1000 + ms;
}

#if PERF_LOG
static int largest_block(void) {
  // probe the largest single allocation that would succeed (free memory is not contiguous memory)
  int lo = 0, hi = (int)heap_bytes_free();
  while (lo < hi) {
    const int mid = (lo + hi + 1) / 2;
    void *p = malloc(mid);
    if (p) {
      free(p);
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}
#define PERF(...) APP_LOG(APP_LOG_LEVEL_INFO, __VA_ARGS__)
#else
#define PERF(...)
#endif

// ---------------------------------------------------------------- resources

static bool load_plane(Plane *p, uint32_t res) {
  ResHandle h = resource_get_handle(res);
  uint8_t header[PL2_HEADER];
  if (resource_load_byte_range(h, 0, header, PL2_HEADER) != PL2_HEADER) return false;
  Plane q;
  plane_header(&q, header);
  if (q.w != p->w || q.h != p->h) return false;  // every plane shares the one buffer size
  memcpy(p->pal, q.pal, 4);
  const size_t n = (size_t)p->stride * p->h;
  return resource_load_byte_range(h, PL2_HEADER, p->data, n) == n;
}

static bool moon_read(void *ctx, uint32_t offset, uint8_t *buf, uint32_t len) {
  return resource_load_byte_range(*(ResHandle *)ctx, offset, buf, len) == len;
}

// ---------------------------------------------------------------- inputs to state

static int moon_phase_now(time_t now) {
  if (s_in.moon_phase < 0) return 90;
  const int32_t dt = (int32_t)(now - s_in.moon_time);
  const int32_t adv = (int32_t)((int64_t)dt * 360 / SYNODIC_S);
  return (int)(((s_in.moon_phase + adv) % 360 + 360) % 360);
}

static DayPhase phase_now(time_t now) {
  // Sky data counts once the phone has answered, even with every event 0 (polar night).
  if (s_in.sky_fetched) {
    SunTimes st;
    sun_roll(&s_in.sun, (int32_t)now, &st);
    return sun_phase(&st, (int32_t)now);
  }
  // no sun times from the phone yet: a rough guess so the first launch is not blank
  const struct tm *t = localtime(&now);
  return (t->tm_hour >= 7 && t->tm_hour < 19) ? PHASE_MIDDAY : PHASE_NIGHT;
}

static void update_state(time_t now) {
  s_state.phase = phase_now(now);
  s_state.wx = (s_in.wx < 0 || s_in.wx >= WX_STALE || now - s_in.wx_time > STALE_AFTER_S) ? WX_STALE : (Weather)s_in.wx;
  s_state.border = s_in.border != 0;
  s_state.wx_bg_day = (s_in.bg & BG_DAY) != 0;
  s_state.wx_bg_night = (s_in.bg & BG_NIGHT) != 0;
}

// ---------------------------------------------------------------- buffers

// The refresh_* functions return true when they changed what the next frame shows.
static bool refresh_texture(void) {
  const TextureId want = face_texture(&s_state);
  if (want == TEX_NONE || (s_tex_valid && want == s_tex_loaded)) return false;
  s_tex_valid = load_plane(&s_face.tex, TEX_RES[want]);
  s_tex_loaded = want;
  if (!s_tex_valid) {
    APP_LOG(APP_LOG_LEVEL_ERROR, "texture %d failed to load", want);
    s_state.wx = WX_STALE;
  }
  return true;
}

static bool refresh_plate(time_t now) {
  const PlateKind kind = face_plate_kind(&s_state);
  if (kind == PLATE_NONE) return false;  // the weather texture is the background: no sky or moon to draw
  if (kind == PLATE_MOON) {
    const int phase = moon_phase_now(now);
    if (s_plate.valid && s_plate.night && s_plate.moon_phase == phase && s_plate.hemisphere == s_in.hemisphere) return false;
#if PERF_LOG
    const uint32_t t0 = now_ms();
#endif
    ResHandle h = resource_get_handle(RESOURCE_ID_MOON);
    s_plate.valid = moon_render(&s_face.plate, TILT_MARGIN, moon_read, &h, phase, s_in.hemisphere, &GEOM->moon);
    PERF("moon render %d ms (phase %d)", (int)(now_ms() - t0), phase);
    s_plate.night = true;
    s_plate.moon_phase = phase;
    s_plate.hemisphere = s_in.hemisphere;
    return true;
  }
  uint8_t ramp[4];
  const int n = sky_ramp(s_state.phase, s_state.wx, s_in.solid, ramp);
  const bool glow = sky_glow(s_state.wx, s_in.solid);
  int sx = 0, sy = 0;
  if (glow) {
    SunTimes st;
    sun_roll(&s_in.sun, (int32_t)now, &st);
    sun_position(&st, (int32_t)now, &GEOM->sun, &sx, &sy);
  }
  if (s_plate.valid && !s_plate.night && s_plate.phase == s_state.phase && s_plate.ramp_n == n &&
      !memcmp(s_plate.ramp, ramp, 4) && s_plate.glow == glow && s_plate.sun_x == sx && s_plate.sun_y == sy)
    return false;
  const uint32_t t0 = now_ms();
  (void)t0;
  sky_render(&s_face.plate, TILT_MARGIN, ramp, n, glow, sx, sy, &s_sky);
  PERF("sky render %d ms (sun %d,%d)", (int)(now_ms() - t0), sx, sy);
  s_plate.valid = true;
  s_plate.night = false;
  s_plate.phase = s_state.phase;
  s_plate.ramp_n = (int8_t)n;
  memcpy(s_plate.ramp, ramp, 4);
  s_plate.glow = glow;
  s_plate.sun_x = sx;
  s_plate.sun_y = sy;
  return true;
}

static void stamp_digit(int row, int value, bool single, int which, int digit) {
  ResHandle h = resource_get_handle(DIGIT_RES[digit]);
  const size_t n = resource_size(h);
  uint8_t *buf = malloc(n);
  if (!buf) {
    APP_LOG(APP_LOG_LEVEL_ERROR, "no memory for digit %d", digit);
    return;
  }
  if (n >= 3 && resource_load(h, buf, n) == n) {
    int x, y;
    face_digit_origin(s_layout, row, value, single, which, buf[2], &x, &y);
    if (!map_stamp(&s_face.map, buf, (int)n, x, y)) APP_LOG(APP_LOG_LEVEL_ERROR, "digit %d malformed", digit);
  }
  free(buf);
}

static bool refresh_digits(const struct tm *t) {
  int hour = t->tm_hour;
  if (!clock_is_24h_style()) hour = hour % 12 ? hour % 12 : 12;
  const bool single = !clock_is_24h_style() && SINGLE_HOUR_12H && hour < 10;
  if (hour == s_hour_shown && t->tm_min == s_min_shown && single == s_single_shown) return false;
  const uint32_t t0 = now_ms();
  (void)t0;
  map_clear(&s_face.map);
  if (single) {
    stamp_digit(0, hour, true, 0, hour);
  } else {
    stamp_digit(0, hour, false, 0, hour / 10);
    stamp_digit(0, hour, false, 1, hour % 10);
  }
  stamp_digit(1, t->tm_min, false, 0, t->tm_min / 10);
  stamp_digit(1, t->tm_min, false, 1, t->tm_min % 10);
  PERF("digits %02d:%02d stamped in %d ms", hour, t->tm_min, (int)(now_ms() - t0));
  s_hour_shown = hour;
  s_min_shown = t->tm_min;
  s_single_shown = single;
  return true;
}

// Brings the buffers up to date and redraws only if the picture changed: a weather reply with the
// same weather, or settings resent unchanged on every launch, cost no frame.
static void refresh(void) {
  if (!s_ready) return;
  time_t now = time(NULL);
  const FaceState before = s_state;
  update_state(now);
  bool dirty = s_state.wx != before.wx || s_state.phase != before.phase || s_state.border != before.border ||
               s_state.wx_bg_day != before.wx_bg_day || s_state.wx_bg_night != before.wx_bg_night;
  // texture first: a failed load turns the weather stale, which brings back the sky or moon plate
  // in this same pass (face_plate_kind), so a half-loaded texture is never shown as the background
  dirty |= refresh_texture();
  dirty |= refresh_plate(now);
  dirty |= refresh_digits(localtime(&now));
  if (dirty) layer_mark_dirty(s_layer);
}

// ---------------------------------------------------------------- drawing

static void update_proc(Layer *layer, GContext *ctx) {
  if (!s_ready) {
    graphics_context_set_fill_color(ctx, GColorBlack);
    graphics_fill_rect(ctx, layer_get_bounds(layer), 0, GCornerNone);
    return;
  }
  const uint32_t t0 = now_ms();
  (void)t0;
  (void)layer_get_unobstructed_bounds(layer);  // counts as peek-aware (see peek_changed)
  Scene sc;
  face_scene(&s_face, &s_state, &sc);
  GBitmap *fb = graphics_capture_frame_buffer(ctx);
  if (!fb) return;
  const GRect b = gbitmap_get_bounds(fb);
  const int h = b.size.h < SCREEN_H ? b.size.h : SCREEN_H;
  for (int y = 0; y < h; y++) {
    const GBitmapDataRowInfo info = gbitmap_get_data_row_info(fb, y);
    const int x1 = info.max_x < SCREEN_W - 1 ? info.max_x : SCREEN_W - 1;
    if (info.min_x <= x1) compose_row(&sc, y, info.min_x, x1, info.data);
  }
  graphics_release_frame_buffer(ctx, fb);
  PERF("frame %d ms (glow %d tilt %d,%d)", (int)(now_ms() - t0), s_state.glow, s_state.tilt_x, s_state.tilt_y);
}

// ---------------------------------------------------------------- backlight and tilt

// Offset for tilt d (milli-g << 4 from the origin), in 1/16 px, clamped to +-max px.
static int32_t offset_16(int32_t d, int max) {
  const int32_t v = d * max / TILT_FULL_MG;
  return v < -16 * max ? -16 * max : v > 16 * max ? 16 * max : v;
}

// Moves the whole-pixel offset only when the tilt has gone clearly past it.
static int follow(int cur, int32_t target_16) {
  if (target_16 - 16 * cur > HYSTERESIS_16 || 16 * cur - target_16 > HYSTERESIS_16)
    return (int)((target_16 + (target_16 >= 0 ? 8 : -8)) / 16);
  return cur;
}

// Every sample moves the picture straight away (no polling timer between the sensor and the
// redraw); the display coalesces redraw requests into frames.
static void accel_handler(AccelData *data, uint32_t n) {
  if (!s_anim) return;  // a batch queued before anim_stop must not move the picture
  for (uint32_t i = 0; i < n; i++) {
    if (data[i].did_vibrate) continue;
    const int32_t x = (int32_t)data[i].x << 4, y = (int32_t)data[i].y << 4;
    if (s_accel_first) {
      // the origin is the pose when the light came on (its first usable sample: a buzz must not
      // set it) and stays put while the light is on, so the picture starts centred and never
      // drifts back on its own
      s_fx = s_bx = x;
      s_fy = s_by = y;
      s_accel_first = false;
    } else {
      s_fx += (x - s_fx) / 2;  // light low-pass: 87.5% of a step in 3 samples (60 ms at 50 Hz)
      s_fy += (y - s_fy) / 2;
    }
  }
  if (!n || s_accel_first) return;
  const int tx = follow(s_state.tilt_x, TILT_SIGN_X * offset_16(s_fx - s_bx, TILT_MAX_X));
  const int ty = follow(s_state.tilt_y, TILT_SIGN_Y * offset_16(s_fy - s_by, TILT_MAX_Y));
  if (tx != s_state.tilt_x || ty != s_state.tilt_y) {
    s_state.tilt_x = tx;
    s_state.tilt_y = ty;
    layer_mark_dirty(s_layer);
  }
}

static void accel_ignore(AccelData *data, uint32_t n) {}

static void bridge_end(void) {
  if (s_bridge_timer) app_timer_cancel(s_bridge_timer);
  s_bridge_timer = NULL;
  if (!s_bridge) return;
  s_bridge = false;
  accel_data_service_unsubscribe();  // safe: the bridge cannot have a batch waiting yet
}

static void bridge_timeout(void *ctx) {
  s_bridge_timer = NULL;
  bridge_end();
}

static void anim_stop(void) {
  if (!s_anim) return;
  s_anim = false;
  accel_data_service_unsubscribe();
  // PebbleOS bug: unsubscribing while a sample batch is still queued for the face marks the app's
  // accelerometer state for a deferred free, and when that batch is drained with nothing subscribed
  // the firmware frees memory it never allocated and the app faults (emulator PC 0xb501c). At
  // 50 Hz, one sample a batch, a batch is often queued, above all while a frame is drawing. A
  // stand-in session catches the stale batch, which is already queued and so drains before
  // bridge_timeout fires.
  accel_data_service_subscribe(BRIDGE_SAMPLES, accel_ignore);
  accel_service_set_sampling_rate(ACCEL_SAMPLING_10HZ);
  s_bridge = true;
  s_bridge_timer = app_timer_register(BRIDGE_MS, bridge_timeout, NULL);
  if (s_anim_timer) app_timer_cancel(s_anim_timer);
  s_anim_timer = NULL;
  if (s_state.tilt_x || s_state.tilt_y) layer_mark_dirty(s_layer);
  s_state.tilt_x = s_state.tilt_y = 0;
}

// Normally light-off stops the tilt. If that edge is late or lost the tilt stops by itself, but
// never while the light is still on (a second flick or a button keeps it lit with no new edge):
// stopping then would snap the picture back to centre in view.
static void anim_timeout(void *ctx) {
  s_anim_timer = NULL;
  if (light_is_on() && now_ms() - s_anim_start < ANIM_MAX_MS) {
    s_anim_timer = app_timer_register(1000, anim_timeout, NULL);
    return;
  }
  anim_stop();
}

static void anim_start(void) {
  if (s_anim || !s_in.tilt || !s_focused) return;
  s_anim = true;
  s_accel_first = true;
  bridge_end();  // never subscribe over a live session: the firmware would leak it and free its buffer
  accel_data_service_subscribe(1, accel_handler);
  accel_service_set_sampling_rate(ACCEL_SAMPLING_50HZ);
  s_anim_start = now_ms();
  PERF("tilt start");
  s_anim_timer = app_timer_register(HOLD_LIGHT ? ANIM_MAX_MS : ANIM_CHECK_MS, anim_timeout, NULL);
}

static void glow_step(void *ctx) {
  s_glow_timer = NULL;
  if (!face_night(&s_state)) {
    s_state.glow = GLOW_FULL;  // day came mid-ramp: the glow draws nothing by day
    return;
  }
  if (s_state.glow < GLOW_FULL) s_state.glow++;
  if (s_state.glow < GLOW_FULL) s_glow_timer = app_timer_register(GLOW_STEP_MS, glow_step, NULL);
  layer_mark_dirty(s_layer);
}

static void glow_set(bool on) {
  if (s_glow_timer) app_timer_cancel(s_glow_timer);
  s_glow_timer = NULL;
  const uint8_t was = s_state.glow;
  s_state.glow = 0;
  if (on && face_night(&s_state) && s_focused) {
    glow_step(NULL);  // 1 now, full after three more steps
  } else if (on) {
    // By day the glow draws nothing; under a notification nobody sees the ramp. Straight to full:
    // no timers, and at most one frame (so the face is right when the notification closes).
    s_state.glow = GLOW_FULL;
    if (face_night(&s_state)) layer_mark_dirty(s_layer);
  } else if (was && face_night(&s_state)) {
    layer_mark_dirty(s_layer);
  }
}

// The firmware turns the light on for a notification before it tells the face it lost focus
// (both in one kernel pass), so light-on waits LIGHT_SETTLE_MS: by then a covered face knows, and
// neither the accelerometer nor the glow ramp starts behind the notification.
static void light_settled(void *ctx) {
  s_light_timer = NULL;
  if (!light_is_on()) return;
  glow_set(true);  // straight to full, no ramp, while covered
  anim_start();    // not while covered
}

static void backlight_handler(bool on) {
  // No redraw of its own: the glow (night only) and the tilt each redraw when they change what is
  // shown, so a daytime flick costs no frame until the wrist moves.
  if (s_light_timer) app_timer_cancel(s_light_timer);
  s_light_timer = NULL;
  if (on) {
    s_light_timer = app_timer_register(LIGHT_SETTLE_MS, light_settled, NULL);
  } else {
    glow_set(false);
    anim_stop();
  }
  PERF("backlight %s, heap free %d, largest %d", on ? "on" : "off", (int)heap_bytes_free(), largest_block());
}

// A notification lights the screen over the face: no tilt (50 Hz accelerometer, redraws) for a
// picture nobody can see. It stops as the notification starts to cover the face and resumes, if
// the light is still on, once the face is fully back.
static void focus_will_change(bool focused) {
  PERF("focus will %d", focused);
  if (focused) return;
  s_focused = false;
  anim_stop();
}

static void focus_did_change(bool focused) {
  PERF("focus did %d", focused);
  s_focused = focused;
  if (!focused) {
    anim_stop();
  } else if (light_is_on()) {
    anim_start();
  }
}

// ---------------------------------------------------------------- harness

#if SHOT
typedef struct {
  Weather wx;
  DayPhase phase;  // PHASE_NIGHT uses the moon; others place the sun by sun_x / sun_y below
  int sun_x, sun_y, moon;  // sun in PT2 px: sun_x only sets how far through the day it is
  uint8_t bg;      // weather as the background (BG_DAY | BG_NIGHT)
} Shot;
static const Shot SHOTS[] = {
  {WX_CLEAR, PHASE_MIDDAY, 100, 6, 0, 0},       {WX_PARTLY, PHASE_MORNING, 18, 196, 0, 0},
  {WX_CLOUDY, PHASE_AFTERNOON, 176, 64, 0, 0},  {WX_RAIN, PHASE_GOLDEN, 180, 204, 0, 0},
  {WX_SNOW, PHASE_MIDDAY, 100, 6, 0, 0},        {WX_STORM, PHASE_AFTERNOON, 176, 64, 0, 0},
  {WX_FOG, PHASE_MORNING, 18, 196, 0, 0},       {WX_CLEAR, PHASE_NIGHT, 0, 0, 90, 0},
  {WX_PARTLY, PHASE_NIGHT, 0, 0, 60, 0},        {WX_RAIN, PHASE_NIGHT, 0, 0, 250, 0},
  {WX_STALE, PHASE_MIDDAY, 100, 6, 0, 0},
  // weather as the background (3 = day and night, 1 = day only)
  {WX_RAIN, PHASE_MORNING, 18, 196, 0, 3},   {WX_PARTLY, PHASE_MIDDAY, 100, 6, 0, 3},
  {WX_STORM, PHASE_GOLDEN, 180, 204, 0, 3},  {WX_CLOUDY, PHASE_NIGHT, 0, 0, 60, 3},
  {WX_CLEAR, PHASE_NIGHT, 0, 0, 200, 3},     {WX_CLEAR, PHASE_MIDDAY, 100, 6, 0, 3},
  {WX_SNOW, PHASE_AFTERNOON, 176, 64, 0, 3}, {WX_FOG, PHASE_MORNING, 18, 196, 0, 3},
  {WX_RAIN, PHASE_NIGHT, 0, 0, 250, 1},
};
static int s_shot;

// Builds sun times that put now in the wanted phase with the sun at roughly (sun_x, sun_y).
static void shot_seed(void) {
  const Shot *sh = &SHOTS[s_shot % (int)ARRAY_LENGTH(SHOTS)];
  const time_t now = time(NULL);
  s_in.wx = (int8_t)sh->wx;
  s_in.bg = sh->bg;
  s_in.wx_time = s_in.wx_fetched = s_in.sky_fetched = (int32_t)now;
  memset(&s_in.sun, 0, sizeof s_in.sun);
  s_in.sun.peak = 60;
  // f = fraction of daylight gone, from the wanted sun x
  const int32_t day = 12 * 3600;
  const int32_t f = (sh->sun_x - 18) * day / 164;
  int32_t rise = (int32_t)now - f, set = rise + day;
  if (sh->phase == PHASE_NIGHT) {
    rise = (int32_t)now + 4 * 3600;
    set = rise + day;
  }
  const int32_t noon = rise + (set - rise) / 2;
  int32_t *t = s_in.sun.t[0];
  t[SUN_DAWN] = rise - 1800;
  t[SUN_RISE] = rise;
  t[SUN_NOON] = noon;
  t[SUN_SET] = set;
  t[SUN_DUSK] = set + 1800;
  // phase boundaries around now so the wanted phase holds whatever the sun position
  switch (sh->phase) {
    case PHASE_MORNING: t[SUN_RISE10] = (int32_t)now + 600; t[SUN_SET10] = set - 3600; break;
    case PHASE_MIDDAY: t[SUN_RISE10] = (int32_t)now - 600; t[SUN_NOON] = (int32_t)now; t[SUN_SET10] = set - 1; break;
    case PHASE_AFTERNOON: t[SUN_RISE10] = rise + 1; t[SUN_NOON] = (int32_t)now - 7200; t[SUN_SET10] = (int32_t)now + 600; break;
    case PHASE_GOLDEN: t[SUN_RISE10] = rise + 1; t[SUN_NOON] = rise + 2; t[SUN_SET10] = (int32_t)now - 60; t[SUN_DUSK] = (int32_t)now + 600; break;
    default: t[SUN_RISE10] = rise + 3600; t[SUN_SET10] = set - 3600; break;
  }
  s_in.moon_phase = (int16_t)sh->moon;
  s_in.moon_time = (int32_t)now;
  APP_LOG(APP_LOG_LEVEL_INFO, "shot %d: wx %d phase %d", s_shot, sh->wx, sh->phase);
}

static void shot_tap(AccelAxisType axis, int32_t direction) {
  s_shot = (s_shot + 1) % (int)ARRAY_LENGTH(SHOTS);
  shot_seed();
  refresh();
}
#endif

// ---------------------------------------------------------------- phone
// The watch asks (REQUEST, a bitmask of what it needs), the phone answers. Requests are driven by
// the age of what the watch holds, so relaunching the face does not refetch anything young.
#define NEED_WEATHER 1
#define NEED_SKY 2
#define RETRY_S (15 * 60)  // floor between requests that went unanswered (persisted, so relaunches respect it)

static void store_save(void) { persist_write_data(STORE_KEY, &s_in, sizeof s_in); }

static void store_load(void) {
  Store t;
  if (persist_exists(STORE_KEY) && persist_read_data(STORE_KEY, &t, sizeof t) == (int)sizeof t &&
      t.version == STORE_VERSION)
    s_in = t;
}

static bool same_local_day(time_t a, time_t b) {
  struct tm ta = *localtime(&a);  // localtime returns one shared struct: copy before the second call
  const struct tm *tb = localtime(&b);
  return ta.tm_year == tb->tm_year && ta.tm_yday == tb->tm_yday;
}

static int needs(time_t now) {
  int need = 0;
  if (!s_in.wx_fetched || now - s_in.wx_fetched >= (time_t)s_in.refresh_min * 60 || now < s_in.wx_fetched)
    need |= NEED_WEATHER;
  // sun and moon once a day, after local midnight
  if (!s_in.sky_fetched || !same_local_day(now, s_in.sky_fetched)) need |= NEED_SKY;
  return need;
}

static bool s_phone_ready;  // READY seen this session: a request sent before it would be lost

static void maybe_request(void) {
#if !SHOT
  if (!s_phone_ready) return;
  const time_t now = time(NULL);
  const int need = needs(now);
  if (!need) return;
  // The last request counts as answered only if everything it asked for arrived (WX_FAILED, or no
  // reply at all, leaves it open); an open request blocks the next for RETRY_S.
  const bool answered = (!(s_in.last_need & NEED_WEATHER) || s_in.wx_fetched >= s_in.last_request) &&
                        (!(s_in.last_need & NEED_SKY) || s_in.sky_fetched >= s_in.last_request);
  if (s_in.last_request && !answered && now >= s_in.last_request && now - s_in.last_request < RETRY_S) return;
  if (!connection_service_peek_pebble_app_connection()) return;
  DictionaryIterator *it;
  if (app_message_outbox_begin(&it) != APP_MSG_OK) return;
  dict_write_uint8(it, MESSAGE_KEY_REQUEST, (uint8_t)need);
  if (app_message_outbox_send() != APP_MSG_OK) return;
  s_in.last_request = (int32_t)now;
  s_in.last_need = (uint8_t)need;
  store_save();
  PERF("request %d", need);
#endif
}

static int32_t tuple_int(const Tuple *t) {
  if (t->type == TUPLE_INT) {
    if (t->length == 1) return t->value->int8;
    if (t->length == 2) return t->value->int16;
    return t->value->int32;
  }
  if (t->length == 1) return t->value->uint8;
  if (t->length == 2) return t->value->uint16;
  return (int32_t)t->value->uint32;
}

static void inbox_received(DictionaryIterator *it, void *ctx) {
  const int32_t now = (int32_t)time(NULL);
  bool changed = false;
  Tuple *t;
  if ((t = dict_find(it, MESSAGE_KEY_WX_STATE))) {
    const int32_t wx = tuple_int(t);
    Tuple *tt = dict_find(it, MESSAGE_KEY_WX_TIME);
    if (wx >= 0 && wx < WX_STALE && tt) {
      s_in.wx = (int8_t)wx;
      s_in.wx_time = tuple_int(tt);
      s_in.wx_fetched = now;
      changed = true;
    }
  }
  if ((t = dict_find(it, MESSAGE_KEY_SUN_TIMES)) && t->type == TUPLE_BYTE_ARRAY && t->length == sizeof s_in.sun.t) {
    memcpy(s_in.sun.t, t->value->data, sizeof s_in.sun.t);  // int32 little endian, like the watch
    Tuple *pk = dict_find(it, MESSAGE_KEY_SUN_PEAK);
    s_in.sun.peak = pk ? (int8_t)tuple_int(pk) : 45;
    s_in.sky_fetched = now;
    changed = true;
  }
  if ((t = dict_find(it, MESSAGE_KEY_MOON_PHASE))) {
    Tuple *mt = dict_find(it, MESSAGE_KEY_MOON_TIME);
    s_in.moon_phase = (int16_t)(((tuple_int(t) % 360) + 360) % 360);
    s_in.moon_time = mt ? tuple_int(mt) : now;
    changed = true;
  }
  // Settings ride along with every READY (each launch) and the hemisphere with every sky reply:
  // only a real change counts, so an unchanged resend costs no flash write and no redraw.
  if ((t = dict_find(it, MESSAGE_KEY_HEMISPHERE))) {
    const int8_t v = tuple_int(t) < 0 ? -1 : 1;
    changed |= v != s_in.hemisphere;
    s_in.hemisphere = v;
  }
  if ((t = dict_find(it, MESSAGE_KEY_CFG_BORDER))) {
    const int32_t v = tuple_int(t);
    const uint8_t b = v != 0;  // older phones sent 1 (adaptive, gone) or 2 (always): both mean on
    changed |= b != s_in.border;
    s_in.border = b;
  }
  if ((t = dict_find(it, MESSAGE_KEY_CFG_SKY))) {
    const uint8_t v = tuple_int(t) == 1;
    changed |= v != s_in.solid;
    s_in.solid = v;
  }
  if ((t = dict_find(it, MESSAGE_KEY_CFG_TILT))) {
    const uint8_t v = tuple_int(t) != 0;
    const bool turned_on = v && !s_in.tilt;
    changed |= v != s_in.tilt;
    s_in.tilt = v;
    if (!s_in.tilt) {
      anim_stop();
    } else if (turned_on && light_is_on()) {
      anim_start();  // turned on while lit: no light-on edge is coming (refused while covered)
    }
  }
  if ((t = dict_find(it, MESSAGE_KEY_CFG_BG))) {
    const uint8_t v = (uint8_t)(tuple_int(t) & (BG_DAY | BG_NIGHT));
    changed |= v != s_in.bg;
    s_in.bg = v;
  }
  if ((t = dict_find(it, MESSAGE_KEY_CFG_REFRESH))) {
    const int32_t v = tuple_int(t);
    const uint8_t m = (uint8_t)(v == 15 || v == 60 ? v : 30);
    changed |= m != s_in.refresh_min;
    s_in.refresh_min = m;
  }
  if (changed) {
    store_save();
    refresh();
  }
  PERF("inbox: changed %d, wx %d, sky day %d", changed, s_in.wx, (int)(s_in.sun.t[0][SUN_NOON] / 86400));
  if (dict_find(it, MESSAGE_KEY_READY)) {
    s_phone_ready = true;
    maybe_request();
  }
}

// ---------------------------------------------------------------- app

static void tick_handler(struct tm *t, TimeUnits changed) {
  refresh();
  maybe_request();
}

// Timeline Peek: registering makes the face peek-aware, so the firmware never squishes it; the
// peek simply covers the bottom of the frame.
static void peek_changed(void *ctx) { layer_mark_dirty(s_layer); }

static bool alloc_plane(Plane *p) {
  p->w = PLANE_W;
  p->h = PLANE_H;
  p->stride = (PLANE_W + 3) / 4;
  p->data = malloc((size_t)p->stride * p->h);
  return p->data != NULL;
}

static bool load_static(void) {
  if (GEOM->w != SCREEN_W || GEOM->h != SCREEN_H) return false;
  // Big buffers first, in the spec's order, while the heap is still one block.
  if (!alloc_plane(&s_face.tex) || !alloc_plane(&s_face.plate)) return false;
  s_face.map.w = SCREEN_W;
  s_face.map.h = SCREEN_H;
  s_face.map.map = malloc(SCREEN_W * SCREEN_H / 2);
  if (!s_face.map.map) return false;
  map_clear(&s_face.map);

  ResHandle lh = resource_get_handle(RESOURCE_ID_LAYOUT);
  s_layout = malloc(sizeof(Layout));
  if (!s_layout || resource_size(lh) != sizeof(Layout) || resource_load(lh, (uint8_t *)s_layout, sizeof(Layout)) != sizeof(Layout))
    return false;

  ResHandle sh = resource_get_handle(RESOURCE_ID_SKY);
  const size_t sn = resource_size(sh);
  s_sky_blob = malloc(sn);
  if (!s_sky_blob || resource_load(sh, s_sky_blob, sn) != sn) return false;
  s_sky.n_grad = (uint16_t)(s_sky_blob[0] | s_sky_blob[1] << 8);
  s_sky.n_bloom = (uint16_t)(s_sky_blob[2] | s_sky_blob[3] << 8);
  if (4 + 2 * ((size_t)s_sky.n_grad + s_sky.n_bloom) != sn) return false;
  s_sky.grad = (const uint16_t *)(s_sky_blob + 4);
  s_sky.bloom = s_sky.grad + s_sky.n_grad;
  return true;
}

static void window_load(Window *w) {
  Layer *root = window_get_root_layer(w);
  s_layer = layer_create(layer_get_bounds(root));
  layer_set_update_proc(s_layer, update_proc);
  layer_add_child(root, s_layer);
}

static void window_unload(Window *w) { layer_destroy(s_layer); }

static void init(void) {
  PERF("start: heap free %d", (int)heap_bytes_free());
  store_load();
  s_ready = load_static();
  if (!s_ready) APP_LOG(APP_LOG_LEVEL_ERROR, "out of memory or bad resources at start");
  PERF("buffers ready: heap free %d, largest %d", (int)heap_bytes_free(), largest_block());
#if SHOT
  shot_seed();
  accel_tap_service_subscribe(shot_tap);
#endif
#if HOLD_LIGHT
  light_enable(true);
#endif
  s_window = window_create();
  window_set_background_color(s_window, GColorClear);
  window_set_window_handlers(s_window, (WindowHandlers){.load = window_load, .unload = window_unload});
  window_stack_push(s_window, false);
  refresh();
  tick_timer_service_subscribe(MINUTE_UNIT, tick_handler);
  unobstructed_area_service_subscribe((UnobstructedAreaHandlers){.did_change = peek_changed}, NULL);
  app_message_register_inbox_received(inbox_received);
  app_message_open(256, 64);  // no request yet: the phone's JS is not running until it says READY
  app_focus_service_subscribe_handlers((AppFocusHandlers){.will_focus = focus_will_change, .did_focus = focus_did_change});
  backlight_service_subscribe(backlight_handler);
  if (light_is_on()) backlight_handler(true);  // launched with the light already on: no edge will come
  PERF("running: heap free %d, largest %d", (int)heap_bytes_free(), largest_block());
}

static void deinit(void) {
  if (s_light_timer) app_timer_cancel(s_light_timer);
  s_light_timer = NULL;
  anim_stop();
  bridge_end();  // the face is exiting: no queued batch will be drained
  glow_set(false);
  backlight_service_unsubscribe();
  app_focus_service_unsubscribe();
  tick_timer_service_unsubscribe();
  unobstructed_area_service_unsubscribe();
  app_message_deregister_callbacks();
#if SHOT
  accel_tap_service_unsubscribe();
#endif
  window_destroy(s_window);
  free(s_face.tex.data);
  free(s_face.plate.data);
  free(s_face.map.map);
  free(s_layout);
  free(s_sky_blob);
}

int main(void) {
  init();
  app_event_loop();
  deinit();
}
