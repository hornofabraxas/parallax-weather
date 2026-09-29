// Host unit tests for the portable watch modules. Build and run: tools/host/build.sh && build/host/test
// Times use real 2026 epoch values on purpose: sums of two timestamps overflow int32.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "face.h"
#include "moon.h"
#include "sky.h"

static int failures, checks;
#define CHECK(cond, ...)                                  \
  do {                                                    \
    checks++;                                             \
    if (!(cond)) {                                        \
      failures++;                                         \
      printf("FAIL %s:%d: ", __FILE__, __LINE__);         \
      printf(__VA_ARGS__);                                \
      printf("\n");                                       \
    }                                                     \
  } while (0)

#define GC(rgb) ((uint8_t)(0xC0 | (((rgb) >> 22) & 3) << 4 | (((rgb) >> 14) & 3) << 2 | (((rgb) >> 6) & 3)))
#define DAY0 1790553600  // 2026-09-28 00:00 UTC

// A mid-latitude day: dawn 06:00, +10 deg 07:30, rise 06:30, noon 12:30, set 18:30, -10 deg 17:30, dusk 19:00.
static SunTimes day_times(void) {
  SunTimes s = {0};
  s.peak = 55;
  for (int d = 0; d < 2; d++) {
    const int32_t b = DAY0 + d * 86400;
    s.t[d][SUN_DAWN] = b + 6 * 3600;
    s.t[d][SUN_RISE] = b + 6 * 3600 + 1800;
    s.t[d][SUN_RISE10] = b + 7 * 3600 + 1800;
    s.t[d][SUN_NOON] = b + 12 * 3600 + 1800;
    s.t[d][SUN_SET10] = b + 17 * 3600 + 1800;
    s.t[d][SUN_SET] = b + 18 * 3600 + 1800;
    s.t[d][SUN_DUSK] = b + 19 * 3600;
  }
  return s;
}

static void test_phase(void) {
  SunTimes s = day_times();
  const struct { int h, m; DayPhase want; } cases[] = {
    {3, 0, PHASE_NIGHT},      {6, 0, PHASE_MORNING},    {7, 29, PHASE_MORNING},   {7, 30, PHASE_MIDDAY},
    {13, 29, PHASE_MIDDAY},   {13, 30, PHASE_AFTERNOON}, {17, 29, PHASE_AFTERNOON}, {17, 30, PHASE_GOLDEN},
    {18, 59, PHASE_GOLDEN},   {19, 0, PHASE_NIGHT},     {23, 59, PHASE_NIGHT},    {24 + 6, 10, PHASE_MORNING},
  };
  for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
    const int32_t now = DAY0 + cases[i].h * 3600 + cases[i].m * 60;
    const DayPhase got = sun_phase(&s, now);
    CHECK(got == cases[i].want, "phase at %02d:%02d = %d, want %d", cases[i].h, cases[i].m, got, cases[i].want);
  }
  // polar night: the sun never reaches civil twilight
  SunTimes p = {0};
  p.peak = -8;
  CHECK(sun_phase(&p, DAY0 + 12 * 3600) == PHASE_NIGHT, "polar night");
  // midnight sun that dips below +10: no dawn or dusk, so golden hour instead of night
  SunTimes m = {0};
  m.peak = 40;
  for (int d = 0; d < 2; d++) {
    const int32_t b = DAY0 + d * 86400;
    m.t[d][SUN_RISE10] = b + 4 * 3600;
    m.t[d][SUN_NOON] = b + 12 * 3600;
    m.t[d][SUN_SET10] = b + 21 * 3600;
  }
  CHECK(sun_phase(&m, DAY0 + 2 * 3600) == PHASE_GOLDEN, "midnight sun before rise10: %d", sun_phase(&m, DAY0 + 2 * 3600));
  CHECK(sun_phase(&m, DAY0 + 23 * 3600) == PHASE_GOLDEN, "midnight sun after set10");
  // short high-latitude day: SET10 comes before noon + 1 h, so no afternoon after golden hour
  SunTimes h = {0};
  h.peak = 8;
  h.t[0][SUN_DAWN] = DAY0 + 9 * 3600; h.t[0][SUN_RISE10] = DAY0 + 11 * 3600; h.t[0][SUN_NOON] = DAY0 + 12 * 3600;
  h.t[0][SUN_SET10] = DAY0 + 12 * 3600 + 56 * 60; h.t[0][SUN_DUSK] = DAY0 + 15 * 3600 + 15 * 60;
  CHECK(sun_phase(&h, DAY0 + 13 * 3600 + 1800) == PHASE_GOLDEN, "short day stays golden: %d", sun_phase(&h, DAY0 + 13 * 3600 + 1800));
  // the sun never reaches the threshold (peak 0): morning while rising, golden after noon
  SunTimes z = {0};
  z.peak = 0;
  z.t[0][SUN_DAWN] = DAY0 + 10 * 3600; z.t[0][SUN_NOON] = DAY0 + 12 * 3600; z.t[0][SUN_DUSK] = DAY0 + 14 * 3600;
  CHECK(sun_phase(&z, DAY0 + 11 * 3600) == PHASE_MORNING && sun_phase(&z, DAY0 + 13 * 3600 + 1800) == PHASE_GOLDEN,
        "low sun day: morning then golden");
  // offline for two days: the last times roll forward instead of sticking on night
  SunTimes r;
  sun_roll(&s, DAY0 + 2 * 86400 + 12 * 3600, &r);
  CHECK(sun_phase(&r, DAY0 + 2 * 86400 + 12 * 3600) == PHASE_MIDDAY, "rolled noon is midday");
  sun_roll(&s, DAY0 + 20 * 3600, &r);
  CHECK(r.t[0][SUN_NOON] == s.t[0][SUN_NOON], "no roll while the data is current");
  sun_roll(&s, DAY0 + 4 * 86400 + 3 * 3600, &r);
  CHECK(sun_phase(&r, DAY0 + 4 * 86400 + 3 * 3600) == PHASE_NIGHT && r.t[1][SUN_DAWN] > DAY0 + 4 * 86400, "rolled night");
}

