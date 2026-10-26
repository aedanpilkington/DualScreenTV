#include "VideoFrames.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static uint32_t sample(const void *screen, unsigned x, unsigned y) {
    uint32_t value;
    memcpy(&value, (const uint8_t *)screen + (y * 256 + x) * 4, 4);
    return value;
}
static void test_rgb565(void) {
    const size_t pitch = 513; // Unaligned, padded rows.
    uint8_t *input = malloc(pitch * 384);
    for (unsigned y = 0; y < 384; ++y) for (unsigned x = 0; x < 256; ++x) {
        uint16_t p = (uint16_t)(y * 256 + x);
        memcpy(input + y * pitch + x * 2, &p, 2);
    }
    dstv_video_set_3ds(0);
    assert(dstv_video_capture_rgb565(input, pitch * 384, 256, 384, pitch));
    for (unsigned y = 0; y < 384; ++y) for (unsigned x = 0; x < 256; ++x) {
        unsigned p = (uint16_t)(y * 256 + x);
        unsigned r = p >> 11, g = (p >> 5) & 63, b = p & 31;
        uint32_t expected = 0xff000000u | ((r << 3 | r >> 2) << 16) |
            ((g << 2 | g >> 4) << 8) | (b << 3 | b >> 2);
        assert(sample(dstv_video_screen(y / 192), x, y % 192) == expected);
    }
    assert(!dstv_video_capture_rgb565(input, 10, 256, 384, pitch));
    assert(!dstv_video_capture_rgb565(input, pitch * 384, 256, 384, 511));
    assert(!dstv_video_capture_rgb565(input, pitch * 384, 256, 383, pitch));
    dstv_video_set_3ds(1);
    assert(!dstv_video_capture_rgb565(input, pitch * 384, 256, 384, pitch));
    dstv_video_set_3ds(0);
    free(input);
}
static void test_3ds_revisions(void) {
    dstv_video_set_3ds(1);
    const size_t pitch=400*4+16,bytes=pitch*480;
    uint8_t *data=calloc(1,bytes);assert(data);
    assert(dstv_video_capture(data,bytes,400,480,pitch));
    const uint64_t top=dstv_video_revision(0),bottom=dstv_video_revision(1);
    assert(dstv_video_capture(data,bytes,400,480,pitch));
    assert(dstv_video_revision(0)==top && dstv_video_revision(1)==bottom);
    data[240*pitch]=99; // Bottom-screen letterbox padding is not visible content.
    assert(dstv_video_capture(data,bytes,400,480,pitch));
    assert(dstv_video_revision(0)==top && dstv_video_revision(1)==bottom);
    data[240*pitch+40*4]=77;
    assert(dstv_video_capture(data,bytes,400,480,pitch));
    assert(dstv_video_revision(0)==top && dstv_video_revision(1)==bottom+1);
    data[0]=55;assert(dstv_video_capture(data,bytes,400,480,pitch));
    assert(dstv_video_revision(0)==top+1 && dstv_video_revision(1)==bottom+1);
    const uint64_t before=dstv_video_revision(0);
    assert(!dstv_video_capture(data,10,400,480,pitch));assert(dstv_video_revision(0)==before);
    dstv_video_reset();assert(dstv_video_revision(0)!=before);
    assert(dstv_video_capture(data,bytes,400,480,pitch));assert(dstv_video_revision(0)>before);
    free(data);dstv_video_set_3ds(0);
}
int main(void) {
    test_3ds_revisions();
    test_rgb565();
    const size_t pitch = 1040;
    uint8_t *source = malloc(pitch * 384);
    memset(source, 0xCC, pitch * 384);
    for (unsigned y = 0; y < 384; ++y) {
        uint32_t value = (y < 192 ? 0x110000 : 0x220000) + y % 192;
        for (unsigned x = 0; x < 256; ++x) memcpy(source + y * pitch + x * 4, &value, 4);
    }
    dstv_video_reset();
    assert(!dstv_video_screen(0) && !dstv_video_screen(1));
    assert(dstv_video_capture(source, pitch * 384, 256, 384, pitch));
    assert(sample(dstv_video_screen(0), 0, 0) == 0x110000);
    assert(sample(dstv_video_screen(0), 255, 191) == 0x110000 + 191);
    assert(sample(dstv_video_screen(1), 0, 0) == 0x220000);
    assert(sample(dstv_video_screen(1), 255, 191) == 0x220000 + 191);
    uint8_t rgba[256 * 192 * 4];
    assert(dstv_video_copy_bottom_rgba(rgba, sizeof(rgba)));
    assert(rgba[0] == 0x22 && rgba[1] == 0 && rgba[2] == 0 && rgba[3] == 255);
    size_t last = sizeof(rgba) - 4;
    assert(rgba[last] == 0x22 && rgba[last + 2] == 191 && rgba[last + 3] == 255);
    assert(dstv_video_copy_screen_rgba(0, rgba, sizeof(rgba)));
    assert(rgba[0] == 0x11 && rgba[1] == 0 && rgba[2] == 0 && rgba[3] == 255);
    assert(rgba[last] == 0x11 && rgba[last + 2] == 191);
    assert(!dstv_video_copy_screen_rgba(-1, rgba, sizeof(rgba)));
    assert(!dstv_video_copy_screen_rgba(2, rgba, sizeof(rgba)));
    assert(!dstv_video_copy_bottom_rgba(rgba, sizeof(rgba) - 1));
    assert(!dstv_video_copy_bottom_rgba(NULL, sizeof(rgba)));
    assert(!dstv_video_capture(NULL, 0, 256, 384, pitch));
    assert(sample(dstv_video_screen(1), 0, 0) == 0x220000); // Duplicate retains snapshot.
    assert(!dstv_video_capture(source, 10, 256, 384, pitch));
    assert(!dstv_video_capture(source, pitch * 384, 255, 384, pitch));
    assert(!dstv_video_capture(source, pitch * 384, 256, 191, pitch));
    assert(!dstv_video_capture(source, pitch * 384, 256, 384, 1023));
    assert(!dstv_video_capture(source, pitch * 384, 256, 384, SIZE_MAX));
    assert(dstv_video_capture(source, pitch * 192, 256, 192, pitch));
    assert(dstv_video_screen(0) && !dstv_video_screen(1)); // Never show stale bottom.
    assert(!dstv_video_screen(2) && !dstv_video_screen(-1));
    dstv_video_reset();
    assert(!dstv_video_screen(0) && !dstv_video_screen(1));
    assert(!dstv_video_copy_bottom_rgba(rgba, sizeof(rgba)));
    dstv_video_set_3ds(1);
    assert(dstv_video_width(0) == 400 && dstv_video_width(1) == 320 && dstv_video_height() == 240);
    uint32_t *three = malloc(400 * 480 * 4);
    for (unsigned y = 0; y < 480; ++y) for (unsigned x = 0; x < 400; ++x) three[y * 400 + x] = (y << 16) | x;
    assert(dstv_video_capture(three, 400 * 480 * 4, 400, 480, 1600));
    const uint32_t *top = dstv_video_screen(0), *bottom = dstv_video_screen(1);
    assert(top[239 * 400 + 399] == (239u << 16 | 399));
    assert(dstv_video_copy_screen_rgba(0, rgba, sizeof(rgba)));
    assert(rgba[0] == 0 && rgba[3] == 255); // Letterbox is opaque black.
    assert(rgba[19 * 256 * 4 + 2] == 0);
    assert(rgba[(19 * 256 + 255) * 4 + 2] == (398 & 255));
    assert(bottom[0] == (240u << 16 | 40));
    assert(bottom[239 * 320 + 319] == (479u << 16 | 359));
    assert(dstv_video_copy_bottom_rgba(rgba, sizeof(rgba)));
    assert(rgba[0] == 240 && rgba[2] == 40 && rgba[3] == 255);
    assert(!dstv_video_capture(three, 400 * 480 * 4 - 1, 400, 480, 1600));
    assert(!dstv_video_capture(three, 400 * 480 * 4, 800, 480, 3200));
    free(three);
    for (unsigned factor = 2; factor <= 4; ++factor) {
        const unsigned w = 400 * factor, h = 240 * factor, bw = 320 * factor;
        const size_t stride = w * 4 + 16, size = stride * h * 2;
        uint8_t *high = malloc(size);
        for (unsigned y = 0; y < h * 2; ++y) for (unsigned x = 0; x < w; ++x) {
            uint32_t value = (y << 16) | x;
            memcpy(high + y * stride + x * 4, &value, 4);
        }
        assert(dstv_video_capture(high, size, w, h * 2, stride));
        assert(dstv_video_width(0) == w && dstv_video_width(1) == bw && dstv_video_height() == h);
        top = dstv_video_screen(0); bottom = dstv_video_screen(1);
        assert(top[(h - 1) * w + w - 1] == ((h - 1) << 16 | (w - 1)));
        assert(bottom[0] == (h << 16 | 40 * factor));
        assert(bottom[(h - 1) * bw + bw - 1] == ((2 * h - 1) << 16 | (360 * factor - 1)));
        assert(dstv_video_copy_bottom_rgba(rgba, sizeof(rgba)));
        assert(rgba[0] == (h & 255) && rgba[2] == ((40 * factor) & 255) && rgba[3] == 255);
        assert(!dstv_video_capture(high, size, 2000, 2400, stride));
        assert(!dstv_video_capture(high, size, w, h * 2 - 1, stride));
        assert(dstv_video_width(0) == w); // Rejected frames preserve geometry.
        free(high);
    }
    dstv_video_set_3ds(0);
    assert(!dstv_video_screen(0) && dstv_video_width(0) == 256);
    for (unsigned factor = 2; factor <= 8; ++factor) {
        unsigned w = 256 * factor, h = 192 * factor;
        size_t stride = w * 4 + 16, bytes = stride * h * 2;
        uint8_t *scaled = calloc(1, bytes);
        uint32_t first = 0x123456, second = 0xabcdef;
        memcpy(scaled, &first, 4); memcpy(scaled + h * stride, &second, 4);
        assert(dstv_video_capture(scaled, bytes, w, h * 2, stride));
        assert(dstv_video_width(0) == w && dstv_video_width(1) == w && dstv_video_height() == h);
        assert(*(const uint32_t *)dstv_video_screen(0) == first);
        assert(*(const uint32_t *)dstv_video_screen(1) == second);
        assert(dstv_video_copy_screen_rgba(0, rgba, sizeof(rgba)) && rgba[0] == 0x12);
        assert(dstv_video_copy_screen_rgba(1, rgba, sizeof(rgba)) && rgba[0] == 0xab);
        assert(!dstv_video_capture(scaled, bytes, w, h * 2 - 1, stride));
        const size_t rgbPitch = w * 2u + 1;
        uint8_t *rgb = calloc(1, rgbPitch * h * 2);
        uint16_t red = 0xf800, blue = 0x001f;
        memcpy(rgb, &red, 2); memcpy(rgb + (h * 2 - 1) * rgbPitch + (w - 1) * 2, &blue, 2);
        assert(dstv_video_capture_rgb565(rgb, rgbPitch * h * 2, w, h * 2, rgbPitch));
        assert(*(const uint32_t *)dstv_video_screen(0) == 0xffff0000);
        assert(((const uint32_t *)dstv_video_screen(1))[w * h - 1] == 0xff0000ff);
        free(rgb);
        free(scaled);
    }
    dstv_video_set_single(1);
    const unsigned sw = 480, sh = 272;
    size_t sp = sw * 4 + 12;
    uint8_t *single = calloc(sh, sp);
    uint32_t pixel = 0xff123456;
    memcpy(single + (sh - 1) * sp + (sw - 1) * 4, &pixel, 4);
    assert(dstv_video_capture(single, sh * sp, sw, sh, sp));
    assert(dstv_video_width(0) == sw && dstv_video_height() == sh);
    assert(!dstv_video_screen(1));
    assert(((const uint32_t *)dstv_video_screen(0))[sw * sh - 1] == pixel);
    assert(!dstv_video_capture(single, sh * sp - sp, sw, sh, sp));
    assert(!dstv_video_capture(single, sh * sp, 4096, sh, sp));
    free(single);
    uint16_t gba[240 * 160] = {0xf800};
    assert(dstv_video_capture_rgb565(gba, sizeof(gba), 240, 160, 480));
    assert(dstv_video_width(0) == 240 && dstv_video_height() == 160);
    assert(*(const uint32_t *)dstv_video_screen(0) == 0xffff0000);
    dstv_video_set_single(0);
    dstv_video_set_3ds(0);
    assert(!dstv_video_screen(0) && dstv_video_width(0) == 256);
    free(source);
    puts("Video screens: distinct top/bottom rows, padded stride, duplicate frames, bounds, missing bottom and reset passed");
}
