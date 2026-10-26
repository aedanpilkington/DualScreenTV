// Opt-in integration check: macOS Dust dylib, user-supplied Pokémon Black ROM.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <filesystem>
#include <chrono>
#include <dlfcn.h>
#include "libretro.h"
static const char *factor = "4", *limit = "4", *rate = "60";
static char saves[256];
static unsigned width, height;
static size_t audioFrames, videoFrames;
static bool audible;
static bool environment(unsigned command, void *data) {
    if(command == RETRO_ENVIRONMENT_GET_VARIABLE) {
        auto *v = static_cast<retro_variable *>(data);
        v->value = !strcmp(v->key,"dust_resolution") ? factor :
            !strcmp(v->key,"dust_output_limit") ? limit :
            !strcmp(v->key,"dust_output_rate") ? rate : nullptr;
        return v->value != nullptr;
    }
    if(command == RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY) { *static_cast<const char **>(data)=saves; return true; }
    return command == RETRO_ENVIRONMENT_SET_PIXEL_FORMAT || command == RETRO_ENVIRONMENT_SET_GEOMETRY;
}
static void video(const void *p,unsigned w,unsigned h,size_t pitch) {
    if(!p || pitch != w*4) std::abort();
    width=w; height=h; ++videoFrames;
}
static size_t audio(const int16_t *p,size_t frames) {
    audioFrames+=frames;
    for(size_t i=0;i<frames*2;++i) if(p[i] > 1024 || p[i] < -1024) audible=true;
    return frames;
}
static void sample(int16_t,int16_t) {}
static void poll() {}
static int16_t input(unsigned,unsigned,unsigned,unsigned) {return 0;}
int main(int argc,char **argv) {
    if(argc!=3) return 2;
    snprintf(saves,sizeof(saves),"/tmp/dstv-dust-integration-%lld",(long long)std::chrono::steady_clock::now().time_since_epoch().count());
    if(!std::filesystem::create_directory(saves)) return 2;
    void *handle=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if(!handle) { puts(dlerror()); return 1; }
#define FN(n) auto n=reinterpret_cast<decltype(&::n)>(dlsym(handle,#n)); if(!n) return 3
    FN(retro_set_environment); FN(retro_set_video_refresh); FN(retro_set_audio_sample);
    FN(retro_set_audio_sample_batch); FN(retro_set_input_poll); FN(retro_set_input_state);
    FN(retro_init); FN(retro_load_game); FN(retro_run); FN(retro_unload_game); FN(retro_deinit); FN(retro_reset);
    auto scale=reinterpret_cast<uint32_t(*)()>(dlsym(handle,"dstv_dust_internal_scale")); if(!scale)return 3;
    auto gpuFrames=reinterpret_cast<uint64_t(*)()>(dlsym(handle,"dstv_dust_gpu_frame_count")); if(!gpuFrames)return 3;
    FILE *file=fopen(argv[2],"rb"); if(!file)return 2;
    fseek(file,0,SEEK_END); std::vector<char> rom(ftell(file)); rewind(file);
    if(fread(rom.data(),1,rom.size(),file)!=rom.size())return 2; fclose(file);
    retro_game_info game={argv[2],rom.data(),rom.size(),nullptr};
    retro_set_environment(environment); retro_set_video_refresh(video); retro_set_audio_sample(sample);
    retro_set_audio_sample_batch(audio); retro_set_input_poll(poll); retro_set_input_state(input);
    retro_init(); if(!retro_load_game(&game))return 4;
    for(int i=0;i<6500;++i)retro_run();
    if(width!=1024 || height!=1536 || videoFrames!=6500 || audioFrames<3500000 || !audible)return 5;
    if(gpuFrames()<100)return 11;
    factor="8"; for(int i=0;i<120;++i)retro_run();
    if(scale()!=8 || width!=1024)return 6;
    limit="8"; for(int i=0;i<60;++i)retro_run();
    if(width!=2048 || height!=3072)return 7;
    for (const char *intermediate : {"3", "5", "6", "7"}) {
        factor=intermediate; unsigned expected=atoi(factor);
        for(int i=0;i<60;++i)retro_run();
        if(scale()!=expected || width!=256*expected || height!=384*expected)return 13;
        limit="4"; for(int i=0;i<60;++i)retro_run();
        if(scale()!=expected || width!=256*(expected<4?expected:4))return 14;
        limit="8";
    }
    factor="2"; for(int i=0;i<120;++i)retro_run();
    if(width!=512 || scale()!=2)return 8;
    rate="30"; auto previous=videoFrames; auto previousAudio=audioFrames;
    for(int i=0;i<120;++i)retro_run();
    if(videoFrames-previous!=60 || audioFrames-previousAudio<65000)return 9;
    rate="60"; previous=videoFrames;
    for(int i=0;i<120;++i)retro_run();
    if(videoFrames-previous!=120)return 12;
    retro_reset(); for(int i=0;i<120;++i)retro_run();
    retro_unload_game();retro_deinit();
    for(int cycle=0;cycle<2;++cycle){
        retro_init();if(!retro_load_game(&game))return 10;
        for(int i=0;i<120;++i)retro_run();
        retro_unload_game();retro_deinit();
    }
    puts("Dust integration: hot GPU, 3x–8x including 5x/6x/7x, output cap, live resize, 30 FPS/audio, reset and reload passed");
}