static void test_sun_position(void) {
  SunTimes s = day_times();
  int x, y;
  sun_position(&s, DAY0 + 6 * 3600 + 1800, &GEOMETRY[SCREEN_PT2].sun, &x, &y);
  CHECK(x == 18 && y == 212, "sunrise at (%d,%d)", x, y);
  sun_position(&s, DAY0 + 12 * 3600 + 1800, &GEOMETRY[SCREEN_PT2].sun, &x, &y);
  CHECK(x == 100 && y >= 212 - 206 * 55 / 60 - 1 && y <= 212 - 206 * 55 / 60 + 1, "noon at (%d,%d)", x, y);
  sun_position(&s, DAY0 + 3 * 3600, &GEOMETRY[SCREEN_PT2].sun, &x, &y);
  CHECK(x == 18 && y == 240, "before sunrise at (%d,%d)", x, y);
  sun_position(&s, DAY0 + 20 * 3600, &GEOMETRY[SCREEN_PT2].sun, &x, &y);
  CHECK(x == 182 && y == 240, "after sunset at (%d,%d)", x, y);
  // midnight sun: no rise or set, the sun stays up and peaks at noon
  SunTimes m = {0};
  m.peak = 44;
  m.t[0][SUN_NOON] = DAY0 + 12 * 3600;
  sun_position(&m, DAY0 + 12 * 3600, &GEOMETRY[SCREEN_PT2].sun, &x, &y);
  CHECK(x == 100 && y < 120, "midnight sun at noon (%d,%d)", x, y);
  // just after local midnight, with today's noon late in the day (DST, west of the zone meridian)
  m.t[0][SUN_NOON] = DAY0 + 13 * 3600 + 1800;
  sun_position(&m, DAY0 + 1800, &GEOMETRY[SCREEN_PT2].sun, &x, &y);
  CHECK(y < 228, "midnight sun after local midnight still up (%d,%d)", x, y);
  m.t[0][SUN_NOON] = DAY0 + 12 * 3600;
  sun_position(&m, DAY0 + 1 * 3600, &GEOMETRY[SCREEN_PT2].sun, &x, &y);
  CHECK(x < 40 && y < 228, "midnight sun at 01:00 still up (%d,%d)", x, y);
  s.peak = 10;  // winter: arc flattened to k = 0.35
  sun_position(&s, DAY0 + 12 * 3600 + 1800, &GEOMETRY[SCREEN_PT2].sun, &x, &y);
  CHECK(y >= 212 - 73 - 1 && y <= 212 - 72 + 1, "winter noon y %d", y);
}

