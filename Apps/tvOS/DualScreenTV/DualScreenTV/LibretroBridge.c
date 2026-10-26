#include "VideoFrames.h"
#include "LibretroBridge.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <time.h>

// MARK: - Libretro callback types

typedef bool (*retro_environment_t)(
    unsigned cmd,
    void *data
);

typedef void (*retro_video_refresh_t)(
    const void *data,
    unsigned width,
    unsigned height,
    size_t pitch
);

typedef void (*retro_audio_sample_t)(
    int16_t left,
    int16_t right
);

typedef size_t (*retro_audio_sample_batch_t)(
    const int16_t *data,
    size_t frames
);

typedef void (*retro_input_poll_t)(void);

typedef int16_t (*retro_input_state_t)(
    unsigned port,
    unsigned device,
    unsigned index,
    unsigned id
);

// MARK: - Libretro structs

struct retro_variable { const char *key; const char *value; };

struct retro_game_info {
    const char *path;
    const void *data;
    size_t size;
    const char *meta;
};

struct retro_system_info {
    const char *library_name;
    const char *library_version;
    const char *valid_extensions;
    bool need_fullpath;
    bool block_extract;
};

struct retro_log_callback {
    void (*log)(
        int level,
        const char *fmt,
        ...
    );
};

struct retro_game_geometry {
    unsigned base_width, base_height, max_width, max_height;
    float aspect_ratio;
};
struct retro_system_timing { double fps, sample_rate; };
struct retro_system_av_info {
    struct retro_game_geometry geometry;
    struct retro_system_timing timing;
};
extern void retro_get_system_av_info(struct retro_system_av_info *info);
static struct retro_system_av_info g_av_info;
// The pinned Azahar libretro wrapper rounds video to 60 and DSP audio to
// 32728. Its actual clocks are ARM11/4481136 and ARM11/8192. Using the
// rounded video rate slowly overproduces audio even with perfectly steady GPU
// work. Correct only that known metadata pair; honour other cores/rates.
static bool rounded_3ds_timing(void) {
    return dstv_is_3ds() == 1 && g_av_info.timing.fps == 60.0 && g_av_info.timing.sample_rate == 32728.0;
}
double dstv_sample_rate(void) {
    return rounded_3ds_timing() ? 268111856.0 / 8192.0 : g_av_info.timing.sample_rate;
}
double dstv_frames_per_second(void) {
    if (rounded_3ds_timing()) return 268111856.0 / 4481136.0;
    return g_av_info.timing.fps > 0 ? g_av_info.timing.fps : 60.0;
}

// MARK: - Libretro functions

extern void retro_set_environment(
    retro_environment_t callback
);

extern void retro_set_video_refresh(
    retro_video_refresh_t callback
);

extern void retro_set_audio_sample(
    retro_audio_sample_t callback
);

extern void retro_set_audio_sample_batch(
    retro_audio_sample_batch_t callback
);

extern void retro_set_input_poll(
    retro_input_poll_t callback
);

extern void retro_set_input_state(
    retro_input_state_t callback
);

extern unsigned retro_api_version(void);

extern void retro_init(void);

extern void retro_deinit(void);

extern bool retro_load_game(
    const struct retro_game_info *game
);

extern void retro_unload_game(void);

extern void retro_run(void);

extern void retro_get_system_info(
    struct retro_system_info *info
);

// MARK: - Libretro environment constants

#define RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY 9
#define RETRO_ENVIRONMENT_SET_PIXEL_FORMAT 10
#define RETRO_ENVIRONMENT_GET_LOG_INTERFACE 27
#define RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY 31

#define RETRO_PIXEL_FORMAT_XRGB8888 1

// MARK: - DS screen constants

#define DSTV_SCREEN_WIDTH 256
#define DSTV_SCREEN_HEIGHT 192
#define DSTV_BYTES_PER_PIXEL 4
#define DSTV_TOP_SCREEN_PITCH \
    (DSTV_SCREEN_WIDTH * DSTV_BYTES_PER_PIXEL)

#define DSTV_TOP_SCREEN_SIZE \
    (DSTV_TOP_SCREEN_PITCH * DSTV_SCREEN_HEIGHT)

// MARK: - Emulator state

static char g_system_directory[PATH_MAX] = {0};
static char g_save_directory[PATH_MAX] = {0};

static void *g_rom_data = NULL;
static size_t g_rom_size = 0;
static char *g_rom_path = NULL;

static bool g_is_3ds, g_is_desmume, g_is_dust, g_is_mgba, g_is_psp;
int32_t dstv_is_single_screen(void) { return g_is_mgba || g_is_psp; }
int32_t dstv_is_psp(void) { return g_is_psp; }
static const char *g_ds_resolution = "512x384";
static const char *g_ds_frameskip = "0";
static bool g_core_initialised = false;
static bool g_game_loaded = false;
static const char *g_3ds_resolution = "1";
static bool g_3ds_options_dirty;
static const char *g_presentation_rate = "60";
static bool g_psp_options_dirty;
static const char *g_psp_resolution = "480x272", *g_psp_filtering = "Auto", *g_psp_anisotropic = "disabled";
void dstv_set_psp_options(uint32_t factor, uint32_t filtering, uint32_t anisotropic) {
    static const char *res[] = {"480x272", "960x544", "1440x816", "1920x1088"};
    static const char *filters[] = {"Auto", "Nearest", "Linear"};
    static const char *aniso[] = {"disabled", "2x", "4x", "8x", "16x"};
    const char *resolution = res[factor >= 1 && factor <= 4 ? factor - 1 : 0];
    const char *filter = filters[filtering < 3 ? filtering : 0];
    const char *anisotropy = aniso[anisotropic < 5 ? anisotropic : 0];
    if (strcmp(g_psp_resolution, resolution) || strcmp(g_psp_filtering, filter) || strcmp(g_psp_anisotropic, anisotropy))
        g_psp_options_dirty = true;
    g_psp_resolution = resolution; g_psp_filtering = filter; g_psp_anisotropic = anisotropy;
}

