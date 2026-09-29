#include "engine.h"

#include <string.h>

void plane_header(Plane *p, const uint8_t header[PL2_HEADER]) {
  p->w = (uint16_t)(header[0] | header[1] << 8);
  p->h = (uint16_t)(header[2] | header[3] << 8);
  p->stride = (uint16_t)((p->w + 3) / 4);
  memcpy(p->pal, header + 4, 4);
}

// ---------------------------------------------------------------- screen map

void map_clear(ScreenMap *m) { memset(m->map, 0, (size_t)m->w * m->h / 2); }

// Priority when two glyphs' codes meet: inside beats edge beats nearer distance beats plate.
static int rank(int code) {
  if (code >= CODE_EDGE_1_3) return code + 1;
  if (code == CODE_PLATE) return 0;
  return 14 - code;
}

bool map_stamp(ScreenMap *m, const uint8_t *rle, int len, int x0, int y0) {
  if (len < 3) return false;
  const int w = rle[0], h = rle[1];
  int i = 3;
  for (int gy = 0; gy < h; gy++) {
    const int y = y0 + gy;
    const bool row_on = y >= 0 && y < m->h;
    uint8_t *row = m->map + (row_on ? (size_t)y * m->w / 2 : 0);
    int gx = 0;
    while (gx < w) {
      if (i >= len) return false;
      const int code = rle[i] >> 4, n = (rle[i] & 15) + 1;
      i++;
      if (gx + n > w) return false;
      if (row_on && code != CODE_PLATE) {
        const int r = rank(code);
        for (int k = 0; k < n; k++) {
          const int x = x0 + gx + k;
          if (x < 0 || x >= m->w) continue;
          uint8_t *b = row + (x >> 1);
          const int old = (x & 1) ? (*b & 15) : (*b >> 4);
          if (rank(old) >= r) continue;
          *b = (x & 1) ? (uint8_t)((*b & 0xF0) | code) : (uint8_t)((*b & 0x0F) | code << 4);
        }
      }
      gx += n;
    }
  }
  return true;
}

// ---------------------------------------------------------------- blend table

static inline int ch_r(uint8_t c) { return ((c >> 4) & 3) * 85; }
static inline int ch_g(uint8_t c) { return ((c >> 2) & 3) * 85; }
static inline int ch_b(uint8_t c) { return (c & 3) * 85; }

static uint32_t isqrt32(uint32_t v) {
  uint32_t r = 0, bit = 1u << 30;
  while (bit > v) bit >>= 2;
  while (bit) {
    if (v >= r + bit) {
      v -= r + bit;
      r = (r >> 1) + bit;
    } else {
      r >>= 1;
    }
    bit >>= 2;
  }
  return r;
}

uint8_t colour_darken(uint8_t c) {
  int r = (c >> 4) & 3, g = (c >> 2) & 3, b = c & 3;
  r = r ? r - 1 : 0;
  g = g ? g - 1 : 0;
  b = b ? b - 1 : 0;
  return (uint8_t)(0xC0 | r << 4 | g << 2 | b);
}

int colour_lum(uint8_t c) { return 299 * ch_r(c) + 587 * ch_g(c) + 114 * ch_b(c); }

uint8_t blend_pick(const uint8_t *colours, const uint8_t *weights, int n) {
  // the mix, in units of 1/total of a channel step of 1/255
  uint32_t total = 0;
  int r = 0, g = 0, b = 0;
  for (int i = 0; i < n; i++) {
    total += weights[i];
    r += weights[i] * ch_r(colours[i]);
    g += weights[i] * ch_g(colours[i]);
    b += weights[i] * ch_b(colours[i]);
  }
  // face.swift: cost = sqrt(2 dr^2 + 4 dg^2 + 3 db^2) / 3 + (present ? 0 : 20), in 0..255 units.
  // Scaled by 3 * total the penalty is 60 * total. The best present and best absent colours are
  // found on squared distances, so only two square roots are taken.
  uint32_t best_in = UINT32_MAX, best_out = UINT32_MAX;
  uint8_t in = 0, out = 0;
  for (int k = 0; k < 64; k++) {
    const uint8_t c = (uint8_t)(0xC0 | k);
    const int dr = r - (int)total * ch_r(c), dg = g - (int)total * ch_g(c), db = b - (int)total * ch_b(c);
    const uint32_t d = 2u * (uint32_t)(dr * dr) + 4u * (uint32_t)(dg * dg) + 3u * (uint32_t)(db * db);
    bool present = false;
    for (int i = 0; i < n; i++) present |= weights[i] && (colours[i] | 0xC0) == c;
    if (present && d < best_in) best_in = d, in = c;
    if (!present && d < best_out) best_out = d, out = c;
  }
  if (best_in == UINT32_MAX) return out;
  if (best_out == UINT32_MAX) return in;
  const uint32_t cost_in = isqrt32(best_in), cost_out = isqrt32(best_out) + 60 * total;
  return cost_in < cost_out || (cost_in == cost_out && in < out) ? in : out;
}