// Round 2: the sun's whole disc (12 px) stays inside the circle while it is up, whatever the day
// length or peak, and is hidden while it is down.
static void test_round2_sun(void) {
  const SunPath *p = &GEOMETRY[SCREEN_ROUND2].sun;
  const int c = GEOMETRY[SCREEN_ROUND2].w / 2, in = (c - 12) * (c - 12), out = (c + 12) * (c + 12);
  SunTimes s = day_times();
  int x, y, worst = 0;
  for (int peak = 1; peak <= 90; peak += 7) {
    s.peak = (int8_t)peak;
    for (int32_t t = s.t[0][SUN_RISE]; t < s.t[0][SUN_SET]; t += 600) {
      sun_position(&s, t, p, &x, &y);
      const int d2 = (x - c) * (x - c) + (y - c) * (y - c);
      if (d2 > worst) worst = d2;
    }
  }
  CHECK(worst <= in, "Round 2 sun disc inside the circle (worst centre distance^2 %d, limit %d)", worst, in);
  sun_position(&s, DAY0 + 3 * 3600, p, &x, &y);
  CHECK((x - c) * (x - c) + (y - c) * (y - c) >= out, "Round 2 sun hidden before sunrise (%d,%d)", x, y);
  sun_position(&s, DAY0 + 20 * 3600, p, &x, &y);
  CHECK((x - c) * (x - c) + (y - c) * (y - c) >= out, "Round 2 sun hidden after sunset (%d,%d)", x, y);
}

static void test_blend(void) {
  BlendTable t;
  const uint8_t tex[4] = {GC(0x000000), GC(0xAA0000), GC(0xFF5500), GC(0xFFAA00)};
  const uint8_t plate[4] = {GC(0xFFFFAA), GC(0xFFFFAA), GC(0xFFFFAA), GC(0xFFFFAA)};
  blend_build(&t, STYLE_DAY, 0, tex, plate);
  CHECK(t.lut[CODE_WINDOW * 16 + 2 * 4] == GC(0xFF5500), "window shows texture");
  CHECK(t.lut[CODE_PLATE * 16 + 2 * 4] == GC(0xFFFFAA), "plate shows plate");
  CHECK(t.lut[5 * 16] == GC(0xFFFFAA), "day: no ring outside the glyph");
  // black meeting pale yellow at 1/3 and 2/3 lands between them, never off hue
  const uint8_t e1 = t.lut[CODE_EDGE_1_3 * 16], e2 = t.lut[CODE_EDGE_2_3 * 16];
  CHECK(e1 != GC(0x000000) && e1 != GC(0xFFFFAA) && e2 != e1, "edges step between (%02X %02X)", e1, e2);
  CHECK((e1 & 3) <= 2 && (e2 & 3) <= 2, "edge blue channel stays between 0 and 2");

  const uint8_t moon[4] = {GC(0x000000), GC(0x555555), GC(0x555555), GC(0x555555)};
  blend_build(&t, STYLE_NIGHT_LIT, GLOW_FULL, tex, moon);
  CHECK(t.lut[1 * 16] == GC(0xAAFFFF), "lit ring 0");
  CHECK(t.lut[6 * 16] == GC(0x00AAAA), "lit ring 1 (bin 6, 2.5..3 px)");
  CHECK(t.lut[10 * 16] == GC(0x005555), "lit ring 2 (bin 10, 4.5..5 px)");
  CHECK(t.lut[12 * 16] != GC(0x005555) && t.lut[12 * 16] != GC(0xAAFFFF), "ring 2 fades into plate at 5.5 px");
  blend_build(&t, STYLE_NIGHT_UNLIT, 0, tex, moon);
  CHECK(t.lut[3 * 16] == GC(0x55FFFF), "unlit border");
  CHECK(t.lut[6 * 16] == GC(0x000000), "unlit: plate beyond 2.5 px");
  const uint8_t c[2] = {GC(0xFF0000), GC(0x0000FF)}, w[2] = {6, 6};
  const uint8_t mid = blend_pick(c, w, 2);
  CHECK(mid == GC(0xFF0000) || mid == GC(0x0000FF) || mid == GC(0xAA00AA) || mid == GC(0x550055) ||
            mid == GC(0xAA0055) || mid == GC(0x5500AA),
        "half red half blue picks a purple or an endpoint (%02X)", mid);
}