static uint64_t g_total_core_audio_frames;
static uint64_t g_total_core_ticks;
uint64_t dstv_total_core_ticks(void) { return g_total_core_ticks; }
void dstv_set_presentation_rate(uint32_t rate) { g_presentation_rate = rate == 30 ? "30" : "60"; }
void dstv_set_3ds_resolution(uint32_t factor) {
    static const char *factors[] = {"1", "2", "3", "4"};
    const char *next = factors[(factor >= 1 && factor <= 4 ? factor : 1) - 1];
    if (strcmp(next, g_3ds_resolution) != 0) {
        g_3ds_resolution = next;
        g_3ds_options_dirty = g_is_3ds && g_core_initialised;
    }
}

int32_t dstv_is_desmume(void) { return g_is_desmume; }
int32_t dstv_is_dust(void) { return g_is_dust; }
void dstv_set_ds_presentation_rate(uint32_t rate) {
    const char *next = rate == 30 ? "1" : "0";
    if (strcmp(next, g_ds_frameskip)) {
        g_ds_frameskip = next;
        g_3ds_options_dirty = (g_is_desmume || g_is_dust) && g_core_initialised;
    }
}

void dstv_set_ds_resolution(uint32_t factor) {
    static const char *factors[] = {"256x192", "512x384", "768x576", "1024x768", "1280x960", "1536x1152", "1792x1344", "2048x1536"};
    const char *next = factors[(factor >= 1 && factor <= 8 ? factor : 1) - 1];
    if (strcmp(next, g_ds_resolution)) {
        g_ds_resolution = next;
        g_3ds_options_dirty = (g_is_desmume || g_is_dust) && g_core_initialised;
    }
}

static bool g_has_run_frame;
static bool g_audio_enabled = true;
void dstv_set_audio_enabled(int32_t enabled) { g_audio_enabled = enabled != 0; }

extern void *retro_get_memory_data(unsigned id);
extern size_t retro_get_memory_size(unsigned id);
extern void retro_reset(void);
extern size_t retro_serialize_size(void);
extern bool retro_serialize(void *data, size_t size);
extern bool retro_unserialize(const void *data, size_t size);