// Zones outside the glyph edge, as (outer boundary in quarter px, colour role). The last zone is
// the plate and runs to infinity.
enum { ROLE_PLATE, ROLE_DARK_PLATE, ROLE_RING0, ROLE_RING1, ROLE_RING2 };
typedef struct {
  uint8_t n;
  uint8_t bound_q[3];  // quarter px
  uint8_t role[4];
} Zones;

static const Zones ZONES[] = {
  [STYLE_DAY] = {1, {0}, {ROLE_PLATE}},
  [STYLE_DAY_BORDER] = {2, {4}, {ROLE_DARK_PLATE, ROLE_PLATE}},
  [STYLE_NIGHT_UNLIT] = {2, {8}, {ROLE_RING0, ROLE_PLATE}},
  [STYLE_NIGHT_LIT] = {4, {8, 14, 22}, {ROLE_RING0, ROLE_RING1, ROLE_RING2, ROLE_PLATE}},
};
#define GC(rgb) ((uint8_t)(0xC0 | (((rgb) >> 22) & 3) << 4 | (((rgb) >> 14) & 3) << 2 | (((rgb) >> 6) & 3)))

// A zone's colour at full glow, and what it shows with no glow (the unlit border, or the plate).
static uint8_t role_colour(EdgeStyle style, int role, uint8_t plate, bool unlit) {
  switch (role) {
    case ROLE_DARK_PLATE: return colour_darken(plate);
    case ROLE_RING0: return style == STYLE_NIGHT_LIT && !unlit ? GC(0xAAFFFF) : GC(0x55FFFF);
    case ROLE_RING1: return unlit ? plate : GC(0x00AAAA);
    case ROLE_RING2: return unlit ? plate : GC(0x005555);
    default: return plate;
  }
}

