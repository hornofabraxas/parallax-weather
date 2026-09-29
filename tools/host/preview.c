// Host build of the watch compositor: renders frames from the real resources with the same C code
// the watch runs, for previews and the settings thumbnails. Build with tools/host/build.sh.
//
// preview <resources dir> <out.png> <HHMM> <weather> <phase> [key=value ...]
//   weather: clear partly cloudy rain snow storm fog stale
//   phase:   night morning midday afternoon golden
//   keys:    lit=1  glow=0..4  tilt=X,Y  sun=X,Y  moon=PHASE  hemi=-1  solid=1  border=1  scale=N  plate=RRGGBB
//            single=1 (hour as one centred digit)
//            bg=1 (weather as the background, day and night)  digit=RRGGBB (override its digit colour)
//            round=1 (Round 2: 260 x 260 from the ~gabbro resources, black outside the circle; sun= is in
//            Round 2 px, default 130,40)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#include "face.h"
#include "moon.h"
#include "sky.h"

static int W = 200, H = 228;
static const char *s_tag = "";  // resource file tag, "~gabbro" for Round 2

// name with the platform tag before the extension (the moon is shared, so it has none)
static const char *tagged(const char *name) {
  static char buf[64];
  const char *dot = strrchr(name, '.');
  snprintf(buf, sizeof buf, "%.*s%s%s", (int)(dot - name), name, s_tag, dot);
  return buf;
}

static uint8_t *slurp(const char *dir, const char *name, long *len) {
  char path[1024];
  snprintf(path, sizeof path, "%s/%s", dir, name);
  FILE *f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
  fseek(f, 0, SEEK_END);
  *len = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *b = malloc(*len ? *len : 1);
  if (!b || fread(b, 1, *len, f) != (size_t)*len) exit(1);
  fclose(f);
  return b;
}

static void load_plane(Plane *p, const char *dir, const char *name) {
  long len;
  uint8_t *b = slurp(dir, name, &len);
  plane_header(p, b);
  if (p->w != W + 2 * TILT_MARGIN || p->h != H + 2 * TILT_MARGIN || len != PL2_HEADER + (long)p->stride * p->h) {
    fprintf(stderr, "%s: unexpected size\n", name);
    exit(1);
  }
  p->data = malloc((size_t)p->stride * p->h);
  memcpy(p->data, b + PL2_HEADER, (size_t)p->stride * p->h);
  free(b);
}

static bool file_read(void *ctx, uint32_t off, uint8_t *buf, uint32_t len) {
  FILE *f = ctx;
  return fseek(f, off, SEEK_SET) == 0 && fread(buf, 1, len, f) == len;
}

static void put32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void chunk(FILE *f, const char *type, const uint8_t *data, uint32_t len) {
  uint8_t hdr[8];
  put32(hdr, len);
  memcpy(hdr + 4, type, 4);
  fwrite(hdr, 1, 8, f);
  if (len) fwrite(data, 1, len, f);
  uLong crc = crc32(0, (const Bytef *)type, 4);
  if (len) crc = crc32(crc, data, len);
  uint8_t c[4];
  put32(c, (uint32_t)crc);
  fwrite(c, 1, 4, f);
}
static void write_png(const char *path, const uint8_t *px, int scale) {
  const int w = W * scale, h = H * scale, stride = 1 + 3 * w;
  uint8_t *raw = malloc((size_t)stride * h);
  for (int y = 0; y < h; y++) {
    raw[y * stride] = 0;
    for (int x = 0; x < w; x++) {
      const uint8_t c = px[(y / scale) * W + x / scale];
      uint8_t *o = raw + y * stride + 1 + 3 * x;
      o[0] = ((c >> 4) & 3) * 85;
      o[1] = ((c >> 2) & 3) * 85;
      o[2] = (c & 3) * 85;
    }
  }
  uLongf zlen = compressBound((uLong)stride * h);
  uint8_t *z = malloc(zlen);
  compress2(z, &zlen, raw, (uLong)stride * h, 9);
  FILE *f = fopen(path, "wb");
  fwrite("\x89PNG\r\n\x1a\n", 1, 8, f);
  uint8_t ihdr[13];
  put32(ihdr, w);
  put32(ihdr + 4, h);
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = ihdr[11] = ihdr[12] = 0;
  chunk(f, "IHDR", ihdr, 13);
  chunk(f, "IDAT", z, (uint32_t)zlen);
  chunk(f, "IEND", NULL, 0);
  fclose(f);
  free(raw);
  free(z);
}