// Keep identical libretro exports isolated: DS is linked, 3DS is loaded locally.
static struct {
    __typeof__(&retro_get_system_av_info) retro_get_system_av_info;
    __typeof__(&retro_set_environment) retro_set_environment;
    __typeof__(&retro_set_video_refresh) retro_set_video_refresh;
    __typeof__(&retro_set_audio_sample) retro_set_audio_sample;
    __typeof__(&retro_set_audio_sample_batch) retro_set_audio_sample_batch;
    __typeof__(&retro_set_input_poll) retro_set_input_poll;
    __typeof__(&retro_set_input_state) retro_set_input_state;
    __typeof__(&retro_api_version) retro_api_version;
    __typeof__(&retro_init) retro_init;
    __typeof__(&retro_deinit) retro_deinit;
    __typeof__(&retro_load_game) retro_load_game;
    __typeof__(&retro_unload_game) retro_unload_game;
    __typeof__(&retro_run) retro_run;
    __typeof__(&retro_get_system_info) retro_get_system_info;
    __typeof__(&retro_get_memory_data) retro_get_memory_data;
    __typeof__(&retro_get_memory_size) retro_get_memory_size;
    __typeof__(&retro_reset) retro_reset;
    __typeof__(&retro_serialize_size) retro_serialize_size;
    __typeof__(&retro_serialize) retro_serialize;
    __typeof__(&retro_unserialize) retro_unserialize;
} g_core;
static void *g_3ds_metal_handle, *g_3ds_handle, *g_desmume_handle, *g_dust_handle, *g_mgba_handle, *g_psp_handle;
static void (*g_ds_metal_set_enabled)(int32_t);
static int32_t (*g_ds_metal_active)(void);
static int32_t g_ds_metal_enabled = 1;
static const char *g_dust_output_limit = "4";
static uint32_t (*g_dust_internal_scale)(void);
static uint64_t (*g_dust_gpu_frames)(void);
uint64_t dstv_ds_gpu_submissions(void) { return g_is_dust && g_dust_gpu_frames ? g_dust_gpu_frames() : 0; }
void dstv_set_ds_output_limit(uint32_t factor) { g_dust_output_limit = factor >= 8 ? "8" : "4"; }
uint32_t dstv_ds_internal_resolution(void) { return g_is_dust && g_dust_internal_scale ? g_dust_internal_scale() : dstv_top_frame_width() / 256; }
void dstv_set_ds_gpu_renderer(int32_t enabled) {
    g_ds_metal_enabled = enabled != 0;
    if (g_ds_metal_set_enabled) g_ds_metal_set_enabled(g_ds_metal_enabled);
}
int32_t dstv_ds_gpu_renderer_active(void) {
    return g_is_dust ? 1 : (g_is_desmume && g_ds_metal_active ? g_ds_metal_active() : 0);
}
static bool g_3ds_native_metal, g_3ds_hybrid;
static uint64_t (*g_metal_native_batches)(void), (*g_metal_fallback_batches)(void), (*g_metal_vertex_batches)(void);
int32_t dstv_is_3ds(void) { return g_is_3ds; }
int32_t dstv_is_3ds_native_metal(void) { return g_is_3ds && g_3ds_native_metal; }
uint64_t dstv_3ds_metal_vertex_batches(void) { return dstv_is_3ds_native_metal() && g_metal_vertex_batches ? g_metal_vertex_batches() : 0; }
int32_t dstv_is_3ds_hybrid(void) { return g_is_3ds && g_3ds_native_metal && g_3ds_hybrid; }
uint64_t dstv_3ds_metal_native_batches(void) { return dstv_is_3ds_native_metal() && g_metal_native_batches ? g_metal_native_batches() : 0; }
uint64_t dstv_3ds_metal_fallback_batches(void) { return dstv_is_3ds_native_metal() && g_metal_fallback_batches ? g_metal_fallback_batches() : 0; }
void dstv_set_metal_surface_cache(int32_t enabled) {
    setenv("DSTV_METAL_SURFACE_CACHE", enabled ? "1" : "0", 1);
}
void dstv_set_metal_profiling(int32_t enabled) {
    setenv("DSTV_METAL_PROFILE", enabled ? "1" : "0", 1);
}
int32_t dstv_select_core(const char *path, int32_t threeDSRenderer) {
    if (g_core_initialised || g_game_loaded) return 0;
    const bool nativeMetal = path && strstr(path, "azahar_metal_libretro") != NULL;
    const bool mgba = path && strstr(path, "mgba_libretro") != NULL;
    const bool psp = path && strstr(path, "ppsspp_libretro") != NULL;
    const bool desmume = path && strstr(path, "desmume_libretro") != NULL;
    const bool dust = path && strstr(path, "dust_libretro") != NULL;
    if (path) {
        void **slot = mgba ? &g_mgba_handle : (psp ? &g_psp_handle : (dust ? &g_dust_handle : (desmume ? &g_desmume_handle : (nativeMetal ? &g_3ds_metal_handle : &g_3ds_handle))));
        if (!*slot) *slot = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        void *handle = *slot;
        if (desmume && handle) {
            g_ds_metal_set_enabled = (void (*)(int32_t))dlsym(handle, "dstv_desmume_metal_set_enabled");
            g_ds_metal_active = (int32_t (*)(void))dlsym(handle, "dstv_desmume_metal_active");
            if (g_ds_metal_set_enabled) g_ds_metal_set_enabled(g_ds_metal_enabled);
        }
        if (dust && handle) g_dust_gpu_frames = (uint64_t (*)(void))dlsym(handle, "dstv_dust_gpu_frame_count");
        if (dust && handle) g_dust_internal_scale = (uint32_t (*)(void))dlsym(handle, "dstv_dust_internal_scale");
        if (!handle) { fprintf(stderr, "Dynamic core: %s\n", dlerror()); return 0; }
        g_core.retro_get_system_av_info = (__typeof__(&retro_get_system_av_info))dlsym(handle, "retro_get_system_av_info");
        if (!g_core.retro_get_system_av_info) return 0;
        g_core.retro_set_environment = (__typeof__(&retro_set_environment))dlsym(handle, "retro_set_environment");
        if (!g_core.retro_set_environment) return 0;
        g_core.retro_set_video_refresh = (__typeof__(&retro_set_video_refresh))dlsym(handle, "retro_set_video_refresh");
        if (!g_core.retro_set_video_refresh) return 0;
        g_core.retro_set_audio_sample = (__typeof__(&retro_set_audio_sample))dlsym(handle, "retro_set_audio_sample");
        if (!g_core.retro_set_audio_sample) return 0;
        g_core.retro_set_audio_sample_batch = (__typeof__(&retro_set_audio_sample_batch))dlsym(handle, "retro_set_audio_sample_batch");
        if (!g_core.retro_set_audio_sample_batch) return 0;
        g_core.retro_set_input_poll = (__typeof__(&retro_set_input_poll))dlsym(handle, "retro_set_input_poll");
        if (!g_core.retro_set_input_poll) return 0;
        g_core.retro_set_input_state = (__typeof__(&retro_set_input_state))dlsym(handle, "retro_set_input_state");
        if (!g_core.retro_set_input_state) return 0;
        g_core.retro_api_version = (__typeof__(&retro_api_version))dlsym(handle, "retro_api_version");
        if (!g_core.retro_api_version) return 0;
        g_core.retro_init = (__typeof__(&retro_init))dlsym(handle, "retro_init");
        if (!g_core.retro_init) return 0;
        g_core.retro_deinit = (__typeof__(&retro_deinit))dlsym(handle, "retro_deinit");
        if (!g_core.retro_deinit) return 0;
        g_core.retro_load_game = (__typeof__(&retro_load_game))dlsym(handle, "retro_load_game");
        if (!g_core.retro_load_game) return 0;
        g_core.retro_unload_game = (__typeof__(&retro_unload_game))dlsym(handle, "retro_unload_game");
        if (!g_core.retro_unload_game) return 0;
        g_core.retro_run = (__typeof__(&retro_run))dlsym(handle, "retro_run");
        if (!g_core.retro_run) return 0;
        g_core.retro_get_system_info = (__typeof__(&retro_get_system_info))dlsym(handle, "retro_get_system_info");
        if (!g_core.retro_get_system_info) return 0;
        g_core.retro_get_memory_data = (__typeof__(&retro_get_memory_data))dlsym(handle, "retro_get_memory_data");
        if (!g_core.retro_get_memory_data) return 0;
        g_core.retro_get_memory_size = (__typeof__(&retro_get_memory_size))dlsym(handle, "retro_get_memory_size");
        if (!g_core.retro_get_memory_size) return 0;
        g_core.retro_reset = (__typeof__(&retro_reset))dlsym(handle, "retro_reset");
        if (!g_core.retro_reset) return 0;
        g_core.retro_serialize_size = (__typeof__(&retro_serialize_size))dlsym(handle, "retro_serialize_size");
        if (!g_core.retro_serialize_size) return 0;
        g_core.retro_serialize = (__typeof__(&retro_serialize))dlsym(handle, "retro_serialize");
        if (!g_core.retro_serialize) return 0;
        g_core.retro_unserialize = (__typeof__(&retro_unserialize))dlsym(handle, "retro_unserialize");
        if (!g_core.retro_unserialize) return 0;
    } else {
        g_core.retro_get_system_av_info = &retro_get_system_av_info;
        g_core.retro_set_environment = &retro_set_environment;
        g_core.retro_set_video_refresh = &retro_set_video_refresh;
        g_core.retro_set_audio_sample = &retro_set_audio_sample;
        g_core.retro_set_audio_sample_batch = &retro_set_audio_sample_batch;
        g_core.retro_set_input_poll = &retro_set_input_poll;
        g_core.retro_set_input_state = &retro_set_input_state;
        g_core.retro_api_version = &retro_api_version;
        g_core.retro_init = &retro_init;
        g_core.retro_deinit = &retro_deinit;
        g_core.retro_load_game = &retro_load_game;
        g_core.retro_unload_game = &retro_unload_game;
        g_core.retro_run = &retro_run;
        g_core.retro_get_system_info = &retro_get_system_info;
        g_core.retro_get_memory_data = &retro_get_memory_data;
        g_core.retro_get_memory_size = &retro_get_memory_size;
        g_core.retro_reset = &retro_reset;
        g_core.retro_serialize_size = &retro_serialize_size;
        g_core.retro_serialize = &retro_serialize;
        g_core.retro_unserialize = &retro_unserialize;
    }
    g_3ds_options_dirty = false;
    g_3ds_native_metal = nativeMetal;
    g_3ds_hybrid = nativeMetal && threeDSRenderer == 2;
    g_metal_native_batches = nativeMetal ? (uint64_t (*)(void))dlsym(g_3ds_metal_handle, "dstv_metal_native_batches") : NULL;
    g_metal_vertex_batches = nativeMetal ? (uint64_t (*)(void))dlsym(g_3ds_metal_handle, "dstv_metal_vertex_batches") : NULL;
    g_metal_fallback_batches = nativeMetal ? (uint64_t (*)(void))dlsym(g_3ds_metal_handle, "dstv_metal_fallback_batches") : NULL;
    g_is_3ds = path != NULL && !desmume && !dust && !mgba && !psp;
    g_is_mgba = mgba; g_is_psp = psp;
    dstv_video_set_single(mgba || psp);
    g_is_dust = dust;
    g_is_desmume = desmume;
    dstv_video_set_3ds(g_is_3ds);
    return g_core.retro_api_version() == 1;
}

