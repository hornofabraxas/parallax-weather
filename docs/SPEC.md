# Parallax Weather: design spec

Written 2026-09-28, updated through v1.0. Build notes and measurements are in [ROADMAP.md](ROADMAP.md).

## Overview

A full-screen, big-digit watch face for Pebble Time 2 (and later Round 2) where the four digits are windows cut through a plate, showing the current weather behind them. By day the plate is the real sky with the sun in its true position; at night it is the real moon in its real phase. Scope for v1 is time and local weather only.

Design principles that decided everything:

- **Legibility first.** The digits fill the screen and are always the highest-contrast element. Any texture that blurs a digit edge is changed, not the digit.
- **Every pixel is an exact Pebble colour.** Art is designed for the 64-colour palette. Flat areas land exactly on a palette colour; dithering is used only where a gradient or photo detail earns it.
- **Real, not arbitrary.** Sun position, time-of-day colour and moon phase come from the user's location and date, never fixed clock ranges.
- **Motion only when lit.** The face redraws once a minute. The tilt effect and glow run only while the backlight is on.
- **Pure cutouts.** The digits are cutouts with no shading or bevel; a thin border is a setting (on by default since v1.0).

## Platforms and hard limits

Build for PT2 first; keep every size relative so Round 2 is a layout change, not a rewrite.

|  | Pebble Time 2 | Pebble Round 2 |
| --- | --- | --- |
| SDK platform | `emery` | `gabbro` |
| Display | 200 x 228, rectangular, 64 colours | 260 x 260, round, 64 colours |
| App RAM (code and heap share it) | 128 KB | 128 KB |
| App image (.text + .data + .bss) | 65,535 bytes max (uint16 `virtual_size`) | same |
| Resources | 256 KB app store, 1 MB max | same |
| Backlight | Single RGB LED: on/off events + tint via `light_set_color` | White only: on/off events, no tint |
| Accelerometer | Yes | Yes |
| Frame cost | Every render pushes all 228 rows, about 30 ms; animation tick 33 ms | Animation tick 28 ms |

Consequences that shape the code:

- **Code is heap.** Floating point pulls in libgcc soft-float and bloats the image. No floats on the watch: all solar and moon maths runs on the phone; the watch uses integers, fixed point and lookup tables.
- **Free memory is not contiguous memory.** Allocate the big buffers once at startup and reuse them.
- **Partial redraws save nothing on PT2.** The compositor always pushes the full frame, so the win is not rendering at all when nothing changed.

## Layout and digits

Two rows of two digits fill the screen: hours on top, minutes below, no colon, no other text.

| Property | PT2 value |
| --- | --- |
| Digit cap height | 98 px (measured on the flat top of "7") |
| Top row | cap top at y = 9, baseline at y = 107 |
| Bottom row | cap top at y = 121, baseline at y = 219 |
| Row centre | x = 100 (ink extents centred, not advance widths) |
| Tracking | -2% of cap height between the two digits |
| Gap between rows | 14 px |

- **Font.** Mockups used SF Pro Heavy, which cannot ship (Apple licence). Pick an OFL font with similarly heavy, open counters (Avenir-style fonts closed their holes too much). The font is only a source: the ten digits are pre-rendered offline, so the choice costs nothing at runtime.
- **Our own bitmap font.** Each digit is rendered at 8x supersampling into a 2-bit coverage bitmap (4 levels: 0, 1/3, 2/3, 1), matching Pebble's 2-bit alpha. Recolour by swapping the bitmap palette.
- **Hinting.** Cap height is chosen so flat tops and baselines land exactly on pixel rows. Each glyph is also shifted by up to half a pixel (1/8 px steps) to minimise partly covered pixels.
- **12 or 24 hour** follows the phone setting; a leading zero shows in 24 hour mode.
- **Round 2.** 94 px cap height (98 px pushed a 2's foot and a 7's corner up to 4 px past the circle), block centred with the same gap and tracking: cap tops at y = 29 and 137. Every hour and minute keeps its ink inside the circle; the asset build checks it (decided 2026-09-29).

## Rendering model

Every frame is three layers: the plate (sky or moon) at the back, the weather texture, and the digit mask that decides which of the two each pixel shows.

