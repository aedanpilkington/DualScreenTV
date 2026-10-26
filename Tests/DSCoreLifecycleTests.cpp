#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include <vector>
#include <cstdlib>
#include <sys/stat.h>
#include <cstdarg>
#include <filesystem>
#include <chrono>
#include "libretro.h"
static void logger(retro_log_level,const char *fmt,...){va_list a;va_start(a,fmt);vprintf(fmt,a);va_end(a);}
static unsigned tick;
static char saves[256];
static bool dirty=false;
static const char *skip="0";
static size_t audioFrames=0, videoFrames=0;
static bool env(unsigned cmd,void *data) {
 if(cmd==RETRO_ENVIRONMENT_GET_LOG_INTERFACE){((retro_log_callback*)data)->log=logger;return true;}
 if(cmd==RETRO_ENVIRONMENT_GET_VARIABLE){auto*v=(retro_variable*)data;const char*val=nullptr;
 if(!strcmp(v->key,"desmume_internal_resolution"))val="1024x768";
 else if(!strcmp(v->key,"desmume_num_cores"))val="4";
 else if(!strcmp(v->key,"desmume_cpu_mode"))val="interpreter";
 else if(!strcmp(v->key,"desmume_screens_layout"))val="top/bottom";
 else if(!strcmp(v->key,"desmume_frameskip"))val=skip;
 else if(!strcmp(v->key,"desmume_opengl_mode"))val="disabled";
 v->value=val;return val;}
 if(cmd==RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE){*(bool*)data=dirty;dirty=false;return true;}
 if(cmd==RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY || cmd==RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY){*(const char**)data=saves;return true;}
 if(cmd==RETRO_ENVIRONMENT_SET_PIXEL_FORMAT || cmd==RETRO_ENVIRONMENT_SET_VARIABLES || cmd==RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS || cmd==RETRO_ENVIRONMENT_SET_GEOMETRY)return true;
 return false;
}
static std::vector<char> pixels;
static void video(const void *data,unsigned,unsigned height,size_t pitch){if(data){++videoFrames;pixels.assign((const char*)data,(const char*)data+height*pitch);}}
static size_t audio(const int16_t*,size_t n){audioFrames+=n;return n;}
static void sample(int16_t,int16_t){}
static void poll(){}
static int16_t input(unsigned,unsigned device,unsigned,unsigned id){if(device==RETRO_DEVICE_JOYPAD && id==RETRO_DEVICE_ID_JOYPAD_START && tick==300)return 1;return 0;}
// Usage: lifecycle-tests macOS-core.dylib game.nds [RAM-fixture.state]
// Uses a unique temporary save directory, never the frontend's save storage.
int main(int argc,char **argv) {
 if(argc<3)return 2;
 const char *ticksSetting=std::getenv("DSTV_CORE_TEST_TICKS");
 const unsigned ticks=ticksSetting ? (unsigned)std::atoi(ticksSetting) : 120;
 if(ticks<120 || ticks>12000)return 2;
 snprintf(saves,sizeof(saves),"/tmp/dstv-core-lifecycle-%lld",(long long)std::chrono::steady_clock::now().time_since_epoch().count());
 if(!std::filesystem::create_directory(saves))return 2;
 void *h=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!h){puts(dlerror());return 1;}
 #define FN(n) auto n=(decltype(&::n))dlsym(h,#n); if(!n){fprintf(stderr,"Missing core entry point: %s\n",#n);return 1;}
 FN(retro_set_environment);FN(retro_set_video_refresh);FN(retro_set_audio_sample);
 FN(retro_set_audio_sample_batch);FN(retro_set_input_poll);FN(retro_set_input_state);
 FN(retro_init);FN(retro_load_game);FN(retro_run);FN(retro_unload_game);FN(retro_deinit);FN(retro_unserialize);
 FILE *f=fopen(argv[2],"rb");if(!f)return 2;fseek(f,0,SEEK_END);
 std::vector<char> rom(ftell(f));rewind(f);fread(rom.data(),1,rom.size(),f);fclose(f);
 std::vector<char> state;
 if(argc>3){f=fopen(argv[3],"rb");if(!f)return 2;fseek(f,0,SEEK_END);state.resize(ftell(f));rewind(f);fread(state.data(),1,state.size(),f);fclose(f);}
 retro_game_info game={argv[2],rom.data(),rom.size(),nullptr};
 for(int cycle=0;cycle<3;++cycle){
  retro_set_environment(env);retro_set_video_refresh(video);retro_set_audio_sample(sample);
  retro_set_audio_sample_batch(audio);retro_set_input_poll(poll);retro_set_input_state(input);
  retro_init();if(!retro_load_game(&game))return 3;
  if(!state.empty() && !retro_unserialize(state.data(),state.size()))return 4;
  audioFrames=videoFrames=0;
  for(tick=0;tick<ticks;++tick)retro_run();
  if(!audioFrames || !videoFrames)return 5;
  retro_unload_game();retro_deinit();
  printf("Lifecycle cycle %d: audio=%zu, video=%zu passed\n",cycle+1,audioFrames,videoFrames);
 }
}