static int lookup(const char *s, const char *const *names, int n) {
  for (int i = 0; i < n; i++)
    if (!strcmp(s, names[i])) return i;
  fprintf(stderr, "unknown value %s\n", s);
  exit(2);
}

int main(int argc, char **argv) {
  if (argc < 6) {
    fprintf(stderr, "usage: preview <res> <out.png> <HHMM> <weather> <phase> [key=value ...]\n");
    return 2;
  }
  const char *res = argv[1], *out = argv[2];
  static const char *const WX[] = {"clear", "partly", "cloudy", "rain", "snow", "storm", "fog", "stale"};
  static const char *const PH[] = {"night", "morning", "midday", "afternoon", "golden"};
  FaceState st = {0};
  st.wx = (Weather)lookup(argv[4], WX, 8);
  st.phase = (DayPhase)lookup(argv[5], PH, 5);
  int sun_x = 100, sun_y = 40, moon_phase = 90, hemi = 1, scale = 1, solid = 0, single = 0;
  long flat_plate = -1, digit = -1;
  bool sun_given = false;
  const Geometry *geom = &GEOMETRY[SCREEN_PT2];
  for (int i = 6; i < argc; i++) {
    const char *a = argv[i];
    if (!strcmp(a, "round=1")) {
      geom = &GEOMETRY[SCREEN_ROUND2];
      s_tag = "~gabbro";
    } else if (!strncmp(a, "lit=", 4)) st.glow = (uint8_t)(atoi(a + 4) ? GLOW_FULL : 0);
    else if (!strncmp(a, "glow=", 5)) st.glow = (uint8_t)atoi(a + 5);
    else if (!strncmp(a, "tilt=", 5)) sscanf(a + 5, "%d,%d", &st.tilt_x, &st.tilt_y);
    else if (!strncmp(a, "sun=", 4)) sun_given = sscanf(a + 4, "%d,%d", &sun_x, &sun_y) == 2;
    else if (!strncmp(a, "moon=", 5)) moon_phase = atoi(a + 5);
    else if (!strncmp(a, "hemi=", 5)) hemi = atoi(a + 5);
    else if (!strncmp(a, "solid=", 6)) solid = atoi(a + 6);
    else if (!strncmp(a, "border=", 7)) st.border = atoi(a + 7) != 0;
    else if (!strncmp(a, "scale=", 6)) scale = atoi(a + 6);
    else if (!strncmp(a, "single=", 7)) single = atoi(a + 7);
    else if (!strncmp(a, "plate=", 6)) flat_plate = strtol(a + 6, NULL, 16);
    else if (!strncmp(a, "bg=", 3)) st.wx_bg_day = st.wx_bg_night = atoi(a + 3) != 0;
    else if (!strncmp(a, "digit=", 6)) digit = strtol(a + 6, NULL, 16);
    else { fprintf(stderr, "unknown option %s\n", a); return 2; }
  }

  W = geom->w;
  H = geom->h;
  if (!sun_given) sun_x = W / 2;  // centred high in the sky (PT2 100,40)
  static Face face;
  face.map.w = W;
  face.map.h = H;
  face.map.map = malloc(W * H / 2);
  map_clear(&face.map);

  // digits
  long len;
  uint8_t *lay = slurp(res, tagged("layout.bin"), &len);
  Layout L;
  if (len != sizeof L) { fprintf(stderr, "layout.bin: %ld bytes\n", len); return 1; }
  memcpy(&L, lay, sizeof L);
  for (int i = 0; i < 4; i++)
    if (argv[3][i] < '0' || argv[3][i] > '9' || !argv[3][i]) { fprintf(stderr, "time must be HHMM\n"); return 2; }
  const int hh = (argv[3][0] - '0') * 10 + argv[3][1] - '0', mm = (argv[3][2] - '0') * 10 + argv[3][3] - '0';
  for (int row = 0; row < 2; row++) {
    const int v = row ? mm : hh;
    const bool one = row == 0 && single && v < 10;
    for (int which = 0; which < (one ? 1 : 2); which++) {
      const int d = one ? v : which ? v % 10 : v / 10;
      char name[32];
      snprintf(name, sizeof name, "digit_%d.bin", d);
      uint8_t *g = slurp(res, tagged(name), &len);
      int x, y;
      face_digit_origin(&L, row, v, one, which, g[2], &x, &y);
      if (!map_stamp(&face.map, g, (int)len, x, y)) { fprintf(stderr, "bad glyph %d\n", d); return 1; }
      free(g);
    }
  }

  // plate
  const int PW = W + 2 * TILT_MARGIN, PH_ = H + 2 * TILT_MARGIN;
  face.plate.w = PW;
  face.plate.h = PH_;
  face.plate.stride = (PW + 3) / 4;
  face.plate.data = calloc(face.plate.stride, PH_);
  if (flat_plate >= 0) {
    const uint8_t c = 0xC0 | ((flat_plate >> 22) & 3) << 4 | ((flat_plate >> 14) & 3) << 2 | ((flat_plate >> 6) & 3);
    memset(face.plate.pal, c, 4);
  } else if (st.phase == PHASE_NIGHT) {
    char path[1024];
    snprintf(path, sizeof path, "%s/moon.pl2", res);
    FILE *f = fopen(path, "rb");
    if (!f || !moon_render(&face.plate, TILT_MARGIN, file_read, f, moon_phase, hemi, &geom->moon)) {
      fprintf(stderr, "moon failed\n");
      return 1;
    }
    fclose(f);
  } else {
    uint8_t *sb = slurp(res, tagged("sky.bin"), &len);
    SkyTables t;
    t.n_grad = sb[0] | sb[1] << 8;
    t.n_bloom = sb[2] | sb[3] << 8;
    t.grad = (const uint16_t *)(sb + 4);
    t.bloom = t.grad + t.n_grad;
    uint8_t ramp[4];
    const int n = sky_ramp(st.phase, st.wx, solid, ramp);
    sky_render(&face.plate, TILT_MARGIN, ramp, n, sky_glow(st.wx, solid), sun_x, sun_y, &t);
  }

  // texture
  static const char *const TEX[] = {"tex_sunny.pl2", "tex_partly.pl2", "tex_cloudy.pl2", "tex_rain.pl2", "tex_snow.pl2",
                                    "tex_storm.pl2", "tex_fog.pl2", "tex_partly_night.pl2", "tex_cloudy_night.pl2"};
  const TextureId tid = face_texture(&st);
  if (tid != TEX_NONE) load_plane(&face.tex, res, tagged(TEX[tid]));

  Scene sc;
  face_scene(&face, &st, &sc);
  if (digit >= 0 && face_weather_bg(&st)) {
    // colour trials: the same scene with another digit colour
    memset(face.tex_pal, 0xC0 | ((digit >> 22) & 3) << 4 | ((digit >> 14) & 3) << 2 | ((digit >> 6) & 3), 4);
    blend_build(&face.blend, face.blend_style, face.blend_glow, face.tex_pal, face.plate_pal);
  }
  uint8_t *px = malloc((size_t)W * H);
  for (int y = 0; y < H; y++) compose_row(&sc, y, 0, W - 1, px + y * W);
  if (geom == &GEOMETRY[SCREEN_ROUND2]) {
    // what the round display shows: pixel centres inside the circle
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) {
        const int dx = 2 * x + 1 - W, dy = 2 * y + 1 - H;
        if (dx * dx + dy * dy > W * W) px[y * W + x] = 0xC0;
      }
  }
  write_png(out, px, scale);
  return 0;
}
