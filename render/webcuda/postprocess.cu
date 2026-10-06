// SPDX-License-Identifier: GPL-3.0-or-later
#include "precision.cuh"
// Bilinear camera sampling, preserving bottom-left texture coordinates while
// attachments themselves are stored top-first. No intermediate byte quantizing.
__device__ float post_sample(const float* source,unsigned int width,unsigned int height,float u,float v,unsigned int channel) {
    float x=fminf(1.0f,fmaxf(0.0f,u))*(float)width-0.5f;
    float y=(1.0f-fminf(1.0f,fmaxf(0.0f,v)))*(float)height-0.5f;
    int ix=(int)floorf(x),iy=(int)floorf(y);float fx=x-floorf(x),fy=y-floorf(y),value=0.0f;
    for(int dy=0;dy<2;dy++)for(int dx=0;dx<2;dx++) {
        int sx=ix+dx,sy=iy+dy;sx=sx<0?0:(sx>=(int)width?(int)width-1:sx);sy=sy<0?0:(sy>=(int)height?(int)height-1:sy);
        value+=source[((unsigned int)sy*width+(unsigned int)sx)*9+channel]*(dx==0?1.0f-fx:fx)*(dy==0?1.0f-fy:fy);
    }
    return value;
}
__global__ void resolve_scene(const float* source,const float* distortion,float* target,
    unsigned int width,unsigned int height,unsigned int source_width,unsigned int source_height,
    unsigned int distortion_width,unsigned int distortion_height,unsigned int use_distortion,float scale_x,float scale_y) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    float u=((float)(i%width)+0.5f)/(float)width,v=1.0f-((float)(i/width)+0.5f)/(float)height;
    u*=scale_x;v*=scale_y;
    float dx=0.0f,dy=0.0f,occlusion=1.0f;
    if(use_distortion!=0) {
        dx=fminf(1.0f,fmaxf(-1.0f,post_sample(distortion,distortion_width,distortion_height,u,v,0)*0.14f));
        dy=fminf(1.0f,fmaxf(-1.0f,post_sample(distortion,distortion_width,distortion_height,u,v,1)*0.14f));
        occlusion=post_sample(distortion,distortion_width,distortion_height,u+dx,v+dy,2);
    }
    for(unsigned int c=0;c<4;c++)target[i*9+c]=post_sample(source,source_width,source_height,u+dx,v+dy,c)*(1.0f-occlusion)
        +post_sample(source,source_width,source_height,u,v,c)*occlusion;
}

// Built-in adjustments.omwfx: contrast about 0.5, followed by gamma.
// Sample the preceding effect at this stage's resolution before adjustment.
__global__ void adjust_scene(const float* source,float* target,unsigned int width,unsigned int height,
    unsigned int source_width,unsigned int source_height,float gamma,float contrast) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    float u=((float)(i%width)+0.5f)/(float)width,v=1.0f-((float)(i/width)+0.5f)/(float)height;
    target[i*9+3]=post_sample(source,source_width,source_height,u,v,3u);
    for(unsigned int channel=0;channel<3;channel++) {
        float value=(post_sample(source,source_width,source_height,u,v,channel)-0.5f)*contrast+0.5f;
        // Negative pow bases have no defined GLSL result. Keep the output
        // deterministic at black instead of allowing NaNs into presentation.
        value=fmaxf(0.0f,value);
        if(gamma==0.0f)value=value<1.0f?0.0f:(value==1.0f?1.0f:3.402823466e+38f);
        else value=powf(value,1.0f/gamma);
        target[i*9+channel]=value;
    }
}

// Compatibility luminance shaders: encoded logarithmic luminance pyramid.
__global__ void scene_log_luminance(const float* source,float* output,unsigned int width,unsigned int height,
    unsigned int source_width,unsigned int source_height,float sx,float sy,unsigned int viewport_width,unsigned int viewport_height) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;if(i>=width*height)return;
    float u=((float)(i%width)+0.5f)/(float)viewport_width*sx;
    float v=((float)(height-1u-i/width)+0.5f)/(float)viewport_height*sy;
    float lum=post_sample(source,source_width,source_height,u,v,0)*0.2126f
        +post_sample(source,source_width,source_height,u,v,1)*0.7152f
        +post_sample(source,source_width,source_height,u,v,2)*0.0722f;
    output[i]=round_half(fminf(1.0f,fmaxf(0.0f,(log2f(fmaxf(0.004f,lum))+9.0f)/13.0f)));
}
__global__ void reduce_luminance(const float* source,float* output,unsigned int width,unsigned int height) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    unsigned int dw=width>1u?width/2u:1u,dh=height>1u?height/2u:1u;if(i>=dw*dh)return;
    unsigned int x0=(i%dw)*width/dw,x1=(i%dw+1u)*width/dw;
    unsigned int y0=(i/dw)*height/dh,y1=(i/dw+1u)*height/dh;
    float sum=0.0f;for(unsigned int y=y0;y<y1;y++)for(unsigned int x=x0;x<x1;x++)sum+=source[y*width+x];
    output[i]=round_half(sum/(float)((x1-x0)*(y1-y0)));
}
__global__ void adapt_luminance(const float* source,float* history,float delta,float speed,unsigned int reset) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;if(i!=0u)return;
    float current=source[0],average=exp2f(current*13.0f-9.0f);
    // The original warm-up blits encoded current luminance into history.
    float previous=reset!=0u?current:history[0];
    history[0]=round_half(previous+(average-previous)*(1.0f-expf(-delta*speed)));
}

