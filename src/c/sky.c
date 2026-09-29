#include "sky.h"

#include "platform.h"

// ---------------------------------------------------------------- phase and sun

void sun_roll(const SunTimes *in, int32_t now, SunTimes *out) {
  *out = *in;
  // reference: tomorrow's solar noon, or its first event when there is no noon
  int32_t ref = in->t[1][SUN_NOON];
  for (int e = 0; !ref && e < SUN_EVENTS; e++)
    if (in->t[1][e] > ref) ref = in->t[1][e];
  if (!ref || now - ref < 43200) return;
  const int32_t days = (now - ref + 43200) / 86400;  // whole days past tomorrow's local day
  for (int e = 0; e < SUN_EVENTS; e++) {
    const int32_t t = in->t[1][e];
    out->t[0][e] = t ? t + (days - 1) * 86400 : 0;
    out->t[1][e] = t ? t + days * 86400 : 0;
  }
}

// The phase that begins at each event; -1 = the event does not change the phase.
static const int8_t STARTS[SUN_EVENTS] = {
  [SUN_DAWN] = PHASE_MORNING, [SUN_RISE10] = PHASE_MIDDAY, [SUN_RISE] = -1, [SUN_NOON] = -1,
  [SUN_SET] = -1, [SUN_SET10] = PHASE_GOLDEN, [SUN_DUSK] = PHASE_NIGHT,
};
#define AFTERNOON_DELAY 3600  // afternoon starts 1 h after solar noon

DayPhase sun_phase(const SunTimes *s, int32_t now) {
  if (s->peak < -6) return PHASE_NIGHT;  // the sun never gets above civil twilight
  // The latest phase-changing event at or before now decides; noon + 1 h counts as an event.
  int32_t best_t = 0, first_t = 0;
  int best = -1, first = -1;
  for (int d = 0; d < 2; d++) {
    for (int e = 0; e < SUN_EVENTS; e++) {
      int32_t t = s->t[d][e];
      int phase = STARTS[e];
      if (e == SUN_NOON && t && !s->t[d][SUN_RISE10] && !s->t[d][SUN_SET10]) {
        phase = PHASE_GOLDEN;  // the sun never reaches the threshold: rising is morning, setting golden
      } else if (e == SUN_NOON && t) {
        t += AFTERNOON_DELAY;
        phase = PHASE_AFTERNOON;
        // short high-latitude days: the sun is already setting before noon + 1 h
        if (s->t[d][SUN_SET10] && t >= s->t[d][SUN_SET10]) continue;
      }
      if (!t || phase < 0) continue;
      if (t <= now && (best < 0 || t > best_t)) {
        best_t = t;
        best = phase;
      }
      if (first < 0 || t < first_t) {
        first_t = t;
        first = phase;
      }
    }
  }
  if (best >= 0) return (DayPhase)best;
  // Before the first event: the phase that precedes it. With no dawn (the sun never drops below
  // -6 degrees) the lowest part of the day is golden hour.
  switch (first) {
    case PHASE_MORNING: return PHASE_NIGHT;
    case PHASE_MIDDAY: return PHASE_GOLDEN;
    case PHASE_AFTERNOON: return PHASE_MIDDAY;
    case PHASE_GOLDEN: return PHASE_AFTERNOON;
    default: return PHASE_NIGHT;
  }
}

void sun_position(const SunTimes *s, int32_t now, const SunPath *path, int *x, int *y) {
  // The rise and set that bracket now, if any; otherwise the side of the screen the sun left
  // from (after sunset) or will rise on (before sunrise).
  int32_t last_t = 0;
  int last = -1, day = -1;
  for (int d = 0; d < 2; d++) {
    for (int e = SUN_RISE; e <= SUN_SET; e += SUN_SET - SUN_RISE) {
      const int32_t t = s->t[d][e];
      if (t && t <= now && (last < 0 || t > last_t)) {
        last_t = t;
        last = e;
        day = d;
      }
    }
  }
  const int left = path->left, span = path->span;
  int32_t f = -1;  // Q16 fraction of the sun's arc, -1 = the sun is down
  if (last == SUN_RISE && s->t[day][SUN_SET] > last_t) {
    const int32_t rise = s->t[day][SUN_RISE], set = s->t[day][SUN_SET];
    f = (int32_t)(((int64_t)(now - rise) << 16) / (set - rise));
  } else if (s->peak > 0) {
    // midnight sun: no rise or set to bracket now, so run the arc from solar midnight to solar
    // midnight around the nearest day's noon (whatever the local clock says)
    for (int d = 0; d < 2 && f < 0; d++) {
      const int32_t noon = s->t[d][SUN_NOON];
      if (noon && !s->t[d][SUN_RISE] && !s->t[d][SUN_SET]) {
        const int32_t since = (int32_t)((((int64_t)now - noon + 43200) % 86400 + 86400) % 86400);
        f = (int32_t)(((int64_t)since << 16) / 86400);
      }
    }
  }
  if (f >= 0) {
    int32_t k = (int32_t)s->peak * 65536 / 60;                                   // Q16
    if (k < 22938) k = 22938;                                                    // 0.35
    if (k > 65536) k = 65536;
    const int32_t sn = sin_lookup((int32_t)((int64_t)f * (TRIG_MAX_ANGLE / 2) >> 16));  // sin(pi f), Q16
    *x = left + (int)((int64_t)span * f >> 16);
    *y = path->base - (int)((int64_t)path->amp * k * sn >> 32);
    return;
  }
  *x = last == SUN_SET ? left + span : left;
  *y = path->below;
}

