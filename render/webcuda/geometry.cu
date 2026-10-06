// SPDX-License-Identifier: GPL-3.0-or-later
// WebCuda renderer foundation. All geometry arithmetic executes in .cu kernels.
// Matrix ABI: column-major, 16 floats per draw. Positions are packed xyz.
__global__ void transform_vertices(const float* positions, const float* matrices,
                                  const unsigned int* matrix_ids, float* clip,
                                  unsigned int vertex_count) {
    unsigned int i = (blockIdx.x + blockIdx.y * gridDim.x) * blockDim.x + threadIdx.x;
    if (i >= vertex_count) return;
    unsigned int p = i * 3;
    unsigned int m = matrix_ids[i] * 16;
    float x = positions[p];
    float y = positions[p + 1];
    float z = positions[p + 2];
    clip[i * 4] = matrices[m] * x + matrices[m + 4] * y + matrices[m + 8] * z + matrices[m + 12];
    clip[i * 4 + 1] = matrices[m + 1] * x + matrices[m + 5] * y + matrices[m + 9] * z + matrices[m + 13];
    clip[i * 4 + 2] = matrices[m + 2] * x + matrices[m + 6] * y + matrices[m + 10] * z + matrices[m + 14];
    clip[i * 4 + 3] = matrices[m + 3] * x + matrices[m + 7] * y + matrices[m + 11] * z + matrices[m + 15];
}

// One thread owns one pixel: no cross-workgroup depth/color race. Input triangles
// must already be clipped. This reference path is intentionally not the tiled
// production rasterizer; it is an oracle for that implementation.
__global__ void raster_reference(const float* clip, const float* colors,
                                 const unsigned int* indices, float* rgba,
                                 float* depth, unsigned int width,
                                 unsigned int height, unsigned int triangle_count) {
    unsigned int pixel = (blockIdx.x + blockIdx.y * gridDim.x) * blockDim.x + threadIdx.x;
    if (pixel >= width * height) return;
    float px = (float)(pixel % width) + 0.5f;
    float py = (float)(pixel / width) + 0.5f;
    float best = 1.0f;
    float red = 0.0f;
    float green = 0.0f;
    float blue = 0.0f;
    for (unsigned int t = 0; t < triangle_count; t++) {
        unsigned int ia = indices[t * 3] * 4;
        unsigned int ib = indices[t * 3 + 1] * 4;
        unsigned int ic = indices[t * 3 + 2] * 4;
        float aw = clip[ia + 3];
        float bw = clip[ib + 3];
        float cw = clip[ic + 3];
        if (aw <= 0.0f || bw <= 0.0f || cw <= 0.0f) continue;
        float ax = (clip[ia] / aw * 0.5f + 0.5f) * (float)width;
        float ay = (0.5f - clip[ia + 1] / aw * 0.5f) * (float)height;
        float bx = (clip[ib] / bw * 0.5f + 0.5f) * (float)width;
        float by = (0.5f - clip[ib + 1] / bw * 0.5f) * (float)height;
        float cx = (clip[ic] / cw * 0.5f + 0.5f) * (float)width;
        float cy = (0.5f - clip[ic + 1] / cw * 0.5f) * (float)height;
        float area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
        if (fabsf(area) < 0.000001f) continue;
        float a = ((bx - px) * (cy - py) - (by - py) * (cx - px)) / area;
        float b = ((cx - px) * (ay - py) - (cy - py) * (ax - px)) / area;
        float c = 1.0f - a - b;
        if (a < 0.0f || b < 0.0f || c < 0.0f) continue;
        float z = (a * clip[ia + 2] / aw + b * clip[ib + 2] / bw + c * clip[ic + 2] / cw) * 0.5f + 0.5f;
        if (z < 0.0f || z >= best) continue;
        best = z;
        float recip = a / aw + b / bw + c / cw;
        a = a / aw / recip;
        b = b / bw / recip;
        c = c / cw / recip;
        red = a * colors[ia] + b * colors[ib] + c * colors[ic];
        green = a * colors[ia + 1] + b * colors[ib + 1] + c * colors[ic + 1];
        blue = a * colors[ia + 2] + b * colors[ib + 2] + c * colors[ic + 2];
    }
    depth[pixel] = best;
    rgba[pixel * 4] = red;
    rgba[pixel * 4 + 1] = green;
    rgba[pixel * 4 + 2] = blue;
    rgba[pixel * 4 + 3] = 1.0f;
}