// Built-in bloomlinear.omwfx stages. Scratch attachments use the shared
// nine-float pixel layout; intermediate RGB stores round to binary16.
__device__ float bloom_nearest(const float* source,unsigned int width,unsigned int height,float u,float v,unsigned int channel) {
    int x=(int)floorf(u*(float)width),y=(int)floorf((1.0f-v)*(float)height);
    x=x<0?0:(x>=(int)width?(int)width-1:x);y=y<0?0:(y>=(int)height?(int)height-1:y);
    return source[((unsigned int)y*width+(unsigned int)x)*9u+channel];
}
__device__ float bloom_scramble(float x) {
    x=x-floorf(x);x+=4.0f;x*=x;x*=x;return x-floorf(x);
}
__global__ void bloom_extract(const float* source,const float* depth,float* target,
    unsigned int width,unsigned int height,unsigned int source_width,unsigned int source_height,
    unsigned int depth_width,unsigned int depth_height,float gamma,float threshold,float sky_factor,
    float near_plane,float far_plane,unsigned int reverse_z) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;if(i>=width*height)return;
    float u=((float)(i%width)+0.5f)/(float)width,v=1.0f-((float)(i/width)+0.5f)/(float)height;
    float z=post_sample(depth,depth_width,depth_height,u,v,4u),distance;
    if(reverse_z!=0u)distance=near_plane*far_plane/(far_plane+z*(near_plane-far_plane));
    else distance=2.0f*near_plane*far_plane/(far_plane+near_plane-(z*2.0f-1.0f)*(far_plane-near_plane));
    unsigned int sky=distance>far_plane*0.999f?1u:0u;
    float color[3],mean=0.0f;
    for(unsigned int c=0;c<3;c++){color[c]=post_sample(source,source_width,source_height,u,v,c);mean+=color[c]/3.0f;}
    float factor=sky!=0u?sky_factor:1.0f;
    if(sky==0u&&mean<threshold)factor=0.0f;
    for(unsigned int c=0;c<3;c++)target[i*9u+c]=round_half(powf(fmaxf(0.0f,color[c]),gamma)*factor);
    target[i*9u+3u]=1.0f;
}
__global__ void bloom_blur(const float* source,float* target,unsigned int width,unsigned int height,
    unsigned int resolution_width,unsigned int resolution_height,float radius_parameter,unsigned int vertical) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;if(i>=width*height)return;
    float u=((float)(i%width)+0.5f)/(float)width,v=1.0f-((float)(i/width)+0.5f)/(float)height;
    float x=u*2.0f-1.0f,y=v*2.0f-1.0f;
    float radius=fmaxf(0.1f,radius_parameter*0.2f*(float)resolution_height)*(x*x+1.0f)*(y*y+1.0f);
    int extent=(int)ceilf(radius);float sum[3];for(unsigned int c=0;c<3;c++)sum[c]=0.0f;
    float normalize=0.0f;
    for(int offset=-extent;offset<=extent;offset++) {
        float position=(float)offset/radius*2.0f,weight=expf(-position*position);
        float su=u+(vertical==0u?(float)offset/(float)resolution_width:0.0f);
        float sv=v+(vertical!=0u?(float)offset/(float)resolution_height:0.0f);
        normalize+=weight;
        for(unsigned int c=0;c<3;c++)sum[c]+=weight*bloom_nearest(source,width,height,su,sv,c);
    }
    for(unsigned int c=0;c<3;c++)target[i*9u+c]=round_half(sum[c]/normalize);
    target[i*9u+3u]=1.0f;
}
__global__ void bloom_combine(const float* source,const float* bloom,float* target,
    unsigned int width,unsigned int height,unsigned int source_width,unsigned int source_height,
    unsigned int bloom_width,unsigned int bloom_height,float gamma,float clamp_value,float strength,float time) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;if(i>=width*height)return;
    float u=((float)(i%width)+0.5f)/(float)width,v=1.0f-((float)(i/width)+0.5f)/(float)height;
    float phase=time-floorf(time);float x=u*61.12f,y=v*61.12f;
    float first=bloom_scramble(x*0.6491f+y*0.029f+phase);
    float seed=phase*(x-floorf(x));seed-=floorf(seed);
    float second=bloom_scramble(x*0.6491f+y*0.029f+seed+0.18943f);
    float color[3],mean=0.0f;
    for(unsigned int c=0;c<3;c++) {
        float value=powf(fmaxf(0.0f,post_sample(bloom,bloom_width,bloom_height,u,v,c)),1.0f/gamma);
        float noise=c==1u?second:first;
        color[c]=fmaxf(0.0f,value-noise*(2.0f/255.0f));mean+=color[c]/3.0f;
    }
    float scale=clamp_value==0.0f?0.0f:(mean>clamp_value?clamp_value/mean:1.0f);
    for(unsigned int c=0;c<3;c++) {
        float base=powf(fmaxf(0.0f,post_sample(source,source_width,source_height,u,v,c)),gamma);
        float addition=powf(color[c]*scale,gamma)*strength*0.5f;
        target[i*9u+c]=powf(base+addition,1.0f/gamma);
    }
    target[i*9u+3u]=1.0f;
}

