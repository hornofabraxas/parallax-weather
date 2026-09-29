#include "face.h"

#include <string.h>

const Geometry GEOMETRY[SCREEN_COUNT] = {
  // PT2, 200 x 228: the 300 px moon's lit limb 10 px past the side it faces; the sun rises and sets
  // near the bottom corners
  [SCREEN_PT2] = {200, 228, {200, 228, 60, 140, 114, 150}, {18, 164, 212, 206, 240}},
  // Round 2, 260 x 260: the same moon (it covers the whole circle); the sun's arc stays inside the
  // circle, its whole disc showing at sunrise and sunset and just hidden while the sun is down
  [SCREEN_ROUND2] = {260, 260, {260, 260, 120, 140, 130, 150}, {36, 188, 196, 184, 238}},
};

TextureId face_texture(const FaceState *s) {
  const bool night = face_night(s);
  switch (s->wx) {
    case WX_CLEAR: return night ? TEX_NONE : TEX_SUNNY;
    case WX_PARTLY: return night ? TEX_PARTLY_NIGHT : TEX_PARTLY;
    case WX_CLOUDY: return night ? TEX_CLOUDY_NIGHT : TEX_CLOUDY;
    case WX_RAIN: return TEX_RAIN;
    case WX_SNOW: return TEX_SNOW;
    case WX_STORM: return TEX_STORM;
    case WX_FOG: return TEX_FOG;
    default: return TEX_NONE;
  }
}

PlateKind face_plate_kind(const FaceState *s) {
  if (face_weather_bg(s) && face_texture(s) != TEX_NONE) return PLATE_NONE;  // the texture is the background
  return face_night(s) ? PLATE_MOON : PLATE_SKY;
}

// Digit colours over each weather background, 0xRRGGBB (every channel 00, 55, AA or FF), picked
// by eye from trial renders for contrast against every colour the texture shows. At night the cyan
// border or glow rings sit between the digits and the texture as well.
#define DIGIT_SUNNY 0xAAFFFF         // black sky, red and orange sun: pale cyan
#define DIGIT_PARTLY 0x000055        // blue sky, lavender and white cloud: navy
#define DIGIT_CLOUDY 0x000055
#define DIGIT_RAIN 0xFFFF55          // grey glass: yellow
#define DIGIT_SNOW 0xFFFFFF          // grey glass, pale crystals: white
#define DIGIT_STORM 0xFFAA00         // navy, blue, white bolts: amber
#define DIGIT_FOG 0xFF5500           // navy sky over a pale grey bank: orange
#define DIGIT_PARTLY_NIGHT 0xFFFFAA  // navy, slate and grey cloud: pale yellow
#define DIGIT_CLOUDY_NIGHT 0xFFFF55
#define DIGIT_MOON 0xFFFFFF          // clear night: the moon stays behind, white digits

#define GC(rgb) ((uint8_t)(0xC0 | (((rgb) >> 22) & 3) << 4 | (((rgb) >> 14) & 3) << 2 | (((rgb) >> 6) & 3)))

// Hand-picked per texture for contrast against every colour it shows (see docs/ROADMAP.md).
uint8_t face_digit_colour(TextureId t) {
  static const uint32_t RGB[TEX_COUNT] = {
    [TEX_SUNNY] = DIGIT_SUNNY, [TEX_PARTLY] = DIGIT_PARTLY, [TEX_CLOUDY] = DIGIT_CLOUDY,
    [TEX_RAIN] = DIGIT_RAIN, [TEX_SNOW] = DIGIT_SNOW, [TEX_STORM] = DIGIT_STORM, [TEX_FOG] = DIGIT_FOG,
    [TEX_PARTLY_NIGHT] = DIGIT_PARTLY_NIGHT, [TEX_CLOUDY_NIGHT] = DIGIT_CLOUDY_NIGHT,
  };
  return t >= 0 && t < TEX_COUNT ? GC(RGB[t]) : GC(DIGIT_MOON);
}

void face_digit_origin(const Layout *l, int row, int value, bool single, int which, int glyph_baseline,
                       int *x, int *y) {
  *x = single ? l->singles[value % 10] : l->pairs[value % 100][which & 1];
  *y = l->baselines[row & 1] - glyph_baseline;
}