// MARK: - Video state

static uint64_t g_total_video_frames = 0;

// MARK: - Logging

static void frontend_log(
    int level,
    const char *fmt,
    ...
)
{
    if ((g_is_mgba || g_is_psp) && level < 2) return;

    va_list args;

    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);

    fflush(stderr);
}

// Copy legacy option defaults: the core's registration array is temporary.
// Its V0 format puts the default first: "Description; default|alternative".
#define DSTV_MAX_CORE_OPTIONS 256
static struct retro_variable g_options[DSTV_MAX_CORE_OPTIONS];
static size_t g_option_count;
static void clear_core_options(void) {
    for (size_t i = 0; i < g_option_count; ++i) {
        free((void *)g_options[i].key); free((void *)g_options[i].value);
    }
    g_option_count = 0;
}
static bool register_core_options(const struct retro_variable *options) {
    if (!options) return false;
    clear_core_options();
    for (size_t i = 0; i < DSTV_MAX_CORE_OPTIONS; ++i) {
        if (!options[i].key) return true;
        // Dynamic file/interface options can legitimately have no choices.
        if (!options[i].value || !options[i].value[0]) continue;
        const char *start = strstr(options[i].value, "; ");
        if (!start) break;
        start += 2;
        const size_t length = strcspn(start, "|");
        const size_t key_length = strlen(options[i].key);
        if (!length || length > 4096 || !key_length || key_length > 256) break;
        char *key = malloc(key_length + 1), *value = malloc(length + 1);
        if (!key || !value) { free(key); free(value); break; }
        memcpy(key, options[i].key, key_length + 1);
        memcpy(value, start, length); value[length] = '\0';
        g_options[g_option_count++] = (struct retro_variable){key, value};
    }
    clear_core_options(); return false;
}

