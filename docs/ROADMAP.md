# Build roadmap

Each stage ends with a code review and fixes before anything is tagged.

| Stage | Goal | Status |
| --- | --- | --- |
| 0 | Repo, spec snapshot, credits | done |
| 1 | Emulator prototype on `emery`: asset exporter, compositor, sky plate, moon phase, backlight + tilt, measurements for every item on the spec's verification checklist | done |
| 2 | Phone side: Open-Meteo weather, solar times, moon phase, AppMessage protocol, settings page | done (emulator round trip verified) |
| 3 | Full review pass, CI, first tagged build for the wrist | review done; wrist build next |
| 4 | OFL font and full-moon image swapped in; Round 2 (`gabbro`) layout | done (Round 2 verified in the emulator; wrist check open) |

## Stage 1 design notes

These are implementation choices made while building the prototype. Anything that changes
what the face looks like is listed under "Decisions" instead.

- **One compositor for every mode.** A 4-bit screen map (one nibble per pixel, 22,800 bytes on
  emery) is stamped once a minute from the four digit sprites. Code 0 is plate, 15 is window,
  13 and 14 are the glyph edge at 1/3 and 2/3 coverage, and 1 to 12 are distance outside the
  glyph edge in half-pixel bins. A 256-byte table, rebuilt only when a palette changes, maps
  (code, texture colour, plate colour) to the final colour. The same path draws day, night
  unlit (2 px cyan border) and night lit (three glow rings), with anti-aliased ring edges and
  no sprites beyond the ten digits.
- **Edge colours follow the mockup renderer exactly**: the true blend, snapped to the nearest
  Pebble colour with a penalty on colours not present in the pixel (`compose()` in
  `tools/face.swift`).
- **Glyph hinting per digit, not per pair.** Each digit is rendered once at its best 1/8 px
  phase; a 100-entry pair table places it on whole pixels, within 0.5 px of the spec's layout.
- **All four digits are re-stamped each minute.** The spec's cache table says only changed digits;
  with overlapping ring distances a full rebuild is simpler and correct, and costs 2 to 7 ms.
- **Clear-night moon tilt** follows the approved mockup (up to 9 x 7 px, about 0.7x), not the spec
  text's 0.35x. Plate and windows move together.
- **Offline beyond two days**, the last sun times roll forward by whole days rather than leaving
  the face on night.
- **No composed-frame cache.** Composing from the cached layers is a single pass over the
  screen; keeping a 45,600-byte copy of the finished frame costs more than it saves. Measured
  in stage 1.

## Stage 1 measurements (emery emulator, 2026-09-28)

Emulator timings are relative only; frame and render times need the watch to confirm.

| Checklist item | Result |
| --- | --- |
| 2-bit alpha glyph blending with `GCompOpSet` | Not needed: the face composes straight into the frame buffer with its own blend table |
| Backlight on/off events in a watchface | Work on emery. The off edge arrives about 4 s after on. A face launched while lit gets no on edge, so init checks `light_is_on()` |
| Accelerometer from a watchface while lit | Works (measured at 25 Hz, 1 sample per update; now 50 Hz, see "Tilt and battery"). Battery cost over 100 flicks: needs the watch |
| Tilt frame time | Compose 1 to 3 ms per frame in the emulator; the 30 ms display push dominates. Needs the watch |
| Palette swap dims the moon | Works (a palette change rebuilds the 256-byte blend table) |
| Resource pack | 196,679 of 262,144 bytes, all art stored raw. As 2-bit PNGs the nine textures would be 52 KB instead of 136 KB |
| Peak heap and largest free block | 120 KB free at start, 65 KB free and 65 KB contiguous with every buffer allocated; a minute's digit stamp borrows at most 3.3 KB |
| App image, no floating point | 9,004 bytes; no soft-float symbols linked |
| Sky plate render time | 2 to 11 ms in the emulator after the stage 3 rewrite (was 31 to 61 ms with 64-bit divides per pixel), a few times an hour |
| Moon render | 17 to 27 ms, at most every couple of hours |

Reference capture from the emulator: `docs/emulator/stage4_live.png` (the stage 1 captures used the mockup font and were removed before the public release).