// ---------------------------------------------------------------- ramps

#define C(rgb) ((uint8_t)(0xC0 | (((rgb) >> 22) & 3) << 4 | (((rgb) >> 14) & 3) << 2 | (((rgb) >> 6) & 3)))

static int copy_ramp(uint8_t out[4], const uint32_t *rgb, int n) {
  for (int i = 0; i < n; i++) out[i] = C(rgb[i]);
  for (int i = n; i < 4; i++) out[i] = out[n - 1];
  return n;
}

int sky_ramp(DayPhase phase, Weather wx, bool solid, uint8_t out[4]) {
  static const uint32_t MORNING[] = {0xAAAAFF, 0xFFAAAA, 0xFFFFAA, 0xFFFFFF};
  static const uint32_t MIDDAY[] = {0x55AAFF, 0xAAFFFF, 0xFFFFFF};
  static const uint32_t AFTERNOON[] = {0x55AAFF, 0xAAFFFF, 0xFFFFAA, 0xFFFFFF};
  static const uint32_t GOLDEN[] = {0xFF5555, 0xFFAA55, 0xFFFF55, 0xFFFFAA};
  // weather-aware tints: sky-coloured textures get a warm pale sky, the orange sun a cool one
  static const uint32_t CLOUD_MORNING[] = {0xFFAAAA, 0xFFFFAA, 0xFFFFFF};
  static const uint32_t CLOUD_DAY[] = {0xFFFFAA, 0xFFFFFF};
  static const uint32_t CLOUD_GOLDEN[] = {0xFFAA55, 0xFFFF55, 0xFFFFAA};
  static const uint32_t SUN_MORNING[] = {0xAAAAFF, 0xAAFFFF, 0xFFFFFF};
  static const uint32_t SUN_DAY[] = {0x55AAFF, 0xAAFFFF, 0xFFFFFF};
  static const uint32_t SUN_GOLDEN[] = {0xFFFF55, 0xFFFFAA, 0xFFFFFF};
  static const uint32_t SOLID[] = {[PHASE_MORNING] = 0xFFAAAA, [PHASE_MIDDAY] = 0xAAFFFF,
                                   [PHASE_AFTERNOON] = 0xFFFFAA, [PHASE_GOLDEN] = 0xFFAA55};
  const uint32_t *r;
  int n;
  const bool cloud = wx == WX_PARTLY || wx == WX_CLOUDY, sun = wx == WX_CLEAR;
  switch (phase) {
    case PHASE_MORNING:
      if (cloud) r = CLOUD_MORNING, n = 3;
      else if (sun) r = SUN_MORNING, n = 3;
      else r = MORNING, n = 4;
      break;
    case PHASE_GOLDEN:
      if (cloud) r = CLOUD_GOLDEN, n = 3;
      else if (sun) r = SUN_GOLDEN, n = 3;
      else r = GOLDEN, n = 4;
      break;
    case PHASE_AFTERNOON:
      if (cloud) r = CLOUD_DAY, n = 2;
      else if (sun) r = SUN_DAY, n = 3;
      else r = AFTERNOON, n = 4;
      break;
    default:
      if (cloud) r = CLOUD_DAY, n = 2;
      else if (sun) r = SUN_DAY, n = 3;
      else r = MIDDAY, n = 3;
      break;
  }
  if (solid) {
    // one flat colour; a weather-tinted sky keeps its tint by using the tinted ramp's top colour
    if (!cloud && !sun) return copy_ramp(out, &SOLID[phase == PHASE_NIGHT ? PHASE_MIDDAY : phase], 1);
    return copy_ramp(out, r, 1);
  }
  return copy_ramp(out, r, n);
}

bool sky_glow(Weather wx, bool solid) { return !solid && wx != WX_CLEAR; }

