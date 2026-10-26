#include "PixelEnhancement.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

int main(void) {
    uint32_t one = 0x00123456;
    uint32_t output[64];
    for (unsigned factor = 2; factor <= 4; factor *= 2) {
        memset(output, 0, sizeof(output));
        assert(dstv_enhance_pixels(&one, 4, 1, 1, 4, factor, output, sizeof(output)));
        for (unsigned i = 0; i < factor * factor; ++i) assert(output[i] == one);
    }
    // A diagonal corner must be reshaped rather than simply duplicating E.
    const uint32_t black = 0, white = 0xFFFFFF;
    uint32_t corner[9] = {black, black, white, black, white, white, white, white, white};
    uint32_t scaled[36];
    assert(dstv_enhance_pixels(corner, sizeof(corner), 3, 3, 12, 2, scaled, sizeof(scaled)));
    assert(scaled[2 * 6 + 2] == black);
    assert(scaled[2 * 6 + 3] == white);
    assert(scaled[3 * 6 + 2] == white);
    assert(scaled[3 * 6 + 3] == white);
    // Border clamping, padded pitch and unaligned source are supported.
    uint8_t padded[17] = {0};
    memcpy(padded + 1, &one, 4);
    memcpy(padded + 9, &one, 4);
    assert(dstv_enhance_pixels(padded + 1, 12, 1, 2, 8, 2, output, sizeof(output)));
    for (unsigned i = 0; i < 8; ++i) assert(output[i] == one);
    memset(output, 0xAA, sizeof(output));
    assert(!dstv_enhance_pixels(NULL, 4, 1, 1, 4, 2, output, sizeof(output)));
    assert(!dstv_enhance_pixels(&one, 4, 0, 1, 4, 2, output, sizeof(output)));
    assert(!dstv_enhance_pixels(&one, 4, 257, 1, 1028, 2, output, sizeof(output)));
    assert(!dstv_enhance_pixels(&one, 4, 1, 1, 3, 2, output, sizeof(output)));
    assert(!dstv_enhance_pixels(&one, 3, 1, 1, 4, 2, output, sizeof(output)));
    assert(!dstv_enhance_pixels(&one, 4, 1, 1, 4, 3, output, sizeof(output)));
    assert(!dstv_enhance_pixels(&one, 4, 1, 1, 4, 4, output, 63));
    assert(output[0] == 0xAAAAAAAA);
    // Exercise full DS geometry and the largest scratch/output sizes under ASAN.
    uint32_t *native = malloc(256 * 192 * 4);
    for (unsigned i = 0; i < 256 * 192; ++i) native[i] = i % 7;
    uint32_t *large = malloc(1024 * 768 * 4);
    assert(dstv_enhance_pixels(native, 256 * 192 * 4, 256, 192, 1024, 4, large, 1024 * 768 * 4));
    assert(large[0] == native[0]);
    assert(large[1024 * 768 - 1] == native[256 * 192 - 1]);
    free(native); free(large);
    native = malloc(400 * 240 * 4); large = malloc(1600 * 960 * 4);
    for (unsigned i = 0; i < 400 * 240; ++i) native[i] = i % 7;
    assert(dstv_enhance_pixels(native, 400 * 240 * 4, 400, 240, 1600, 4, large, 1600 * 960 * 4));
    assert(large[1600 * 960 - 1] == native[400 * 240 - 1]);
    free(native); free(large);
    puts("Pixel enhancement: diagonal edges, 2x/4x, borders, stride, invalid buffers and full geometry passed");
}
