#ifndef DSTV_PIXEL_ENHANCEMENT_H
#define DSTV_PIXEL_ENHANCEMENT_H
#include <stddef.h>
#include <stdint.h>
// Edge-aware output scaling of XRGB8888, not internal emulation resolution.
// Main-thread-only (bounded shared scratch). Source/destination must not overlap.
// Supports native DS-sized images and factors 2/4. Returns 0 on invalid input.
int32_t dstv_enhance_pixels(const void *source, size_t source_bytes,
    uint32_t width, uint32_t height, uint32_t pitch, uint32_t factor,
    void *destination, size_t destination_bytes);
#endif
