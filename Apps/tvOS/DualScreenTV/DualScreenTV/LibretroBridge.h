#ifndef DSTV_LIBRETRO_BRIDGE_H
#define DSTV_LIBRETRO_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#include "AudioRing.h"
#include "PixelEnhancement.h"
#include "VideoFrames.h"

// Core, input, video and SRAM functions are confined to the main thread.
int32_t dstv_select_core(const char *path, int32_t threeDSRenderer); // NULL selects the existing DS core
int32_t dstv_is_3ds(void);
int32_t dstv_is_3ds_native_metal(void);
uint64_t dstv_3ds_metal_vertex_batches(void);
int32_t dstv_is_3ds_hybrid(void);
uint64_t dstv_3ds_metal_native_batches(void);
uint64_t dstv_3ds_metal_fallback_batches(void);
void dstv_set_metal_profiling(int32_t enabled);
void dstv_set_metal_surface_cache(int32_t enabled);
int32_t dstv_is_single_screen(void);
int32_t dstv_is_psp(void);
void dstv_set_psp_options(uint32_t factor, uint32_t filtering, uint32_t anisotropic);
void dstv_set_analog(int16_t lx, int16_t ly, int16_t rx, int16_t ry);
uint32_t dstv_bottom_frame_width(void);
uint32_t dstv_bottom_frame_height(void);
uint32_t dstv_bottom_frame_pitch(void);
uint64_t dstv_total_core_ticks(void);
void dstv_set_presentation_rate(uint32_t rate); // 30/60 output; guest timing unchanged
void dstv_set_3ds_resolution(uint32_t factor); // 1–4, applied at the next safe core tick
uint32_t dstv_initialise_core(void);
int32_t dstv_load_rom(const char *path);
int32_t dstv_set_directories(const char *system, const char *save);
int32_t dstv_run_one_frame(void);
const void *dstv_top_framebuffer(void);
const void *dstv_bottom_framebuffer(void);
uint32_t dstv_top_frame_width(void);
uint32_t dstv_top_frame_height(void);
uint32_t dstv_top_frame_pitch(void);
uint64_t dstv_total_video_frames(void);
void dstv_deinitialise_core(void);
void dstv_set_buttons(uint16_t buttons);
void dstv_set_companion_buttons(uint16_t buttons);
void dstv_set_touch(int32_t pressed, uint16_t x, uint16_t y);
void dstv_set_audio_enabled(int32_t enabled);
int32_t dstv_reset_game(void);
size_t dstv_state_size(void);
int32_t dstv_save_state(void *data, size_t size);
int32_t dstv_load_state(const void *data, size_t size);
double dstv_sample_rate(void);
double dstv_frames_per_second(void);
size_t dstv_memory_size(uint32_t region);
int32_t dstv_copy_memory(uint32_t region, void *destination, size_t size);
int32_t dstv_restore_memory(uint32_t region, const void *source, size_t size);
size_t dstv_sram_size(void);
int32_t dstv_copy_sram(void *destination, size_t size);
int32_t dstv_restore_sram(const void *source, size_t size);
int32_t dstv_is_desmume(void);
int32_t dstv_is_dust(void);
void dstv_set_ds_output_limit(uint32_t factor);
uint32_t dstv_ds_internal_resolution(void);
uint64_t dstv_ds_gpu_submissions(void);
void dstv_set_ds_resolution(uint32_t factor);
void dstv_set_ds_presentation_rate(uint32_t rate); // 1–8
void dstv_set_ds_gpu_renderer(int32_t enabled);
int32_t dstv_ds_gpu_renderer_active(void);
#endif