static int clampi(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

typedef struct {
  uint8_t n, cols[8], wts[8];  // weights in 48ths
} Mix;

static void mix_add(Mix *m, uint8_t c, int w) {
  if (w <= 0) return;
  for (int i = 0; i < m->n; i++)
    if (m->cols[i] == c) {
      m->wts[i] = (uint8_t)(m->wts[i] + w);
      return;
    }
  m->cols[m->n] = c;
  m->wts[m->n++] = (uint8_t)w;
}

// Adds zone zi with weight w (a multiple of 4), split between its lit and unlit colours by glow.
static void mix_zone(Mix *m, EdgeStyle style, int glow, int role, uint8_t plate, int w) {
  if (style != STYLE_NIGHT_LIT) {
    mix_add(m, role_colour(style, role, plate, false), w);
    return;
  }
  mix_add(m, role_colour(style, role, plate, false), w * glow / GLOW_FULL);
  mix_add(m, role_colour(style, role, plate, true), w - w * glow / GLOW_FULL);
}

void blend_build(BlendTable *t, EdgeStyle style, int glow, const uint8_t tex_pal[4], const uint8_t plate_pal[4]) {
  const Zones *z = &ZONES[style];
  glow = clampi(glow, 0, GLOW_FULL);
  for (int ti = 0; ti < 4; ti++) {
    for (int pi = 0; pi < 4; pi++) {
      const uint8_t tex = tex_pal[ti] | 0xC0, plate = plate_pal[pi] | 0xC0;
      // palettes repeat their last colour: reuse an identical column already built
      int same = -1;
      for (int k = 0; k < ti * 4 + pi && same < 0; k++)
        if ((tex_pal[k / 4] | 0xC0) == tex && (plate_pal[k % 4] | 0xC0) == plate) same = k;
      for (int code = 0; code < 16; code++) {
        if (same >= 0) {
          t->lut[code * 16 + ti * 4 + pi] = t->lut[code * 16 + same];
          continue;
        }
        Mix m = {0};
        if (code == CODE_PLATE) {
          mix_add(&m, plate, 48);
        } else if (code >= CODE_EDGE_1_3) {
          const int in = code == CODE_WINDOW ? 48 : code == CODE_EDGE_2_3 ? 32 : 16;
          mix_add(&m, tex, in);
          mix_zone(&m, style, glow, z->role[0], plate, 48 - in);
        } else {
          // bin centre (2k - 1) / 4 px; a zone ending at b covers clamp(b - centre + 1/2, 0, 1)
          const int centre_q = 2 * code - 1;
          int covered = 0;  // quarters already given to inner zones
          for (int zi = 0; zi < z->n; zi++) {
            const int upto = zi < z->n - 1 ? clampi(z->bound_q[zi] - centre_q + 2, 0, 4) : 4;
            if (upto > covered) mix_zone(&m, style, glow, z->role[zi], plate, 12 * (upto - covered));
            if (upto > covered) covered = upto;
          }
        }
        t->lut[code * 16 + ti * 4 + pi] = blend_pick(m.cols, m.wts, m.n);
      }
    }
  }
}

// ---------------------------------------------------------------- compositor

// Copies n pixels of a 2-bit plane row, starting at plane x, through a palette.
static void fill_run(uint8_t *out, const uint8_t *row, int sx, int n, const uint8_t *pal) {
  const uint8_t *p = row + (sx >> 2);
  int sh = 6 - 2 * (sx & 3);
  uint32_t b = *p;
  while (n-- > 0) {
    *out++ = pal[(b >> sh) & 3];
    if (sh) {
      sh -= 2;
    } else if (n) {  // never read past the run's last byte
      b = *++p;
      sh = 6;
    }
  }
}

// fill_run for a plate that is part way through fading to plate_pal_dim.
static void fill_run_fade(uint8_t *out, const uint8_t *row, int sx, int x, int y, int n, const Scene *s) {
  static const uint8_t RANK[2][2] = {{0, 2}, {3, 1}};
  for (int i = 0; i < n; i++, sx++, x++) {
    const int v = (row[sx >> 2] >> (6 - 2 * (sx & 3))) & 3;
    out[i] = (RANK[y & 1][x & 1] < s->dim_level ? s->plate_pal_dim : s->plate_pal)[v];
  }
}

void compose_row(const Scene *s, int y, int x0, int x1, uint8_t *out) {
  const ScreenMap *m = s->map;
  const uint8_t *mrow = m->map + (size_t)y * m->w / 2;
  const Plane *tp = s->tex, *pp = s->plate;
  const uint8_t *trow = tp ? tp->data + (size_t)(y + s->tex_y) * tp->stride : NULL;
  const uint8_t *prow = pp->data + (size_t)(y + s->plate_y) * pp->stride;
  const uint8_t *lut = s->blend->lut;
  int x = x0;
  while (x <= x1) {
    const int code = (x & 1) ? (mrow[x >> 1] & 15) : (mrow[x >> 1] >> 4);
    if (code == CODE_PLATE || code == CODE_WINDOW) {
      // most of the screen is long runs of plate or window: copy them straight through
      const uint8_t both = code == CODE_PLATE ? 0x00 : 0xFF;
      int e = x + 1;
      while (e <= x1) {
        if (!(e & 1) && e + 1 <= x1 && mrow[e >> 1] == both) {
          e += 2;
          continue;
        }
        if (((e & 1) ? (mrow[e >> 1] & 15) : (mrow[e >> 1] >> 4)) != code) break;
        e++;
      }
      if (code == CODE_PLATE && s->dim_level) {
        fill_run_fade(out + x, prow, x + s->plate_x, x, y, e - x, s);
      } else if (code == CODE_PLATE) {
        fill_run(out + x, prow, x + s->plate_x, e - x, s->plate_pal);
      } else if (trow) {
        fill_run(out + x, trow, x + s->tex_x, e - x, s->tex_pal);
      } else {
        for (int i = x; i < e; i++) out[i] = s->tex_pal[0];
      }
      x = e;
      continue;
    }
    int ti = 0;
    if (trow) {
      const int tx = x + s->tex_x;
      ti = (trow[tx >> 2] >> (6 - 2 * (tx & 3))) & 3;
    }
    const int px = x + s->plate_x;
    const int pi = (prow[px >> 2] >> (6 - 2 * (px & 3))) & 3;
    out[x] = lut[code * 16 + ti * 4 + pi];
    x++;
  }
}