// MARK: - Environment callback

static bool environment_callback(
    unsigned cmd,
    void *data
)
{
    switch (cmd) {
        case 15: { // RETRO_ENVIRONMENT_GET_VARIABLE
            if (!data) return false;
            struct retro_variable *variable = data;
            if (g_is_psp && variable->key) {
                if (!strcmp(variable->key, "ppsspp_cropto16x9") || !strcmp(variable->key, "ppsspp_fast_memory") || !strcmp(variable->key, "ppsspp_skip_buffer_effects") || !strcmp(variable->key, "ppsspp_skip_gpu_readbacks")) { variable->value = "disabled"; return true; }
                if (!strcmp(variable->key, "ppsspp_backend")) { variable->value = "vulkan"; return true; }
                if (!strcmp(variable->key, "ppsspp_cpu_core")) { variable->value = "IR JIT"; return true; } // upstream name for its non-JIT IR interpreter
                if (!strcmp(variable->key, "ppsspp_internal_resolution")) { variable->value = g_psp_resolution; return true; }
                if (!strcmp(variable->key, "ppsspp_texture_filtering")) { variable->value = g_psp_filtering; return true; }
                if (!strcmp(variable->key, "ppsspp_texture_anisotropic_filtering")) { variable->value = g_psp_anisotropic; return true; }
                if (!strcmp(variable->key, "ppsspp_inflight_frames")) { variable->value = "No buffer"; return true; }
                if (!strcmp(variable->key, "ppsspp_frameskip")) { variable->value = "0"; return true; }
                if (!strcmp(variable->key, "ppsspp_auto_frameskip")) { variable->value = "disabled"; return true; }
            }

            if (variable->key && strcmp(variable->key, "melonds_show_cursor") == 0) {
                variable->value = "disabled"; // A real touchscreen needs no software pointer.
                #if DEBUG
                printf("Core cursor option read: disabled\n");
                #endif
                return true;
            }
            if (g_is_dust && variable->key) {
                if (!strcmp(variable->key, "dust_resolution")) {
                    static const char *factors[] = {"1", "2", "3", "4", "5", "6", "7", "8"};
                    unsigned factor = (unsigned)atoi(g_ds_resolution) / 256;
                    variable->value = factors[(factor >= 1 && factor <= 8 ? factor : 1) - 1]; return true;
                }
                if (!strcmp(variable->key, "dust_output_limit")) { variable->value = g_dust_output_limit; return true; }
                if (!strcmp(variable->key, "dust_output_rate")) {
                    variable->value = !strcmp(g_ds_frameskip, "1") ? "30" : "60"; return true;
                }
            }
            if (g_is_desmume && variable->key) {
                if (!strcmp(variable->key, "desmume_internal_resolution")) {
                    variable->value = g_ds_resolution; return true;
                }
                if (!strcmp(variable->key, "desmume_frameskip")) {
                    variable->value = g_ds_frameskip; return true;
                }
                #if DEBUG
                if (!strcmp(variable->key, "desmume_num_cores")) {
                    const char *workers = getenv("DSTV_DS_WORKERS");
                    if (workers && strlen(workers) == 1 && workers[0] >= '1' && workers[0] <= '4') {
                        variable->value = workers; return true;
                    }
                }
                #endif
                static const struct retro_variable ds_overrides[] = {
                    {"desmume_color_depth", "16-bit"}, {"desmume_opengl_mode", "disabled"},
                    {"desmume_cpu_mode", "interpreter"}, {"desmume_num_cores", "4"},
                    {"desmume_screens_layout", "top/bottom"},
                    {"desmume_pointer_mouse", "enabled"}, {"desmume_pointer_type", "touch"},
                    {"desmume_pointer_device_l", "none"}, {"desmume_pointer_device_r", "none"},
                    {"desmume_load_to_memory", "enabled"}
                };
                for (size_t i = 0; i < sizeof(ds_overrides)/sizeof(ds_overrides[0]); ++i)
                    if (!strcmp(variable->key, ds_overrides[i].key)) {
                        variable->value = ds_overrides[i].value; return true;
                    }
            }
            if (g_is_3ds && variable->key) {
                if (g_3ds_native_metal && !strcmp(variable->key, "citra_graphics_api")) { variable->value = g_3ds_hybrid ? "MetalHybrid" : "Metal"; return true; }
                if (!strcmp(variable->key, "dstv_presentation_rate")) {
                    variable->value = g_presentation_rate; return true;
                }
                if (!strcmp(variable->key, "citra_resolution_factor")) {
                    variable->value = g_3ds_resolution; return true;
                }
                static const struct retro_variable overrides[] = {
                    {"citra_graphics_api", "Vulkan"},
                    {"citra_use_cpu_jit", "disabled"}, {"citra_use_shader_jit", "disabled"},
                    {"citra_layout_option", "default"},
                    {"citra_swap_screen", "Top"}, {"citra_render_3d", "off"},
                    {"citra_analog_function", "c_stick"},
                    {"citra_enable_mouse_touchscreen", "disabled"},
                    {"citra_enable_touch_touchscreen", "enabled"},
                    {"citra_use_libretro_save_path", "LibRetro Default"}
                };
                for (size_t i = 0; i < sizeof(overrides)/sizeof(overrides[0]); ++i)
                    if (!strcmp(variable->key, overrides[i].key)) {
                        variable->value = overrides[i].value; return true;
                    }
            }
            for (size_t i = 0; variable->key && i < g_option_count; ++i) {
                if (strcmp(variable->key, g_options[i].key) == 0) {
                    variable->value = g_options[i].value; return true;
                }
            }
            variable->value = NULL; return false;
        }
        case 16: // RETRO_ENVIRONMENT_SET_VARIABLES
            return register_core_options(data);
        case 17: // RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE
            if (!data) return false;
            *(bool *)data = g_is_psp ? g_psp_options_dirty : ((g_is_3ds || g_is_desmume || g_is_dust) && g_3ds_options_dirty);
            if (g_is_psp) g_psp_options_dirty = false; else g_3ds_options_dirty = false;
            return true;
        case 37: return data != NULL; // SET_GEOMETRY: snapshots validate bounded vertical layouts
        case 74: // RETRO_ENVIRONMENT_GET_JIT_CAPABLE
            if (!g_is_psp || !data) return false;
            *(bool *)data = false; return true;
        case 52: // RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION
            if (!data) return false;
            *(unsigned *)data = 0; return true;

        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            if (
                !data ||
                g_system_directory[0] == '\0'
            ) {
                return false;
            }

            *(const char **)data =
                g_system_directory;

            return true;

        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            if (
                !data ||
                g_save_directory[0] == '\0'
            ) {
                return false;
            }

            *(const char **)data =
                g_save_directory;

            return true;

        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            if (!data) {
                return false;
            }

            ((struct retro_log_callback *)data)->log =
                frontend_log;

            return true;

        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            if (!data) {
                return false;
            }

            return (
                *(unsigned *)data ==
                RETRO_PIXEL_FORMAT_XRGB8888 || ((g_is_desmume || g_is_mgba) && *(unsigned *)data == 2)
            );

        default:
            return false;
    }
}

