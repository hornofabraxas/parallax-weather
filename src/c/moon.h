// Night plate: a window of the moon image, cut for the current placement, with the phase applied.
// Portable (see platform.h); integer maths only.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#include "engine.h"

// Reads len bytes at offset of the moon resource (a .pl2 file). Returns false on failure.
typedef bool (*MoonRead)(void *ctx, uint32_t offset, uint8_t *buf, uint32_t len);

typedef struct {
  int screen_w, screen_h;
  int cx_lit_right, cx_lit_left, cy;  // disc centre on screen, by which side the lit limb is on
  int radius;                         // disc radius in px
} MoonLayout;

// phase: 0..359 degrees, 0 = new, 180 = full. hemisphere: +1 north, -1 south (the image is
// turned 180 degrees and the lit side mirrors). The lit limb always faces into the screen.
// dst must be allocated with the plate's size; pixel (margin, margin) is screen (0, 0).
bool moon_render(Plane *dst, int margin, MoonRead reader, void *ctx, int phase, int hemisphere,
                 const MoonLayout *layout);
// Which side the lit limb is on for this phase and hemisphere.
bool moon_lit_right(int phase, int hemisphere);