static void test_stamp(void) {
  uint8_t buf[20 * 10 / 2];
  ScreenMap m = {20, 10, buf};
  map_clear(&m);
  // 3 x 2 glyph: row 0 = [15 15 1], row 1 = [13 2 0]
  const uint8_t g[] = {3, 2, 1, 0xF1, 0x10, 0xD0, 0x20, 0x00};
  CHECK(map_stamp(&m, g, sizeof g, -1, 0), "stamp");
  CHECK(map_code(&m, 0, 0) == 15 && map_code(&m, 1, 0) == 1 && map_code(&m, 0, 1) == 2, "clipped left edge");
  CHECK(map_stamp(&m, g, sizeof g, 0, 0), "stamp again");
  CHECK(map_code(&m, 0, 0) == 15 && map_code(&m, 1, 0) == 15, "window beats distance");
  CHECK(map_code(&m, 0, 1) == 13, "edge beats distance");
  CHECK(map_code(&m, 2, 0) == 1 && map_code(&m, 1, 1) == 2, "nearer distance kept");
  CHECK(map_stamp(&m, g, sizeof g, 18, 9), "stamp at bottom right");
  CHECK(map_code(&m, 19, 9) == 15, "clipped bottom right");
  const uint8_t bad[] = {3, 2, 1, 0xF3};
  CHECK(!map_stamp(&m, bad, sizeof bad, 0, 0), "run past row end rejected");
  const uint8_t shortg[] = {3, 2, 1, 0xF2};
  CHECK(!map_stamp(&m, shortg, sizeof shortg, 0, 0), "truncated glyph rejected");
}

// A synthetic moon source: 64 x 64, the whole canvas at index 2 (bright) so the mask is visible.
static uint8_t moon_src[PL2_HEADER + 16 * 64];
static bool mem_read(void *ctx, uint32_t off, uint8_t *buf, uint32_t len) {
  (void)ctx;
  if (off + len > sizeof moon_src) return false;
  memcpy(buf, moon_src + off, len);
  return true;
}
static int lit_count(int phase, int hemi, int *left, int *right) {
  memset(moon_src, 0xAA, sizeof moon_src);
  const uint8_t hdr[PL2_HEADER] = {64, 0, 64, 0, GC(0), GC(0x555555), GC(0xAAAAAA), GC(0xAAAAAA)};
  memcpy(moon_src, hdr, PL2_HEADER);
  static uint8_t data[16 * 64];
  Plane p = {64, 64, 16, {0}, data};
  const MoonLayout L = {64, 64, 32, 32, 32, 20};
  bool ok = moon_render(&p, 0, mem_read, NULL, phase, hemi, &L);
  int n = 0;
  *left = *right = 0;
  for (int y = 0; y < 64; y++)
    for (int x = 0; x < 64; x++)
      if (plane_px(&p, x, y)) {
        n++;
        if (x < 32) (*left)++; else (*right)++;
      }
  return ok ? n : -1;
}