// MARK: - Video callback

static void video_callback(
    const void *data,
    unsigned width,
    unsigned height,
    size_t pitch
)
{
    if (
        data == NULL ||
        data == (const void *)(intptr_t)-1
    ) {
        return;
    }

    if (!height || pitch > SIZE_MAX / height) return;
    const int captured = (g_is_desmume || g_is_mgba)
        ? dstv_video_capture_rgb565(data, pitch * height, width, height, pitch)
        : dstv_video_capture(data, pitch * height, width, height, pitch);
    if (captured) g_total_video_frames++;

}

// MARK: - Audio callbacks

static void audio_callback(
    int16_t left,
    int16_t right
)
{
    ++g_total_core_audio_frames;
    const int16_t pair[2] = {left, right};
    if (g_audio_enabled) dstv_audio_push(pair, 1);
}

static size_t audio_batch_callback(
    const int16_t *data,
    size_t frames
)
{
    g_total_core_audio_frames += frames;
    if (g_audio_enabled) dstv_audio_push(data, frames);
    return frames;
}

// Libretro joypad IDs: B=0, Y=1, Select=2, Start=3, Up=4, Down=5,
// Left=6, Right=7, A=8, X=9, L=10, R=11.
static uint16_t g_buttons, g_companion_buttons;
void dstv_set_companion_buttons(uint16_t buttons) { g_companion_buttons = buttons & 0x0fff; }
static int16_t g_analog[2][2];
void dstv_set_analog(int16_t lx, int16_t ly, int16_t rx, int16_t ry) {
    g_analog[0][0] = lx; g_analog[0][1] = ly; g_analog[1][0] = rx; g_analog[1][1] = ry;
}
static int16_t g_touch_x, g_touch_y, g_touch_pressed;
void dstv_set_touch(int32_t pressed, uint16_t x, uint16_t y) {
    g_touch_pressed = pressed && x < 256 && y < 192;
    // Pointer space covers the core's fixed 256x384 top/bottom layout.
    // Aim at pixel centres to avoid rounding onto the neighbouring pixel.
    if (g_is_3ds) {
        // Companion retains its 256x192 wire format; map into native 320x240.
        int32_t px = x * 320 / 256 + 40, py = y * 240 / 192 + 240;
        g_touch_x = (int16_t)(((2 * px + 1) * 32767) / 400 - 32767);
        g_touch_y = (int16_t)(((2 * py + 1) * 32767) / 480 - 32767);
        return;
    }
    g_touch_x = (int16_t)(((2 * (int32_t)x + 1) * 32767) / 256 - 32767);
    g_touch_y = (g_is_desmume || g_is_dust) ? (int16_t)(((2 * (int32_t)y + 1) * 32767) / 192 - 32767) :
        (int16_t)(((2 * ((int32_t)y + 192) + 1) * 32767) / 384 - 32767);
}
void dstv_set_buttons(uint16_t buttons) { g_buttons = buttons & (g_is_3ds ? 0x3fff : 0x0fff); }

// MARK: - Input callbacks

static void input_poll_callback(void)
{
}

