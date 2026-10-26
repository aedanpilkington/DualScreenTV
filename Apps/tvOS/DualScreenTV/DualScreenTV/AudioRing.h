#ifndef DSTV_AUDIO_RING_H
#define DSTV_AUDIO_RING_H
#include <stdint.h>
#include <stddef.h>
#include <AudioToolbox/AudioToolbox.h>
// One producer (retro_run/main), one consumer (audio render thread).
void dstv_audio_push(const int16_t *samples, size_t frames);
OSStatus dstv_audio_render(uint32_t frames, AudioBufferList *buffers);
// Reset only with producer and render thread stopped.
void dstv_audio_reset(void);
// Atomic bounded reserve; 1024 preserves normal low-latency behavior.
void dstv_audio_set_reserve_frames(uint32_t frames);
uint32_t dstv_audio_buffered_frames(void);
uint64_t dstv_audio_underruns(void);
uint64_t dstv_audio_dropped_frames(void);
#endif
