// The only file that decides between the watch SDK and the host build (tools/host).
#pragma once
#ifdef HOST
#include <math.h>
#include <stdint.h>
#define TRIG_MAX_RATIO 0xffff
#define TRIG_MAX_ANGLE 0x10000
static inline int32_t sin_lookup(int32_t a) { return (int32_t)lround(sin(a * 6.283185307179586 / TRIG_MAX_ANGLE) * TRIG_MAX_RATIO); }
static inline int32_t cos_lookup(int32_t a) { return (int32_t)lround(cos(a * 6.283185307179586 / TRIG_MAX_ANGLE) * TRIG_MAX_RATIO); }
#else
#include <pebble.h>
#endif
