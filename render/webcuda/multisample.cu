// SPDX-License-Identifier: GPL-3.0-or-later
#include "precision.cuh"
// Each sample plane uses the existing attachment ABI: pixels*9 float color,
// depth and normals, followed by pixels float stencil. Planes are contiguous.
__global__ void seed_multisample(const float* source,float* samples,unsigned int pixel_count,unsigned int sample_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=pixel_count*sample_count)return;
    unsigned int pixel=i%pixel_count,sample=i/pixel_count,base=sample*pixel_count*10;
    for(unsigned int channel=0;channel<9;channel++)samples[base+pixel*9+channel]=source[pixel*9+channel];
    samples[base+pixel_count*9+pixel]=source[pixel_count*9+pixel];
}
// Color/normal samples average in the linear representation used by the target
// ABI, then quantize to destination storage. Depth/stencil select one sample;
// they are never numerically averaged. The caller supplies that sample index.
__global__ void resolve_multisample(const float* samples,float* target,unsigned int pixel_count,unsigned int sample_count,
    unsigned int mask,unsigned int depth_sample,unsigned int normal_enabled,unsigned int normal_channels,unsigned int normal_storage,unsigned int color_channels,
    unsigned int color_storage,unsigned int depth_bits,unsigned int stencil_enabled) {
    unsigned int pixel=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(pixel>=pixel_count)return;
    if((mask&16384)!=0) {
        for(unsigned int channel=0;channel<4;channel++) {
            float color=0.0f,normal=0.0f;
            for(unsigned int sample=0;sample<sample_count;sample++) {
                unsigned int base=sample*pixel_count*10+pixel*9;
                color+=samples[base+channel];
                if(normal_enabled!=0)normal+=samples[base+5+channel];
            }
            target[pixel*9+channel]=store_color_value(color/(float)sample_count,channel,color_channels,color_storage);
            if(normal_enabled!=0)target[pixel*9+5+channel]=store_color_value(normal/(float)sample_count,channel,normal_channels,normal_storage);
        }
    }
    unsigned int selected=depth_sample*pixel_count*10;
    if((mask&256)!=0)target[pixel*9+4]=store_depth_value(samples[selected+pixel*9+4],depth_bits);
    if(stencil_enabled!=0&&(mask&1024)!=0)target[pixel_count*9+pixel]=samples[selected+pixel_count*9+pixel];
}

// plane0 depth, plane1 normal RGBA, plane2 stencil. Preserve all other planes.
__global__ void copy_multisample_plane(const float* source,float* target,unsigned int pixel_count,unsigned int sample_count,unsigned int plane) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=pixel_count*sample_count)return;
    unsigned int pixel=i%pixel_count,base=(i/pixel_count)*pixel_count*10;
    if(plane==0u)target[base+pixel*9+4]=source[base+pixel*9+4];
    if(plane==1u)for(unsigned int channel=0;channel<4;channel++)target[base+pixel*9+5+channel]=source[base+pixel*9+5+channel];
    if(plane==2u)target[base+pixel_count*9+pixel]=source[base+pixel_count*9+pixel];
}
__global__ void clear_multisample_depth(float* target,unsigned int pixel_count,unsigned int sample_count,float depth) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=pixel_count*sample_count)return;
    unsigned int pixel=i%pixel_count,base=(i/pixel_count)*pixel_count*10;
    target[base+pixel*9+4]=depth;
}

// Fullscreen postprocess writes are pixel shaded and broadcast to covered
// samples. Preserve depth/stencil/normals and pixels outside the viewport.
__global__ void broadcast_multisample_color(const float* source,float* target,unsigned int width,unsigned int height,unsigned int sample_count,
    int viewport_x,int viewport_y,unsigned int viewport_width,unsigned int viewport_height) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x,pixels=width*height;
    if(i>=pixels*sample_count)return;
    unsigned int pixel=i%pixels,base=(i/pixels)*pixels*10;
    float x=(float)(pixel%width)+0.5f,y=(float)height-(float)(pixel/width)-0.5f;
    if(x<(float)viewport_x||y<(float)viewport_y||x>=(float)viewport_x+(float)viewport_width||y>=(float)viewport_y+(float)viewport_height)return;
    for(unsigned int channel=0;channel<4;channel++)target[base+pixel*9+channel]=source[pixel*9+channel];
}

// Copy resolved attachments to the explicit resolve FBO's texture identities.
__global__ void copy_resolved_attachment(const float* source,float* target,unsigned int width,unsigned int height,unsigned int plane,
    unsigned int color_channels,unsigned int color_storage,unsigned int depth_bits,int viewport_x,int viewport_y,unsigned int viewport_width,unsigned int viewport_height,unsigned int source_compact,unsigned int target_compact) {
    unsigned int pixel=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(pixel>=width*height)return;
    float x=(float)(pixel%width)+0.5f,y=(float)height-(float)(pixel/width)-0.5f;
    if(x<(float)viewport_x||y<(float)viewport_y||x>=(float)viewport_x+(float)viewport_width||y>=(float)viewport_y+(float)viewport_height)return;
    if(plane==0u)for(unsigned int channel=0;channel<4;channel++)target[pixel*9+channel]=store_color_value(source[pixel*9+channel],channel,color_channels,color_storage);
    if(plane==1u||plane==4u)target[target_compact!=0u?pixel:pixel*9+4]=store_depth_value(source[source_compact!=0u?pixel:pixel*9+4],depth_bits);
    if(plane==2u)for(unsigned int channel=0;channel<4;channel++)target[pixel*9+5+channel]=store_color_value(source[pixel*9+5+channel],channel,color_channels,color_storage);
    if(plane==3u||plane==4u)target[width*height*9+pixel]=source[width*height*9+pixel];
}