## Decisions (2026-09-28)

- **Waning moon placement:** mirrored to centre (140, 114) when the lit limb is on the left. Kept.
- **12 hour mode:** leading zero ("08"), like 24 hour mode.
- **Timeline Peek:** the peek simply covers the lower half of the minutes; the face is peek-aware
  only so PebbleOS+ never squishes it.
- **Font:** Inter Display Black (OFL), from the Inter 4.1 release.
- **Moon:** NASA SVS "Moon Phase and Libration, 2026", the full moon of 26 Sep 2026. Its tone
  settings are retuned for a full disc (black point 0.35, gamma 1.0; the spec's 0.18 and 0.8 were
  set on the half-moon photo and wash a full moon out to flat grey).

Still open: moon dimming by palette swap vs the lit mockup (check on the wrist), the stale-weather
look, the face's final name.

## Phone protocol (stage 2)

The watch asks, the phone answers; nothing is pushed unprompted except settings.

| Key | Direction | Type | Meaning |
| --- | --- | --- | --- |
| `READY` | phone to watch | uint8 | The phone's JS is running. The watch sends no request before this, since it would be lost |
| `REQUEST` | watch to phone | uint8 bitmask | 1 = weather, 2 = sun and moon |
| `WX_STATE`, `WX_TIME` | phone to watch | uint8, uint32 | Weather state 0 to 6 (the watch decides day or night) and observation time |
| `WX_FAILED` | phone to watch | uint8 | No location or weather; the watch retries after 15 minutes |
| `SUN_TIMES` | phone to watch | 56-byte array | 14 x int32 LE: today's then tomorrow's seven events, 0 = does not happen |
| `SUN_PEAK` | phone to watch | int8 | Today's peak elevation, degrees |
| `MOON_PHASE`, `MOON_TIME` | phone to watch | uint16, uint32 | Elongation 0 to 359 at that time; the watch advances it by the mean lunar month |
| `HEMISPHERE` | phone to watch | int8 | +1 north, -1 south |
| `CFG_BORDER`, `CFG_SKY`, `CFG_TILT`, `CFG_REFRESH` | phone to watch | uint8 | Settings; location settings stay on the phone |
| `CFG_BG` | phone to watch | uint8 bitmask | 1 = weather as the day background, 2 = at night (v0.3.0) |

Request rules (all persisted, so relaunching the face refetches nothing young): weather when older
than the refresh setting; sun and moon once per local day; an unanswered request blocks the next
for 15 minutes.

Timeline Peek: the face registers as peek-aware so PebbleOS+ never squishes it; the peek covers
the bottom 59 px, which hides the lower half of the minutes. How the digits should behave during
a peek is an open question.

## Stage 3 review (2026-09-28)

Three independent reviews (watch C, phone JS, asset pipeline), then a fourth pass over the fixes
themselves; every verified finding was fixed.

| Area | Fixed |
| --- | --- |
| Watch | Polar night (all 14 events 0) was read as "no data": clock-guess sky and a request every minute. Sky data now counts once the phone answers, and the retry gate is per requested item |
| Watch | Offline past two days stuck on night: sun times roll forward |
| Watch | Short high-latitude days showed afternoon after golden hour; days whose sun never reaches the threshold skipped golden hour |
| Watch | Midnight sun hid the sun all day (and, after the first fix, for up to 2.5 h after local midnight) |
| Watch | Sky renderer: four 64-bit divides per pixel removed (identical output across 2,744 cases) |
| Phone | Sun day picked by the phone's calendar date as a UTC date: wrong day in Samoa, Kiritimati, or with a remote manual location |
| Phone | Busy flag could stick for the session; no watchdogs; requests dropped while busy; READY not retried |
| Phone | Sun times not resent after travel (spec: "on location change") |
| Phone | Settings only reached the watch when saved; READY now carries them, so a reset store recovers |
| Phone | Settings page ignored `return_to` in the query (emulator config); no inline lat/lon validation |
| Pipeline | Glyph distance codes 1/8 px long on right and bottom edges; moon diameter could drift from the watch's; packer and preview lacked size checks; `shot.py` PPM parsing; CI link flag and tool pin |

