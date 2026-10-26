#include "VideoFrames.h"
#include <stdbool.h>
#include <string.h>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

// Bounded 8x DS / 4x 3DS snapshots; only populated pages consume physical memory.
static uint8_t screens[2][2048u * 1536u * 4u];
static unsigned resolution = 1;
static uint64_t revisions[2];
uint64_t dstv_video_revision(int32_t bottom) {return bottom==0 || bottom==1 ? revisions[bottom] : 0;}
static bool valid[2], is_3ds, single_screen;
static unsigned single_width = 240, single_height = 160;
void dstv_video_set_single(int32_t enabled) { single_screen = enabled != 0; dstv_video_reset(); }
uint32_t dstv_video_width(int32_t bottom) { return single_screen ? single_width : (is_3ds ? (bottom ? 320 : 400) : 256) * resolution; }
uint32_t dstv_video_height(void) { return single_screen ? single_height : (is_3ds ? 240 : 192) * resolution; }
void dstv_video_set_3ds(int32_t enabled) { is_3ds = enabled != 0; resolution = 1; dstv_video_reset(); }
int32_t dstv_video_capture(const void *source, size_t bytes,
    uint32_t width, uint32_t height, size_t pitch) {
    if (single_screen) {
        if (!source || !width || !height || width > 2048 || height > 1536 || pitch < width * 4u || pitch > SIZE_MAX / height || bytes < (height - 1) * pitch + width * 4u) return 0;
        single_width = width; single_height = height;
        for (unsigned y = 0; y < height; ++y) memcpy(screens[0] + y * width * 4u, (const uint8_t *)source + y * pitch, width * 4u);
        valid[0] = true; valid[1] = false; ++revisions[0]; return 1;
    }
    unsigned scale = 1;
    if (is_3ds) {
        if (width % 400 || width < 400 || width > 1600) return 0;
        scale = width / 400;
        if (height != 480 * scale) return 0;
    }
    else if (width > 256) {
        if (width % 256 || width > 2048) return 0;
        scale = width / 256;
        if (height != 384 * scale) return 0;
    }
    const unsigned w = (is_3ds ? 400 : 256) * scale, h = (is_3ds ? 240 : 192) * scale;
    if (!source || width < w || height < h || pitch < (size_t)width * 4 ||
        pitch > SIZE_MAX / (2 * h)) return 0;
    const unsigned count = height >= 2 * h ? 2 : 1;
    if (bytes < (count * h - 1) * pitch + w * 4) return 0;
    const bool resized=resolution!=scale;
    resolution = scale;
    const uint8_t *src = source;
    for (unsigned screen = 0; screen < count; ++screen) {
        const unsigned row = dstv_video_width(screen) * 4;
        const unsigned x = is_3ds && screen ? 40 * resolution * 4 : 0;
        bool changed=!valid[screen] || resized || !is_3ds;
        for (unsigned y = 0; y < h; ++y) {
            const uint8_t* input=src+(screen*h+y)*pitch+x;
            uint8_t* output=screens[screen]+y*row;
            if(!is_3ds || memcmp(output,input,row)!=0) {memcpy(output,input,row);changed=true;}
        }
        if(changed)++revisions[screen];
        valid[screen] = true;
    }
    if (count == 1) valid[1] = false;
    return 1;
}
// Convert directly into the snapshots: no intermediate full-frame allocation/copy.
int32_t dstv_video_capture_rgb565(const void *source, size_t bytes,
    uint32_t width, uint32_t height, size_t pitch) {
    if (single_screen) {
        if (!source || !width || !height || width > 2048 || height > 1536 || pitch < width * 2u || pitch > SIZE_MAX / height || bytes < (height - 1) * pitch + width * 2u) return 0;
        single_width = width; single_height = height;
        for (unsigned y = 0; y < height; ++y) for (unsigned x = 0; x < width; ++x) {
            uint16_t p; memcpy(&p, (const uint8_t *)source + y * pitch + x * 2u, 2);
            uint8_t *d = screens[0] + (y * width + x) * 4u;
            unsigned rr = p >> 11, gg = (p >> 5) & 63, bb = p & 31;
            d[0] = bb << 3 | bb >> 2; d[1] = gg << 2 | gg >> 4; d[2] = rr << 3 | rr >> 2; d[3] = 255;
        }
        valid[0] = true; valid[1] = false; ++revisions[0]; return 1;
    }
    if (is_3ds || !source || width < 256 || width > 2048 || width % 256 ||
        height != width / 256 * 384 || pitch < width * 2u ||
        pitch > SIZE_MAX / height || bytes < (height - 1) * pitch + width * 2u) return 0;
    resolution = width / 256;
    const unsigned h = height / 2;
    for (unsigned screen = 0; screen < 2; ++screen) {
        for (unsigned y = 0; y < h; ++y) {
            const uint8_t *src = (const uint8_t *)source + (screen * h + y) * pitch;
            uint8_t *dst = screens[screen] + y * width * 4u;
            unsigned x = 0;
#if defined(__ARM_NEON)
            for (; x + 8 <= width; x += 8) {
                const uint16x8_t p = vreinterpretq_u16_u8(vld1q_u8(src + x * 2u));
                const uint16x8_t r = vshrq_n_u16(p, 11);
                const uint16x8_t g = vandq_u16(vshrq_n_u16(p, 5), vdupq_n_u16(63));
                const uint16x8_t b = vandq_u16(p, vdupq_n_u16(31));
                uint8x8x4_t bgra;
                bgra.val[0] = vmovn_u16(vorrq_u16(vshlq_n_u16(b, 3), vshrq_n_u16(b, 2)));
                bgra.val[1] = vmovn_u16(vorrq_u16(vshlq_n_u16(g, 2), vshrq_n_u16(g, 4)));
                bgra.val[2] = vmovn_u16(vorrq_u16(vshlq_n_u16(r, 3), vshrq_n_u16(r, 2)));
                bgra.val[3] = vdup_n_u8(255);
                vst4_u8(dst + x * 4u, bgra);
            }
#endif
            for (; x < width; ++x) {
                uint16_t p; memcpy(&p, src + x * 2u, 2);
                const unsigned r = p >> 11, g = (p >> 5) & 63, b = p & 31;
                dst[x * 4] = b << 3 | b >> 2;
                dst[x * 4 + 1] = g << 2 | g >> 4;
                dst[x * 4 + 2] = r << 3 | r >> 2;
                dst[x * 4 + 3] = 255;
            }
        }
        valid[screen] = true;++revisions[screen];
    }
    return 1;
}
const void *dstv_video_screen(int32_t bottom) {
    if (bottom != 0 && bottom != 1) return NULL;
    return valid[bottom] ? screens[bottom] : NULL;
}
void dstv_video_reset(void) { valid[0] = valid[1] = false; ++revisions[0];++revisions[1]; }

