// SPDX-License-Identifier: GPL-3.0-or-later
// Write a padded RGBA8 buffer for a WebGPU copy into the canvas texture.
// No JavaScript fragment shader and no CPU pixel readback are used to present.
__global__ void pack_present(const float* rgba, unsigned int* pixels,
                             unsigned int width, unsigned int height,
                             unsigned int row_pixels) {
    unsigned int i = (blockIdx.x + blockIdx.y * gridDim.x) * blockDim.x + threadIdx.x;
    if (i >= width * height) return;
    unsigned int r = (unsigned int)(fminf(1.0f, fmaxf(0.0f, rgba[i * 4])) * 255.0f + 0.5f);
    unsigned int g = (unsigned int)(fminf(1.0f, fmaxf(0.0f, rgba[i * 4 + 1])) * 255.0f + 0.5f);
    unsigned int b = (unsigned int)(fminf(1.0f, fmaxf(0.0f, rgba[i * 4 + 2])) * 255.0f + 0.5f);
    unsigned int a = (unsigned int)(fminf(1.0f, fmaxf(0.0f, rgba[i * 4 + 3])) * 255.0f + 0.5f);
    pixels[(i / width) * row_pixels + i % width] = r | (g << 8) | (b << 16) | (a << 24);
}
