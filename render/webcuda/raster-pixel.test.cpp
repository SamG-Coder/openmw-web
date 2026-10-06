// The traversal must be a bijection, including compact partial edge tiles.
#include <cassert>
#include <cstdio>
#include <utility>
#include <vector>
#define __device__
#include "raster-pixel.cuh"

static void check(unsigned width,unsigned height) {
    std::vector<unsigned char> seen(width*height);
    for(unsigned invocation=0;invocation<width*height;invocation++) {
        unsigned pixel=raster_pixel_index(invocation,width,height);
        assert(pixel<width*height);
        assert(seen[pixel]++==0);
        // Each complete tile has 256 invocations. Consecutive 32-lane warps
        // stay within its one candidate list when tile rows are complete.
        if(width%16==0 && height%16==0) {
            unsigned first=raster_pixel_index(invocation/32*32,width,height);
            assert(pixel%width/16==first%width/16);
            assert(pixel/width/16==first/width/16);
        }
    }
    for(auto count:seen)assert(count==1);
}

int main() {
    unsigned cases=0;
    for(unsigned width:{1u,2u,7u,15u,16u,17u,31u,32u,33u,127u,128u,129u})
    for(unsigned height:{1u,2u,7u,15u,16u,17u,31u,32u,33u,127u,128u,129u}) {
        check(width,height);cases++;
    }
    for(auto shape: {std::pair{8192u,33u},std::pair{33u,8192u},std::pair{8192u,8192u}}) {
        check(shape.first,shape.second);cases++;
    }
    std::printf("Raster traversal: %u dimensions cover every pixel exactly once; full-tile warps share a candidate list\n",cases);
}