static int16_t input_state_callback(
    unsigned port,
    unsigned device,
    unsigned index,
    unsigned id
)
{
    if (port == 0 && (device & 0xff) == 5 && index < 2 && id < 2) return g_analog[index][id];
    if (port == 0 && (device & 0xff) == 6 && index == 0) {
        if (id == 0) return g_touch_x;
        if (id == 1) return g_touch_y;
        if (id == 2) return g_touch_pressed;
        return 0;
    }
    if (port != 0 || (device & 0xff) != 1 || index != 0 || id >= 16)
        return 0;
    return ((g_buttons | g_companion_buttons) & (1u << id)) ? 1 : 0;
}

// MARK: - Directory setup

int32_t dstv_set_directories(
    const char *system_directory,
    const char *save_directory
)
{
    if (
        !system_directory ||
        !save_directory
    ) {
        return 0;
    }

    int system_result = snprintf(
        g_system_directory,
        sizeof(g_system_directory),
        "%s",
        system_directory
    );

    if (
        system_result < 0 ||
        (size_t)system_result >=
            sizeof(g_system_directory)
    ) {
        return 0;
    }

    int save_result = snprintf(
        g_save_directory,
        sizeof(g_save_directory),
        "%s",
        save_directory
    );

    if (
        save_result < 0 ||
        (size_t)save_result >=
            sizeof(g_save_directory)
    ) {
        return 0;
    }

    return 1;
}

// MARK: - Core initialisation

uint32_t dstv_initialise_core(void)
{
    if (!g_core.retro_init && !dstv_select_core(NULL, 0)) return 0;
    if (g_core_initialised) {
        return g_core.retro_api_version();
    }

    g_core.retro_set_environment(
        environment_callback
    );

    g_core.retro_set_video_refresh(
        video_callback
    );

    g_core.retro_set_audio_sample(
        audio_callback
    );

    g_core.retro_set_audio_sample_batch(
        audio_batch_callback
    );

    g_core.retro_set_input_poll(
        input_poll_callback
    );

    g_core.retro_set_input_state(
        input_state_callback
    );

    g_core.retro_init();

    g_core_initialised = true;

    return g_core.retro_api_version();
}

// MARK: - ROM loading

int32_t dstv_load_rom(
    const char *path
)
{
    if (!path) {
        return -1;
    }

    if (g_game_loaded) {
        return -2;
    }

    if (!g_core_initialised) {
        return -10;
    }

    struct retro_system_info info = {0};
    g_core.retro_get_system_info(&info);
    if (!info.need_fullpath) {
    FILE *file = fopen(
        path,
        "rb"
    );

    if (!file) {
        return -3;
    }

    if (
        fseek(
            file,
            0,
            SEEK_END
        ) != 0
    ) {
        fclose(file);
        return -4;
    }

    long length = ftell(file);

    if (length <= 0) {
        fclose(file);
        return -5;
    }

    rewind(file);

    g_rom_size = (size_t)length;

    g_rom_data = malloc(
        g_rom_size
    );

    if (!g_rom_data) {
        fclose(file);
        g_rom_size = 0;
        return -6;
    }

    size_t bytes_read = fread(
        g_rom_data,
        1,
        g_rom_size,
        file
    );

    fclose(file);

    if (
        bytes_read !=
        g_rom_size
    ) {
        free(g_rom_data);

        g_rom_data = NULL;
        g_rom_size = 0;

        return -7;
    }

    }
    g_rom_path = strdup(path);

    if (!g_rom_path) {
        free(g_rom_data);

        g_rom_data = NULL;
        g_rom_size = 0;

        return -8;
    }

    struct retro_game_info game = {
        .path = g_rom_path,
        .data = g_rom_data,
        .size = g_rom_size,
        .meta = NULL
    };

    if (!g_core.retro_load_game(&game)) {
        free(g_rom_path);
        free(g_rom_data);

        g_rom_path = NULL;
        g_rom_data = NULL;
        g_rom_size = 0;

        return -9;
    }

    g_has_run_frame = false;
    g_game_loaded = true;
    g_core.retro_get_system_av_info(&g_av_info);
    fprintf(stderr, "Core timing: %.6f fps, %.0f Hz\n",
            g_av_info.timing.fps, g_av_info.timing.sample_rate);

    return 1;
}

// MARK: - Live frame execution

int32_t dstv_run_one_frame(void)
{
    if (!g_game_loaded) {
        return 0;
    }

    g_has_run_frame = true;
    // Opt-in wall/thread CPU timing distinguishes emulation work from GPU
    // waits or descheduling. No timers/logging in normal frame execution.
    const char *timing = g_is_3ds ? getenv("DSTV_TICK_PROFILE") : NULL;
    const bool profile = timing && strcmp(timing,"0") != 0;
    struct timespec wallStart, cpuStart, wallEnd, cpuEnd;
    if (profile) {clock_gettime(CLOCK_MONOTONIC,&wallStart);clock_gettime(CLOCK_THREAD_CPUTIME_ID,&cpuStart);}
    g_core.retro_run();
    if (profile) {
        clock_gettime(CLOCK_THREAD_CPUTIME_ID,&cpuEnd);clock_gettime(CLOCK_MONOTONIC,&wallEnd);
        const double wall=(wallEnd.tv_sec-wallStart.tv_sec)+(wallEnd.tv_nsec-wallStart.tv_nsec)*1e-9;
        const double cpu=(cpuEnd.tv_sec-cpuStart.tv_sec)+(cpuEnd.tv_nsec-cpuStart.tv_nsec)*1e-9;
        static double window=0,totalWall=0,totalCPU=0,maxWall=0,maxCPU=0;
        static uint64_t ticks=0,over33=0,over100=0,previousAudio=0;
        const double now=wallEnd.tv_sec+wallEnd.tv_nsec*1e-9;
        if (!window) window=now;
        totalWall+=wall;totalCPU+=cpu;++ticks;
        if(wall>maxWall) {maxWall=wall;maxCPU=cpu;}
        over33+=wall>0.033333;over100+=wall>0.1;
        if(now-window>=5) {
            printf("Core wall/CPU: seconds=%.3f ticks=%llu wall_ms/tick=%.3f cpu_ms/tick=%.3f max_wall_ms=%.3f cpu_at_max_ms=%.3f over33=%llu over100=%llu audio_frames_per_tick=%.4f\n",now-window,(unsigned long long)ticks,totalWall*1000/ticks,totalCPU*1000/ticks,maxWall*1000,maxCPU*1000,(unsigned long long)over33,(unsigned long long)over100,(double)(g_total_core_audio_frames-previousAudio)/ticks);
            previousAudio=g_total_core_audio_frames;window=now;totalWall=totalCPU=maxWall=maxCPU=0;ticks=over33=over100=0;
        }
    }
    ++g_total_core_ticks;

    return 1;
}

