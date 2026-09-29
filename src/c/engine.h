// Portable compositor: no Pebble calls, so the same code runs on the watch and in the host
// tests and previews (tools/host). Colours are GColor8 bytes (0b11RRGGBB).
#pragma once
#include <stdbool.h>
#include <stdint.h>

// ---------------------------------------------------------------- 2-bit palettised planes
// Matches the .pl2 resource format written by tools/pack.py.
#define PL2_HEADER 8

typedef struct {
  uint16_t w, h, stride;  // stride = bytes per row = (w + 3) / 4
  uint8_t pal[4];         // GColor8, darkest first
  uint8_t *data;          // h rows, leftmost pixel in the two most significant bits
} Plane;

static inline int plane_px(const Plane *p, int x, int y) {
  return (p->data[y * p->stride + (x >> 2)] >> (6 - 2 * (x & 3))) & 3;
}
static inline void plane_set(Plane *p, int x, int y, int v) {
  uint8_t *b = &p->data[y * p->stride + (x >> 2)];
  int s = 6 - 2 * (x & 3);
  *b = (uint8_t)((*b & ~(3 << s)) | (v << s));
}
// Reads w, h and palette from a .pl2 header; data is left for the caller to fill.
void plane_header(Plane *p, const uint8_t header[PL2_HEADER]);

// ---------------------------------------------------------------- screen map
// One nibble per screen pixel, even x in the high nibble:
//   0 plate, 15 window, 14 / 13 glyph edge at 2/3 and 1/3 cover,
//   1..12 outside the glyph, at distance (k-1)/2 .. k/2 px from its edge.
#define CODE_PLATE 0
#define CODE_WINDOW 15
#define CODE_EDGE_2_3 14
#define CODE_EDGE_1_3 13
#define CODE_BINS 12

typedef struct {
  uint16_t w, h;  // w must be even: every row starts on a byte
  uint8_t *map;   // (w * h) / 2 bytes
} ScreenMap;

static inline int map_code(const ScreenMap *m, int x, int y) {
  uint8_t b = m->map[(y * m->w + x) >> 1];
  return (x & 1) ? (b & 15) : (b >> 4);
}
void map_clear(ScreenMap *m);
// Stamps one run-length glyph (digit_N.bin, see tools/pack.py) with its bitmap's top-left at (x, y).
// Where glyphs overlap, the code closer to a glyph wins. Returns false on a malformed glyph.
bool map_stamp(ScreenMap *m, const uint8_t *rle, int len, int x, int y);

// ---------------------------------------------------------------- blend table
typedef enum {
  STYLE_DAY = 0,         // plate right up to the glyph edge
  STYLE_DAY_BORDER,      // 1 px line in the plate colour darkened one step
  STYLE_NIGHT_UNLIT,     // 2 px #55FFFF border
  STYLE_NIGHT_LIT,       // three glow rings
} EdgeStyle;

// lut[code * 16 + texture index * 4 + plate index] = final colour
typedef struct {
  uint8_t lut[256];
} BlendTable;

#define GLOW_FULL 4  // glow intensity steps: 0 = the unlit border, GLOW_FULL = the three lit rings
// glow only matters for STYLE_NIGHT_LIT, where it fades the rings in from the unlit look.
void blend_build(BlendTable *t, EdgeStyle style, int glow, const uint8_t tex_pal[4], const uint8_t plate_pal[4]);
// The mockup renderer's edge rule (compose() in tools/face.swift): the true mix of up to three
// colours, snapped to the nearest Pebble colour with a penalty on colours not in the mix.
// weights are relative (any total up to 48).
uint8_t blend_pick(const uint8_t *colours, const uint8_t *weights, int n);
uint8_t colour_darken(uint8_t c);
// Rec. 601 luminance, 0..255000
int colour_lum(uint8_t c);

// ---------------------------------------------------------------- compositor
// Palettes are separate from planes so one plane can be shown two ways: on a clear night the
// moon is both the plate (dimmed while lit) and the view through the windows (never dimmed).
typedef struct {
  const ScreenMap *map;
  const Plane *tex;    // NULL = every window pixel is tex_pal[0] (stale weather)
  const uint8_t *tex_pal;
  int tex_x, tex_y;    // plane pixel shown at screen (0, 0)
  const Plane *plate;
  const uint8_t *plate_pal;
  int plate_x, plate_y;
  const BlendTable *blend;  // built from the same tex_pal and plate_pal
  // Fading between two plate palettes (the moon dimming as the glow ramps in): plate pixels whose
  // 2 x 2 ordered-dither rank is below dim_level (1..3) use plate_pal_dim. 0 = off.
  const uint8_t *plate_pal_dim;
  uint8_t dim_level;
} Scene;

// Writes screen row y, pixels x0..x1 inclusive, into out (out[x] is screen pixel x).
void compose_row(const Scene *s, int y, int x0, int x1, uint8_t *out);
