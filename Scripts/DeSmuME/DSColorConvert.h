// GPL-2.0-or-later. Exact DeSmuME BGR555 to RGB565 conversion for ARM.
#pragma once
#include <stdint.h>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif
static inline void DSTVConvert1555Row(uint16_t *dst,const uint16_t *src,unsigned width) {
    unsigned x=0;
#if defined(__ARM_NEON)
    for(;x+8<=width;x+=8) {
        const uint16x8_t p=vld1q_u16(src+x);
        const uint16x8_t r=vandq_u16(vshlq_n_u16(p,11),vdupq_n_u16(0xf800));
        const uint16x8_t g=vandq_u16(vshlq_n_u16(p,1),vdupq_n_u16(0x07c0));
        const uint16x8_t b=vandq_u16(vshrq_n_u16(p,10),vdupq_n_u16(0x001f));
        const uint16x8_t lowGreen=vandq_u16(vshrq_n_u16(p,4),vdupq_n_u16(0x0020));
        vst1q_u16(dst+x,vorrq_u16(vorrq_u16(r,g),vorrq_u16(b,lowGreen)));
    }
#endif
    for(;x<width;++x) {
        const uint16_t p=src[x];
        dst[x]=((p<<11)&0xf800)|((p<<1)&0x07c0)|((p>>10)&0x001f)|((p>>4)&0x0020);
    }
}
