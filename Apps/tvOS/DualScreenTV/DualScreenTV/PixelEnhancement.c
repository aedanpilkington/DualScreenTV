#include "PixelEnhancement.h"
#include <string.h>

// Independently implemented from the published Scale2x neighborhood rules:
// https://www.scale2x.it/algorithm . Two passes provide 4x output.
// Scratch is bounded at DS geometry; no allocation in the filter.
static uint32_t scratch2[800 * 480];

static uint32_t pixel(const uint8_t *row, uint32_t x) {
    uint32_t value;
    memcpy(&value, row + 4 * x, sizeof(value));
    return value;
}
static int same(uint32_t a, uint32_t b) { return (a & 0xFFFFFFu) == (b & 0xFFFFFFu); }
static void pass(const uint8_t *src, uint32_t w, uint32_t h, uint32_t pitch, uint8_t *dst) {
    for (uint32_t y = 0; y < h; ++y) {
        const uint8_t *row = src + (size_t)y * pitch;
        const uint8_t *up = src + (size_t)(y ? y - 1 : y) * pitch;
        const uint8_t *down = src + (size_t)(y + 1 < h ? y + 1 : y) * pitch;
        for (uint32_t x = 0; x < w; ++x) {
            const uint32_t e = pixel(row, x), b = pixel(up, x), hpx = pixel(down, x);
            const uint32_t d = pixel(row, x ? x - 1 : x), f = pixel(row, x + 1 < w ? x + 1 : x);
            uint32_t top[2] = {e, e}, bottom[2] = {e, e};
            if (!same(b, hpx) && !same(d, f)) {
                if (same(d, b)) top[0] = d;
                if (same(b, f)) top[1] = f;
                if (same(d, hpx)) bottom[0] = d;
                if (same(hpx, f)) bottom[1] = f;
            }
            const size_t offset = ((size_t)(2 * y) * (2 * w) + 2 * x) * 4;
            memcpy(dst + offset, top, sizeof(top));
            memcpy(dst + offset + (size_t)(2 * w) * 4, bottom, sizeof(bottom));
        }
    }
}
int32_t dstv_enhance_pixels(const void *source, size_t source_bytes,
    uint32_t width, uint32_t height, uint32_t pitch, uint32_t factor,
    void *destination, size_t destination_bytes) {
    if (!source || !destination || !width || !height || width > 400 || height > 240 ||
        pitch < width * 4 || (factor != 2 && factor != 4) ||
        source_bytes < (size_t)(height - 1) * pitch + width * 4 ||
        destination_bytes < (size_t)width * height * factor * factor * 4) return 0;
    if (factor == 2) {
        pass(source, width, height, pitch, destination);
    } else {
        pass(source, width, height, pitch, (uint8_t *)scratch2);
        pass((uint8_t *)scratch2, width * 2, height * 2, width * 8, destination);
    }
    return 1;
}
