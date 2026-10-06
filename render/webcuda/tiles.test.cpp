#include <cassert>
#include <cmath>
#include <cstdio>
#include <random>
#include <vector>
unsigned int atomicAdd(unsigned int* p,unsigned int value){auto old=*p;*p+=value;return old;}
unsigned int atomicMax(unsigned int* p,unsigned int value){auto old=*p;if(value>*p)*p=value;return old;}
#define __global__
struct Dim { unsigned int x = 0, y = 0; } blockIdx, blockDim, threadIdx, gridDim;
#include "geometry.cu"
#include "tiles.cu"

int main() {
    const unsigned int width = 35, height = 19, triangles = 64, tiles = 6;
    std::mt19937 rng(2048);
    std::uniform_real_distribution<float> coord(-1.f, 1.f), unit(0.f, 1.f);
    std::vector<float> clip(triangles * 12), colors(clip.size());
    std::vector<unsigned int> indices(triangles * 3), counts(tiles), candidates(tiles * triangles);
    std::vector<float> rgba(width * height * 4), expected(rgba.size());
    std::vector<float> depth(width * height), expectedDepth(depth.size());
    blockDim.x = 1;
    for (int scene = 0; scene < 30; ++scene) {
        for (unsigned int v = 0; v < triangles * 3; ++v) {
            indices[v] = v;
            float w = .1f + unit(rng) * 3.f;
            for (unsigned int k = 0; k < 3; ++k) clip[v*4+k] = coord(rng)*w;
            clip[v*4+3] = w;
            for (unsigned int k = 0; k < 4; ++k) colors[v*4+k] = unit(rng);
        }
        for (blockIdx.x = 0; blockIdx.x < tiles; ++blockIdx.x)
            bin_triangles(clip.data(), indices.data(), counts.data(), candidates.data(), width, height, triangles, triangles, 4, 3);
        for (unsigned int tile = 0; tile < tiles; ++tile) {
            assert(counts[tile] <= triangles);
            for (unsigned int i = 1; i < counts[tile]; ++i)
                assert(candidates[tile*triangles+i-1] < candidates[tile*triangles+i]);
        }
        for (blockIdx.x = 0; blockIdx.x < width*height; ++blockIdx.x) {
            raster_reference(clip.data(), colors.data(), indices.data(), expected.data(), expectedDepth.data(), width, height, triangles);
            raster_tiled(clip.data(), colors.data(), indices.data(), counts.data(), candidates.data(), rgba.data(), depth.data(), width, height, triangles);
        }
        assert(rgba == expected && depth == expectedDepth);
        // Exercise the production triangle-driven count/prefix/scatter path.
        std::vector<float> packed(triangles*3*10),attributes(50);
        std::vector<unsigned int> packedIndices(triangles*4),compactCounts(tiles+1),offsets(tiles+1);
        unsigned int materials[12]={},summary[2]={},blocks[1]={};
        materials[7]=width;materials[8]=height;
        for(unsigned int t=0;t<triangles;t++)for(unsigned int v=0;v<3;v++) {
            packedIndices[t*4+v]=t*3+v;
            for(unsigned int k=0;k<4;k++)packed[(t*3+v)*10+k]=clip[(t*3+v)*4+k];
        }
        const unsigned int maxWords=tiles+1+tiles*triangles;
        std::vector<unsigned int> compact(maxWords+1,0xdeadbeef);
        for(blockIdx.x=0;blockIdx.x<triangles;blockIdx.x++)
            bin_triangle_bounds(packed.data(),packedIndices.data(),compactCounts.data(),compact.data(),offsets.data(),summary,materials,attributes.data(),width,height,triangles,0,0,0,1);
        blockIdx.x=0;prefix_tile_blocks(compactCounts.data(),offsets.data(),blocks,tiles,maxWords);
        prefix_tile_block_totals(compactCounts.data(),blocks,summary,tiles,maxWords);
        assert(summary[1]==0 && summary[0]<=maxWords);
        for(blockIdx.x=0;blockIdx.x<=tiles;blockIdx.x++)finish_tile_prefix(offsets.data(),blocks,summary,tiles);
        for(blockIdx.x=0;blockIdx.x<=tiles;blockIdx.x++)copy_tile_offsets(offsets.data(),compact.data(),tiles);
        for(blockIdx.x=0;blockIdx.x<tiles;blockIdx.x++)clear_tile_counts(compactCounts.data(),tiles);
        // Reverse submission simulates an unordered atomic append schedule.
        for(unsigned int t=triangles;t>0;t--){blockIdx.x=t-1;
            bin_triangle_bounds(packed.data(),packedIndices.data(),compactCounts.data(),compact.data(),offsets.data(),summary,materials,attributes.data(),width,height,triangles,0,1,0,1);
        }
        for(blockIdx.x=0;blockIdx.x<tiles;blockIdx.x++)sort_tile_candidates(compactCounts.data(),compact.data(),tiles,0);
        assert(compact.back()==0xdeadbeef);
        for(unsigned int tile=0;tile<tiles;tile++){
            assert(compactCounts[tile]<=triangles);
            assert(offsets[tile+1]-offsets[tile]==compactCounts[tile]);
            for(unsigned int j=0;j<compactCounts[tile];j++){
                if(j)assert(compact[offsets[tile]+j-1]<compact[offsets[tile]+j]);
                candidates[tile*triangles+j]=compact[offsets[tile]+j];
            }
        }
        for(blockIdx.x=0;blockIdx.x<width*height;blockIdx.x++)
            raster_tiled(clip.data(),colors.data(),indices.data(),compactCounts.data(),candidates.data(),rgba.data(),depth.data(),width,height,triangles);
        assert(rgba==expected && depth==expectedDepth);

    }
    // A tiny list cannot overwrite the next tile's storage or hide its required size.
    std::vector<unsigned int> small(tiles+1, 0xdeadbeef);
    for (blockIdx.x = 0; blockIdx.x < tiles; ++blockIdx.x)
        bin_triangles(clip.data(), indices.data(), counts.data(), small.data(), width, height, triangles, 1, 4, 3);
    assert(small.back() == 0xdeadbeef && counts[0] > 1);
    blockIdx.x = 0;
    raster_tiled(clip.data(), colors.data(), indices.data(), counts.data(), small.data(), rgba.data(), depth.data(), width, height, 1);
    assert(rgba[0] == 1 && rgba[1] == 0 && rgba[2] == 1);
    std::puts("WebCuda tiles: 30 randomized scenes match reference, partial tiles, stable order and overflow checks passed");
}