## Tilt and battery (v0.2.0, 2026-09-29)

The tilt no longer follows spec steps 1 to 3 literally; the spec's look is unchanged.

- **Origin:** the pose when the light came on (the first accelerometer sample that is not a buzz),
  fixed for the whole lit period. A 250 ms settle window and a slow recentring drift were tried
  after the first wrist test and removed: on the wrist the late recentre read as the face lagging.
  If a flick-lit origin often sits off the rest pose, that is the thing to revisit.
- **Sampling:** 50 Hz, one sample per callback, a 1/2 low-pass; every sample that moves the whole-
  pixel offset past a 10/16 px hysteresis redraws straight away (no animation timer). Full offset
  at about 17 degrees.
- **Stop:** light-off stops the tilt and recentres. Six seconds in, and every second after, the
  tilt stops by itself only if the light is really off (30 s hard cap), so a light kept on by a
  second flick never snaps back in view.
- **Night glow:** ramps in over four 60 ms steps. By day the light costs no timers and no frame.
- **Notifications:** the tilt pauses while a modal covers the face (app focus) and resumes if the
  light is still on when it closes; a night glow under a notification jumps straight to full.
- **No idle frames:** `refresh()` redraws only when the picture changed (weather, phase, border,
  texture, plate, digits). Settings resent with every READY, and weather replies with the same
  weather, cost no frame and (for settings) no flash write.

Review of these changes plus the unreviewed tilt and compositor commits: no bugs; four minor
items fixed (snap at the old 6 s hard stop, glow ramp under a notification, tilt setting turned
on while lit, focus flag on `did_focus(false)`) and the compositor equivalence test now covers
the full tilt range.

Emulator light cycling (100 plus on/off cycles) turned up one fault, only in `PERF_LOG` builds and
already in v0.1: the app faulted inside the firmware (PC 0xb501c) about one light-off in ten. It was
blamed on the `PERF_LOG` heap probe at the time; v1.1 found the real cause, a firmware bug in
accelerometer unsubscribe (see "v1.1: accelerometer unsubscribe crash" below). The slow logging
only made it more likely.

Considered and not done:
- **Sun position steps.** The sky re-renders when the sun moves a pixel (every few minutes, 2 to
  11 ms). Rounding to 2 px would halve that but moves the sun in visible jumps.
- **Partial recompose.** The frame buffer persists, so a minute tick could recompose only the
  changed rows. PT2 pushes all 228 rows whatever was drawn, the compose is 1 to 3 ms, and a
  notification or peek clobbering the buffer would need its own invalidation. Not worth it.
- **Cached digit sprites.** Four resource reads and a 2 to 7 ms stamp a minute; the display push
  dwarfs it.

## Weather as the background (v0.3.0, 2026-09-29)

Two settings, day and night, each choosing between the original look (sky or moon plate, weather
through the digits) and the weather texture as the background with solid digits. Simple toggles
for now; a preview image per option on the settings page is planned once the look is final.

- **Digits:** one colour per texture, picked by eye from trial renders (every candidate scored
  first by worst-case contrast against each texture colour covering 3% or more of the screen).
  They live in `src/c/face.c` as `DIGIT_*`:

  | Background | Digits |
  | --- | --- |
  | Sunny (black sky, red and orange sun) | `#AAFFFF` |
  | Partly cloudy, cloudy (day) | `#000055` |
  | Rain | `#FFFF55` |
  | Snow | `#FFFFFF` |
  | Storm | `#FFAA00` |
  | Fog | `#FF5500` |
  | Partly cloudy night | `#FFFFAA` |
  | Cloudy night | `#FFFF55` |
  | Clear night (moon) | `#FFFFFF` |

- **Parallax:** the background takes the full texture offset (13 x 9 px). No zoom was needed: every
  texture already carries 16 px beyond each screen edge.
- **Clear night** has no texture, so the moon stays behind the digits (moon tilt, dims while lit);
  the digits are solid white. A weather texture never dims.
- **Night edges:** the cyan unlit border and the lit glow rings work as before.
- **Day border** setting still applies (Adaptive draws the border when the digit colour is light).
- **Stale weather** looks the same in both modes (flat grey digits over the sky or moon).
- **Cost:** no new assets or buffers; the plate buffer is simply not drawn, so this mode skips the
  sky render (2 to 11 ms a few times an hour) and, on every night that is not clear, the moon
  render.
