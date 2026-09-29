// What to draw: turns the face's state (weather, phase, backlight, tilt, settings) into a Scene.
// Portable (see platform.h). The watch and tools/host share every rule in here.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#include "engine.h"
#include "moon.h"
#include "sky.h"

#define TILT_MARGIN 16   // px of texture and plate beyond each screen edge
#define TILT_MAX_X 13    // texture offset limits while lit
#define TILT_MAX_Y 9
#define MOON_TILT_X 9    // clear night: the moon (plate and windows together) moves this far
#define MOON_TILT_Y 7

// Per-screen geometry. The art for each screen is built to match (tools/build_assets.sh).
typedef enum { SCREEN_PT2 = 0, SCREEN_ROUND2, SCREEN_COUNT } ScreenKind;
typedef struct {
  int w, h;
  MoonLayout moon;
  SunPath sun;
} Geometry;
extern const Geometry GEOMETRY[SCREEN_COUNT];

// Weather textures, in resource order.
typedef enum {
  TEX_NONE = -1,
  TEX_SUNNY = 0, TEX_PARTLY, TEX_CLOUDY, TEX_RAIN, TEX_SNOW, TEX_STORM, TEX_FOG,
  TEX_PARTLY_NIGHT, TEX_CLOUDY_NIGHT, TEX_COUNT
} TextureId;

typedef struct {
  Weather wx;           // WX_STALE when the weather is too old to show
  // Background settings. Off: the sky (day) or moon (night) is the plate and the weather shows
  // through the digits. On: the weather texture is the background, moving with the tilt, and the
  // digits are one solid colour picked for that texture (a clear night keeps the moon behind).
  bool wx_bg_day, wx_bg_night;
  DayPhase phase;
  uint8_t glow;         // night glow, 0 (backlight off) .. GLOW_FULL; ramps in when the light comes on
  int tilt_x, tilt_y;   // texture offset in px, within +-TILT_MAX_X / +-TILT_MAX_Y
  bool border;          // day: a 1 px line in the plate colour darkened one step around the digits
} FaceState;

typedef struct {
  ScreenMap map;
  Plane tex;            // weather texture (unused on a clear night or with stale weather)
  Plane plate;          // sky by day, moon by night
  BlendTable blend;
  // cache key for blend
  bool blend_ok;
  EdgeStyle blend_style;
  uint8_t blend_glow;
  uint8_t blend_tex_pal[4], blend_plate_pal[4];
  uint8_t tex_pal[4], plate_pal[4], plate_pal_dim[4];
} Face;

static inline bool face_night(const FaceState *s) { return s->phase == PHASE_NIGHT; }
static inline bool face_clear_night(const FaceState *s) { return s->phase == PHASE_NIGHT && s->wx == WX_CLEAR; }
// Whether the weather is the background right now (never with stale weather: that look is the same
// in both modes, flat grey digits over the sky or moon).
static inline bool face_weather_bg(const FaceState *s) {
  return s->wx != WX_STALE && (face_night(s) ? s->wx_bg_night : s->wx_bg_day);
}

// What the plate buffer has to hold for this state.
typedef enum { PLATE_NONE = 0, PLATE_SKY, PLATE_MOON } PlateKind;
PlateKind face_plate_kind(const FaceState *s);

// Digit placement table (resource layout.bin, see tools/pack.py).
typedef struct {
  int16_t pairs[100][2];  // left x of the tens and units bitmaps for "00".."99"
  int16_t singles[10];    // left x of one digit centred alone
  int16_t baselines[2];   // top row, bottom row
} Layout;
_Static_assert(sizeof(Layout) == 424, "layout.bin is 212 int16 values");

// Top-left of a digit bitmap. row: 0 hours, 1 minutes. value: 0..99, or 0..9 with single.
// which: 0 tens (or the single digit), 1 units. glyph_baseline: byte 2 of the digit resource.
void face_digit_origin(const Layout *l, int row, int value, bool single, int which, int glyph_baseline,
                       int *x, int *y);

// The weather texture this state shows, through the digits or as the background
// (TEX_NONE: the moon on a clear night, or stale weather).
TextureId face_texture(const FaceState *s);
// Solid digit colour (GColor8) over a weather background; TEX_NONE = over the clear-night moon.
uint8_t face_digit_colour(TextureId t);
// Fills scene for this state from the face's buffers, rebuilding the blend table if its inputs changed.
void face_scene(Face *f, const FaceState *s, Scene *scene);
