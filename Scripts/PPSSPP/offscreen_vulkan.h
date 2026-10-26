// DualScreenTV offscreen Vulkan adapter. GPL-2.0-or-later.
#pragma once
#include "libretro.h"
namespace DSTVOffscreen {
retro_environment_t WrapEnvironment(retro_environment_t callback);
retro_video_refresh_t WrapVideo(retro_video_refresh_t callback);
bool Initialize();
void Shutdown();
}