// ---------------------------------------------------------------- sky bitmap

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

#define ONE 65535
#define SEAM 5243  // 0.08: each band's dithered seam is 2 x 8% of the step between two colours

static const uint8_t BAYER[4][4] = {{0, 8, 2, 10}, {12, 4, 14, 6}, {3, 11, 1, 9}, {15, 7, 13, 5}};

// The terraced dither of face.swift's skyPlate3, for a value v in band k (between colours k and
// k + 1): smoothstep across a narrow seam around the band's middle, compared with a Bayer threshold.
static bool terrace_up(int32_t v, int32_t a, int32_t b, int m) {
  if (b <= a) return v > a;  // two colours of equal luminance: no seam to dither
  int32_t u = (int32_t)((int64_t)(v - a) * ONE / (b - a));
  if (u < 0) u = 0;
  if (u > ONE) u = ONE;
  int32_t e = (int32_t)((int64_t)(u - (ONE / 2 - SEAM)) * ONE / (2 * SEAM));
  if (e < 0) e = 0;
  if (e > ONE) e = ONE;
  const int32_t sm = (int32_t)((int64_t)e * e / ONE * (3 * ONE - 2 * e) / ONE);  // smoothstep
  return sm > (2 * m + 1) * 2048;                                                // (m + 0.5) / 16
}

void sky_render(Plane *p, int margin, const uint8_t *ramp, int n, bool glow, int sun_x, int sun_y,
                const SkyTables *t) {
  for (int i = 0; i < 4; i++) p->pal[i] = ramp[i < n ? i : n - 1];
  // band positions: each colour's luminance, 0 at the top colour and ONE at the last
  int32_t lum[4], tk[4];
  for (int i = 0; i < n; i++) lum[i] = colour_lum(ramp[i]);
  if (n < 2 || lum[n - 1] == lum[0]) {
    for (int i = 0; i < p->h * p->stride; i++) p->data[i] = 0;
    return;
  }
  for (int i = 0; i < n; i++) tk[i] = (int32_t)((int64_t)(lum[i] - lum[0]) * ONE / (lum[n - 1] - lum[0]));
  // Per band and Bayer cell, the smallest v that dithers up to the next colour. The dither is
  // monotonic in v, so the pixel loop only compares (no divisions per pixel).
  int32_t up[3][16];
  for (int k = 0; k + 1 < n; k++) {
    for (int m = 0; m < 16; m++) {
      int32_t lo = tk[k], hi = tk[k + 1] + 1;  // terrace_up(lo) is false, (hi) is true
      if (terrace_up(lo, tk[k], tk[k + 1], m)) hi = lo;
      while (hi - lo > 1) {
        const int32_t mid = lo + (hi - lo) / 2;
        if (terrace_up(mid, tk[k], tk[k + 1], m)) hi = mid; else lo = mid;
      }
      up[k][m] = hi;
    }
  }
  // the gradient ends exactly on a band colour so the horizon is flat
  const int32_t gmax = n >= 4 ? tk[2] : tk[1];
  for (int y = 0; y < p->h; y++) {
    int ys = y - margin;
    if (ys < 0) ys = 0;
    if (ys >= t->n_grad) ys = t->n_grad - 1;
    const int32_t grad = (int32_t)((uint32_t)gmax * t->grad[ys] / ONE);
    const int32_t dy2 = 2 * (y - margin) + 1 - 2 * sun_y;  // half px
    uint8_t *row = p->data + y * p->stride;
    for (int x = 0; x < p->stride; x++) row[x] = 0;
    // distance to the sun in half px, tracked incrementally along the row
    int32_t dx2 = 2 * (0 - margin) + 1 - 2 * sun_x;
    uint32_t j = glow ? isqrt((uint32_t)(dx2 * dx2 + dy2 * dy2)) : 0;
    for (int x = 0; x < p->w; x++, dx2 += 2) {
      int32_t v = grad;
      if (glow) {
        const uint32_t d2 = (uint32_t)(dx2 * dx2 + dy2 * dy2);
        while ((j + 1) * (j + 1) <= d2) j++;
        while (j * j > d2) j--;
        const int32_t bloom = j < t->n_bloom ? t->bloom[j] : 0;
        v = ONE - (int32_t)((uint32_t)(ONE - grad) * (uint32_t)(ONE - bloom) / ONE);
      }
      int k = 0;
      while (k + 1 < n - 1 && v > tk[k + 1]) k++;
      const int idx = k + (v >= up[k][BAYER[y & 3][x & 3]] ? 1 : 0);
      row[x >> 2] |= (uint8_t)(idx << (6 - 2 * (x & 3)));
    }
  }
}
