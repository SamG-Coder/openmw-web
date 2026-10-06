// CPU execution of authored .cu bodies; browser WGSL validation is a separate gate.
#include <array>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <random>
#define __global__
struct Dim { unsigned int x = 0, y = 0; } blockIdx, blockDim, threadIdx, gridDim;
#include "clip.cu"

static unsigned int check(const std::array<float, 12>& input, bool zeroToOne=false) {
    std::array<float, 86> positions, weights;
    std::array<unsigned int, 9> valid;
    positions.fill(12345); weights.fill(12345); valid.fill(12345);
    unsigned int indices[] = {0, 1, 2, 0}, materials[12]={}, edges[]={7};
    materials[3]=zeroToOne?8388608u:0u;
    clip_triangles(input.data(), indices, materials, edges, positions.data() + 1, weights.data() + 1, valid.data() + 1, 1, 4, 4);
    assert(positions.front() == 12345 && positions.back() == 12345);
    assert(weights.front() == 12345 && weights.back() == 12345);
    assert(valid.front() == 12345 && valid.back() == 12345);
    unsigned int count = 0;
    for (unsigned int t = 0; t < 7; t++) {
        if (!valid[t + 1]) continue;
        count++;
        for (unsigned int v = 0; v < 3; v++) {
            const float* p = positions.data() + 1 + t * 12 + v * 4;
            const float* a = weights.data() + 1 + t * 12 + v * 4;
            assert(p[3] > 0);
            if(zeroToOne)assert(p[2]>=-1e-5f);
            for (unsigned int axis = 0; axis < 3; axis++) assert(std::abs(p[axis]) <= p[3] + 1e-5f);
            assert(std::abs(a[0] + a[1] + a[2] - 1) < 1e-5f);
            assert(a[3]==0.f || a[3]==1.f);
            for (unsigned int k = 0; k < 4; k++) {
                const float expected = a[0] * input[k] + a[1] * input[4+k] + a[2] * input[8+k];
                assert(std::abs(p[k] - expected) < 1e-4f);
            }
        }
    }
    return count;
}
int main() {
    blockDim.x = 64;
    assert(check({-.5f,-.5f,0,1, .5f,-.5f,0,1, 0,.5f,0,1}) == 1);
    assert(check({-.5f,-.5f,2,1, .5f,-.5f,2,1, 0,.5f,2,1}) == 0);
    assert(check({-.5f,-.5f,-2,1, .5f,-.5f,0,1, 0,.5f,0,1}) == 2);
    assert(check({-1,-1,-1,1, 1,-1,-1,1, 0,1,-1,1}) == 1);
    assert(check({0,0,0,0, 0,0,0,0, 0,0,0,0}) == 0);
    assert(check({-.5f,-.5f,-.1f,1, .5f,-.5f,-.1f,1, 0,.5f,-.1f,1},true)==0);
    assert(check({-.5f,-.5f,0,1, .5f,-.5f,0,1, 0,.5f,0,1},true)==1);
    std::mt19937 random(1729);
    std::uniform_real_distribution<float> coordinate(-4,4), w(-1,2);
    for (unsigned int test = 0; test < 10000; test++) {
        std::array<float, 12> input;
        for (unsigned int v = 0; v < 3; v++) {
            for (unsigned int k = 0; k < 3; k++) input[v * 4 + k] = coordinate(random);
            input[v * 4 + 3] = w(random);
        }
        check(input);
        check(input,true);
    }
    std::puts("20,000 clipping cases across both depth conventions: frustum containment, barycentric reconstruction and buffer bounds passed");
}
