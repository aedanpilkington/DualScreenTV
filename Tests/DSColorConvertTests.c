#include "../Scripts/DeSmuME/DSColorConvert.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
int main(void) {
    uint16_t *in=malloc(65536*2),*out=malloc(65536*2);
    for(unsigned p=0;p<65536;++p) in[p]=p;
    DSTVConvert1555Row(out,in,65536);
    for(unsigned p=0;p<65536;++p) {
        unsigned r=p&31,g=(p>>5)&31,b=(p>>10)&31;
        assert(out[p]==((r<<11)|(g<<6)|(g>>4)<<5|b));
    }
    for(unsigned n=1;n<33;++n) {
        DSTVConvert1555Row(out+1,in+1,n);
        for(unsigned x=1;x<=n;++x) assert(out[x]==((x&31)<<11|((x>>5)&31)<<6|((x>>9)&1)<<5|((x>>10)&31)));
    }
    free(in);free(out);puts("DS colour conversion: all 65536 values, unaligned rows and scalar tails passed");
}
