#include "AudioRing.h"
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>

#define CAPACITY 4096u
#define MASK (CAPACITY - 1u)
#define PREFILL 1024u
static _Atomic uint32_t reserve_frames = PREFILL;
void dstv_audio_set_reserve_frames(uint32_t frames) {
    atomic_store_explicit(&reserve_frames, frames < PREFILL ? PREFILL : (frames > 3072 ? 3072 : frames), memory_order_relaxed);
}
static int16_t pcm[CAPACITY][2];
static _Atomic uint64_t read_index, write_index;
static _Atomic uint64_t underruns, dropped;
static bool primed; // Consumer-owned; reset only while stopped.

void dstv_audio_reset(void) {
    atomic_store(&read_index, 0);
    atomic_store(&write_index, 0);
    atomic_store(&underruns, 0);
    atomic_store(&dropped, 0);
    primed = false;
}

void dstv_audio_push(const int16_t *samples, size_t frames) {
    if (!samples) return;
    uint64_t w = atomic_load_explicit(&write_index, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&read_index, memory_order_acquire);
    size_t room = CAPACITY - (size_t)(w - r);
    size_t count = frames < room ? frames : room;
    for (size_t i = 0; i < count; ++i) {
        pcm[(w + i) & MASK][0] = samples[2 * i];
        pcm[(w + i) & MASK][1] = samples[2 * i + 1];
    }
    atomic_store_explicit(&write_index, w + count, memory_order_release);
    atomic_fetch_add_explicit(&dropped, frames - count, memory_order_relaxed);
}

OSStatus dstv_audio_render(uint32_t frames, AudioBufferList *buffers) {
    // AVAudioSourceNode is connected with stereo, noninterleaved Float32.
    for (uint32_t b = 0; b < buffers->mNumberBuffers; ++b)
        if (buffers->mBuffers[b].mData)
            memset(buffers->mBuffers[b].mData, 0, buffers->mBuffers[b].mDataByteSize);
    if (buffers->mNumberBuffers != 2 || !buffers->mBuffers[0].mData ||
        !buffers->mBuffers[1].mData ||
        buffers->mBuffers[0].mDataByteSize < frames * sizeof(float) ||
        buffers->mBuffers[1].mDataByteSize < frames * sizeof(float)) return kAudio_ParamError;
    uint64_t r = atomic_load_explicit(&read_index, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&write_index, memory_order_acquire);
    uint64_t available = w - r;
    const uint32_t reserve = atomic_load_explicit(&reserve_frames, memory_order_relaxed);
    if (!primed) {
        if (available < reserve) return noErr;
        primed = true;
    }
    // The larger reserve deliberately absorbs bursty core output. Do not
    // discard that audio merely because a valid burst fills this bounded ring:
    // at 3DS's 32728 Hz the entire capacity is only 125 ms. The producer still
    // rejects true overflow. Keep the legacy low-latency policy for small reserves.
    const uint32_t highWater = reserve > PREFILL ? CAPACITY : 3072;
    const uint32_t retain = 1536;
    if (available > highWater) {
        atomic_fetch_add_explicit(&dropped, available - retain, memory_order_relaxed);
        r = w - retain;
        available = retain;
    }
    size_t count = available < frames ? (size_t)available : frames;
    float *left = buffers->mBuffers[0].mData;
    float *right = buffers->mBuffers[1].mData;
    for (size_t i = 0; i < count; ++i) {
        left[i] = pcm[(r + i) & MASK][0] / 32768.0f;
        right[i] = pcm[(r + i) & MASK][1] / 32768.0f;
    }
    atomic_store_explicit(&read_index, r + count, memory_order_release);
    if (count < frames) {
        primed = false;
        atomic_fetch_add_explicit(&underruns, 1, memory_order_relaxed);
    }
    return noErr;
}
uint64_t dstv_audio_underruns(void) { return atomic_load(&underruns); }
uint64_t dstv_audio_dropped_frames(void) { return atomic_load(&dropped); }

uint32_t dstv_audio_buffered_frames(void) {
    const uint64_t r = atomic_load_explicit(&read_index, memory_order_acquire);
    const uint64_t w = atomic_load_explicit(&write_index, memory_order_acquire);
    const uint64_t count = w - r;
    return (uint32_t)(count < CAPACITY ? count : CAPACITY);
}