static void test_moon(void) {
  int l, r;
  const int full = lit_count(180, 1, &l, &r);
  CHECK(full > 1200 && full < 1300, "full moon lights the disc (%d px, pi*20^2 = 1257)", full);
  CHECK(lit_count(0, 1, &l, &r) == 0, "new moon is dark");
  const int q1 = lit_count(90, 1, &l, &r);
  CHECK(q1 > 580 && q1 < 680 && l == 0, "first quarter: right half (%d, left %d)", q1, l);
  lit_count(270, 1, &l, &r);
  CHECK(r == 0 && l > 580, "last quarter: left half (left %d right %d)", l, r);
  lit_count(90, -1, &l, &r);
  CHECK(r == 0 && l > 580, "southern first quarter: left half");
  lit_count(45, 1, &l, &r);
  CHECK(l == 0 && r > 100 && r < 400, "waxing crescent: a sliver on the right (%d)", r);
  CHECK(moon_lit_right(10, 1) && !moon_lit_right(200, 1) && !moon_lit_right(10, -1), "lit side");
}

static void test_face(void) {
  static Face f;
  static uint8_t td[16], pd[16], md[8];
  f.tex = (Plane){4, 4, 1, {GC(0x0055AA), GC(0x5555AA), GC(0xAAAAFF), GC(0xFFFFFF)}, td};
  f.plate = (Plane){4, 4, 1, {GC(0x000000), GC(0x555555), GC(0xAAAAAA), GC(0xAAAAAA)}, pd};
  f.map = (ScreenMap){4, 4, md};
  FaceState s = {.wx = WX_CLEAR, .phase = PHASE_NIGHT, .glow = GLOW_FULL, .tilt_x = 13, .tilt_y = -9};
  Scene sc;
  face_scene(&f, &s, &sc);
  CHECK(sc.tex == &f.plate, "clear night: windows look at the moon");
  CHECK(sc.tex_pal[2] == GC(0xAAAAAA) && sc.plate_pal[2] == GC(0x555555), "moon dims around the windows only");
  CHECK(sc.plate_x == TILT_MARGIN + 9 && sc.plate_y == TILT_MARGIN - 7 && sc.tex_x == sc.plate_x, "moon moves as one");
  s.wx = WX_RAIN;
  face_scene(&f, &s, &sc);
  CHECK(sc.tex == &f.tex && sc.plate_x == TILT_MARGIN && sc.tex_x == TILT_MARGIN + 13, "other nights: moon still");
  s.phase = PHASE_MIDDAY;
  s.glow = 0;
  s.tilt_x = 13;
  s.tilt_y = -9;
  face_scene(&f, &s, &sc);
  CHECK(sc.plate_x == TILT_MARGIN + 5 && sc.plate_y == TILT_MARGIN - 3, "day plate at 0.35x (%d,%d)", sc.plate_x, sc.plate_y);
  CHECK(sc.plate_pal[2] == GC(0xAAAAAA), "no dimming by day");
  s.wx = WX_STALE;
  face_scene(&f, &s, &sc);
  CHECK(sc.tex == NULL && sc.tex_pal[0] == GC(0x555555), "stale weather: flat grey");
  CHECK(face_texture(&(FaceState){.wx = WX_PARTLY, .phase = PHASE_NIGHT}) == TEX_PARTLY_NIGHT, "night clouds");
  CHECK(face_texture(&(FaceState){.wx = WX_CLEAR, .phase = PHASE_NIGHT}) == TEX_NONE, "clear night: no texture");
  CHECK(face_texture(&(FaceState){.wx = WX_SNOW, .phase = PHASE_NIGHT}) == TEX_SNOW, "snow by night uses day texture");
  s = (FaceState){.wx = WX_RAIN, .phase = PHASE_MIDDAY, .border = true};
  face_scene(&f, &s, &sc);
  CHECK(f.blend_style == STYLE_DAY_BORDER, "border on by day");
  s.phase = PHASE_NIGHT;
  face_scene(&f, &s, &sc);
  CHECK(f.blend_style == STYLE_NIGHT_UNLIT, "the border setting does not touch the night border");

  // weather as the background
  s = (FaceState){.wx = WX_RAIN, .phase = PHASE_MIDDAY, .tilt_x = 13, .tilt_y = -9, .wx_bg_day = true};
  CHECK(face_weather_bg(&s) && face_plate_kind(&s) == PLATE_NONE, "day weather background: no sky to draw");
  face_scene(&f, &s, &sc);
  CHECK(sc.plate == &f.tex && sc.tex == NULL, "the texture is the plate, the digits are solid");
  CHECK(sc.plate_x == TILT_MARGIN + 13 && sc.plate_y == TILT_MARGIN - 9, "the background takes the full tilt");
  CHECK(sc.tex_pal[0] == face_digit_colour(TEX_RAIN) && sc.tex_pal[3] == sc.tex_pal[0], "digits in the rain colour");
  CHECK(!memcmp(sc.plate_pal, f.tex.pal, 4), "background in its own palette");
  s.phase = PHASE_NIGHT;
  CHECK(!face_weather_bg(&s) && face_plate_kind(&s) == PLATE_MOON, "night setting is separate");
  s.wx_bg_night = true;
  s.glow = GLOW_FULL;
  const Plane day_tex = f.tex;
  f.tex.pal[2] = GC(0xAAAAAA);  // the shade the moon dims: a texture showing it must keep it
  face_scene(&f, &s, &sc);
  CHECK(sc.plate == &f.tex && sc.plate_pal[2] == GC(0xAAAAAA) && sc.dim_level == 0, "a night texture never dims");
  s.glow = 2;
  face_scene(&f, &s, &sc);
  CHECK(sc.plate_pal_dim == NULL && sc.dim_level == 0, "no dimming fade on a texture");
  f.tex = day_tex;
  s.wx = WX_CLEAR;
  s.glow = GLOW_FULL;
  CHECK(face_plate_kind(&s) == PLATE_MOON, "clear night falls back to the moon");
  face_scene(&f, &s, &sc);
  CHECK(sc.plate == &f.plate && sc.tex == NULL && sc.tex_pal[0] == face_digit_colour(TEX_NONE), "solid digits over the moon");
  CHECK(sc.plate_pal[2] == GC(0x555555) && sc.plate_x == TILT_MARGIN + 9, "that moon dims and tilts as usual");
  s.wx = WX_STALE;
  face_scene(&f, &s, &sc);
  CHECK(!face_weather_bg(&s) && sc.tex == NULL && sc.tex_pal[0] == GC(0x555555), "stale looks the same in both modes");
  // every digit colour is an opaque Pebble colour
  for (int t = TEX_NONE; t < TEX_COUNT; t++) CHECK((face_digit_colour((TextureId)t) & 0xC0) == 0xC0, "colour %d opaque", t);
}