// Match the colour storage of the scene texture cloned for ping-pong targets.
// storage: 0=UNORM8, 1=binary16, 2=binary32. Missing channels follow texture
// sampling defaults (zero RGB, one alpha), independent of the previous pass.
__global__ void store_postprocess_color(float* target,unsigned int pixel_count,unsigned int channels,unsigned int storage) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;if(i>=pixel_count)return;
    for(unsigned int c=0;c<4;c++) {
        float value=target[i*9u+c];
        target[i*9u+c]=store_color_value(value,c,channels,storage);
    }
}

// Copy a viewport-sized final effect into the full destination. Coordinates
// are bottom-left window coordinates; storage is top-first. Only colour is
// written: destination depth, stencil, normals and uncovered pixels survive.
__global__ void place_postprocess(const float* source,float* target,
    unsigned int width,unsigned int height,unsigned int source_width,unsigned int source_height,
    int viewport_x,int viewport_y) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    float sx=(float)(i%width)-(float)viewport_x;
    float sy=(float)(height-1u-i/width)-(float)viewport_y;
    if(sx<0.0f||sy<0.0f||sx>=(float)source_width||sy>=(float)source_height)return;
    unsigned int source_pixel=(source_height-1u-(unsigned int)sy)*source_width+(unsigned int)sx;
    for(unsigned int c=0;c<4;c++)target[i*9u+c]=source[source_pixel*9u+c];
}

// Built-in debug.omwfx, including its alpha-preserving normals overlay.
// settings: near, far, depth factor, then column-major view matrix.
__global__ void debug_scene(const float* source,const float* depth,const float* normals,
    const float* settings,float* target,unsigned int width,unsigned int height,
    unsigned int source_width,unsigned int source_height,unsigned int depth_width,unsigned int depth_height,
    unsigned int normal_width,unsigned int normal_height,unsigned int flags) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    float u=((float)(i%width)+0.5f)/(float)width,v=1.0f-((float)(i/width)+0.5f)/(float)height;
    for(unsigned int c=0;c<4;c++)target[i*9u+c]=post_sample(source,source_width,source_height,u,v,c);
    if((flags&1u)!=0u) {
        float z=post_sample(depth,depth_width,depth_height,u,v,4u);
        float near_plane=settings[0],far_plane=settings[1],distance;
        if((flags&8u)!=0u)distance=near_plane*far_plane/(far_plane+z*(near_plane-far_plane));
        else distance=2.0f*near_plane*far_plane/(far_plane+near_plane-(z*2.0f-1.0f)*(far_plane-near_plane));
        for(unsigned int c=0;c<3;c++)target[i*9u+c]=distance/far_plane*settings[2];
        target[i*9u+3u]=1.0f;
    }
    if((flags&2u)!=0u&&((flags&1u)==0u||u<0.5f)) {
        float n[3];
        for(unsigned int c=0;c<3;c++)n[c]=post_sample(normals,normal_width,normal_height,u,v,5u+c)*2.0f-1.0f;
        for(unsigned int c=0;c<3;c++) {
            float value=n[c];
            if((flags&4u)!=0u)value=n[0]*settings[3u+c*4u]+n[1]*settings[4u+c*4u]+n[2]*settings[5u+c*4u];
            target[i*9u+c]=value*0.5f+0.5f;
        }
    }
}