1. **Plate.** Day: sky bitmap for the current phase plus the sun bloom. Night: the moon with its phase applied, dimmed while lit.
2. **Weather texture.** 2 bits per pixel, stored larger than the screen by a tilt margin of 16 px each side (232 x 260 on PT2), so it can shift without running out of image.
3. **Digit mask.** Built once a minute from the four glyph bitmaps. Where the mask is set, the texture shows; elsewhere the plate shows. Edge pixels (coverage 1/3 or 2/3) take a blended colour.
4. **Night border and glow** drawn around the mask, then the optional user border.

Palette rules (these made every mockup work):

- **Edge colours stay between the two colours meeting there.** An edge pixel picks the nearest palette colour to the true blend, but only colours already present or genuinely between them; this stops off-hue fringes. Pebble's four levels per channel are exact thirds, so channel pairs 0 and 255 blend perfectly.
- **Flat areas land exactly on a palette colour** (sky, glass, mist, navy night sky), with a dead zone around the typical tone. Otherwise they dither into a checkerboard.
- **Photos are mapped by brightness onto a small hand-picked ramp** (3 or 4 colours) and dithered with Atkinson (it passes on only 3/4 of the error, so highlights and blacks stay clean). Mapping in full RGB failed.
- **Plate lighter than window by day.** Window content is darker than the plate, and its brightest tones must not approach the plate colour; that is why the sun core is capped at orange.

## Day face

By day the plate is the sky: its colour follows the sun's real elevation at the user's location, and a soft sun bloom sits where the sun actually is.

**Phases come from solar elevation, not the clock.** The phone computes today's and tomorrow's transition times from location and date; the watch only compares the current time against them.

