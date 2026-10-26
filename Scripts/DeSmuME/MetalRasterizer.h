// GPL-2.0-or-later. Native Metal fragment backend for DeSmuME's scan converter.
#pragma once
#include <cstddef>
#include <cstdint>
class SoftRasterizerRenderer;
void DSTVMetalRelease();
void DSTVMetalSchedule(SoftRasterizerRenderer *renderer, void (*waitGeometry)(SoftRasterizerRenderer *));
bool DSTVMetalWait();
bool DSTVMetalBegin(SoftRasterizerRenderer *renderer);
bool DSTVMetalRecording();
bool DSTVMetalReference();
bool DSTVMetalPostProcessed();
void DSTVMetalSpan(unsigned y, unsigned x, unsigned count, unsigned polygon,
                   uint32_t attr, unsigned flags, const float *coord,
                   const float *coordDelta, const float *color, const float *colorDelta);
bool DSTVMetalFinish(SoftRasterizerRenderer *renderer);
