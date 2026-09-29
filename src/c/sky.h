// Day plate and sun: which phase of the day it is, where the sun is, and the sky bitmap.
// Portable (see platform.h); integer maths only.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#include "engine.h"

typedef enum { PHASE_NIGHT = 0, PHASE_MORNING, PHASE_MIDDAY, PHASE_AFTERNOON, PHASE_GOLDEN } DayPhase;

// Weather states, the WX_STATE wire values (spec "Weather states and textures").
typedef enum { WX_CLEAR = 0, WX_PARTLY, WX_CLOUDY, WX_RAIN, WX_SNOW, WX_STORM, WX_FOG, WX_STALE, WX_COUNT } Weather;

// SUN_TIMES events, per day. 0 = does not happen that day.
enum { SUN_DAWN = 0, SUN_RISE10, SUN_RISE, SUN_NOON, SUN_SET, SUN_SET10, SUN_DUSK, SUN_EVENTS };

typedef struct {
  int32_t t[2][SUN_EVENTS];  // today, tomorrow (unix seconds)
  int8_t peak;               // today's peak elevation, degrees
} SunTimes;

// The watch keeps working offline on the last two days it was sent: once now is past tomorrow's
// local day, both days roll forward by whole days (they drift a few minutes a day).
void sun_roll(const SunTimes *in, int32_t now, SunTimes *out);
DayPhase sun_phase(const SunTimes *s, int32_t now);

// The sun's arc on one screen (spec "Sun position"): x = left + span f, y = base - amp k sin(pi f).
// While the sun is down it waits at the side it set on (or will rise on), at y = below.
typedef struct {
  int16_t left, span, base, amp, below;
} SunPath;
// Sun centre in screen px.
void sun_position(const SunTimes *s, int32_t now, const SunPath *path, int *x, int *y);

// Precomputed curves (resource sky.bin, see tools/pack.py), Q16:
//   grad[i]  = (i / (n_grad - 1)) ^ 1.3            vertical gradient, i = screen row
//   bloom[j] = 1 inside the disc, else 0.97 exp(-(d - 12) / 44) with d = j / 2 px
typedef struct {
  uint16_t n_grad, n_bloom;
  const uint16_t *grad, *bloom;
} SkyTables;

// Fills out[] with the ramp (top of the sky first) and returns its length (1 = solid sky).
int sky_ramp(DayPhase phase, Weather wx, bool solid, uint8_t out[4]);
// Whether the plate carries the sun bloom (never with the sunny texture: no second sun).
bool sky_glow(Weather wx, bool solid);

// Renders the sky into p (already sized and allocated), whose pixel (margin, margin) is screen (0, 0).
void sky_render(Plane *p, int margin, const uint8_t *ramp, int n, bool glow, int sun_x, int sun_y,
                const SkyTables *t);
