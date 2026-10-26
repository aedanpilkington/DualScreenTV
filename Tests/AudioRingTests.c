#include "AudioRing.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

static struct {
    UInt32 count;
    AudioBuffer buffers[2];
} output;
static float left[1024], right[1024];
static int16_t samples[20000];
static void render(unsigned frames) {
    output.count = 2;
    output.buffers[0] = (AudioBuffer){1, sizeof(left), left};
    output.buffers[1] = (AudioBuffer){1, sizeof(right), right};
    assert(dstv_audio_render(frames, (AudioBufferList *)&output) == noErr);
    for (unsigned i = 0; i < frames; ++i) assert(left[i] == -right[i]);
}
static _Atomic bool done;
static void *produce(void *unused) {
    (void)unused;
    for (int i = 0; i < 20000; ++i) dstv_audio_push(samples, 137);
    atomic_store(&done, true);
    return NULL;
}
int main(void) {
    for (int i = 0; i < 10000; ++i) {
        samples[2*i] = (int16_t)(i % 30000 + 1);
        samples[2*i+1] = -samples[2*i];
    }
    dstv_audio_reset();
    dstv_audio_push(samples, 512);
    assert(dstv_audio_buffered_frames() == 512);
    render(512);
    assert(dstv_audio_buffered_frames() == 512);
    assert(left[0] == 0); // Wait for startup prefill without consuming.
    dstv_audio_push(samples + 1024, 512);
    render(1024);
    assert(left[0] == 1 / 32768.0f);
    assert(left[1023] == 1024 / 32768.0f);
    assert(dstv_audio_buffered_frames() == 0);
    render(512);
    assert(left[0] == 0 && dstv_audio_underruns() == 1);
    for (int i = 0; i < 100; ++i) {
        dstv_audio_push(samples, 1024);
        render(1024);
        assert(left[1023] == 1024 / 32768.0f);
    }
    dstv_audio_reset();
    dstv_audio_push(samples, 10000);
    render(512);
    assert(dstv_audio_dropped_frames() == 10000 - 1536);
    dstv_audio_reset();
    // Reduced DS rendering: retain enough audio across a long rendering tick.
    dstv_audio_set_reserve_frames(2560);
    dstv_audio_push(samples, 2048);
    render(512);
    assert(left[0] == 0 && dstv_audio_buffered_frames() == 2048);
    dstv_audio_push(samples + 4096, 1024);
    render(512);
    assert(left[0] != 0 && dstv_audio_buffered_frames() == 2560);
    assert(dstv_audio_dropped_frames() == 0); // No stale-audio trim of the reserve.
    for (int i=0;i<4;++i) render(512);
    assert(dstv_audio_underruns() == 0 && dstv_audio_buffered_frames() == 512);
    // 3DS 48 kHz reserve survives a 40 ms producer stall after priming.
    dstv_audio_reset();
    dstv_audio_set_reserve_frames(2880);
    dstv_audio_push(samples, 2880);
    for (int i = 0; i < 4; ++i) render(480);
    assert(dstv_audio_underruns() == 0);
    assert(dstv_audio_buffered_frames() == 960);
    dstv_audio_push(samples, 1920);
    render(480);
    assert(dstv_audio_dropped_frames() == 0);
    // A full valid 3DS burst previously discarded exactly 4096-1963=2133
    // stereo frames per event. Preserve it and play all samples in order.
    dstv_audio_reset();
    dstv_audio_set_reserve_frames(1963);
    dstv_audio_push(samples, 4096);
    for (int i = 0; i < 4; ++i) {
        render(1024);
        assert(left[0] == (float)(i * 1024 + 1) / 32768.0f);
        assert(dstv_audio_dropped_frames() == 0);
        assert(dstv_audio_underruns() == 0);
    }
    assert(dstv_audio_buffered_frames() == 0);
    // Actual overflow is still bounded and counted, never hidden.
    dstv_audio_reset();
    dstv_audio_push(samples, 5000);
    assert(dstv_audio_buffered_frames() == 4096);
    assert(dstv_audio_dropped_frames() == 904);
    render(1024);
    assert(dstv_audio_dropped_frames() == 904);
    dstv_audio_set_reserve_frames(1024);
    dstv_audio_reset();
    pthread_t producer;
    assert(pthread_create(&producer, NULL, produce, NULL) == 0);
    do { render(512); } while (!atomic_load(&done));
    pthread_join(producer, NULL);
    puts("Audio ring: prefill, PCM, silence, wraparound, overflow and concurrent stereo passed");
}