| Phase | Rule (elevation = sun's angle above the horizon) | Sky ramp, top to horizon |
| --- | --- | --- |
| Night | below -6° (after civil dusk, before civil dawn) | night face (moon) |
| Morning | rising, from -6° until 10° | `#AAAAFF` > `#FFAAAA` > `#FFFFAA` > `#FFFFFF` |
| Midday | above 10°, until 1 h after solar noon | `#55AAFF` > `#AAFFFF` > `#FFFFFF` |
| Afternoon | above 10°, from 1 h after solar noon | `#55AAFF` > `#AAFFFF` > `#FFFFAA` > `#FFFFFF` |
| Golden hour | setting, from 10° down to -6° | `#FF5555` > `#FFAA55` > `#FFFF55` > `#FFFFAA` |

- **High latitudes.** If today's peak elevation is under 20°, the 10° threshold becomes half the peak. If the sun never gets above -6°, it is night all day. If it never drops below -6°, there is no night face; the lowest part of the day uses golden hour.
- **Sun position.** Let f = (now - sunrise) / (sunset - sunrise), clamped 0 to 1. Sun x = 18 + 164 f. Sun y = 212 - 206 k sin(pi f), with k = peak elevation / 60 clamped to 0.35 to 1, so winter suns stay low. Before sunrise or after sunset the sun sits just below the bottom edge and only its bloom shows. Use the SDK's integer `sin_lookup`. Round 2: x = 36 + 188 f, y = 196 - 184 k sin(pi f), and y = 238 while down, so the whole disc stays inside the circle while the sun is up.
- **Sky rendering.** A vertical gradient that ends exactly on a band colour, terraced into flat bands with narrow dithered seams (8% of each step), plus a bloom: disc radius 12 px, falloff exp(-(d - 12) / 44). Render on the watch in integer maths with ordered (Bayer 4 x 4) dither into a cached plate buffer, rebuilt only when the phase changes or the sun moves a whole pixel (every few minutes).
- **Weather-aware tints.** When the weather in the windows is sky-coloured or orange, the plate switches to a contrasting ramp:

| Weather | Morning | Midday and afternoon | Golden hour |
| --- | --- | --- | --- |
| Partly cloudy, cloudy | `#FFAAAA` > `#FFFFAA` > `#FFFFFF` | `#FFFFAA` > `#FFFFFF` | `#FFAA55` > `#FFFF55` > `#FFFFAA` |
| Sunny (no bloom, so never two suns) | `#AAAAFF` > `#AAFFFF` > `#FFFFFF` | `#55AAFF` > `#AAFFFF` > `#FFFFFF` | `#FFFF55` > `#FFFFAA` > `#FFFFFF` |
| Rain, snow, storm, fog | phase default | phase default | phase default |

- **Solid sky option.** One flat colour per phase, no bands and no bloom: morning `#FFAAAA`, midday `#AAFFFF`, afternoon `#FFFFAA`, golden hour `#FFAA55`; the weather-aware rule picks a contrasting solid the same way.
- **Tilt.** While lit, the plate shifts at 0.35 x the texture's offset, reading as a far layer.

## Night face

At night the plate is a large photographic moon in its real phase; the digits keep showing the weather, framed by a thin cyan border that becomes a neon glow when the light comes on.

- **Moon image.** Public-domain photo, disc detected automatically, sharpened (unsharp 0.7 over a 1 px blur), black point 0.18, white point 0.90, gamma 0.8, Atkinson dithered onto `#000000` `#555555` `#AAAAAA`. The brightest tone stays at `#AAAAAA` so light digits and borders always stand clear of it.
- **Placement.** 300 px across, centre at (60, 114) on PT2, so the lit side fills the right two thirds of the screen. Stored with a 12 px margin for the clear-night tilt. Round 2 uses the same image centred at (120, 130), so the disc covers the whole circle.
- **Phase.** The mockups used a half-moon photo; the build needs a full-moon source with the phase applied on the watch. The unlit part is masked to black using the terminator ellipse from the phone's phase angle, mirrored in the southern hemisphere. Recompute once an hour.
- **Dimming.** While lit, the moon remaps `#AAAAAA` to `#555555` (a palette swap, not a second image).
- **Clear night.** The digits look through to the moon at normal brightness while the plate moon stays dimmed; with the tilt, both move together as one moon behind the digits.
- **Other weathers.** The moon stays still; only the texture in the digits moves.
- **No brightening.** Textures in the digits are never brightened at night. Partly cloudy and cloudy use night versions (below); rain, snow, storm and fog use their day textures.

| Border state | Rings outside the digit edge |
| --- | --- |
| Unlit | 2 px `#55FFFF` |
| Lit | 0 to 2 px `#AAFFFF`, 2 to 3.5 px `#00AAAA`, 3.5 to 5.5 px `#005555` |

The border and glow rings are pre-rendered per digit offline, as small 2-bit sprites with a transparent entry.

## Weather states and textures

Seven day states and a clear-night state, mapped from Open-Meteo WMO weather codes; every texture is 2 bits per pixel at 232 x 260 (PT2, including the 16 px tilt margin) or 292 x 292 (Round 2; photo crops grow with the texture so the detail keeps its size next to the digits).

| State | WMO codes | Day texture | Night texture |
| --- | --- | --- | --- |
| Sunny / clear | 0, 1 | NASA SDO sun limb, fiery | Clear night: the moon (see Night face) |
| Partly cloudy | 2 | Front-lit cumulus, white on blue | Same clouds, silver on navy |
| Cloudy | 3 | Dense mackerel sky, blue and white | Same, grey and slate on navy |
| Rain | 51 to 67, 80 to 82 | Grey droplets on grey glass | Same as day |
| Snow | 71 to 77, 85, 86 | Grey crystals on grey glass (generated) | Same as day |
| Storm | 95 to 99 | NOAA lightning | Same as day |
| Fog | 45, 48 | Low bank over the bottom digits (generated) | Same as day |

Processing, exactly as mocked (all dithering Atkinson unless noted):

- **Sunny.** `SDO_20140611_000908_4096_0304_(AIA).jpg`. Rotated crop: the limb point at 160° from disc centre (2048, 2048, radius 1593) is placed at screen (100, 152) with its outward normal pointing up; crop width 1800 source px; 3 x 3 supersampled. Unsharp 0.6. t = ((l - 0.015) / (p98 - 0.015))^0.5; above the limb t = max(t, 0.42 exp(-h / 34)) for a red corona. Ramp `#000000` `#AA0000` `#FF5500` `#FFAA00`.
- **Partly cloudy.** `Clouds_and_blue_sky_in_Russia._IMG_110.jpg`, crop x 0.10, y 0.05, width 0.60 of the image. Unsharp 0.5, stretch 2nd to 98th percentile; values under 0.45 snap to flat sky, the rest span 0.25 to 1. Day ramp `#0055AA` `#5555AA` `#AAAAFF` `#FFFFFF`; night ramp `#000055` `#555555` `#5555AA` `#AAAAAA`; strength 0.8.
- **Cloudy.** Mackerel sky photo (James St. John), crop x 0.20, y 0.20, width 0.50; flatten (subtract a 28 px box blur), unsharp 0.5; values under 0.22 snap to sky. Same day and night ramps as partly cloudy; strength 0.8.
- **Rain.** `Raindrops_on_the_glass.jpg`, crop x 0.15, y 0, width 0.58. Flatten (18 px box blur, 3 passes), unsharp 0.5, stretch 2nd to 98th percentile, then the median snaps to the middle level with a 0.08 dead zone so the glass is flat. Ramp `#000000` `#555555` `#AAAAAA`.
- **Snow (generated).** 40 six-armed dendrites, arm length 5 to 14 px, line width max(1, 0.085 x size), side branches at 30%, 52% and 74% of each arm; 26 faint out-of-focus discs (radius 3 to 7 px, 30% strength) behind. Crystals snap to `#AAAAAA` on flat `#555555` glass; ramp `#555555` `#AAAAAA` `#FFFFFF`, strength 0.9. Fixed random seed.
- **Storm.** `Lightning_NOAA.jpg`, crop x 0.12, y 0.10, width 0.45. Unsharp 0.3, gamma 1.8. Ramp `#000000` `#000055` `#5555FF` `#FFFFFF`.
- **Fog (generated).** Flat navy sky above a bank whose top edge sits at y = 132 +/- 22 px (noise-shaped), rising over a 34 px soft transition, with thin wisps drifting up to 40 px above it. Ramp `#000055` `#555555` `#AAAAAA`.
- **Stale data.** Weather older than 3 hours drops the texture: the digits show flat `#555555` (proposed) until fresh data arrives, so an old condition is never shown as current.

## Backlight and tilt

The tilt effect and night glow exist only while the backlight is on; the rest of the time the face is static. In bright light the firmware keeps the backlight off (Settings > Display > Backlight > Ambient Sensor, on by default), so neither runs.

1. **Light on** (`backlight_service_subscribe`, fires immediately): after 50 ms (see Notifications below), subscribe to the accelerometer at 50 Hz, one sample per callback. At night the glow rings ramp in over four levels 60 ms apart (full after 180 ms) while the moon dims with them.
2. **Each sample:** a light low-pass (half the step per sample) on the gravity vector. The origin is the first usable sample after the light came on and stays fixed while lit. Tilt maps to an offset of up to 13 px horizontally and 9 px vertically (full at about 17 degrees); the whole-pixel offset moves only once the tilt is 10/16 px past it, and every change redraws straight away (no animation timer). The sky plate moves at 0.35 x that offset, the texture at the full offset, the clear-night moon with its windows at about 0.7 x (9 x 7 px); with the weather background the texture plate takes the full offset.
3. **Light off** (fires after the 500 ms fade finishes): unsubscribe the accelerometer, return offsets to zero and redraw the static frame once.

- **Day:** tilt only, no glow. The light alone costs no frame until the wrist moves.
- **Stop rule:** light-off stops the tilt. Six seconds in, and every second after, the tilt stops by itself only if the light is really off (30 s cap), so a light kept on by a second press never snaps back to centre in view.
- **Notifications:** the firmware lights the screen for a notification before telling the face it lost focus, so light-on waits 50 ms before starting the tilt or the glow ramp; a covered face starts neither. The tilt resumes if the light is still on when the notification closes. Timeline Peek does not take focus, so the tilt runs under it.
- **Tint (PT2 only):** the LED can be tinted with `light_set_color`; the tint colours everything on this reflective screen, so any tint (for example a cool cast at night) is decided on hardware. Round 2 has no tint.
- **Setting:** the tilt can be turned off; the light then only swaps in the glow at night.

## Settings

A phone-side configuration page (self-contained, opened as a data URL) with seven settings. Since v1.0 the day background defaults to Weather and the digit border to On. Visual options are chosen by tapping a thumbnail rendered by the watch's own compositor (`tools/thumbs.py`); a Round 2 watch gets round frames. Sky style shows only with the sky background, the coordinates only in manual mode.

| Setting | Options | Default | Notes |
| --- | --- | --- | --- |
| Digit border (day) | Off, On | On | 1 px line in the local plate colour darkened one step. (An adaptive option was dropped in v0.4.0: it was not visible on the watch.) At night the cyan border always shows. |
| Day background | Sky, Weather | Weather | Sky = the sky plate with the weather through the digits. Weather = the weather texture fills the screen and the digits are one solid colour (see Weather background below). |
| Night background | Moonphase, Weather | Moonphase | Same choice at night. On a clear night Weather keeps the moon behind solid digits. |
| Sky style | Gradient, Solid | Gradient | Solid = one flat colour per phase, no bloom (see Day face). Applies only to the sky background. |
| Tilt effect | On, Off | On | Off = the light only swaps in the night glow. |
| Weather refresh | 15, 30, 60 min | 30 min | Phone side only. |
| Location | Automatic, Manual | Automatic | Manual takes latitude and longitude; also used for sun and moon. |

**Weather background** (v0.3.0). The weather texture becomes the plate and takes the full tilt offset (13 x 9 px; the textures already carry 16 px past each edge, so no zoom). The digits are one solid colour, hand-picked per texture for contrast against every colour it shows. Textures never dim; the clear-night moon still dims while lit. Night keeps the cyan border and glow rings; stale weather looks the same in both modes. The settings page shows each option as a thumbnail.

| Background | Digit colour |
| --- | --- |
| Sunny | `#AAFFFF` |
| Partly cloudy, cloudy (day) | `#000055` |
| Rain | `#FFFF55` |
| Snow | `#FFFFFF` |
| Storm | `#FFAA00` |
| Fog | `#FF5500` |
| Partly cloudy night | `#FFFFAA` |
| Cloudy night | `#FFFF55` |
| Clear night (moon) | `#FFFFFF` |

## Battery and performance rules

The face renders once a minute and does nothing in between; everything expensive is computed once and cached.

- **One redraw per minute.** `tick_timer_service` on `MINUTE_UNIT`; no seconds, no polling. The window background is `GColorClear`, so the framebuffer persists and nothing is redrawn when nothing changed.
- **Cache layers by how often they change:**

| Cached item | Rebuilt when |
| --- | --- |
| Digit mask and edge list | the minute changes (only the changed digits are re-stamped) |
| Day sky plate | the phase changes, the sun moves a whole pixel, or sky style changes |
| Moon with phase applied | once an hour, or at the day/night switch |
| Weather texture | a new weather state arrives |
| Composed static frame | any of the above changes |

- **Animation only while lit,** capped at 6 s, accelerometer unsubscribed the moment it ends.
- **No floats on the watch.** Integer and fixed-point maths, `sin_lookup`, precomputed tables stored as raw resources (read with `resource_load_byte_range`), not as C arrays in the app image.
- **Allocate once.** Texture, plate, moon and mask buffers are allocated at startup, in that order, and reused; a new texture overwrites the old buffer in place (free, then load, if sizes differ).
- **Phone does the thinking.** Location, weather, solar times and moon phase are computed in PebbleKit JS; the watch receives small integers.
- **Quiet messaging.** The phone sends only when a value changes; no message if the weather state and schedule are unchanged.
- **Measure, don't estimate.** Log `heap_bytes_free()` and probe the largest free block at peak (a texture swap while lit).

## Memory and storage budget

Estimates, to be replaced with measurements in the emulator: PT2 peaks near 95 KB of its 128 KB, Round 2 near 116 KB, so Round 2 needs the mitigations below from day one.

| Heap item (peak = lit night during a texture swap) | PT2 | Round 2 |
| --- | --- | --- |
| App image (code + static data) | 20 to 25 KB | 20 to 25 KB |
| Weather texture, 2 bpp with tilt margin | 15.1 KB (232 x 260) | 21.3 KB (292 x 292) |
| Plate: sky or moon (never both), 2 bpp with margin | 15.1 KB | 21.3 KB |
| Digit mask, 2-bit coverage | 11.4 KB | 16.9 KB |
| Glow ring sprites, 4 digits (lit night only) | 11 KB | 13 KB |
| Messages, layers, misc | 7 KB | 7 KB |
| Transient while a new texture decodes | 10 KB | 13 KB |
| **Peak** | **about 95 KB** | **about 116 KB** |

Mitigations if a platform runs short: free the glyph bitmaps once the mask is built; load glow sprites only while lit; draw the glow rings from the mask instead of sprites; swap the texture only while unlit.

**Storage** (each platform gets its own resource pack, 256 KB limit): 9 textures (7 day, 2 night) at roughly 10 to 17 KB each, one moon image, 10 glyphs and 10 glow sprites come to about 150 KB on PT2 and 200 KB on Round 2. Measure the real PNG sizes before adding anything; dithered images compress worse than flat art. Measured 2026-09-29, stored raw: 196 KB on PT2 and 251 KB on Round 2 (nine 21 KB textures; the moon image is shared), so Round 2 has about 11 KB left and no room for a second moon.

## Phone to watch data flow

The watch asks, the phone answers: when a value is due, the watch sends a request, PebbleKit JS fetches and computes, and replies with a few integers.

| Message key | Type | Sent when |
| --- | --- | --- |
| `WX_STATE` | uint8, 0 to 7 (the eight states above) | on request, only if changed |
| `WX_TIME` | uint32, time of the observation | with `WX_STATE` |
| `SUN_TIMES` | 7 x uint32 for today and 7 for tomorrow: civil dawn, 10° rising, sunrise, solar noon, sunset, 10° setting, civil dusk (thresholds already adjusted for high latitudes) | once a day after local midnight, and on location change |
| `SUN_PEAK` | int8, today's peak elevation in degrees | with `SUN_TIMES` |
| `MOON_PHASE` | uint16, 0 to 359 (0 = new, 180 = full) | once a day |
| `HEMISPHERE` | int8, +1 north, -1 south | with `MOON_PHASE` |
| `CFG_*` | uint8 per setting | when the settings page is saved |

- **Weather source:** Open-Meteo (no API key), current `weather_code`, requested every refresh interval (default 30 min).
- **Solar and moon maths** in JS (a NOAA-style solar position algorithm and a standard phase formula), so the watch never does trigonometry beyond `sin_lookup` for the sun's arc.
- **Offline:** tomorrow's sun times keep day and night correct for a day without the phone; weather older than 3 hours goes to the stale state.
- **Location:** coarse geolocation, cached on the phone; manual latitude and longitude override it.

## Asset pipeline and project files

Everything lives in the repo `hornofabraxas/parallax-weather`: the texture pipeline and design renderer, and the source photos.

| Path | Contents |
| --- | --- |
| `tools/face.swift` | Mockup renderer and texture pipeline (Swift, CoreGraphics and ImageIO only, no packages). Many experimental modes; the canonical ones are listed below. |
| `tools/sheet.py` | Stitches renders into comparison sheets (stdlib only). |
| `art/src/` | Source photos: `sdo.jpg`, `clouds.jpg`, `mackerel.jpg`, `drops_grey.jpg`, `lightning.jpg`, `moon.jpg` (half-moon mockup source only). |

Run the tool from `art/` (it reads `src/...`):

```bash
swiftc -O ../tools/face.swift -o face
export MB=0.18 MW=0.9 MG=0.8 MD=300 MX=60 MY=114 CUW=0.6 CUX=0.1 CUY=0.05 CUT=0.45 SUNA=160 SUNW=1800 SUNY=152 SEAM=0.08 BLOOM=44
./face wx SF-Heavy out_rain rain          # day, night unlit, night lit stills
./face wxgif SF-Heavy out_rain rain       # day and night tilt GIFs
./face clearnight SF-Heavy out_clear      # clear night stills + GIF
./face dayplate3 SF-Heavy out_sky rain morning,noon,afternoon,golden
```

Weather names: `sunny`, `partly`, `cloudy`, `rain`, `snow`, `storm`, `fog`. The build phase still needs an exporter that writes each texture as a palettised 2-bit PNG resource per platform, plus the glyph and glow sprites.

## Credits and licensing

The code and the generated textures are MIT (`LICENSE`); two textures are share-alike (their converted images ship as CC BY-SA 4.0) and one needs attribution. `CREDITS.md` holds the full record and every GitHub release carries the credits.

| Asset | Source file | Author | Licence |
| --- | --- | --- | --- |
| Sunny | [SDO_20140611_000908_4096_0304_(AIA).jpg](https://commons.wikimedia.org/wiki/File:SDO_20140611_000908_4096_0304_(AIA).jpg) | NASA/SDO and the AIA, EVE and HMI science teams | Public domain |
| Partly cloudy | [Clouds_and_blue_sky_in_Russia._IMG_110.jpg](https://commons.wikimedia.org/wiki/File:Clouds_and_blue_sky_in_Russia._IMG_110.jpg) | Dmitry Makeev | CC BY-SA 4.0 |
| Cloudy | [Altocumulus clouds (mackerel sky) ... 3 (22859440393).jpg](https://commons.wikimedia.org/wiki/File:Altocumulus_clouds_(mackerel_sky)_(late_afternoon,_10_June_2015)_(Virginia,_Minnesota,_USA)_3_(22859440393).jpg) | James St. John | CC BY 2.0 |
| Rain | [Raindrops_on_the_glass.jpg](https://commons.wikimedia.org/wiki/File:Raindrops_on_the_glass.jpg) | BogTar201213 | CC BY-SA 4.0 |
| Storm | [Lightning_NOAA.jpg](https://commons.wikimedia.org/wiki/File:Lightning_NOAA.jpg) | C. Clark, NOAA | Public domain |
| Moon | [Moon Phase and Libration, 2026](https://svs.gsfc.nasa.gov/5587), frame 6450 | NASA's Scientific Visualization Studio | Public domain |
| Moon (design renderer only) | [Half_Waxed_Moon.jpg](https://commons.wikimedia.org/wiki/File:Half_Waxed_Moon.jpg) | Tomruen, retouched by Ninomy | Public domain |
| Snow, fog | Generated in `tools/face.swift` | this project | MIT |
| Digits | [Inter Display Black](https://github.com/rsms/inter) (Inter 4.1) | The Inter Project Authors | SIL Open Font License 1.1 |

- SF Pro Heavy (used for the early mockups) is not shipped; those mockups were removed before the public release.
- Unused downloads (frost, backlit clouds, silver droplets) were left out of the project.

## Emulator verification checklist

Prove the risky mechanics in a bare prototype before building features; each item below can kill or reshape part of the design.

- [ ] 2-bit alpha glyph bitmaps blend correctly with `GCompOpSet` (edge pixels at 1/3 and 2/3), or plan a manual framebuffer blend
- [x] A watchface receives `backlight_service` on and off events on emery and gabbro
- [ ] Accelerometer subscription from a watchface while lit, and its battery cost over 100 flicks
- [ ] Tilt frame time: texture blit + plate blit + mask at 15 to 20 fps on PT2 (the emulator is slower than hardware; confirm on the watch)
- [ ] Palette swap on a 2-bit bitmap recolours glyphs and dims the moon at runtime
- [ ] Real PNG sizes of the dithered textures, per platform, against the 256 KB pack
- [ ] Peak heap and largest free block during a texture swap while lit, on both platforms
- [ ] App image stays well under 65,535 bytes with no floating point linked in
- [ ] Sky plate render time in integer maths (target under 50 ms, a few times an hour)
- [ ] Colours on the real PT2 screen (reflective): recheck ramps that looked marginal on a monitor, especially golden hour and the cyan glow

## Open questions

- [x] Which OFL font replaces SF Pro Heavy: Inter Display Black (decided 2026-09-28).
- [x] Which public-domain full-moon image becomes the night source: NASA SVS "Moon Phase and Libration, 2026", frame 6450 (decided 2026-09-28).
- [x] 12 hour mode: a leading zero ("08"), like 24 hour mode (decided 2026-09-28).
- [ ] Stale weather look: flat `#555555` digits as proposed, or something else?
- [ ] PT2 backlight tint at night: none, or a colour chosen on hardware?
- [x] Round 2 layout for the 2 x 2 block inside the circle: 94 px digits, centred (decided 2026-09-29).
- [x] Final name: Parallax Weather (decided 2026-09-29).