// Keep companion protocol v1 compatible: resample either screen to 256x192.
// TV presentation keeps the full selected internal resolution.
int32_t dstv_video_copy_screen_rgba(int32_t bottom, void *output, size_t bytes) {
    if (bottom < 0 || bottom > 1) return 0;
    if (!valid[bottom] || !output || bytes != 256u * 192u * 4u) return 0;
    uint8_t *dst = output;
    const uint8_t *src = screens[bottom];
    const unsigned w = dstv_video_width(bottom), h = dstv_video_height();
    // The companion v1 canvas is 4:3. Letterbox the wider 3DS top screen.
    const unsigned target_h = is_3ds && !bottom ? 154 : 192;
    const unsigned offset_y = (192 - target_h) / 2;
    for (unsigned y = 0; y < 192; ++y) for (unsigned x = 0; x < 256; ++x) {
        if (y < offset_y || y >= offset_y + target_h) {
            const unsigned to = (y * 256 + x) * 4;
            dst[to] = dst[to + 1] = dst[to + 2] = 0; dst[to + 3] = 255;
            continue;
        }
        const unsigned from = (((y - offset_y) * h / target_h) * w + x * w / 256) * 4;
        const unsigned to = (y * 256 + x) * 4;
        dst[to] = src[from + 2]; dst[to + 1] = src[from + 1];
        dst[to + 2] = src[from]; dst[to + 3] = 255;
    }
    return 1;
}

int32_t dstv_video_copy_bottom_rgba(void *output, size_t bytes) {
    return dstv_video_copy_screen_rgba(1, output, bytes);
}