#define GREY_DARK 0xD5   // #555555
#define GREY_LIGHT 0xEA  // #AAAAAA

// round(v * 0.35) without floats
static int far_layer(int v) { return (v * 7 + (v >= 0 ? 10 : -10)) / 20; }

void face_scene(Face *f, const FaceState *s, Scene *sc) {
  const bool night = face_night(s), clear = face_clear_night(s), wx_bg = face_weather_bg(s);
  const bool tex_bg = face_plate_kind(s) == PLATE_NONE;  // the weather texture is the plate
  memset(sc, 0, sizeof(*sc));
  sc->map = &f->map;
  sc->plate = tex_bg ? &f->tex : &f->plate;

  // plate: the moon never brightens; while lit it dims (#AAAAAA shown as #555555). As the glow
  // ramps in, a growing share of the moon's pixels take the dim palette (a 2 x 2 ordered dither),
  // so the dimming fades in with the rings instead of snapping. A weather texture never dims.
  memcpy(f->plate_pal, sc->plate->pal, 4);
  memcpy(f->plate_pal_dim, sc->plate->pal, 4);
  const bool moon = night && !tex_bg;
  if (moon) {
    for (int i = 0; i < 4; i++)
      if ((f->plate_pal_dim[i] | 0xC0) == GREY_LIGHT) f->plate_pal_dim[i] = GREY_DARK;
    if (s->glow >= GLOW_FULL) memcpy(f->plate_pal, f->plate_pal_dim, 4);
    if (s->glow > 0 && s->glow < GLOW_FULL) {
      sc->plate_pal_dim = f->plate_pal_dim;
      sc->dim_level = s->glow;
    }
  }

  int px = 0, py = 0;
  if (tex_bg) {
    // the weather background is the layer that moves: the full texture offset
    px = s->tilt_x;
    py = s->tilt_y;
  } else if (clear) {
    // one moon behind the digits: plate and windows move together
    px = s->tilt_x * MOON_TILT_X / TILT_MAX_X;
    py = s->tilt_y * MOON_TILT_Y / TILT_MAX_Y;
  } else if (!night) {
    px = far_layer(s->tilt_x);
    py = far_layer(s->tilt_y);
  }
  sc->plate_x = TILT_MARGIN + px;
  sc->plate_y = TILT_MARGIN + py;

  if (wx_bg) {
    // solid digits in the colour picked for this background
    sc->tex = NULL;
    memset(f->tex_pal, face_digit_colour(face_texture(s)), 4);
  } else if (clear) {
    sc->tex = &f->plate;
    memcpy(f->tex_pal, f->plate.pal, 4);  // the moon at its normal brightness
    sc->tex_x = sc->plate_x;
    sc->tex_y = sc->plate_y;
  } else if (s->wx == WX_STALE) {
    sc->tex = NULL;
    memset(f->tex_pal, GREY_DARK, 4);
  } else {
    sc->tex = &f->tex;
    memcpy(f->tex_pal, f->tex.pal, 4);
    sc->tex_x = TILT_MARGIN + s->tilt_x;
    sc->tex_y = TILT_MARGIN + s->tilt_y;
  }
  sc->tex_pal = f->tex_pal;
  sc->plate_pal = f->plate_pal;

  EdgeStyle style = night ? (s->glow ? STYLE_NIGHT_LIT : STYLE_NIGHT_UNLIT)
                          : (s->border ? STYLE_DAY_BORDER : STYLE_DAY);
  const uint8_t glow = style == STYLE_NIGHT_LIT ? s->glow : 0;
  if (!f->blend_ok || f->blend_style != style || f->blend_glow != glow || memcmp(f->blend_tex_pal, f->tex_pal, 4) ||
      memcmp(f->blend_plate_pal, f->plate_pal, 4)) {
    blend_build(&f->blend, style, glow, f->tex_pal, f->plate_pal);
    f->blend_ok = true;
    f->blend_style = style;
    f->blend_glow = glow;
    memcpy(f->blend_tex_pal, f->tex_pal, 4);
    memcpy(f->blend_plate_pal, f->plate_pal, 4);
  }
  sc->blend = &f->blend;
}
