// Numerical tests execute the authored kernel bodies on CPU. They do not prove
// generated WGSL correctness or GPU/browser integration.
#include <cassert>
#include <cmath>
#include <cstdio>
#define __global__
struct Dim { unsigned int x = 0, y = 0; } blockIdx, blockDim, threadIdx, gridDim;
#include "geometry.cu"

int main() {
    blockDim.x = 64;
    float positions[] = { 2, 3, 4 };
    float matrix[] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 10,20,30,1 };
    unsigned int matrixIds[] = { 0 };
    float transformed[4] = {};
    transform_vertices(positions, matrix, matrixIds, transformed, 1);
    assert(transformed[0] == 12 && transformed[1] == 23 && transformed[2] == 34 && transformed[3] == 1);
    float clip[] = {
        -1,-1,0.5f,1, 1,-1,0.5f,1, 0,1,0.5f,1,
        -1,-1,-0.5f,1, 1,-1,-0.5f,1, 0,1,-0.5f,1
    };
    float colors[] = {
        1,0,0,1, 1,0,0,1, 1,0,0,1,
        0,1,0,1, 0,1,0,1, 0,1,0,1
    };
    unsigned int indices[] = { 0,1,2, 3,4,5 };
    float rgba[4 * 16] = {}, depth[16] = {};
    auto render = [&]() {
        for (threadIdx.x = 0; threadIdx.x < 64; threadIdx.x++)
            raster_reference(clip, colors, indices, rgba, depth, 4, 4, 2);
    };
    render();
    const unsigned int inside = 9;
    assert(depth[inside] == .25f);
    assert(rgba[inside * 4] == 0 && rgba[inside * 4 + 1] == 1);
    assert(depth[0] == 1 && rgba[0] == 0 && rgba[3] == 1);
    // Reverse triangle submission: depth ordering is independent of input order.
    for (unsigned int i = 0; i < 3; i++) { indices[i] = i + 3; indices[i + 3] = i; }
    render();
    assert(depth[inside] == .25f && rgba[inside * 4 + 1] == 1);
    // Reject geometry behind the camera instead of dividing by zero/negative w.
    for (unsigned int i = 0; i < 6; i++) clip[i * 4 + 3] = 0;
    render();
    assert(depth[inside] == 1 && rgba[inside * 4 + 1] == 0);
    std::puts("transform, depth ordering, background and invalid-w kernel checks passed");
}
