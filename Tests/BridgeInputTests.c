// Exercise the actual frontend callback boundary without loading a ROM/core.
#include "../Apps/tvOS/DualScreenTV/DualScreenTV/LibretroBridge.c"
#include <assert.h>
#include <math.h>
int main(void) {
    g_is_3ds=true;g_av_info.timing.fps=60;g_av_info.timing.sample_rate=32728;
    assert(fabs(dstv_frames_per_second()-268111856.0/4481136.0)<1e-10);
    assert(fabs(dstv_sample_rate()-268111856.0/8192.0)<1e-10);
    // One guest video tick generates FRAME_TICKS/8192 stereo sample frames.
    assert(fabs(dstv_sample_rate()/dstv_frames_per_second()-4481136.0/8192.0)<1e-10);
    g_av_info.timing.fps=59.5;assert(dstv_frames_per_second()==59.5 && dstv_sample_rate()==32728);
    g_is_3ds=false;g_av_info.timing.fps=60;
    assert(dstv_frames_per_second()==60 && dstv_sample_rate()==32728);
    g_av_info.timing.fps=0;assert(dstv_frames_per_second()==60);

    g_is_psp = true;
    dstv_set_psp_options(2, 2, 4);
    bool psp_updated = false;
    assert(environment_callback(17, &psp_updated) && psp_updated);
    assert(environment_callback(17, &psp_updated) && !psp_updated);
    dstv_set_psp_options(2, 2, 4);
    assert(environment_callback(17, &psp_updated) && !psp_updated);
    struct retro_variable psp_resolution = {"ppsspp_internal_resolution", NULL};
    assert(environment_callback(15, &psp_resolution) && !strcmp(psp_resolution.value, "960x544"));
    dstv_set_psp_options(1, 0, 0);
    assert(environment_callback(17, &psp_updated) && psp_updated);
    g_is_psp = false;

    struct retro_variable cursor = {"melonds_show_cursor", NULL};
    assert(environment_callback(15, &cursor));
    assert(strcmp(cursor.value, "disabled") == 0);
    assert(!environment_callback(15, NULL));
    unsigned version = 99;
    assert(environment_callback(52, &version) && version == 0);
    char temporary[] = "Render mode; software|opengl";
    struct retro_variable definitions[] = {
        {"melonds_show_cursor", "Cursor; always|disabled"},
        {"render", temporary}, {"unavailable", ""}, {NULL, NULL}
    };
    assert(environment_callback(16, definitions));
    memset(temporary, 'x', sizeof(temporary) - 1);
    struct retro_variable render = {"render", NULL};
    assert(environment_callback(15, &render) && strcmp(render.value, "software") == 0);
    assert(environment_callback(15, &cursor) && strcmp(cursor.value, "disabled") == 0);
    bool changed = true;
    assert(environment_callback(17, &changed) && !changed);
    struct retro_variable replacement[] = {{"new", "New; first|second"}, {NULL, NULL}};
    assert(environment_callback(16, replacement));
    assert(!environment_callback(15, &render) && render.value == NULL);
    clear_core_options();
    dstv_set_buttons(1 << 8);
    dstv_set_companion_buttons((1 << 4) | (1 << 0));
    assert(input_state_callback(0, 1, 0, 8) == 1);
    assert(input_state_callback(0, 1, 0, 4) == 1);
    assert(input_state_callback(0, 1, 0, 0) == 1);
    dstv_set_companion_buttons(0);
    assert(input_state_callback(0, 1, 0, 8) == 1); // Releasing iPad doesn't release gamepad A.
    assert(input_state_callback(0, 1, 0, 4) == 0);
    for (int y = 0; y < 192; ++y) for (int x = 0; x < 256; ++x) {
        dstv_set_touch(1, x, y);
        int px = input_state_callback(0, 6, 0, 0), py = input_state_callback(0, 6, 0, 1);
        assert(input_state_callback(0, 6, 0, 2) == 1);
        // Invert melonDS's 256x384 pointer matrix and bottom translation.
        assert((int)((px + 32767.0) * 256 / 65534) == x);
        assert((int)((py + 32767.0) * 384 / 65534 - 192) == y);
    }
    dstv_set_touch(0, 0, 0);
    assert(input_state_callback(0, 6, 0, 2) == 0);
    dstv_set_touch(1, 256, 0);
    assert(input_state_callback(0, 6, 0, 2) == 0);
    assert(input_state_callback(1, 6, 0, 2) == 0);
    assert(input_state_callback(0, 6, 1, 2) == 0);
    g_is_dust = true;
    struct retro_variable dustResolution = {"dust_resolution", NULL};
    for (unsigned factor = 1; factor <= 8; ++factor) {
        dstv_set_ds_resolution(factor);
        assert(environment_callback(15, &dustResolution));
        assert(dustResolution.value[0] == (char)('0' + factor) && dustResolution.value[1] == 0);
    }
    g_is_dust = false;
    g_is_3ds = true;
    struct retro_variable cadence = {"dstv_presentation_rate", NULL};
    dstv_set_presentation_rate(30);
    assert(environment_callback(15, &cadence) && !strcmp(cadence.value, "30"));
    dstv_set_presentation_rate(99);
    assert(environment_callback(15, &cadence) && !strcmp(cadence.value, "60"));
    struct retro_variable resolution = {"citra_resolution_factor", NULL};
    for (unsigned factor = 1; factor <= 4; ++factor) {
        dstv_set_3ds_resolution(factor);
        assert(environment_callback(15, &resolution));
        assert(resolution.value[0] == (char)('0' + factor) && resolution.value[1] == 0);
    }
    g_3ds_native_metal = true;
    dstv_set_3ds_resolution(2);
    assert(environment_callback(15, &resolution) && !strcmp(resolution.value, "2"));
    g_3ds_hybrid = true;
    assert(environment_callback(15, &resolution) && !strcmp(resolution.value, "2"));
    g_3ds_native_metal = false; g_3ds_hybrid = false;
    dstv_set_3ds_resolution(1);
    g_game_loaded = true; g_core_initialised = true;
    dstv_set_3ds_resolution(2);
    assert(environment_callback(15, &resolution) && !strcmp(resolution.value, "2"));
    assert(environment_callback(17, &changed) && changed);
    assert(environment_callback(17, &changed) && !changed); // One notification per change.
    dstv_set_3ds_resolution(2);
    assert(environment_callback(17, &changed) && !changed);
    g_game_loaded = false; g_core_initialised = false;
    dstv_set_3ds_resolution(99);
    assert(environment_callback(15, &resolution) && !strcmp(resolution.value, "1"));
    struct retro_variable graphics = {"citra_graphics_api", NULL};
    assert(environment_callback(15, &graphics) && !strcmp(graphics.value, "Vulkan"));
    struct retro_variable cpuJIT = {"citra_use_cpu_jit", NULL};
    struct retro_variable shaderJIT = {"citra_use_shader_jit", NULL};
    assert(environment_callback(15, &cpuJIT) && !strcmp(cpuJIT.value, "disabled"));
    assert(environment_callback(15, &shaderJIT) && !strcmp(shaderJIT.value, "disabled"));
    dstv_set_buttons((1 << 12) | (1 << 13));
    assert(input_state_callback(0, 1, 0, 12) && input_state_callback(0, 1, 0, 13));
    g_is_3ds = false; dstv_set_buttons(1 << 12);
    assert(!input_state_callback(0, 1, 0, 12));
    g_is_3ds = true;
    dstv_set_analog(12345, -23456, 30000, -30000);
    assert(input_state_callback(0, 5, 0, 0) == 12345);
    assert(input_state_callback(0, 5, 1, 1) == -30000);
    for (int y = 0; y < 192; ++y) for (int x = 0; x < 256; ++x) {
        dstv_set_touch(1, x, y);
        int px = input_state_callback(0, 6, 0, 0), py = input_state_callback(0, 6, 0, 1);
        assert((int)((px + 32767.0) * 400 / 65534) == x * 320 / 256 + 40);
        assert((int)((py + 32767.0) * 480 / 65534) == y * 240 / 192 + 240);
    }
    g_is_3ds = false; g_is_desmume = true; g_core_initialised = true;
    dstv_set_ds_resolution(3);
    struct retro_variable dsResolution = {"desmume_internal_resolution", NULL};
    assert(environment_callback(15, &dsResolution) && !strcmp(dsResolution.value, "768x576"));
    dstv_set_ds_resolution(8);
    assert(environment_callback(15, &dsResolution) && !strcmp(dsResolution.value, "2048x1536"));
    dstv_set_ds_resolution(99);
    assert(environment_callback(15, &dsResolution) && !strcmp(dsResolution.value, "256x192"));
    bool dsUpdated = false;
    assert(environment_callback(17, &dsUpdated) && dsUpdated);
    assert(environment_callback(17, &dsUpdated) && !dsUpdated);
    struct retro_variable dsSkip = {"desmume_frameskip", NULL};
    dstv_set_ds_presentation_rate(30);
    assert(environment_callback(15, &dsSkip) && !strcmp(dsSkip.value, "1"));
    dstv_set_ds_presentation_rate(60);
    assert(environment_callback(15, &dsSkip) && !strcmp(dsSkip.value, "0"));
    assert(environment_callback(17, &dsUpdated) && dsUpdated);
    dstv_set_ds_presentation_rate(60);
    assert(environment_callback(17, &dsUpdated) && !dsUpdated);
    for (int y = 0; y < 192; ++y) for (int x = 0; x < 256; ++x) {
        dstv_set_touch(1, x, y);
        int px = input_state_callback(0, 6, 0, 0), py = input_state_callback(0, 6, 0, 1);
        assert((px + 32768) * 256 / 65536 == x);
        assert((py + 32768) * 192 / 65536 == y);
    }
    dstv_video_set_3ds(0);
    uint16_t rgb565[256 * 384] = {0};
    rgb565[0] = 0xf800; rgb565[1] = 0x07e0; rgb565[2] = 0x001f;
    video_callback(rgb565, 256, 384, 256 * 2);
    const uint32_t *converted = dstv_top_framebuffer();
    assert(converted[0] == 0xffff0000 && converted[1] == 0xff00ff00 && converted[2] == 0xff0000ff);
    puts("Bridge input: no software cursor, physical/companion button merge, all DS touch pixels and release passed");
}