static void test_ramps(void) {
  uint8_t r[4];
  CHECK(sky_ramp(PHASE_MORNING, WX_RAIN, false, r) == 4 && r[0] == GC(0xAAAAFF) && r[3] == GC(0xFFFFFF), "morning");
  CHECK(sky_ramp(PHASE_MIDDAY, WX_CLOUDY, false, r) == 2 && r[0] == GC(0xFFFFAA), "cloudy midday tint");
  CHECK(sky_ramp(PHASE_GOLDEN, WX_CLEAR, false, r) == 3 && r[0] == GC(0xFFFF55), "sunny golden tint");
  CHECK(sky_ramp(PHASE_AFTERNOON, WX_FOG, true, r) == 1 && r[0] == GC(0xFFFFAA), "solid afternoon");
  CHECK(!sky_glow(WX_CLEAR, false) && sky_glow(WX_RAIN, false) && !sky_glow(WX_RAIN, true), "glow rules");
}

// The straightforward per-pixel compositor the run-based one replaced; they must agree exactly.
static void compose_row_ref(const Scene *s, int y, int x0, int x1, uint8_t *out) {
  for (int x = x0; x <= x1; x++) {
    const int code = map_code(s->map, x, y);
    const int ti = s->tex ? plane_px(s->tex, x + s->tex_x, y + s->tex_y) : 0;
    const int pi = plane_px(s->plate, x + s->plate_x, y + s->plate_y);
    static const int RANK[2][2] = {{0, 2}, {3, 1}};
    if (code == CODE_WINDOW) out[x] = s->tex_pal[ti];
    else if (code == CODE_PLATE && s->dim_level && RANK[y & 1][x & 1] < s->dim_level) out[x] = s->plate_pal_dim[pi];
    else if (code == CODE_PLATE) out[x] = s->plate_pal[pi];
    else out[x] = s->blend->lut[code * 16 + ti * 4 + pi];
  }
}

