#ifndef DSTV_VIDEO_FRAMES_H
#define DSTV_VIDEO_FRAMES_H
#include <stdint.h>
#include <stddef.h>
// Main-thread-only snapshots of stacked DS/3DS screens (3DS factors 1–4).
int32_t dstv_video_capture(const void *source, size_t bytes,
    uint32_t width, uint32_t height, size_t pitch);
int32_t dstv_video_capture_rgb565(const void *source, size_t bytes,
    uint32_t width, uint32_t height, size_t pitch);
const void *dstv_video_screen(int32_t bottom);
int32_t dstv_video_copy_screen_rgba(int32_t bottom, void *output, size_t bytes);
int32_t dstv_video_copy_bottom_rgba(void *output, size_t bytes);
void dstv_video_reset(void);
uint64_t dstv_video_revision(int32_t bottom);
void dstv_video_set_single(int32_t enabled);
void dstv_video_set_3ds(int32_t enabled);
uint32_t dstv_video_width(int32_t bottom);
uint32_t dstv_video_height(void);
#endif