- The stored settings grew a byte (`STORE_VERSION` 3): the first launch after updating refetches
  the weather and sky, and the phone resends the settings with READY.

## Settings page with thumbnails (2026-09-29)

- Every visual option is chosen by tapping its thumbnail: Day background, Sky style, Digit border,
  Night background. The thumbnails come from the watch's own compositor (`tools/thumbs.py`,
  lossless WebP: 200 x 228 frames, 64 x 64 crops for the border since a 1 px line vanishes at
  thumbnail size), about 30 KB of base64 in `src/pkjs/thumbs.js`; the page is a 43 KB data URL.
  Rerun the tool whenever an option's look changes.
- Sky style is hidden while the day background is Weather (it has no effect there); its value
  is kept. Latitude and longitude show only in manual mode.
- Look: black page, the night border cyan `#55FFFF` for selection (with a soft glow like the lit
  rings), the morning sky ramp as a thin rule under the title, segmented controls for the
  non-visual settings, a fixed Save bar. The tilt note says plainly that bright light keeps the
  backlight (and so the tilt) off.

## v0.4.0: Parallax Weather (2026-09-29)

- **Name:** Parallax Weather (app, settings page, GitHub repo `hornofabraxas/parallax-weather`);
  developer shown in the Pebble app: OmgSlayKween. The UUID is unchanged, so installs upgrade.
- **Border:** Off or On. The adaptive mode is gone (it could not be seen on the watch), with its
  per-pixel neighbour test in the compositor. Stored 1 (adaptive) or 2 (always) from older
  versions reads as On, on the phone and on the watch.
- **Notifications:** the firmware turns the light on for a notification before the face hears it
  lost focus (one kernel pass: push the window, light, then the focus event), so the face used to
  start the accelerometer for a moment behind the notification. Light-on now waits 50 ms; a
  covered face starts neither the tilt nor the glow ramp. Timeline Peek does not take focus.
- **Settings page:** no subtitle, no explainer text, border as two thumbnails, "Moonphase".
- **Credits:** `CREDITS.md` maps every source photo and converted resource to its licence, covers
  the settings thumbnails, and says what to credit when publishing.


## v0.5.0: Round 2 (`gabbro`, 2026-09-29)

The face now builds for Round 2 (260 x 260, round) as well as PT2. Same code, same looks; the art
is rebuilt for the bigger screen and the SDK picks it by file tag (`tex_sunny~gabbro.pl2` beside
`tex_sunny.pl2`), so resource ids and the C code are shared.

- **Digits:** 94 px cap height (PT2 98), chosen so every hour and minute fits the circle. At 98 px,
  14 of the 84 values pushed up to 4 px past the edge (a 2's foot in the minutes, a 7's corner in
  the hours). The block is centred with the same 14 px row gap and -2% tracking: rows at 29 and 137.
  `tools/pack.py` fails the asset build if any ink comes within 1 px of the edge (now 1.9 px).
- **Textures:** 292 x 292 (the screen plus the 16 px tilt margin). Photo crops grow with the texture
  about their centre, so a screen pixel covers the same source pixels as on PT2 and the detail keeps
  its size next to the digits; the scattered snow crystals scale with the area; the fog bank and
  the sun's limb keep their place relative to the minutes row. The rest of the PT2 art regenerates
  byte for byte.
- **Moon:** the same 300 px disc and resource, centred at (120, 130), or (140, 130) when the lit
  limb is on the left. It covers the whole circle; no second moon image (it would not fit: see
  storage).
- **Sun path:** x = 36 + 188 f, y = 196 - 184 k sin(pi f), and y = 238 while the sun is down: the
  whole 12 px disc stays inside the circle for any day length and peak, and is hidden while down
  (host test `test_round2_sun`).
- **Per-screen geometry** (screen, moon placement, sun path) is one table, `GEOMETRY` in
  `src/c/face.c`, shared by the watch and the host tools. `preview ... round=1` renders Round 2 with
  the circle masked; `tools/emu/shot.py out.png 1 gabbro` picks the gabbro emulator when several run.