static void test_compose_equivalence(void) {
  enum { MW = 40, MH = 12, PW = MW + 32, PH = MH + 32 };
  static uint8_t map[MW * MH / 2], tex[(PW / 4) * PH], plate[(PW / 4) * PH];
  ScreenMap m = {MW, MH, map};
  Plane tp = {PW, PH, PW / 4, {GC(0x0055AA), GC(0x5555AA), GC(0xAAAAFF), GC(0xFFFFFF)}, tex};
  Plane pp = {PW, PH, PW / 4, {GC(0xFFFFAA), GC(0xFFFFFF), GC(0xAAFFFF), GC(0xFFFFFF)}, plate};
  BlendTable bt;
  blend_build(&bt, STYLE_NIGHT_LIT, 2, tp.pal, pp.pal);
  uint32_t seed = 12345;
  int bad = 0;
  for (int round = 0; round < 300; round++) {
    for (size_t i = 0; i < sizeof map; i++) {
      seed = seed * 1103515245 + 12345;
      const int r = (seed >> 16) & 7;  // long runs of 0x00 / 0xFF with scattered edge codes
      map[i] = r < 3 ? 0x00 : r < 6 ? 0xFF : (uint8_t)(seed >> 8);
    }
    for (size_t i = 0; i < sizeof tex; i++) tex[i] = (uint8_t)(seed = seed * 1103515245 + 12345) >> 3;
    for (size_t i = 0; i < sizeof plate; i++) plate[i] = (uint8_t)((seed = seed * 1103515245 + 12345) >> 5);
    // offsets cover the full tilt range: texture +-13 x +-9, plate +-9 x +-7 (clear-night moon)
    Scene sc = {&m, round % 7 ? &tp : NULL, tp.pal, 16 + round % 27 - 13, 16 + round % 19 - 9, &pp, pp.pal,
                16 + round % 19 - 9, 16 + round % 15 - 7, &bt, tp.pal, (uint8_t)(round % 4)};
    for (int y = 0; y < MH; y++) {
      uint8_t a[MW], b[MW];
      const int x0 = round % 3, x1 = MW - 1 - round % 4;
      compose_row(&sc, y, x0, x1, a);
      compose_row_ref(&sc, y, x0, x1, b);
      if (memcmp(a + x0, b + x0, (size_t)(x1 - x0 + 1))) bad++;
    }
  }
  CHECK(bad == 0, "run-based compositor matches the per-pixel one (%d rows differ)", bad);
}

static void test_glow_ramp(void) {
  BlendTable t;
  const uint8_t tex[4] = {GC(0x000000), GC(0x555555), GC(0xAAAAAA), GC(0xAAAAAA)};
  const uint8_t moon[4] = {GC(0x000000), GC(0x555555), GC(0x555555), GC(0x555555)};
  uint8_t ring1[GLOW_FULL + 1];
  for (int g = 0; g <= GLOW_FULL; g++) {
    blend_build(&t, STYLE_NIGHT_LIT, g, tex, moon);
    ring1[g] = t.lut[6 * 16];  // 2.5..3 px out, over a black plate pixel
  }
  CHECK(ring1[0] == GC(0x000000) && ring1[GLOW_FULL] == GC(0x00AAAA), "ring 1 fades from plate to teal");
  CHECK(ring1[GLOW_FULL / 2] != ring1[0] || ring1[GLOW_FULL / 2 + 1] != ring1[0], "the ramp has in-between steps");
  blend_build(&t, STYLE_NIGHT_LIT, 0, tex, moon);
  BlendTable u;
  blend_build(&u, STYLE_NIGHT_UNLIT, 0, tex, moon);
  CHECK(!memcmp(t.lut, u.lut, sizeof t.lut), "glow 0 looks exactly like the unlit border");
}

int main(void) {
  test_compose_equivalence();
  test_glow_ramp();
  test_phase();
  test_sun_position();
  test_round2_sun();
  test_blend();
  test_stamp();
  test_moon();
  test_face();
  test_ramps();
  printf("%d checks, %d failures\n", checks, failures);
  return failures != 0;
}