// MARK: - Top screen access

const void *dstv_top_framebuffer(void) { return dstv_video_screen(0); }
const void *dstv_bottom_framebuffer(void) { return dstv_video_screen(1); }

uint32_t dstv_top_frame_width(void)
{
    return dstv_video_width(0);
}

uint32_t dstv_top_frame_height(void)
{
    return dstv_video_height();
}

uint32_t dstv_top_frame_pitch(void)
{
    return dstv_video_width(0) * 4;
}

uint64_t dstv_total_video_frames(void)
{
    return g_total_video_frames;
}

// SRAM is owned by the core. Only copies cross into Swift, between frames.


size_t dstv_memory_size(uint32_t region) { return g_game_loaded && region <= 1 ? g_core.retro_get_memory_size(region) : 0; }
int32_t dstv_copy_memory(uint32_t region, void *destination, size_t size) {
    const void *source = g_game_loaded && region <= 1 ? g_core.retro_get_memory_data(region) : NULL;
    if (!source || !destination || !size || size != dstv_memory_size(region)) return 0;
    memcpy(destination, source, size); return 1;
}
int32_t dstv_restore_memory(uint32_t region, const void *source, size_t size) {
    void *destination = g_game_loaded && region <= 1 ? g_core.retro_get_memory_data(region) : NULL;
    if (g_has_run_frame || !destination || !source || !size || size != dstv_memory_size(region)) return 0;
    memcpy(destination, source, size); return 1;
}
size_t dstv_sram_size(void) {
    return g_game_loaded ? g_core.retro_get_memory_size(0) : 0; // RETRO_MEMORY_SAVE_RAM
}
int32_t dstv_copy_sram(void *destination, size_t size) {
    if (!destination || !size || size != dstv_sram_size()) return 0;
    const void *source = g_core.retro_get_memory_data(0);
    if (!source) return 0;
    memcpy(destination, source, size);
    return 1;
}
int32_t dstv_restore_sram(const void *source, size_t size) {
    if (g_has_run_frame || !source || !size || size != dstv_sram_size()) return 0;
    void *destination = g_core.retro_get_memory_data(0);
    if (!destination) return 0;
    memcpy(destination, source, size);
    return 1;
}

// MARK: - Shutdown

void dstv_deinitialise_core(void)
{
    dstv_set_touch(0, 0, 0);
    g_buttons = 0; g_companion_buttons = 0;
    dstv_set_analog(0, 0, 0, 0);
    if (g_game_loaded) {
        g_core.retro_unload_game();
        g_game_loaded = false;
    }

    if (g_rom_path) {
        free(g_rom_path);
        g_rom_path = NULL;
    }

    if (g_rom_data) {
        free(g_rom_data);
        g_rom_data = NULL;
    }

    g_rom_size = 0;
    dstv_video_reset();

    if (g_core_initialised) {
        g_core.retro_deinit();
        g_core_initialised = false;
    }
    clear_core_options();
}
// Emulator control operations share retro_run's main-thread ownership.

int32_t dstv_reset_game(void) {
    if (!g_game_loaded) return 0;
    g_core.retro_reset();
    return 1;
}




size_t dstv_state_size(void) {
    // Azahar serializes its full VM here (variable size and high memory use).
    // Enable states only after implementing a dedicated, validated 3DS path.
    return g_game_loaded && !g_is_3ds ? g_core.retro_serialize_size() : 0;
}
int32_t dstv_save_state(void *data, size_t size) {
    return data && size && size <= (g_is_psp ? 128u : 64u) * 1024u * 1024u && size == dstv_state_size() && g_core.retro_serialize(data, size);
}
int32_t dstv_load_state(const void *data, size_t size) {
    return data && size && size <= (g_is_psp ? 128u : 64u) * 1024u * 1024u && size == dstv_state_size() && g_core.retro_unserialize(data, size);
}

uint32_t dstv_bottom_frame_width(void) { return dstv_video_width(1); }
uint32_t dstv_bottom_frame_height(void) { return dstv_video_height(); }
uint32_t dstv_bottom_frame_pitch(void) { return dstv_video_width(1) * 4; }
