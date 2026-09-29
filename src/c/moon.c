#include "moon.h"

#include "platform.h"

bool moon_lit_right(int phase, int hemisphere) { return (phase < 180) != (hemisphere < 0); }

static uint32_t isqrt(uint32_t v) {
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

#define MAX_SRC_ROW 128  // bytes: a source row segment as wide as the plate (<= 512 px)

bool moon_render(Plane *dst, int margin, MoonRead reader, void *ctx, int phase, int hemisphere,
                 const MoonLayout *L) {
  uint8_t header[PL2_HEADER];
  if (!reader(ctx, 0, header, PL2_HEADER)) return false;
  Plane src;
  plane_header(&src, header);
  for (int i = 0; i < 4; i++) dst->pal[i] = src.pal[i];
  if (dst->w / 4 + 2 > MAX_SRC_ROW) return false;

  phase = ((phase % 360) + 360) % 360;
  const bool right = moon_lit_right(phase, hemisphere), south = hemisphere < 0;
  const int cx = right ? L->cx_lit_right : L->cx_lit_left, cy = L->cy;
  const int mc_x = src.w / 2, mc_y = src.h / 2;  // the disc is centred on the source canvas
  // Terminator: with p' = 0 (new) .. 180 (full) and s = +1 when the lit limb is on the right,
  // a pixel at x from the centre is lit when s * x > w(y) * cos(p'), w = the disc's half width.
  const int pp = phase <= 180 ? phase : 360 - phase;
  const int32_t cosp = cos_lookup(pp * TRIG_MAX_ANGLE / 360);
  const int s = right ? 1 : -1;
  const int32_t r2 = 4 * L->radius * L->radius;  // (2R)^2, half px units

  uint8_t seg[MAX_SRC_ROW];
  for (int y = 0; y < dst->h; y++) {
    uint8_t *row = dst->data + y * dst->stride;
    for (int i = 0; i < dst->stride; i++) row[i] = 0;
    const int ly = y - margin - cy;  // row relative to the disc centre
    const int sy = south ? mc_y - 1 - ly : mc_y + ly;
    if (sy < 0 || sy >= src.h) continue;
    // source columns this row needs: dst x -> lx = x - margin - cx -> sx = mc_x + lx (north)
    const int lx0 = -margin - cx, lx1 = dst->w - 1 - margin - cx;
    int sx0 = south ? mc_x - 1 - lx1 : mc_x + lx0, sx1 = south ? mc_x - 1 - lx0 : mc_x + lx1;
    if (sx0 < 0) sx0 = 0;
    if (sx1 >= src.w) sx1 = src.w - 1;
    if (sx0 > sx1) continue;
    const int b0 = sx0 >> 2, b1 = sx1 >> 2;
    if (!reader(ctx, PL2_HEADER + (uint32_t)sy * src.stride + b0, seg, (uint32_t)(b1 - b0 + 1))) return false;
    // phase mask for this row, in half px
    const int32_t yc = 2 * ly + 1, rest = r2 - yc * yc;
    const int32_t half = rest > 0 ? (int32_t)isqrt((uint32_t)rest) : 0;  // disc half width
    const int32_t xt = (int32_t)((int64_t)half * cosp / TRIG_MAX_RATIO);
    for (int x = 0; x < dst->w; x++) {
      const int lx = x - margin - cx;
      const int sx = south ? mc_x - 1 - lx : mc_x + lx;
      if (sx < sx0 || sx > sx1) continue;
      const int32_t xc = 2 * lx + 1;
      if (rest <= 0 || xc > half || xc < -half || s * xc <= xt) continue;  // off the disc or unlit: black
      const int v = (seg[(sx >> 2) - b0] >> (6 - 2 * (sx & 3))) & 3;
      row[x >> 2] |= (uint8_t)(v << (6 - 2 * (x & 3)));
    }
  }
  return true;
}