- **Settings thumbnails:** a second set of Round 2 frames (round, black outside the circle) in
  `src/pkjs/thumbs.js`; the page picks the set from `Pebble.getActiveWatchInfo().platform`,
  remembering the last platform seen for when the watch is out of reach. The phone JS grew by 34 KB;
  the page itself stays about 43 KB.
- **Review fixes:** photo crops are now clamped inside their source photo (shrunk if bigger, slid in
  if past an edge). The cumulus crop overran clouds.jpg on both screens: on PT2 by 16 px, all in the
  tilt margin, so at full downward tilt with the Weather background a flat cloudless strip showed
  along the bottom. That changes the PT2 partly-cloudy textures (day and night), the only PT2 art
  that changed; the cumulus detail is about 1% larger. Also: the CI check that the .pbw holds both
  binaries no longer pipes `unzip` into `grep -q` under pipefail, and the host preview's `round=1`
  no longer overrides an earlier `sun=`.

Emulator measurements (gabbro, 2026-09-29):

| Item | Result |
| --- | --- |
| Resource pack | 251,079 of 262,144 bytes (PT2 196,244). Nine textures at 21 KB each; room for about 11 KB more |
| Heap | 116,640 free at start; 37,092 free after every buffer, 37,088 of it contiguous (PT2 about 65 KB) |
| Frame | 1 to 3 ms compose in the emulator; digits stamp 2 to 7 ms, sky 2 to 5 ms |
| Backlight events | On and off edges arrive in a watchface (off about 4 s after on, as on PT2); the glow ramps in over four steps and the tilt starts and stops with the light |
| Tilt | Accelerometer runs from the face while lit; offset reaches the full -13 px; clear-night moon moves with it |
| All 20 harness looks | Render correctly (`docs/emulator/round2_tour.png`) |

Still for the wrist: frame push and tilt smoothness on the real round display, colours on it, and
battery.

## v1.0: open source (2026-09-29)

- **Licence:** MIT for the code and the generated textures (`LICENSE`); the photographs, their
  converted textures and the Inter font keep their own licences (`CREDITS.md`). Every GitHub
  release carries the image credits (`.github/release-notes.md`).
- **Removed before publishing:** the design mockups and the two early emulator captures, which were
  drawn with SF Pro (Apple's licence covers mockups for Apple platforms only). The README shows
  screenshots from the watch's own compositor instead (`docs/screenshots/`).
- **Scrubbed:** personal names, private links and local paths from the docs; the settings page's
  example coordinates are now Greenwich, and the phone tests use Denver's published sun times.
- **History:** one fresh commit; earlier versions (v0.2.0 to v0.5.0) are not published.

## v1.1: accelerometer unsubscribe crash (2026-10-02)

Rare crashes on the wrist ("not responding" after two within a minute), one while bowling. Cause:
a PebbleOS bug, present since the original Pebble code. If an app unsubscribes from accelerometer
data while a sample batch is still queued for it, the firmware marks the app's accelerometer state
for a deferred free; when that batch is drained with nothing subscribed it calls `kernel_free()` on
memory inside the app's state and the app faults (emulator PC 0xb501c, LR 0x27c2b). The tilt asks
for one sample a batch at 50 Hz, so a batch is often queued, above all while a frame is drawing:
a light-off (or a notification, or the 30 s cap) with the wrist moving was the likely trigger.

| Check | Result |
| --- | --- |
| Test app: subscribe 1 at 50 Hz, busy 60 ms, unsubscribe | Faults on the first cycle, every run |
| Same, then a stand-in session dropped 100 ms later | 154 cycles, no fault |

Fix (`anim_stop`): right after unsubscribing, subscribe a stand-in session (25 samples at 10 Hz,
ignored) and drop it from a 100 ms timer. The stale batch is already queued, so it drains first and
finds a live session; the stand-in cannot fill a batch of its own in 100 ms. `anim_start` drops the
stand-in before subscribing, because subscribing over a live session leaks it in the firmware and
frees the buffer it still writes into. The `PERF_LOG` heap probe no longer skips while the tilt runs.
