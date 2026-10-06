#include "cluster-lighting.cuh"
// SPDX-License-Identifier: GPL-3.0-or-later
#include "precision.cuh"
// Vertex ABI: clip xyzw, RGBA, UV (10 floats). Triangle ABI: i0,i1,i2,material.
// Material ABI: 12 uints: resource/descriptor offset, width, height, flags,
// alpha reference, scissor xywh, raster control, blend factors, sampler.
// Target ABI: nine interleaved floats (RGBA, depth, normal RGBA) per pixel,
// followed by a separate stencil float plane. Bins retain submission order.
// Fixed-function texture environments are linked 44-word descriptors; up to
// four UV sets are transported. Render math and sampling are authored here.
// Extended-state flag 128: word4 is a float-bit alpha reference; word9 packs
// depth compare (bits0..3), alpha compare (4..7), RGB/alpha blend equations
// (8..10/11..13), cull mode (14..15) and clockwise front (16). Word10 contains
// sourceRGB,destinationRGB,sourceAlpha,destinationAlpha as four 4-bit factors.
// Control bit26 enables blending for normal attachment 1 independently of color.
// Flag256 clamps fragment/blend output for normalized render targets.
// Flag16777216 carries an unclipped GL scissor: signed origin bits and positive
// extents in words5..8. Other packets retain their top-left xywh convention.
__device__ float raster_unit_value(float value) {
    return fminf(1.0f,fmaxf(0.0f,value));
}
__device__ unsigned int raw_scissor_axis(unsigned int pixel,unsigned int origin,unsigned int extent) {
    // Unsigned subtraction represents pixel - signed_origin exactly whenever
    // pixel is not below a positive origin. It avoids signed overflow at INT_MIN.
    return ((origin&2147483648u)!=0u||pixel>=origin)&&pixel-origin<extent;
}
// Signed area of the disk inside the rectangle from (0,0) to (x,y).
__device__ float point_disk_integral(float x,float y,float radius) {
    float sx=x<0.0f?-1.0f:1.0f,sy=y<0.0f?-1.0f:1.0f;
    x=fminf(fabsf(x),radius);y=fminf(fabsf(y),radius);
    float cut=sqrtf(fmaxf(0.0f,radius*radius-y*y));
    float flat=fminf(x,cut),area=flat*y;
    if(x>cut) {
        // WebCuda exposes atan2f; use the equivalent quadrant angle without
        // requiring asinf or dividing by the radius near a tiny footprint.
        float height=sqrtf(fmaxf(0.0f,radius*radius-x*x));
        float end=0.5f*(x*height+radius*radius*atan2f(x,height));
        float begin=0.5f*(cut*y+radius*radius*atan2f(cut,y));
        area+=end-begin;
    }
    return sx*sy*area;
}
__device__ float point_disk_coverage(float x,float y,float radius) {
    if(radius<=0.0f)return 0.0f;
    float farX=fabsf(x)+0.5f,farY=fabsf(y)+0.5f;
    if(farX*farX+farY*farY<=radius*radius)return 1.0f;
    float nearX=fmaxf(0.0f,fabsf(x)-0.5f),nearY=fmaxf(0.0f,fabsf(y)-0.5f);
    if(nearX*nearX+nearY*nearY>=radius*radius)return 0.0f;
    float area=point_disk_integral(x+0.5f,y+0.5f,radius)-point_disk_integral(x-0.5f,y+0.5f,radius)
        -point_disk_integral(x+0.5f,y-0.5f,radius)+point_disk_integral(x-0.5f,y-0.5f,radius);
    return fminf(1.0f,fmaxf(0.0f,area));
}
// Compare t + e*t1 + e^2*t2 as e approaches zero from above.
// Symbolic perturbation avoids selecting an arbitrary screen-space epsilon.
__device__ unsigned int line_parameter_less(float a,float a1,float a2,float b,float b1,float b2) {
    if(a!=b)return a<b;
    if(a1!=b1)return a1<b1;
    return a2<b2;
}
__device__ unsigned int line_diamond_exit(float ax,float ay,float dx,float dy) {
    // Inputs are relative to the fragment centre, in top-left coordinates.
    // GL's (-e,-e^2) bottom-left perturbation becomes (-e,+e^2).
    float enter=0.0f,enter1=0.0f,enter2=0.0f;
    float leave=1.0f,leave1=0.0f,leave2=0.0f;
    for(unsigned int axis=0u;axis<2u;axis++) {
        float origin=axis==0u?ax+ay:ax-ay;
        float delta=axis==0u?dx+dy:dx-dy;
        float second=axis==0u?-1.0f:1.0f;
        if(delta==0.0f) {
            // Both rotated coordinates have leading perturbation -e.
            if(origin<=-0.5f||origin>0.5f)return 0u;
        } else {
            float low=(-0.5f-origin)/delta,high=(0.5f-origin)/delta;
            float first=1.0f/delta,last=second/delta;
            if(delta<0.0f){float swap=low;low=high;high=swap;}
            if(line_parameter_less(enter,enter1,enter2,low,first,last)!=0u)
                {enter=low;enter1=first;enter2=last;}
            if(line_parameter_less(high,first,last,leave,leave1,leave2)!=0u)
                {leave=high;leave1=first;leave2=last;}
        }
    }
    // An intersection alone is insufficient: the segment must leave the
    // diamond before its final endpoint, yielding half-open connected lines.
    return line_parameter_less(enter,enter1,enter2,leave,leave1,leave2)!=0u
        &&line_parameter_less(leave,leave1,leave2,1.0f,0.0f,0.0f)!=0u;
}
__device__ unsigned int line_wide_diamond(float ax,float ay,float dx,float dy,float width) {
    if(width==1.0f)return line_diamond_exit(ax,ay,dx,dy);
    unsigned int xMajor=fabsf(dx)>=fabsf(dy)?1u:0u;
    float shift=(width-1.0f)*0.5f;
    // GL shifts the base line toward negative bottom-left minor coordinates,
    // then replicates fragments toward positive minor coordinates.
    float baseX=ax-(xMajor==0u?shift:0.0f);
    float baseY=ay+(xMajor!=0u?shift:0.0f);
    float expected=xMajor!=0u?baseY-baseX*dy/dx:-(baseX-baseY*dx/dy);
    float nearest=floorf(expected);
    // Across one pixel of the major axis, the minor axis changes by <=1.
    // Only these neighbouring replicas can intersect its diamond, regardless
    // of line width; avoid a loop proportional to an arbitrary input width.
    for(unsigned int candidate=0u;candidate<3u;candidate++) {
        float replica=nearest+(float)candidate-1.0f;
        if(replica<0.0f||replica>=width)continue;
        float x=baseX+(xMajor==0u?replica:0.0f);
        float y=baseY-(xMajor!=0u?replica:0.0f);
        if(line_diamond_exit(x,y,dx,dy)!=0u)return 1u;
    }
    return 0u;
}
// Clip the finite line rectangle to the pixel square and integrate its area.
__device__ float line_rectangle_coverage(float ax,float ay,float dx,float dy,float width) {
    float length=sqrtf(dx*dx+dy*dy);
    if(length<=0.0f||width<=0.0f)return 0.0f;
    float nx=-dy/length*width*0.5f,ny=dx/length*width*0.5f;
    float polygon[40],next[40];
    polygon[0]=ax+nx;polygon[1]=ay+ny;
    polygon[2]=ax+dx+nx;polygon[3]=ay+dy+ny;
    polygon[4]=ax+dx-nx;polygon[5]=ay+dy-ny;
    polygon[6]=ax-nx;polygon[7]=ay-ny;
    unsigned int count=4u;
    for(unsigned int plane=0u;plane<4u;plane++) {
        if(count<3u)return 0.0f;
        unsigned int axis=plane/2u,out=0u;
        float sign=plane%2u==0u?1.0f:-1.0f;
        for(unsigned int i=0u;i<count;i++) {
            unsigned int previous=i==0u?count-1u:i-1u;
            float d0=0.5f+sign*polygon[previous*2u+axis],d1=0.5f+sign*polygon[i*2u+axis];
            if((d0>=0.0f)!=(d1>=0.0f)&&d0!=0.0f&&d1!=0.0f) {
                float t=d0/(d0-d1);
                for(unsigned int k=0u;k<2u;k++)next[out*2u+k]=polygon[previous*2u+k]+t*(polygon[i*2u+k]-polygon[previous*2u+k]);
                out++;
            }
            if(d1>=0.0f) {next[out*2u]=polygon[i*2u];next[out*2u+1u]=polygon[i*2u+1u];out++;}
        }
        count=out;
        for(unsigned int i=0u;i<count*2u;i++)polygon[i]=next[i];
    }
    float area=0.0f;
    for(unsigned int i=0u;i<count;i++) {
        unsigned int nextIndex=i+1u==count?0u:i+1u;
        area+=polygon[i*2u]*polygon[nextIndex*2u+1u]-polygon[i*2u+1u]*polygon[nextIndex*2u];
    }
    return fminf(1.0f,fabsf(area)*0.5f);
}
__device__ unsigned int compare_value(float a, float b, unsigned int function) {
    if(function==0)return 0;
    if(function==1)return a<b;
    if(function==2)return a==b;
    if(function==3)return a<=b;
    if(function==4)return a>b;
    if(function==5)return a!=b;
    if(function==6)return a>=b;
    return 1;
}
// One raster thread owns each pixel/sample, so stencil updates need no atomics.
__device__ unsigned int apply_stencil(float* target,const float* attributes,unsigned int raster,
    unsigned int pixel,unsigned int pixel_count,unsigned int front,unsigned int depth_pass,unsigned int target_offset) {
    unsigned int base=raster+(front!=0u?8u:15u);
    unsigned int previous=(unsigned int)target[target_offset+pixel_count*9u+pixel]&255u;
    unsigned int reference=(unsigned int)fminf(255.0f,fmaxf(0.0f,attributes[base+1u])),mask=(unsigned int)attributes[base+2u];
    unsigned int passed=compare_value((float)(reference&mask),(float)(previous&mask),(unsigned int)attributes[base]);
    unsigned int operation=(unsigned int)attributes[base+(passed==0u?4u:(depth_pass==0u?5u:6u))];
    unsigned int value=previous;
    if(operation==1u)value=0u;
    if(operation==2u)value=reference;
    if(operation==3u)value=previous<255u?previous+1u:255u;
    if(operation==4u)value=previous>0u?previous-1u:0u;
    if(operation==5u)value=previous^255u;
    if(operation==6u)value=(previous+1u)&255u;
    if(operation==7u)value=(previous+255u)&255u;
    unsigned int write=(unsigned int)attributes[base+3u];
    target[target_offset+pixel_count*9u+pixel]=(float)((previous&(~write&255u))|(value&write));
    return passed&depth_pass;
}
__device__ float blend_factor(unsigned int factor, float source, float dest, float sa, float da, unsigned int channel, float constant, float constantAlpha) {
    if(factor==0)return 0.0f;
    if(factor==1)return 1.0f;
    if(factor==2)return source;
    if(factor==3)return 1.0f-source;
    if(factor==4)return sa;
    if(factor==5)return 1.0f-sa;
    if(factor==6)return da;
    if(factor==7)return 1.0f-da;
    if(factor==8)return dest;
    if(factor==9)return 1.0f-dest;
    if(factor==11)return raster_unit_value(constant);
    if(factor==12)return 1.0f-raster_unit_value(constant);
    if(factor==13)return raster_unit_value(constantAlpha);
    if(factor==14)return 1.0f-raster_unit_value(constantAlpha);
    return channel==3?1.0f:fminf(sa,1.0f-da);
}
__device__ float blend_value(float source, float dest, float sf, float df, unsigned int equation) {
    if(equation==3)return fminf(source,dest);
    if(equation==4)return fmaxf(source,dest);
    if(equation==1)return source*sf-dest*df;
    if(equation==2)return dest*df-source*sf;
    return source*sf+dest*df;
}
__device__ float clamp_blend_component(float value,unsigned int storage) {
    if(storage==1u||storage==2u)return value;
    return fminf(1.0f,fmaxf(storage==5u||storage==6u?-1.0f:0.0f,value));
}
__device__ float texture_environment(float primary,float texture,float texture_alpha,float constant,
    unsigned int mode,unsigned int format,unsigned int channel) {
    // Format 0 RGBA/LA, 1 RGB/L, 2 alpha, 3 intensity.
    if((channel==3u&&format==1u)||(channel<3u&&format==2u))return primary;
    if(mode==1u)return texture;
    if(mode==2u) {
        if(channel==3u)return primary;
        return format==1u?texture:primary*(1.0f-texture_alpha)+texture*texture_alpha;
    }
    if(mode==3u&&(channel<3u||format==3u))return primary*(1.0f-texture)+constant*texture;
    if(mode==4u&&(channel<3u||format==3u))return primary+texture;
    return primary*texture;
}
__device__ float combine_texture_arguments(float a,float b,float c,unsigned int operation) {
    if(operation==0u)return a;
    if(operation==1u)return a*b;
    if(operation==2u)return a+b;
    if(operation==3u)return a+b-0.5f;
    if(operation==4u)return a*c+b*(1.0f-c);
    return a-b;
}
__device__ unsigned int color_logic(unsigned int source,unsigned int dest,unsigned int operation) {
    if(operation==0u)return 0u;
    if(operation==1u)return source&dest;
    if(operation==2u)return source&~dest;
    if(operation==3u)return source;
    if(operation==4u)return ~source&dest;
    if(operation==5u)return dest;
    if(operation==6u)return source^dest;
    if(operation==7u)return source|dest;
    if(operation==8u)return ~(source|dest);
    if(operation==9u)return ~(source^dest);
    if(operation==10u)return ~dest;
    if(operation==11u)return source|~dest;
    if(operation==12u)return ~source;
    if(operation==13u)return ~source|dest;
    if(operation==14u)return ~(source&dest);
    return 0xffffffffu;
}
__device__ float logic_unorm(float source,float dest,unsigned int operation,unsigned int mask) {
    unsigned int s=(unsigned int)floorf(fminf(1.0f,fmaxf(0.0f,source))*(float)mask+0.5f);
    unsigned int d=(unsigned int)floorf(fminf(1.0f,fmaxf(0.0f,dest))*(float)mask+0.5f);
    return (float)(color_logic(s,d,operation)&mask)/(float)mask;
}
__device__ int texture_coord(int x, int size, unsigned int repeat) {
    if (repeat != 0) return ((x % size) + size) % size;
    return x < 0 ? 0 : (x >= size ? size - 1 : x);
}

__device__ float sample_channel(const unsigned int* texels, unsigned int base,
                                unsigned int width, unsigned int height,
                                float u, float v, unsigned int flags, unsigned int channel) {
    if (width == 0 || height == 0) return 1.0f;
    // Reduce before conversion to integer, including negative repeated UVs.
    u = (flags & 16) != 0 ? u - floorf(u) : fminf(1.0f, fmaxf(0.0f, u));
    v = (flags & 16) != 0 ? v - floorf(v) : fminf(1.0f, fmaxf(0.0f, v));
    float x = u * (float)width;
    float y = v * (float)height;
    if ((flags & 32) == 0) {
        unsigned int ix = (unsigned int)texture_coord((int)floorf(x), (int)width, flags & 16);
        unsigned int iy = (unsigned int)texture_coord((int)floorf(y), (int)height, flags & 16);
        return (float)((texels[base + iy * width + ix] >> (channel * 8)) & 255) / 255.0f;
    }
    x -= 0.5f; y -= 0.5f;
    int x0 = (int)floorf(x); int y0 = (int)floorf(y);
    float fx = x - floorf(x); float fy = y - floorf(y);
    float result = 0.0f;
    for (int row = 0; row < 2; row++) {
        for (int col = 0; col < 2; col++) {
            unsigned int ix = (unsigned int)texture_coord(x0 + col, (int)width, flags & 16);
            unsigned int iy = (unsigned int)texture_coord(y0 + row, (int)height, flags & 16);
            float weight = (col == 0 ? 1.0f - fx : fx) * (row == 0 ? 1.0f - fy : fy);
            result += weight * (float)((texels[base + iy * width + ix] >> (channel * 8)) & 255) / 255.0f;
        }
    }
    return result;
}

// Camera passes may clear color and depth independently or preserve both.
__global__ void generate_mip(unsigned int* texels, unsigned int source, unsigned int destination,
    unsigned int width, unsigned int height) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    unsigned int dw=width>1?width/2:1,dh=height>1?height/2:1;
    if(i>=dw*dh)return;
    // Area average covers every source texel for odd-size mip levels too.
    unsigned int x0=(i%dw)*width/dw,x1=(i%dw+1)*width/dw;
    unsigned int y0=(i/dw)*height/dh,y1=(i/dw+1)*height/dh;
    unsigned int packed=0,n=(x1-x0)*(y1-y0);
    for(unsigned int c=0;c<4;c++) {
        unsigned int sum=0;
        for(unsigned int y=y0;y<y1;y++)for(unsigned int x=x0;x<x1;x++)sum+=(texels[source+y*width+x]>>(c*8))&255;
        packed|=((sum+n/2)/n)<<(c*8);
    }
    texels[destination+i]=packed;
}

__device__ int sampler_index(int i,int size,unsigned int wrap) {
    if(wrap==1)return ((i%size)+size)%size;
    if(wrap==2) {int p=((i%(size*2))+size*2)%(size*2);return p<size?p:size*2-1-p;}
    return i<0?0:(i>=size?size-1:i);
}
__global__ void generate_float_mip(unsigned int* texels,unsigned int source,unsigned int destination,
    unsigned int width,unsigned int height,unsigned int color_channels,unsigned int color_storage) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    unsigned int dw=width>1?width/2:1,dh=height>1?height/2:1;
    if(i>=dw*dh)return;
    unsigned int x0=(i%dw)*width/dw,x1=(i%dw+1)*width/dw;
    unsigned int y0=(i/dw)*height/dh,y1=(i/dw+1)*height/dh;
    for(unsigned int c=0;c<4;c++) {
        float sum=0.0f;
        for(unsigned int y=y0;y<y1;y++)for(unsigned int x=x0;x<x1;x++)sum+=__uint_as_float(texels[source+(y*width+x)*4+c]);
        texels[destination+i*4+c]=__float_as_uint(store_color_value(sum/(float)((x1-x0)*(y1-y0)),c,color_channels,color_storage));
    }
}
// Depth atlas entries contain one float-bit word, not packed RGBA bytes.
__global__ void generate_depth_mip(unsigned int* texels,unsigned int source,unsigned int destination,
    unsigned int width,unsigned int height,unsigned int depth_bits) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    unsigned int dw=width>1u?width/2u:1u,dh=height>1u?height/2u:1u;
    if(i>=dw*dh)return;
    unsigned int x0=(i%dw)*width/dw,x1=(i%dw+1u)*width/dw;
    unsigned int y0=(i/dw)*height/dh,y1=(i/dw+1u)*height/dh;
    float sum=0.0f;
    for(unsigned int y=y0;y<y1;y++)for(unsigned int x=x0;x<x1;x++)sum+=__uint_as_float(texels[source+y*width+x]);
    texels[destination+i]=__float_as_uint(store_depth_value(sum/(float)((x1-x0)*(y1-y0)),depth_bits));
}

__device__ float mip_sample(const unsigned int* texels,unsigned int base,unsigned int width,unsigned int height,
    float u,float v,unsigned int sampler,unsigned int channel,unsigned int level,unsigned int linear) {
    float borderValue=(sampler&8192)!=0?(channel==3?1.0f:((sampler&16384)!=0?1.0f:0.0f)):0.0f;
    if((sampler&536870912u)!=0u) {
        unsigned int description=texels[base+5u],kind=description&15u,range=description>>4u,component=channel;
        if(kind==4u||kind==5u)component=channel==3u?3u:0u;
        if(kind==7u)component=0u;
        if((sampler&8192)!=0u)component=0u;
        borderValue=__uint_as_float(texels[base+1u+component]);
        if(range==0u)borderValue=fminf(1.0f,fmaxf(0.0f,borderValue));
        if(range==1u)borderValue=fminf(1.0f,fmaxf(-1.0f,borderValue));
        if(range==2u)borderValue=fminf(65504.0f,fmaxf(-65504.0f,borderValue));
        if((kind>=1u&&kind<=3u&&channel>=kind)||(kind==4u&&channel==3u)||(kind==6u&&channel<3u))
            borderValue=channel==3u?1.0f:0.0f;
        if((sampler&8192)!=0u&&channel==3u)borderValue=1.0f;
        base=texels[base];
    }
    unsigned int stride=(sampler&32768)!=0?4:1;
    for(unsigned int l=0;l<level;l++) {base+=width*height*stride;width=width>1?width/2:1;height=height>1?height/2:1;}
    unsigned int ws=(sampler>>9)&3,wt=(sampler>>11)&3;
    // Legacy CLAMP bounds coordinates first. Nearest taps stay at the edge;
    // linear taps outside that edge blend the border into the result.
    if((sampler&1073741824u)!=0u){u=fminf(1.0f,fmaxf(0.0f,u));ws=linear!=0u?3u:0u;}
    if((sampler&2147483648u)!=0u){v=fminf(1.0f,fmaxf(0.0f,v));wt=linear!=0u?3u:0u;}
    // Bound the float-to-integer conversion before sampling, retaining wrap phase.
    u=ws==3?fminf(2.0f,fmaxf(-1.0f,u)):(ws==0?fminf(1.0f,fmaxf(0.0f,u)):u-floorf(u/(ws==2?2.0f:1.0f))*(ws==2?2.0f:1.0f));
    v=wt==3?fminf(2.0f,fmaxf(-1.0f,v)):(wt==0?fminf(1.0f,fmaxf(0.0f,v)):v-floorf(v/(wt==2?2.0f:1.0f))*(wt==2?2.0f:1.0f));
    float x=u*(float)width-(linear!=0?0.5f:0.0f),y=v*(float)height-(linear!=0?0.5f:0.0f);
    int ix=(int)floorf(x),iy=(int)floorf(y);
    float fx=x-floorf(x),fy=y-floorf(y),result=0.0f;
    unsigned int taps=linear!=0?2:1;
    for(unsigned int dy=0;dy<taps;dy++)for(unsigned int dx=0;dx<taps;dx++) {
        unsigned int address=base+((unsigned int)sampler_index(iy+(int)dy,(int)height,wt)*width+(unsigned int)sampler_index(ix+(int)dx,(int)width,ws))*stride;
        float weight=linear!=0?(dx==0?1.0f-fx:fx)*(dy==0?1.0f-fy:fy):1.0f;
        unsigned int border=(ws==3&&(ix+(int)dx<0||ix+(int)dx>=(int)width))||(wt==3&&(iy+(int)dy<0||iy+(int)dy>=(int)height));
        float value=(sampler&32768)!=0?__uint_as_float(texels[address+channel]):((sampler&8192)!=0?(channel==3?1.0f:__uint_as_float(texels[address])):(float)((texels[address]>>(channel*8))&255)/255.0f);
        if(border!=0)value=borderValue;
        result+=weight*value;
    }
    return result;
}
__device__ float sample_mipped(const unsigned int* texels,unsigned int base,unsigned int width,unsigned int height,
    float u,float v,float lod,unsigned int sampler,unsigned int channel) {
    if((sampler&268435456u)!=0u) {
        unsigned int selected=(sampler>>(16u+channel*3u))&7u;
        if(selected>=4u)return selected==5u?1.0f:0.0f;
        channel=selected;
    }

    if((sampler&536870912u)!=0u) {
        float minimum=__uint_as_float(texels[base+6u]),maximum=__uint_as_float(texels[base+7u]);
        float bias=fminf(16.0f,fmaxf(-16.0f,__uint_as_float(texels[base+8u])));
        lod=fminf(maximum,fmaxf(minimum,lod+bias));
    }
    unsigned int filter=(sampler>>5)&7,last=sampler&31;
    unsigned int magnification=(sampler>>8)&1;
    float crossover=magnification!=0u&&(filter==2u||filter==4u)?0.5f:0.0f;
    // Resolve filter state before sampling. Keep one static sampler call site
    // so downstream inlining does not duplicate the full addressing/format path
    // for magnification, nonmip minification and both trilinear levels.
    unsigned int linear=magnification,low=0u,high=0u,samples=1u;
    float fraction=0.0f;
    if(lod>crossover) {
        linear=filter;
        if(filter>=2u) {
            lod=fminf((float)last,fmaxf(0.0f,lod));
            linear=filter&1u;
            low=(unsigned int)floorf(lod+0.5f);
            if(filter>=4u) {
                low=(unsigned int)floorf(lod);high=low<last?low+1u:low;
                fraction=lod-(float)low;samples=2u;
            }
        }
    }
    float result=0.0f;
    for(unsigned int sample=0u;sample<samples;sample++) {
        float value=mip_sample(texels,base,width,height,u,v,sampler,channel,sample==0u?low:high,linear);
        if(sample==0u)result=value;
        else result=result*(1.0f-fraction)+value*fraction;
    }
    return result;
}

// Derivatives are in texels per screen pixel. The eigensystem of J*J^T
// gives the texture-space footprint's long axis, including rotated footprints.
__device__ float sample_gradient(const unsigned int* texels,unsigned int base,unsigned int width,unsigned int height,
    float u,float v,float ux,float vx,float uy,float vy,unsigned int sampler,unsigned int channel) {
    float isotropic=0.5f*log2f(fmaxf(0.00000001f,fmaxf(ux*ux+vx*vx,uy*uy+vy*vy)));
    float maximum=1.0f;
    if((sampler&536870912u)!=0u)maximum=fminf(16.0f,__uint_as_float(texels[base+9u]));
    if(maximum<=1.0f)return sample_mipped(texels,base,width,height,u,v,isotropic,sampler,channel);
    float xx=ux*ux+uy*uy,yy=vx*vx+vy*vy,xy=ux*vx+uy*vy;
    float difference=xx-yy;
    float discriminant=sqrtf(fmaxf(0.0f,difference*difference+4.0f*xy*xy));
    float majorSquared=fmaxf(0.00000001f,(xx+yy+discriminant)*0.5f);
    float major=sqrtf(majorSquared),minor=sqrtf(fmaxf(0.00000001f,(xx+yy-discriminant)*0.5f));
    if(major<=1.0f)return sample_mipped(texels,base,width,height,u,v,isotropic,sampler,channel);
    float ratio=fminf(maximum,major/fmaxf(1.0f,minor));
    unsigned int taps=(unsigned int)ceilf(fmaxf(1.0f,ratio));
    if(taps<=1u)return sample_mipped(texels,base,width,height,u,v,isotropic,sampler,channel);
    float axisU=xx>=yy?1.0f:0.0f,axisV=xx>=yy?0.0f:1.0f;
    if(fabsf(xy)>0.00000001f) {
        axisU=xx>=yy?majorSquared-yy:xy;axisV=xx>=yy?xy:majorSquared-xx;
        float length=sqrtf(fmaxf(0.000000000001f,axisU*axisU+axisV*axisV));axisU/=length;axisV/=length;
    }
    float lod=log2f(fmaxf(minor,major/maximum)),result=0.0f;
    for(unsigned int tap=0;tap<taps;tap++) {
        float offset=((float)tap+0.5f)/(float)taps-0.5f;
        result+=sample_mipped(texels,base,width,height,u+axisU*major*offset/(float)width,
            v+axisV*major*offset/(float)height,lod,sampler,channel);
    }
    return result/(float)taps;
}

// Fixed texture stage: environment24, width/height/sampler/unit, matrix16.
// Keep homogeneous texture Q until fragment interpolation and differentiation.
__device__ float sample_fixed_stage(const unsigned int* texels,const float* attributes,unsigned int descriptor,
    unsigned int va,unsigned int vb,unsigned int vc,float a,float b,float c,
    float dax,float dbx,float dcx,float day,float dby,float dcy,float inv,unsigned int channel,unsigned int spriteMask,float spriteU,float spriteV,float spriteDx,float spriteDy) {
    unsigned int unit=texels[descriptor+27u],coord=unit==0u?16u:10u+(unit-1u)*2u;
    if((spriteMask&(1u<<unit))!=0u) {
        // Coordinate replacement occurs after texture matrices and uses R=0,Q=1.
        return sample_gradient(texels,texels[descriptor],texels[descriptor+24u],texels[descriptor+25u],
            spriteU,spriteV,spriteDx*(float)texels[descriptor+24u],0.0f,0.0f,spriteDy*(float)texels[descriptor+25u],texels[descriptor+26u],channel);
    }
    unsigned int indices[3];indices[0]=va;indices[1]=vb;indices[2]=vc;
    float ss[3],ts[3],qs[3];
    for(unsigned int corner=0;corner<3;corner++) {
        float u=attributes[indices[corner]*34u+coord],v=attributes[indices[corner]*34u+coord+1u];
        float r=attributes[indices[corner]*34u+26u+unit*2u],q=attributes[indices[corner]*34u+27u+unit*2u];
        ss[corner]=__uint_as_float(texels[descriptor+28u])*u+__uint_as_float(texels[descriptor+32u])*v+__uint_as_float(texels[descriptor+36u])*r+__uint_as_float(texels[descriptor+40u])*q;
        ts[corner]=__uint_as_float(texels[descriptor+29u])*u+__uint_as_float(texels[descriptor+33u])*v+__uint_as_float(texels[descriptor+37u])*r+__uint_as_float(texels[descriptor+41u])*q;
        qs[corner]=__uint_as_float(texels[descriptor+31u])*u+__uint_as_float(texels[descriptor+35u])*v+__uint_as_float(texels[descriptor+39u])*r+__uint_as_float(texels[descriptor+43u])*q;
    }
    float ns=a*ss[0]+b*ss[1]+c*ss[2],nt=a*ts[0]+b*ts[1]+c*ts[2],q=a*qs[0]+b*qs[1]+c*qs[2];
    if(fabsf(q)<0.000000000001f)return 0.0f;
    float u=ns/q,v=nt/q;
    float qx=(dax*(qs[0]-q)+dbx*(qs[1]-q)+dcx*(qs[2]-q))/inv;
    float qy=(day*(qs[0]-q)+dby*(qs[1]-q)+dcy*(qs[2]-q))/inv;
    float sx=(dax*(ss[0]-ns)+dbx*(ss[1]-ns)+dcx*(ss[2]-ns))/inv;
    float sy=(day*(ss[0]-ns)+dby*(ss[1]-ns)+dcy*(ss[2]-ns))/inv;
    float tx=(dax*(ts[0]-nt)+dbx*(ts[1]-nt)+dcx*(ts[2]-nt))/inv;
    float ty=(day*(ts[0]-nt)+dby*(ts[1]-nt)+dcy*(ts[2]-nt))/inv;
    float width=(float)texels[descriptor+24u],height=(float)texels[descriptor+25u];
    float ux=(sx-u*qx)/q*width,uy=(sy-u*qy)/q*width;
    float vx=(tx-v*qx)/q*height,vy=(ty-v*qy)/q*height;
    float lod=0.5f*log2f(fmaxf(0.00000001f,fmaxf(ux*ux+vx*vx,uy*uy+vy*vy)));
    return sample_gradient(texels,texels[descriptor],texels[descriptor+24u],texels[descriptor+25u],u,v,ux,vx,uy,vy,texels[descriptor+26u],channel);
}

// Layer descriptor: atlas offset, size, sampler, UV set, reserved, matrix at 8.
// Channels 4/5 return the coverage LOD at fixed 256 / actual texture dimensions.
__device__ float sample_layer_shifted(const unsigned int* texels,const float* attributes,unsigned int descriptor,
    unsigned int va,unsigned int vb,unsigned int vc,float a,float b,float c,
    float dax,float dbx,float dcx,float day,float dby,float dcy,float inv,unsigned int channel,
    float offsetU,float offsetV,float offsetUx,float offsetVx,float offsetUy,float offsetVy) {
    unsigned int unit=texels[descriptor+4],coord=unit==0?16:10+(unit-1)*2;
    unsigned int indices[3];indices[0]=va;indices[1]=vb;indices[2]=vc;
    float us[3],vs[3];
    for(unsigned int corner=0;corner<3;corner++) {
        float u=attributes[indices[corner]*34+coord],v=attributes[indices[corner]*34+coord+1];
        us[corner]=__uint_as_float(texels[descriptor+8])*u+__uint_as_float(texels[descriptor+12])*v+__uint_as_float(texels[descriptor+20]);
        vs[corner]=__uint_as_float(texels[descriptor+9])*u+__uint_as_float(texels[descriptor+13])*v+__uint_as_float(texels[descriptor+21]);
    }
    float u=a*us[0]+b*us[1]+c*us[2],v=a*vs[0]+b*vs[1]+c*vs[2];
    float w=channel==4?256.0f:(float)texels[descriptor+1],h=channel==4?256.0f:(float)texels[descriptor+2];
    float ux=(dax*(us[0]-u)+dbx*(us[1]-u)+dcx*(us[2]-u))/inv*w;
    float vx=(dax*(vs[0]-v)+dbx*(vs[1]-v)+dcx*(vs[2]-v))/inv*h;
    float uy=(day*(us[0]-u)+dby*(us[1]-u)+dcy*(us[2]-u))/inv*w;
    float vy=(day*(vs[0]-v)+dby*(vs[1]-v)+dcy*(vs[2]-v))/inv*h;
    ux+=offsetUx*w;vx+=offsetVx*h;uy+=offsetUy*w;vy+=offsetVy*h;
    float lod=0.5f*log2f(fmaxf(0.00000001f,fmaxf(ux*ux+vx*vx,uy*uy+vy*vy)));
    if(channel>=4)return fmaxf(lod,0.0f);
    return sample_gradient(texels,texels[descriptor],texels[descriptor+1],texels[descriptor+2],u+offsetU,v+offsetV,ux,vx,uy,vy,texels[descriptor+3],channel);
}

__device__ float sample_layer(const unsigned int* texels,const float* attributes,unsigned int descriptor,
    unsigned int va,unsigned int vb,unsigned int vc,float a,float b,float c,
    float dax,float dbx,float dcx,float day,float dby,float dcy,float inv,unsigned int channel) {
    return sample_layer_shifted(texels,attributes,descriptor,va,vb,vc,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,channel,0.0f,0.0f,0.0f,0.0f,0.0f,0.0f);
}

__device__ float parallax_offset(const unsigned int* texels,const float* attributes,unsigned int descriptor,
    unsigned int va,unsigned int vb,unsigned int vc,float a,float b,float c,
    float dax,float dbx,float dcx,float day,float dby,float dcy,float inv,unsigned int axis) {
    float position[3],length=0.0f,projection=0.0f;
    for(unsigned int k=0;k<3;k++) {
        position[k]=a*attributes[va*34+k]+b*attributes[vb*34+k]+c*attributes[vc*34+k];length+=position[k]*position[k];
    }
    length=sqrtf(fmaxf(length,0.000000000001f));
    unsigned int column=axis==0?6:18;
    for(unsigned int k=0;k<3;k++)projection-=position[k]/length*(a*attributes[va*34+column+k]+b*attributes[vb*34+column+k]+c*attributes[vc*34+column+k]);
    float height=sample_layer(texels,attributes,descriptor,va,vb,vc,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,3);
    return projection*(height*0.04f-0.02f);
}

// Alpha inputs at arbitrary quad-helper coordinates, before shader alphaTest.
__device__ float object_alpha(const unsigned int* texels,const float* attributes,const float* vertices,unsigned int data,unsigned int flags,unsigned int falloff_offset,
    unsigned int va,unsigned int vb,unsigned int vc,float a,float b,float c,float dax,float dbx,float dcx,float day,float dby,float dcy,float inv) {
    unsigned int features=texels[data+4],layers=texels[data+72],mode=texels[data+5];
    float offsets[6];for(unsigned int k=0;k<6;k++)offsets[k]=0.0f;
    if((features&1536)!=0) {
        unsigned int heightMap=data+((features&512)!=0?176:224);
        float ix=fmaxf(0.000000000001f,inv+dax+dbx+dcx),iy=fmaxf(0.000000000001f,inv+day+dby+dcy);
        for(unsigned int k=0;k<2;k++) {
            offsets[k]=parallax_offset(texels,attributes,heightMap,va,vb,vc,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,k);
            offsets[k+2]=parallax_offset(texels,attributes,heightMap,va,vb,vc,(a*inv+dax)/ix,(b*inv+dbx)/ix,(c*inv+dcx)/ix,dax,dbx,dcx,day,dby,dcy,ix,k)-offsets[k];
            offsets[k+4]=parallax_offset(texels,attributes,heightMap,va,vb,vc,(a*inv+day)/iy,(b*inv+dby)/iy,(c*inv+dcy)/iy,dax,dbx,dcx,day,dby,dcy,iy,k)-offsets[k];
        }
    }
    float alpha=(mode==2||mode==4)?a*vertices[va*10+7]+b*vertices[vb*10+7]+c*vertices[vc*10+7]:__uint_as_float(texels[data+15]);
    if((features&(16384u|1073741824u))!=0u)alpha=1.0f;
    if((flags&1)!=0&&(features&5120)==0)alpha*=sample_layer_shifted(texels,attributes,data+224,va,vb,vc,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,3,offsets[0],offsets[1],offsets[2],offsets[3],offsets[4],offsets[5]);
    if((layers&1)!=0)alpha*=sample_layer(texels,attributes,data+80,va,vb,vc,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,3);
    if((layers&1024)!=0)alpha*=sample_layer(texels,attributes,data+328,va,vb,vc,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,3);
    if((features&67108864)!=0) {
        float depth=a*attributes[va*34+9]+b*attributes[vb*34+9]+c*attributes[vc*34+9];
        float start=__uint_as_float(texels[data+320]),end=__uint_as_float(texels[data+321]);
        float fade=fminf(1.0f,fmaxf(0.0f,(depth-start)/fmaxf(0.000001f,end-start)));
        alpha*=1.0f-fade*fade*(3.0f-2.0f*fade);
    }
    if((features&64)!=0&&(layers&1)!=0)alpha*=1.0f+0.25f*sample_layer(texels,attributes,data+80,va,vb,vc,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,(features&128)!=0?5:4);
    if((features&64)!=0&&(flags&1)!=0&&(features&5120)==0) {
        float lod=sample_layer_shifted(texels,attributes,data+224,va,vb,vc,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,(features&128)!=0?5:4,offsets[0],offsets[1],offsets[2],offsets[3],offsets[4],offsets[5]);
        alpha*=1.0f+0.25f*fmaxf(0.0f,lod);
    }
    if((features&268435456u)!=0u)alpha*=a*attributes[falloff_offset+va*4u]+b*attributes[falloff_offset+vb*4u]+c*attributes[falloff_offset+vc*4u];
    return alpha;
}

__device__ float environment_coordinate(const unsigned int* texels,const float* attributes,unsigned int data,
    unsigned int va,unsigned int vb,unsigned int vc,float a,float b,float c,
    float dax,float dbx,float dcx,float day,float dby,float dcy,float inv,unsigned int axis) {
    unsigned int layers=texels[data+72],features=texels[data+4];
    unsigned int mapped=(layers&16)!=0;
    float result=mapped!=0?0.0f:a*attributes[va*34+21+axis]+b*attributes[vb*34+21+axis]+c*attributes[vc*34+21+axis];
    for(unsigned int corner=0;corner<(mapped!=0?1:0);corner++) {
        float aa=mapped!=0?a:(corner==0?1.0f:0.0f),bb=mapped!=0?b:(corner==1?1.0f:0.0f),cc=mapped!=0?c:(corner==2?1.0f:0.0f);
        float p[3],n[3],pl=0.0f,nl=0.0f;
        for(unsigned int k=0;k<3;k++) {
            p[k]=aa*attributes[va*34+k]+bb*attributes[vb*34+k]+cc*attributes[vc*34+k];
            n[k]=aa*attributes[va*34+3+k]+bb*attributes[vb*34+3+k]+cc*attributes[vc*34+3+k];pl+=p[k]*p[k];
        }
        if(mapped!=0) {
            float offsets[6];for(unsigned int k=0;k<6;k++)offsets[k]=0.0f;
            if((features&1536)!=0) {
                unsigned int heightMap=data+((features&512)!=0?176:224);
                float ix=fmaxf(0.000000000001f,inv+dax+dbx+dcx),iy=fmaxf(0.000000000001f,inv+day+dby+dcy);
                for(unsigned int k=0;k<2;k++) {
                    offsets[k]=parallax_offset(texels,attributes,heightMap,va,vb,vc,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,k);
                    offsets[k+2]=parallax_offset(texels,attributes,heightMap,va,vb,vc,(a*inv+dax)/ix,(b*inv+dbx)/ix,(c*inv+dcx)/ix,dax,dbx,dcx,day,dby,dcy,ix,k)-offsets[k];
                    offsets[k+4]=parallax_offset(texels,attributes,heightMap,va,vb,vc,(a*inv+day)/iy,(b*inv+dby)/iy,(c*inv+dcy)/iy,dax,dbx,dcx,day,dby,dcy,iy,k)-offsets[k];
                }
            }
            float sample[3];
            for(unsigned int k=0;k<3;k++)sample[k]=sample_layer_shifted(texels,attributes,data+176,va,vb,vc,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,k,offsets[0],offsets[1],offsets[2],offsets[3],offsets[4],offsets[5])*2.0f-1.0f;
            if((features&256)!=0)sample[2]=sqrtf(fmaxf(0.0f,1.0f-sample[0]*sample[0]-sample[1]*sample[1]));
            for(unsigned int k=0;k<3;k++) {
                float tangent=a*attributes[va*34+6+k]+b*attributes[vb*34+6+k]+c*attributes[vc*34+6+k];
                float bitangent=a*attributes[va*34+18+k]+b*attributes[vb*34+18+k]+c*attributes[vc*34+18+k];
                n[k]=tangent*sample[0]+bitangent*sample[1]+n[k]*sample[2];
            }
        }
        for(unsigned int k=0;k<3;k++)nl+=n[k]*n[k];
        pl=sqrtf(fmaxf(pl,0.000000000001f));nl=sqrtf(fmaxf(nl,0.000000000001f));
        float dot=0.0f;
        for(unsigned int k=0;k<3;k++){p[k]/=pl;n[k]/=nl;dot+=p[k]*n[k];}
        float reflected[3];for(unsigned int k=0;k<3;k++)reflected[k]=p[k]-2.0f*dot*n[k];
        float denominator=2.0f*sqrtf(fmaxf(0.000000000001f,reflected[0]*reflected[0]+reflected[1]*reflected[1]+(reflected[2]+1.0f)*(reflected[2]+1.0f)));
        result+=(reflected[axis]/denominator+0.5f)*(mapped!=0?1.0f:(corner==0?a:(corner==1?b:c)));
    }
    if((layers&256)!=0) {
        float bx=sample_layer(texels,attributes,data+272,va,vb,vc,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,0);
        float by=sample_layer(texels,attributes,data+272,va,vb,vc,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,1);
        result+=bx*__uint_as_float(texels[data+320+axis*2])+by*__uint_as_float(texels[data+321+axis*2]);
    }
    return result;
}

__device__ float shadow_mip(const unsigned int* texels,unsigned int descriptor,float u,float v,float reference,unsigned int level,unsigned int linear) {
    unsigned int width=texels[descriptor+1],height=texels[descriptor+2],sampler=texels[descriptor+3];
    unsigned int base=texels[descriptor];
    float borderValue=(sampler&16384)!=0?1.0f:0.0f;
    if((sampler&536870912u)!=0u) {
        borderValue=__uint_as_float(texels[base+1u]);
        if((texels[descriptor+5u]&8u)==0u)borderValue=fminf(1.0f,fmaxf(0.0f,borderValue));
        base=texels[base];
    }
    for(unsigned int l=0;l<level;l++){base+=width*height;width=width>1u?width/2u:1u;height=height>1u?height/2u:1u;}
    unsigned int ws=(sampler>>9)&3,wt=(sampler>>11)&3;
    // Legacy CLAMP bounds coordinates first. Nearest taps stay at the edge;
    // linear taps outside that edge blend the border into the result.
    if((sampler&1073741824u)!=0u){u=fminf(1.0f,fmaxf(0.0f,u));ws=linear!=0u?3u:0u;}
    if((sampler&2147483648u)!=0u){v=fminf(1.0f,fmaxf(0.0f,v));wt=linear!=0u?3u:0u;}
    u=ws==3?fminf(2.0f,fmaxf(-1.0f,u)):(ws==0?fminf(1.0f,fmaxf(0.0f,u)):u-floorf(u/(ws==2?2.0f:1.0f))*(ws==2?2.0f:1.0f));
    v=wt==3?fminf(2.0f,fmaxf(-1.0f,v)):(wt==0?fminf(1.0f,fmaxf(0.0f,v)):v-floorf(v/(wt==2?2.0f:1.0f))*(wt==2?2.0f:1.0f));
    float x=u*(float)width-(linear!=0?0.5f:0.0f),y=v*(float)height-(linear!=0?0.5f:0.0f);
    int ix=(int)floorf(x),iy=(int)floorf(y);float fx=x-floorf(x),fy=y-floorf(y),result=0.0f;
    unsigned int taps=linear!=0?2:1;
    for(unsigned int dy=0;dy<taps;dy++)for(unsigned int dx=0;dx<taps;dx++) {
        int xx=ix+(int)dx,yy=iy+(int)dy;
        unsigned int border=(ws==3&&(xx<0||xx>=(int)width))||(wt==3&&(yy<0||yy>=(int)height));
        unsigned int address=base+(unsigned int)sampler_index(yy,(int)height,wt)*width+(unsigned int)sampler_index(xx,(int)width,ws);
        float depth=border!=0?borderValue:__uint_as_float(texels[address]);
        float weight=linear!=0?(dx==0?1.0f-fx:fx)*(dy==0?1.0f-fy:fy):1.0f;
        float comparedReference=reference;
        if((texels[descriptor+5u]&8u)==0u) {
            comparedReference=fminf(1.0f,fmaxf(0.0f,comparedReference));
            depth=fminf(1.0f,fmaxf(0.0f,depth));
        }
        result+=weight*(float)compare_value(comparedReference,depth,texels[descriptor+4]);
    }
    return result;
}

__device__ float shadow_mipped(const unsigned int* texels,unsigned int descriptor,float u,float v,float reference,float lod) {
    unsigned int sampler=texels[descriptor+3u],base=texels[descriptor];
    if((sampler&536870912u)!=0u) {
        float bias=fminf(16.0f,fmaxf(-16.0f,__uint_as_float(texels[base+8u])));
        lod=fminf(__uint_as_float(texels[base+7u]),fmaxf(__uint_as_float(texels[base+6u]),lod+bias));
    }
    unsigned int filter=(sampler>>5u)&7u,magnification=(sampler>>8u)&1u,last=sampler&31u;
    float crossover=magnification!=0u&&(filter==2u||filter==4u)?0.5f:0.0f;
    if(lod<=crossover)return shadow_mip(texels,descriptor,u,v,reference,0u,magnification);
    if(filter<2u)return shadow_mip(texels,descriptor,u,v,reference,0u,filter);
    lod=fminf((float)last,fmaxf(0.0f,lod));
    unsigned int linear=filter&1u;
    if(filter<4u)return shadow_mip(texels,descriptor,u,v,reference,(unsigned int)floorf(lod+0.5f),linear);
    unsigned int low=(unsigned int)floorf(lod),high=low<last?low+1u:low;
    float fraction=lod-(float)low;
    return shadow_mip(texels,descriptor,u,v,reference,low,linear)*(1.0f-fraction)
        +shadow_mip(texels,descriptor,u,v,reference,high,linear)*fraction;
}

__device__ float shadow_compare(const unsigned int* texels,unsigned int descriptor,
    float u,float v,float reference,float ux,float vx,float uy,float vy) {
    unsigned int base=texels[descriptor],width=texels[descriptor+1u],height=texels[descriptor+2u],sampler=texels[descriptor+3u];
    float isotropic=0.5f*log2f(fmaxf(0.00000001f,fmaxf(ux*ux+vx*vx,uy*uy+vy*vy)));
    float maximum=1.0f;
    if((sampler&536870912u)!=0u)maximum=fminf(16.0f,__uint_as_float(texels[base+9u]));
    if(maximum<=1.0f)return shadow_mipped(texels,descriptor,u,v,reference,isotropic);
    float xx=ux*ux+uy*uy,yy=vx*vx+vy*vy,xy=ux*vx+uy*vy;
    float difference=xx-yy;
    float discriminant=sqrtf(fmaxf(0.0f,difference*difference+4.0f*xy*xy));
    float majorSquared=fmaxf(0.00000001f,(xx+yy+discriminant)*0.5f);
    float major=sqrtf(majorSquared),minor=sqrtf(fmaxf(0.00000001f,(xx+yy-discriminant)*0.5f));
    if(major<=1.0f)return shadow_mipped(texels,descriptor,u,v,reference,isotropic);
    float ratio=fminf(maximum,major/fmaxf(1.0f,minor));
    unsigned int taps=(unsigned int)ceilf(fmaxf(1.0f,ratio));
    if(taps<=1u)return shadow_mipped(texels,descriptor,u,v,reference,isotropic);
    float axisU=xx>=yy?1.0f:0.0f,axisV=xx>=yy?0.0f:1.0f;
    if(fabsf(xy)>0.00000001f) {
        axisU=xx>=yy?majorSquared-yy:xy;axisV=xx>=yy?xy:majorSquared-xx;
        float length=sqrtf(fmaxf(0.000000000001f,axisU*axisU+axisV*axisV));axisU/=length;axisV/=length;
    }
    float lod=log2f(fmaxf(minor,major/maximum)),result=0.0f;
    for(unsigned int tap=0;tap<taps;tap++) {
        float offset=((float)tap+0.5f)/(float)taps-0.5f;
        result+=shadow_mipped(texels,descriptor,u+axisU*major*offset/(float)width,
            v+axisV*major*offset/(float)height,reference,lod);
    }
    return result/(float)taps;
}

__global__ void clear_attachment(float* target, unsigned int pixel_count,
    unsigned int mask, float red, float green, float blue, float alpha, float depth,unsigned int normal_enabled,unsigned int normal_channels,unsigned int normal_storage,unsigned int color_channels,unsigned int color_storage,unsigned int depth_bits,unsigned int stencil_enabled,unsigned int stencil_clear,unsigned int clear_color_mask,unsigned int width,unsigned int height,int viewport_x,int viewport_y,unsigned int viewport_width,unsigned int viewport_height,unsigned int sample_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=pixel_count*sample_count)return;
    unsigned int target_offset=(i/pixel_count)*pixel_count*10;i=i%pixel_count;
    float x=(float)(i%width)+0.5f,y=(float)height-(float)(i/width)-0.5f;
    if(x<(float)viewport_x||y<(float)viewport_y
        ||x>=(float)viewport_x+(float)viewport_width||y>=(float)viewport_y+(float)viewport_height)return;
    if(color_channels==0u) {
        if((mask&256u)!=0u)target[i]=store_depth_value(depth,depth_bits);
        return;
    }
    if((mask&16384)!=0) {
        for(unsigned int c=0;c<4;c++) {
            if(c<color_channels&&(clear_color_mask&(1u<<c))==0u)continue;
            float value=c==0u?red:(c==1u?green:(c==2u?blue:alpha));
            target[target_offset+i*9+c]=store_color_value(value,c,color_channels,color_storage);
        }
        if(normal_enabled!=0)for(unsigned int c=0;c<4;c++) {
            if(c<normal_channels&&(clear_color_mask&(1u<<c))==0u)continue;
            float value=c==0u?red:(c==1u?green:(c==2u?blue:alpha));
            target[target_offset+i*9+5+c]=store_color_value(value,c,normal_channels,normal_storage);
        }
    }
    if((mask&256)!=0)target[target_offset+i*9+4]=store_depth_value(depth,depth_bits);
    if(stencil_enabled!=0u&&(mask&1024u)!=0u)target[target_offset+pixel_count*9u+i]=(float)stencil_clear;
}

__global__ void clear_target(float* target, unsigned int pixel_count,
                            float red, float green, float blue, float alpha, float depth) {
    unsigned int p = (blockIdx.x + blockIdx.y * gridDim.x) * blockDim.x + threadIdx.x;
    if (p >= pixel_count) return;
    target[p*9] = red; target[p*9+1] = green; target[p*9+2] = blue;
    target[p*9+3] = alpha; target[p*9+4] = depth;
    target[p*9+5]=red;target[p*9+6]=green;target[p*9+7]=blue;target[p*9+8]=alpha;
    target[pixel_count*9u+p]=0.0f;
}

#include "water.cu"
#include "raster-pixel.cuh"

__global__ void raster_material(const float* vertices, const unsigned int* triangles,
                               unsigned int* counts, const unsigned int* candidates,
                               const unsigned int* materials, const unsigned int* texels,
                               float* target, const float* attributes, unsigned int width, unsigned int height,
                               unsigned int capacity,unsigned int raster_offset,unsigned int boundary_offset,unsigned int point_fade_offset,unsigned int lighting_offset,unsigned int cluster_offset,unsigned int fixed_offset,unsigned int falloff_offset,unsigned int fixed_enabled,unsigned int normal_enabled,unsigned int normal_channels,unsigned int normal_storage,unsigned int color_channels,unsigned int color_storage,unsigned int depth_bits,unsigned int stencil_enabled,unsigned int sample_count) {
    unsigned int pixel = (blockIdx.x + blockIdx.y * gridDim.x) * blockDim.x + threadIdx.x;
    if (pixel >= width * height*sample_count) return;
    unsigned int sample=pixel/(width*height),target_offset=sample*width*height*10;
    pixel=raster_pixel_index(pixel%(width*height),width,height);
    unsigned int x = pixel % width; unsigned int y = pixel / width;
    unsigned int tile = (y / 16) * ((width + 15) / 16) + x / 16;
    unsigned int count = counts[tile];
    if (capacity!=0u && count > capacity) return; // Zero capacity selects compact lists.
    unsigned int candidateBase=capacity==0u?candidates[tile]:tile*capacity;
    float sampleX=0.5f,sampleY=0.5f;
    if(sample_count==2u){sampleX=sample==0u?0.25f:0.75f;sampleY=sampleX;}
    if(sample_count==4u) {
        sampleX=sample==0u?0.375f:(sample==1u?0.875f:(sample==2u?0.125f:0.625f));
        sampleY=sample==0u?0.125f:(sample==1u?0.375f:(sample==2u?0.625f:0.875f));
    }
    if(sample_count==8u) {
        unsigned int xs[8],ys[8];
        xs[0]=9u;xs[1]=7u;xs[2]=13u;xs[3]=5u;xs[4]=3u;xs[5]=1u;xs[6]=11u;xs[7]=15u;
        ys[0]=5u;ys[1]=11u;ys[2]=9u;ys[3]=3u;ys[4]=13u;ys[5]=7u;ys[6]=15u;ys[7]=1u;
        sampleX=(float)xs[sample]/16.0f;sampleY=(float)ys[sample]/16.0f;
    }
    if(sample_count==16u){sampleX=((float)(sample%4u)+0.5f)/4.0f;sampleY=((float)(sample/4u)+0.5f)/4.0f;}
    // Flatten candidate/edge traversal so the full shading body is not nested
    // in a small bounded loop that shader compilers may duplicate. Advance the
    // cursor before shading: every discard continues at the next primitive.
    unsigned int draw=0u,nextPrimitive=0u;
    while(draw<count) {
        unsigned int t = candidates[candidateBase + draw] * 4;
        unsigned int m = triangles[t+3] * 12;
        unsigned int flags = materials[m+3];
        // Polygon-mode edges/points are distinct primitives. Each eligible one
        // must run depth, stencil, queries and blending even if footprints overlap.
        unsigned int modes=(materials[m+9]>>27u)&15u;
        unsigned int primitiveCount=modes==0u?1u:3u;
        unsigned int primitive=nextPrimitive;
        nextPrimitive++;
        if(nextPrimitive>=primitiveCount){nextPrimitive=0u;draw++;}
        unsigned int raster=raster_offset+triangles[t+3]*50;
        unsigned int multisample=sample_count>1u&&attributes[raster+27]!=0.0f?1u:0u;
        float px=(float)x+(multisample!=0u?sampleX:0.5f);
        float py=(float)y+(multisample!=0u?sampleY:0.5f);
        if(multisample!=0u) {
            if((((unsigned int)attributes[raster+26]>>sample)&1u)==0u)continue;
            // Monotonic coverage; inversion complements this exact sample set.
            unsigned int rank=(sample+(x*3u+y*5u)%sample_count)%sample_count;
            unsigned int covered=raster_unit_value(attributes[raster+24])>=((float)rank+0.5f)/(float)sample_count?1u:0u;
            if(attributes[raster+25]!=0.0f)covered=1u-covered;
            if(covered==0u)continue;
        }
        if((flags&16777216u)!=0u) {
            if(raw_scissor_axis(x,materials[m+5u],materials[m+7u])==0u
                ||raw_scissor_axis(height-1u-y,materials[m+6u],materials[m+8u])==0u)continue;
        } else if (x < materials[m+5] || y < materials[m+6]
            || x - materials[m+5] >= materials[m+7] || y - materials[m+6] >= materials[m+8]) continue;
        unsigned int ia = triangles[t] * 10;
        unsigned int ib = triangles[t+1] * 10;
        unsigned int ic = triangles[t+2] * 10;
        float aw = vertices[ia+3]; float bw = vertices[ib+3]; float cw = vertices[ic+3];
        if (aw <= 0.0f || bw <= 0.0f || cw <= 0.0f) continue;
        float ax = (vertices[ia]/aw * 0.5f + 0.5f) * (float)width;
        float ay = (0.5f - vertices[ia+1]/aw * 0.5f) * (float)height;
        float bx = (vertices[ib]/bw * 0.5f + 0.5f) * (float)width;
        float by = (0.5f - vertices[ib+1]/bw * 0.5f) * (float)height;
        float cx = (vertices[ic]/cw * 0.5f + 0.5f) * (float)width;
        float cy = (0.5f - vertices[ic+1]/cw * 0.5f) * (float)height;
        float area = (bx-ax)*(cy-ay) - (by-ay)*(cx-ax);
        if (fabsf(area) < 0.000001f) continue;
        unsigned int control=materials[m+9];
        unsigned int front=(control&65536)!=0?area>0.0f:area<0.0f;
        if((flags&128)!=0) {
            unsigned int cull=(control>>14)&3;
            if(cull==3 || (cull==1 && front!=0) || (cull==2 && front==0))continue;
        }
        // Orient edge equations consistently, independent of triangle winding.
        float sign = area > 0.0f ? 1.0f : -1.0f;
        float ea = ((bx-px)*(cy-py) - (by-py)*(cx-px)) * sign;
        float eb = ((cx-px)*(ay-py) - (cy-py)*(ax-px)) * sign;
        float ec = ((ax-px)*(by-py) - (ay-py)*(bx-px)) * sign;
        unsigned int polygonMode=front!=0u?(control>>27u)&3u:(control>>29u)&3u;
        if(polygonMode==0u) {
            if(primitive!=0u)continue;
            if (ea < 0.0f || eb < 0.0f || ec < 0.0f) continue;
            // Top-left ownership prevents double blending on adjacent triangles.
            if (ea == 0.0f && !((cy-by)*sign < 0.0f || (cy == by && (cx-bx)*sign > 0.0f))) continue;
            if (eb == 0.0f && !((ay-cy)*sign < 0.0f || (ay == cy && (ax-cx)*sign > 0.0f))) continue;
            if (ec == 0.0f && !((by-ay)*sign < 0.0f || (by == ay && (bx-ax)*sign > 0.0f))) continue;
        }
        // Rejected filled samples need no interpolation weights or gradients.
        // Keep the original arithmetic/order for samples that reach shading.
        float pointFade=1.0f,spriteU=0.0f,spriteV=0.0f,spriteDx=0.0f,spriteDy=0.0f;
        unsigned int spriteMask=0u;
        float a = ea / fabsf(area); float b = eb / fabsf(area); float c = ec / fabsf(area);
        float gradAx=(by-cy)/area,gradBx=(cy-ay)/area,gradCx=(ay-by)/area;
        float gradAy=(cx-bx)/area,gradBy=(ax-cx)/area,gradCy=(bx-ax)/area;
        if(polygonMode!=0u) {
            // Process a perimeter edge/vertex, including coverage outside the
            // filled triangle. Clipping fan diagonals have a zero boundary flag.
            float xs[3],ys[3];xs[0]=ax;xs[1]=bx;xs[2]=cx;ys[0]=ay;ys[1]=by;ys[2]=cy;
            unsigned int selected=primitive;
            if(attributes[boundary_offset+(t/4u)*3u+selected]==0.0f)continue;
            unsigned int next=selected==2u?0u:selected+1u;
            float dx=xs[next]-xs[selected],dy=ys[next]-ys[selected];
            float qx=px-xs[selected],qy=py-ys[selected],along=0.0f;
            float pointSize=attributes[raster+38u];
            if(polygonMode==2u) {
                unsigned int pointVertex=triangles[t+selected]*34u;
                float distance2=0.0f;
                for(unsigned int axis=0u;axis<3u;axis++)distance2+=attributes[pointVertex+axis]*attributes[pointVertex+axis];
                float attenuation=attributes[raster+46u]+attributes[raster+47u]*sqrtf(distance2)+attributes[raster+48u]*distance2;
                pointSize/=sqrtf(fmaxf(0.000000000001f,attenuation));
                pointSize=fminf(attributes[raster+44u],fmaxf(attributes[raster+43u],pointSize));
                // Multisample point fading preserves a minimum footprint and
                // scales final fragment alpha after programmable shading.
                float threshold=attributes[raster+45u];
                if(multisample!=0u&&threshold>0.0f&&pointSize<threshold) {
                    float ratio=pointSize/threshold;pointFade=ratio*ratio;
                    pointSize=threshold;
                }
            }
            float halfSize=(polygonMode==1u?attributes[raster+37u]:pointSize)*0.5f;
            if(polygonMode==1u) {
                float length2=dx*dx+dy*dy;
                if(length2<=0.000000000001f)continue;
                along=(qx*dx+qy*dy)/length2;
                float aliasedWidth=fmaxf(1.0f,floorf(attributes[raster+37u]+0.5f));
                if(multisample==0u&&(((unsigned int)attributes[raster+49u])&128u)!=0u) {
                    float coverage=line_rectangle_coverage(-qx,-qy,dx,dy,attributes[raster+37u]);
                    if(coverage<=0.0f)continue;
                    pointFade*=coverage;along=fminf(1.0f,fmaxf(0.0f,along));
                } else if(multisample==0u) {
                    if(line_wide_diamond(-qx,-qy,dx,dy,aliasedWidth)==0u)continue;
                    // Coverage can reach beyond an endpoint's perpendicular
                    // plane; endpoint attributes remain clamped to the segment.
                    along=fminf(1.0f,fmaxf(0.0f,along));
                } else {
                    if(along<0.0f||along>=1.0f)continue;
                    float perpendicular=qx*dy-qy*dx;
                    if(perpendicular*perpendicular>halfSize*halfSize*length2)continue;
                }
            } else {
                // Outgoing boundary flags also select polygon-mode points.
                // Aliased points round size and snap their centre in GL's
                // bottom-left window coordinates; MSAA keeps subpixel centres.
                unsigned int pointFlags=(unsigned int)attributes[raster+49u];
                unsigned int smooth=multisample==0u&&(pointFlags&3u)==1u?1u:0u;
                if((pointFlags&2u)!=0u&&pointSize>0.0f) {
                    spriteMask=(pointFlags>>2u)&15u;spriteDx=1.0f/pointSize;
                    spriteDy=(pointFlags&64u)!=0u?-spriteDx:spriteDx;
                    // Sprite coordinates are fragment-centre values even when
                    // coverage is evaluated at an individual MSAA sample.
                    spriteU=0.5f+((float)x+0.5f-xs[selected])*spriteDx;
                    spriteV=0.5f+((float)y+0.5f-ys[selected])*spriteDy;
                }
                if(multisample==0u&&(pointFlags&3u)==0u) {
                    float size=fmaxf(1.0f,floorf(pointSize+0.5f));
                    float odd=size-2.0f*floorf(size*0.5f);
                    float centerX=odd!=0.0f?floorf(xs[selected])+0.5f:floorf(xs[selected]+0.5f);
                    float bottomY=(float)height-ys[selected];
                    float centerY=odd!=0.0f?floorf(bottomY)+0.5f:floorf(bottomY+0.5f);
                    qx=px-centerX;qy=py-((float)height-centerY);halfSize=size*0.5f;
                }
                if(smooth!=0u) {
                    float coverage=point_disk_coverage(qx,qy,halfSize);
                    if(coverage<=0.0f)continue;
                    pointFade*=coverage;
                } else if(qx < -halfSize || qx >= halfSize || qy < -halfSize || qy >= halfSize)continue;
            }
            a=selected==0u?1.0f-along:(selected==2u?along:0.0f);
            b=selected==1u?1.0f-along:(selected==0u?along:0.0f);
            c=selected==2u?1.0f-along:(selected==1u?along:0.0f);
            float gx=0.0f,gy=0.0f;
            if(polygonMode==1u) {
                unsigned int next=selected==2u?0u:selected+1u;
                float dx=xs[next]-xs[selected],dy=ys[next]-ys[selected];
                float length2=dx*dx+dy*dy;gx=dx/length2;gy=dy/length2;
            }
            // Line varyings follow the selected segment; point varyings are
            // constant. Reusing triangle gradients would choose incorrect mips.
            gradAx=selected==0u?-gx:(selected==2u?gx:0.0f);
            gradBx=selected==1u?-gx:(selected==0u?gx:0.0f);
            gradCx=selected==2u?-gx:(selected==1u?gx:0.0f);
            gradAy=selected==0u?-gy:(selected==2u?gy:0.0f);
            gradBy=selected==1u?-gy:(selected==0u?gy:0.0f);
            gradCy=selected==2u?-gy:(selected==1u?gy:0.0f);
        }
        unsigned int lineBase=point_fade_offset+(ia/10u)*12u;
        unsigned int generatedLine=attributes[lineBase+7u]>0.0f&&attributes[lineBase+11u]>0.0f?1u:0u;
        if(generatedLine!=0u) {
            float w0=attributes[lineBase+7u],w1=attributes[lineBase+11u];
            float x0=(attributes[lineBase+4u]/w0*0.5f+0.5f)*(float)width;
            float y0=(0.5f-attributes[lineBase+5u]/w0*0.5f)*(float)height;
            float dx=(attributes[lineBase+8u]/w1*0.5f+0.5f)*(float)width-x0;
            float dy=(0.5f-attributes[lineBase+9u]/w1*0.5f)*(float)height-y0;
            float length2=dx*dx+dy*dy;if(length2<=0.000000000001f)continue;
            float qx=px-x0,qy=py-y0,lineWidth=attributes[lineBase+2u];
            float along=(qx*dx+qy*dy)/length2;
            if(multisample==0u&&(((unsigned int)attributes[raster+49u])&128u)!=0u) {
                float coverage=line_rectangle_coverage(-qx,-qy,dx,dy,lineWidth);
                if(coverage<=0.0f)continue;pointFade*=coverage;
            } else if(multisample==0u) {
                if(line_wide_diamond(-qx,-qy,dx,dy,fmaxf(1.0f,floorf(lineWidth+0.5f)))==0u)continue;
            } else {
                float perpendicular=qx*dy-qy*dx;
                if(along<0.0f||along>=1.0f||perpendicular*perpendicular>lineWidth*lineWidth*0.25f*length2)continue;
            }
            float gradient=along>0.0f&&along<1.0f?1.0f:0.0f;
            along=fminf(1.0f,fmaxf(0.0f,along));
            float reciprocal=(1.0f-along)/w0+along/w1;
            float parameter=along/w1/reciprocal;
            float derivative=gradient/(w0*w1*reciprocal*reciprocal);
            float parameters[3],ws[3],basis[3],gx[3],gy[3];
            parameters[0]=attributes[lineBase+1u];
            parameters[1]=attributes[point_fade_offset+ib/10u*12u+1u];
            parameters[2]=attributes[point_fade_offset+ic/10u*12u+1u];
            ws[0]=aw;ws[1]=bw;ws[2]=cw;
            unsigned int low=0u,high=0u;
            for(unsigned int k=1u;k<3u;k++){if(parameters[k]<parameters[low])low=k;if(parameters[k]>parameters[high])high=k;}
            float span=parameters[high]-parameters[low];if(span<=0.000000000001f)continue;
            float weight=(parameter-parameters[low])/span;
            float sum=(1.0f-weight)*ws[low]+weight*ws[high];if(sum<=0.0f)continue;
            for(unsigned int k=0u;k<3u;k++) {
                float p=k==low?1.0f-weight:(k==high?weight:0.0f);
                float dp=k==low?-1.0f/span:(k==high?1.0f/span:0.0f);
                basis[k]=p*ws[k]/sum;
                float d=(dp*ws[k]-basis[k]*(ws[high]-ws[low])/span)/sum*derivative;
                gx[k]=d*dx/length2;gy[k]=d*dy/length2;
            }
            a=basis[0];b=basis[1];c=basis[2];
            gradAx=gx[0];gradBx=gx[1];gradCx=gx[2];gradAy=gy[0];gradBy=gy[1];gradCy=gy[2];
        }
        float depthScale=(flags&8388608u)!=0u?1.0f:0.5f;
        float depthBias=(flags&8388608u)!=0u?0.0f:0.5f;
        float z = (a*vertices[ia+2]/aw + b*vertices[ib+2]/bw + c*vertices[ic+2]/cw)*depthScale+depthBias;
        if((flags&262144u)==0u&&(z < 0.0f || z > 1.0f))continue;
        float nearDepth=raster_unit_value(attributes[raster+2]),farDepth=raster_unit_value(attributes[raster+3]);
        z=nearDepth+z*(farDepth-nearDepth);
        float dzdx=((by-cy)*vertices[ia+2]/aw+(cy-ay)*vertices[ib+2]/bw+(ay-by)*vertices[ic+2]/cw)/area*depthScale*(farDepth-nearDepth);
        float dzdy=((cx-bx)*vertices[ia+2]/aw+(ax-cx)*vertices[ib+2]/bw+(bx-ax)*vertices[ic+2]/cw)/area*depthScale*(farDepth-nearDepth);
        float largest=0.0f;
        largest=fmaxf(largest,fabsf(nearDepth+(vertices[ia+2]/aw*depthScale+depthBias)*(farDepth-nearDepth)));
        largest=fmaxf(largest,fabsf(nearDepth+(vertices[ib+2]/bw*depthScale+depthBias)*(farDepth-nearDepth)));
        largest=fmaxf(largest,fabsf(nearDepth+(vertices[ic+2]/cw*depthScale+depthBias)*(farDepth-nearDepth)));
        float unit=depth_bits==16u?1.0f/65536.0f:1.0f/16777216.0f;
        if(depth_bits==0u) {
            unsigned int exponent=(__float_as_uint(largest)>>23)&255u;
            unit=exponent>23u?__uint_as_float((exponent-23u)<<23):__uint_as_float(1u);
        }
        unsigned int offsetState=raster+(front!=0u?39u:41u);
        z+=fmaxf(fabsf(dzdx),fabsf(dzdy))*attributes[offsetState]+attributes[offsetState+1u]*unit;
        if((flags&262144u)!=0u)z=fminf(fmaxf(nearDepth,farDepth),fmaxf(fminf(nearDepth,farDepth),z));
        z=store_depth_value(z,depth_bits);
        unsigned int depth_pass=1u;
        if ((flags & 4) != 0) {
            float old = target[color_channels==0u?pixel:target_offset+pixel*9+4];
            if((flags&128)!=0)depth_pass=compare_value(z,old,control&15);
            else depth_pass=(flags&64)!=0?z<=old:z<old;
        }
        if(depth_pass==0u&&((flags&8192u)==0u||stencil_enabled==0u))continue;
        float inv = a/aw + b/bw + c/cw;
        a = a/aw/inv; b = b/bw/inv; c = c/cw/inv;
        float pointMetadata[4];
        for(unsigned int channel=0;channel<4;channel++)pointMetadata[channel]=
            a*attributes[point_fade_offset+ia/10u*12u+channel]+b*attributes[point_fade_offset+ib/10u*12u+channel]+c*attributes[point_fade_offset+ic/10u*12u+channel];
        pointFade*=pointMetadata[0];
        if(pointMetadata[3]>0.0f) {
            float coverage=point_disk_coverage(pointMetadata[1],pointMetadata[2],pointMetadata[3]);
            if(coverage<=0.0f)continue;
            pointFade*=coverage;
        }
        if(pointMetadata[3]<0.0f) {
            unsigned int pointFlags=(unsigned int)attributes[raster+49u];
            spriteMask=(pointFlags>>2u)&15u;
            spriteDx=-0.5f/pointMetadata[3];
            spriteDy=(pointFlags&64u)!=0u?-spriteDx:spriteDx;
            // Expanded metadata uses bottom-left local Y. Move sample-local
            // values back to the fragment centre before coordinate replacement.
            float localX=pointMetadata[1]+(multisample!=0u?0.5f-sampleX:0.0f);
            float localY=pointMetadata[2]+(multisample!=0u?sampleY-0.5f:0.0f);
            spriteU=0.5f+localX*spriteDx;
            spriteV=0.5f-localY*spriteDy;
        }
        float u = a*vertices[ia+8] + b*vertices[ib+8] + c*vertices[ic+8];
        float v = a*vertices[ia+9] + b*vertices[ib+9] + c*vertices[ic+9];
        float dax=gradAx/aw,dbx=gradBx/bw,dcx=gradCx/cw;
        float day=gradAy/aw,dby=gradBy/bw,dcy=gradCy/cw;
        float dudx=(dax*(vertices[ia+8]-u)+dbx*(vertices[ib+8]-u)+dcx*(vertices[ic+8]-u))/inv*(float)materials[m+1];
        float dvdx=(dax*(vertices[ia+9]-v)+dbx*(vertices[ib+9]-v)+dcx*(vertices[ic+9]-v))/inv*(float)materials[m+2];
        float dudy=(day*(vertices[ia+8]-u)+dby*(vertices[ib+8]-u)+dcy*(vertices[ic+8]-u))/inv*(float)materials[m+1];
        float dvdy=(day*(vertices[ia+9]-v)+dby*(vertices[ib+9]-v)+dcy*(vertices[ic+9]-v))/inv*(float)materials[m+2];
        if((spriteMask&1u)!=0u) {
            u=spriteU;v=spriteV;dudx=spriteDx*(float)materials[m+1];dvdy=spriteDy*(float)materials[m+2];
            dvdx=0.0f;dudy=0.0f;
        }
        float lod=0.5f*log2f(fmaxf(0.00000001f,fmaxf(dudx*dudx+dvdx*dvdx,dudy*dudy+dvdy*dvdy)));
        float color[4],fixedSpecular[3];for(unsigned int k=0;k<3;k++)fixedSpecular[k]=0.0f;
        unsigned int fixedLit=0,fa=0,fb=0,fc=0;
        if(fixed_enabled!=0) {
            fa=fixed_offset+(ia/10)*16+(front!=0?0u:8u);
            fb=fixed_offset+(ib/10)*16+(front!=0?0u:8u);
            fc=fixed_offset+(ic/10)*16+(front!=0?0u:8u);
            fixedLit=attributes[fa+7]>0.5f;
            if(fixedLit!=0)for(unsigned int k=0;k<3;k++)fixedSpecular[k]=a*attributes[fa+4+k]+b*attributes[fb+4+k]+c*attributes[fc+4+k];
        }
        float fragmentNormal[3];for(unsigned int k=0;k<3;k++)fragmentNormal[k]=0.0f;
        unsigned int writeNormal=0;
        for (unsigned int k = 0; k < 4; k++) {
            color[k] = fixedLit!=0?a*attributes[fa+k]+b*attributes[fb+k]+c*attributes[fc+k]
                :a*vertices[ia+4+k]+b*vertices[ib+4+k]+c*vertices[ic+4+k];
            if ((flags & 1) != 0 && (flags&547840)==0) color[k] *= (flags&512)!=0
                ?sample_gradient(texels,materials[m],materials[m+1],materials[m+2],u,v,dudx,dvdx,dudy,dvdy,materials[m+11],k)
                :sample_channel(texels, materials[m], materials[m+1], materials[m+2], u, v, flags, k);
        }
        if((flags&524288u)!=0u) {
            float glyphAlpha=color[3],shadowAlpha=0.0f,glyphRgb[3];
            for(unsigned int k=0;k<3u;k++)glyphRgb[k]=color[k];
            unsigned int shadow=attributes[raster+30]==1.0f?1u:0u;
            unsigned int outline=attributes[raster+30]==2.0f?1u:0u;
            float outlineWidth=outline!=0u?attributes[raster+31]*0.5f:0.0f;
            for(unsigned int layer=0;layer<=shadow;layer++) {
            float gu=u,gv=v;
            color[3]=glyphAlpha;
            for(unsigned int k=0;k<3u;k++)color[k]=glyphRgb[k];
            if(layer==0u&&shadow!=0u) {
                float scale=-attributes[raster+28]/attributes[raster+29];
                gu+=attributes[raster+31]*scale;gv+=attributes[raster+32]*scale;
            }
            unsigned int channel=(flags&1048576u)!=0u?0u:3u;
            if((flags&2097152u)==0u) {
                float coverage=sample_gradient(texels,materials[m],materials[m+1],materials[m+2],gu,gv,dudx,dvdx,dudy,dvdy,materials[m+11],channel);
                if(outline!=0u) {
                    // GLES text shader uses the maximum of a 3x3 coverage grid.
                    float delta=1.6f*attributes[raster+31]*attributes[raster+28]/attributes[raster+29];
                    float outer=coverage;
                    for(unsigned int oy=0;oy<3u;oy++)for(unsigned int ox=0;ox<3u;ox++) {
                        float local=sample_gradient(texels,materials[m],materials[m+1],materials[m+2],gu+((float)ox-1.0f)*delta*0.5f,gv+((float)oy-1.0f)*delta*0.5f,dudx,dvdx,dudy,dvdy,materials[m+11],channel);
                        outer=fmaxf(outer,local);
                    }
                    outer=fminf(1.0f,outer);
                    float mixValue=coverage*coverage*(3.0f-2.0f*coverage);
                    for(unsigned int k=0;k<3u;k++)color[k]=attributes[raster+33+k]*(1.0f-mixValue)+color[k]*mixValue;
                    color[3]=glyphAlpha*outer*outer*(3.0f-2.0f*outer);
                } else color[3]*=coverage;
            }
            else {
                channel=channel==0u?1u:0u;
                float dxu=0.75f*dudx/(float)materials[m+1],dxv=0.75f*dvdx/(float)materials[m+2];
                float dyu=0.75f*dudy/(float)materials[m+1],dyv=0.75f*dvdy/(float)materials[m+2];
                float textureDimension=attributes[raster+29],glyphDimension=attributes[raster+28];
                float distance=sqrtf((dxu+dyu)*(dxu+dyu)+(dxv+dyv)*(dxv+dyv))*textureDimension/glyphDimension;
                unsigned int nx=(unsigned int)fminf(4.0f,fmaxf(2.0f,floorf(textureDimension*sqrtf(dxu*dxu+dxv*dxv))));
                unsigned int ny=(unsigned int)fminf(4.0f,fmaxf(2.0f,floorf(textureDimension*sqrtf(dyu*dyu+dyv*dyv))));
                float blend=1.5f*distance/(float)(nx*ny),halfBlend=blend*0.5f;
                float center=sample_mipped(texels,materials[m],materials[m+1],materials[m+2],gu,gv,0.0f,materials[m+11],channel);
                float edge=center==0.0f?-1.0f:(center-0.5f)*(1.41f/6.0f);
                if(-edge-outlineWidth-halfBlend>distance)color[3]=0.0f;
                else if(edge-halfBlend<=distance) {
                    float sum=0.0f,rgbSum[3];
                    for(unsigned int k=0;k<3u;k++)rgbSum[k]=0.0f;
                    for(unsigned int sy=0;sy<ny;sy++)for(unsigned int sx=0;sx<nx;sx++) {
                        float su=gu-dxu*0.5f-dyu*0.5f+dxu*(float)sx/(float)(nx-1u)+dyu*(float)sy/(float)(ny-1u);
                        float sv=gv-dxv*0.5f-dyv*0.5f+dxv*(float)sx/(float)(nx-1u)+dyv*(float)sy/(float)(ny-1u);
                        float value=sample_mipped(texels,materials[m],materials[m+1],materials[m+2],su,sv,0.0f,materials[m+11],channel);
                        float e=value==0.0f?-1.0f:(value-0.5f)*(1.41f/6.0f);
                        float coverage=e>halfBlend?1.0f:0.0f;
                        if(e>-halfBlend&&e<=halfBlend&&blend>0.0f) {
                            coverage=fminf(1.0f,fmaxf(0.0f,(e+halfBlend)/blend));coverage=coverage*coverage*(3.0f-2.0f*coverage);
                        }
                        float sampleColor[3];
                        for(unsigned int k=0;k<3u;k++)sampleColor[k]=color[k];
                        float alpha=glyphAlpha*coverage;
                        if(outline!=0u&&e<=halfBlend) {
                            if(e>-halfBlend&&blend>0.0f) {
                                float transition=fminf(1.0f,fmaxf(0.0f,(halfBlend-e)/blend));
                                transition=transition*transition*(3.0f-2.0f*transition);
                                for(unsigned int k=0;k<3u;k++)sampleColor[k]=color[k]*(1.0f-transition)+attributes[raster+33+k]*transition;
                                alpha=glyphAlpha*((1.0f-transition)+attributes[raster+36]*transition);
                            } else {
                                for(unsigned int k=0;k<3u;k++)sampleColor[k]=attributes[raster+33+k];
                                if(e>halfBlend-outlineWidth)alpha=glyphAlpha*attributes[raster+36];
                                else if(e>-(outlineWidth+halfBlend)&&blend>0.0f)alpha=glyphAlpha*(halfBlend+outlineWidth+e)/blend;
                                else alpha=0.0f;
                            }
                        }
                        sum+=alpha*alpha;
                        for(unsigned int k=0;k<3u;k++)rgbSum[k]+=sampleColor[k]*alpha;
                    }
                    if(sum>0.0f)for(unsigned int k=0;k<3u;k++)color[k]=rgbSum[k]/sum;
                    color[3]=sum/(float)(nx*ny);
                }
            }
            if(shadow!=0u) {
                float alpha=render_power(fmaxf(0.0f,color[3]),(flags&2097152u)!=0u?0.6f:0.5f);
                if(layer==0u)shadowAlpha=alpha;
                else {
                    for(unsigned int k=0;k<3;k++)color[k]=attributes[raster+33+k]*(1.0f-alpha)+color[k]*alpha;
                    color[3]=shadowAlpha*(1.0f-alpha)+alpha*alpha;
                }
            }
            }
            if(color[3]==0.0f)continue;
        }
        if((flags&16384u)!=0u) {
            float primary[4],samples[16];
            for(unsigned int k=0;k<4;k++)primary[k]=color[k];
            for(unsigned int k=0;k<16;k++)samples[k]=1.0f;
            unsigned int environment=materials[m];
            for(unsigned int stage=0;stage<4u&&environment!=0u;stage++) {
                unsigned int unit=texels[environment+27u];
                for(unsigned int k=0;k<4;k++)samples[unit*4u+k]=sample_fixed_stage(texels,attributes,environment,
                    triangles[t],triangles[t+1],triangles[t+2],a,b,c,dax,dbx,dcx,day,dby,dcy,inv,k,spriteMask,spriteU,spriteV,spriteDx,spriteDy);
                environment=texels[environment+3u];
            }
            environment=materials[m];
            for(unsigned int stage=0;stage<4u&&environment!=0u;stage++) {
            unsigned int unit=texels[environment+27u];
            if(texels[environment+1u]==5u) {
                float arguments[12];
                for(unsigned int k=0;k<4;k++)for(unsigned int argument=0;argument<3;argument++) {
                    unsigned int descriptor=environment+(k==3u?18u:12u)+argument;
                    unsigned int source=texels[descriptor],operand=texels[descriptor+3u],channel=operand>=2u?3u:k;
                    // All samples are ready, including references to later units.
                    float value=source==0u?samples[unit*4u+channel]:(source==1u?primary[channel]:
                        (source==2u?raster_unit_value(__uint_as_float(texels[environment+4u+channel])):
                        (source==3u?color[channel]:samples[(source-4u)*4u+channel])));
                    arguments[k*3u+argument]=(operand&1u)!=0u?1.0f-value:value;
                }
                unsigned int rgbOperation=texels[environment+8u];
                float dot=0.0f;
                for(unsigned int k=0;k<3;k++)dot+=4.0f*(arguments[k*3u]-0.5f)*(arguments[k*3u+1u]-0.5f);
                for(unsigned int k=0;k<4;k++) {
                    unsigned int operation=texels[environment+(k==3u?9u:8u)];
                    float value=(rgbOperation>=6u&&(k<3u||rgbOperation==7u))?dot
                        :combine_texture_arguments(arguments[k*3u],arguments[k*3u+1u],arguments[k*3u+2u],operation);
                    // DOT3_RGBA replaces alpha with the RGB dot result and RGB scale.
                    unsigned int scale=texels[environment+(k==3u&&rgbOperation!=7u?11u:10u)];
                    color[k]=fminf(1.0f,fmaxf(0.0f,value*(float)scale));
                }
            } else for(unsigned int k=0;k<4;k++)color[k]=fminf(1.0f,fmaxf(0.0f,texture_environment(color[k],samples[unit*4u+k],samples[unit*4u+3u],
                raster_unit_value(__uint_as_float(texels[environment+4u+k])),texels[environment+1u],texels[environment+2u],k)));
            environment=texels[environment+3u];
            }
        }
        if((flags&4096)!=0) {
            unsigned int data=materials[m];
            float alpha=texels[data+5]!=0?((texels[data+7]&1)!=0?1.0f:color[3]):__uint_as_float(texels[data+6]);
            if((flags&1)!=0)alpha*=sample_gradient(texels,texels[data],texels[data+1],texels[data+2],u,v,dudx,dvdx,dudy,dvdy,texels[data+3],3);
            unsigned int function=texels[data+8];float reference=__uint_as_float(texels[data+4]);
            if((texels[data+7]&4u)!=0u&&(function==1u||function==3u||function==4u||function==6u)) {
                float quadAlpha[4];
                for(unsigned int lane=0;lane<4;lane++) {
                    float dx=(float)(x-x%2u+lane%2u)+0.5f-px,dy=(float)(y-y%2u+lane/2u)+0.5f-py;
                    float qi=inv+dx*(dax+dbx+dcx)+dy*(day+dby+dcy);
                    qi=fabsf(qi)>0.000000000001f?qi:0.000000000001f;
                    float qa=(a*inv+dx*dax+dy*day)/qi,qb=(b*inv+dx*dbx+dy*dby)/qi,qc=(c*inv+dx*dcx+dy*dcy)/qi;
                    float value=texels[data+5]!=0?((texels[data+7]&1u)!=0u?1.0f:qa*vertices[ia+7]+qb*vertices[ib+7]+qc*vertices[ic+7]):__uint_as_float(texels[data+6]);
                    if((flags&1u)!=0u) {
                        float qu=qa*vertices[ia+8]+qb*vertices[ib+8]+qc*vertices[ic+8];
                        float qv=qa*vertices[ia+9]+qb*vertices[ib+9]+qc*vertices[ic+9];
                        float ux=(dax*(vertices[ia+8]-qu)+dbx*(vertices[ib+8]-qu)+dcx*(vertices[ic+8]-qu))/qi*(float)texels[data+1];
                        float vx=(dax*(vertices[ia+9]-qv)+dbx*(vertices[ib+9]-qv)+dcx*(vertices[ic+9]-qv))/qi*(float)texels[data+2];
                        float uy=(day*(vertices[ia+8]-qu)+dby*(vertices[ib+8]-qu)+dcy*(vertices[ic+8]-qu))/qi*(float)texels[data+1];
                        float vy=(day*(vertices[ia+9]-qv)+dby*(vertices[ib+9]-qv)+dcy*(vertices[ic+9]-qv))/qi*(float)texels[data+2];
                        value*=sample_gradient(texels,texels[data],texels[data+1],texels[data+2],qu,qv,ux,vx,uy,vy,texels[data+3],3);
                    }
                    quadAlpha[lane]=value;
                }
                unsigned int row=(y%2u)*2u,column=x%2u;
                float alphaWidth=fabsf(quadAlpha[row+1]-quadAlpha[row])+fabsf(quadAlpha[column+2]-quadAlpha[column]);
                float coverage=(alpha-fminf(0.9999f,fmaxf(0.0001f,reference)))/fmaxf(alphaWidth,0.0001f)+0.5f;
                alpha=(function==1u||function==3u)?1.0f-coverage:coverage;
            } else if(compare_value(alpha,reference,function)==0)continue;
            if((texels[data+7]&2)!=0&&alpha<=0.5f)continue;
            color[0]=1.0f;color[1]=1.0f;color[2]=1.0f;color[3]=alpha;
        }
        if((flags&2048)!=0) {
            unsigned int data=materials[m],features=texels[data+4],mode=texels[data+5];
            unsigned int cluster=(features&16777216)!=0?texels[cluster_offset+m/12]:0;
            unsigned int layers=texels[data+72];
            float offsets[6];for(unsigned int k=0;k<6;k++)offsets[k]=0.0f;
            if((features&1536)!=0) {
                unsigned int heightMap=data+((features&512)!=0?176:224);
                float ix=fmaxf(0.000000000001f,inv+dax+dbx+dcx),iy=fmaxf(0.000000000001f,inv+day+dby+dcy);
                for(unsigned int axis=0;axis<2;axis++) {
                    offsets[axis]=parallax_offset(texels,attributes,heightMap,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,axis);
                    offsets[axis+2]=parallax_offset(texels,attributes,heightMap,ia/10,ib/10,ic/10,(a*inv+dax)/ix,(b*inv+dbx)/ix,(c*inv+dcx)/ix,dax,dbx,dcx,day,dby,dcy,ix,axis)-offsets[axis];
                    offsets[axis+4]=parallax_offset(texels,attributes,heightMap,ia/10,ib/10,ic/10,(a*inv+day)/iy,(b*inv+dby)/iy,(c*inv+dcy)/iy,dax,dbx,dcx,day,dby,dcy,iy,axis)-offsets[axis];
                }
            }
            float position[3],normal[3],eye[3];
            float normalLength=0.0f,eyeLength=0.0f;
            for(unsigned int k=0;k<3;k++) {
                position[k]=a*attributes[(ia/10)*34+k]+b*attributes[(ib/10)*34+k]+c*attributes[(ic/10)*34+k];
                normal[k]=a*attributes[(ia/10)*34+3+k]+b*attributes[(ib/10)*34+3+k]+c*attributes[(ic/10)*34+3+k];
                if((features&(268435456u|536870912u))!=0u&&(layers&16u)==0u)normal[k]=a*attributes[falloff_offset+(ia/10u)*4u+1u+k]+b*attributes[falloff_offset+(ib/10u)*4u+1u+k]+c*attributes[falloff_offset+(ic/10u)*4u+1u+k];
                normalLength+=normal[k]*normal[k];eyeLength+=position[k]*position[k];
            }
            if((layers&16)!=0) {
                float mapped[3];
                for(unsigned int k=0;k<3;k++)mapped[k]=sample_layer_shifted(texels,attributes,data+176,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,k,offsets[0],offsets[1],offsets[2],offsets[3],offsets[4],offsets[5])*2.0f-1.0f;
                if((features&256)!=0)mapped[2]=sqrtf(fmaxf(0.0f,1.0f-mapped[0]*mapped[0]-mapped[1]*mapped[1]));
                normalLength=0.0f;
                for(unsigned int k=0;k<3;k++) {
                    float tangent=a*attributes[(ia/10)*34+6+k]+b*attributes[(ib/10)*34+6+k]+c*attributes[(ic/10)*34+6+k];
                    float bitangent=a*attributes[(ia/10)*34+18+k]+b*attributes[(ib/10)*34+18+k]+c*attributes[(ic/10)*34+18+k];
                    normal[k]=tangent*mapped[0]+bitangent*mapped[1]+normal[k]*mapped[2];normalLength+=normal[k]*normal[k];
                }
            }
            normalLength=sqrtf(fmaxf(normalLength,0.000000000001f));eyeLength=sqrtf(fmaxf(eyeLength,0.000000000001f));
            for(unsigned int k=0;k<3;k++){normal[k]/=normalLength;eye[k]=position[k]/eyeLength;}
            if((features&131072)!=0) {writeNormal=1;for(unsigned int k=0;k<3;k++)fragmentNormal[k]=normal[k]*0.5f+0.5f;}
            float clipDistance=__uint_as_float(texels[data+71]);
            for(unsigned int row=0;row<3;row++) {
                float world=__uint_as_float(texels[data+52+12+row]);
                for(unsigned int col=0;col<3;col++)world+=__uint_as_float(texels[data+52+col*4+row])*position[col];
                clipDistance+=world*__uint_as_float(texels[data+68+row]);
            }
            if(clipDistance<0.0f&&(features&16384)==0)continue;
            if((features&524288)!=0) {
                unsigned int particle=data+texels[data+79];
                float world[4];
                for(unsigned int row=0;row<4;row++) {
                    world[row]=__uint_as_float(texels[data+52+12+row]);
                    for(unsigned int col=0;col<3;col++)world[row]+=__uint_as_float(texels[data+52+col*4+row])*position[col];
                }
                float coord[3];
                for(unsigned int row=0;row<3;row++) {
                    coord[row]=0.0f;for(unsigned int col=0;col<4;col++)coord[row]+=__uint_as_float(texels[particle+16+col*4+row])*world[col];
                }
                float sceneDepth=sample_mipped(texels,texels[particle+12],texels[particle+13],texels[particle+14],coord[0]*0.5f+0.5f,coord[1]*0.5f+0.5f,0.0f,texels[particle+15],0);
                if((features&65536)!=0?coord[2]<sceneDepth:coord[2]*0.5f+0.5f>sceneDepth)continue;
            }
            float diffuse[4],ambient[3],specular[3],lighting[3],shine[3];
            float linearDepth=(features&(69210112u|268435456u|536870912u))!=0u&&(features&65536)==0?a*vertices[ia+2]+b*vertices[ib+2]+c*vertices[ic+2]:-position[2];
            float shadowing=1.0f,shadowDebug[3];for(unsigned int k=0;k<3;k++)shadowDebug[k]=0.0f;
            unsigned int shadowDone=0;
            for(unsigned int cascade=0;cascade<texels[data+324];cascade++) {
                if(shadowDone!=0)break;
                unsigned int descriptor=data+texels[data+325]+cascade*40;
                float coords[4],region[4],coordsDx[4],coordsDy[4];
                for(unsigned int row=0;row<4;row++) {
                    coordsDx[row]=0.0f;coordsDy[row]=0.0f;
                    coords[row]=__uint_as_float(texels[descriptor+8+12+row]);
                    region[row]=__uint_as_float(texels[descriptor+24+12+row]);
                    for(unsigned int col=0;col<3;col++) {
                        float unitNormal=a*attributes[(ia/10)*34+23+col]+b*attributes[(ib/10)*34+23+col]+c*attributes[(ic/10)*34+23+col];
                        float offset=unitNormal*__uint_as_float(texels[descriptor+6]);
                        coords[row]+=__uint_as_float(texels[descriptor+8+col*4+row])*(position[col]+offset);
                        region[row]+=__uint_as_float(texels[descriptor+24+col*4+row])*position[col];
                        float normalOffset=__uint_as_float(texels[descriptor+6]);
                        float av=attributes[(ia/10)*34+col]+attributes[(ia/10)*34+23+col]*normalOffset-position[col]-offset;
                        float bv=attributes[(ib/10)*34+col]+attributes[(ib/10)*34+23+col]*normalOffset-position[col]-offset;
                        float cv=attributes[(ic/10)*34+col]+attributes[(ic/10)*34+23+col]*normalOffset-position[col]-offset;
                        float coefficient=__uint_as_float(texels[descriptor+8+col*4+row]);
                        coordsDx[row]+=coefficient*(dax*av+dbx*bv+dcx*cv)/inv;
                        coordsDy[row]+=coefficient*(day*av+dby*bv+dcy*cv)/inv;
                    }
                }
                if(fabsf(coords[3])<0.000000000001f)continue;
                float sx=coords[0]/coords[3],sy=coords[1]/coords[3],sz=coords[2]/coords[3];
                if(sx<=0.0f||sx>=1.0f||sy<=0.0f||sy>=1.0f)continue;
                shadowing=fminf(shadowing,shadow_compare(texels,descriptor,sx,sy,sz,
                    (coordsDx[0]-sx*coordsDx[3])/coords[3]*(float)texels[descriptor+1],
                    (coordsDx[1]-sy*coordsDx[3])/coords[3]*(float)texels[descriptor+2],
                    (coordsDy[0]-sx*coordsDy[3])/coords[3]*(float)texels[descriptor+1],
                    (coordsDy[1]-sy*coordsDy[3])/coords[3]*(float)texels[descriptor+2]));
                if((texels[descriptor+5]&2)!=0)shadowDebug[texels[descriptor+7]]+=0.1f;
                shadowDone=sx>0.05f&&sx<0.95f&&sy>0.05f&&sy<0.95f&&sz>0.0f&&sz<1.0f;
                if((texels[descriptor+5]&1)!=0) {
                    if(fabsf(region[3])<0.000000000001f)shadowDone=0;
                    else shadowDone=shadowDone!=0&&region[0]/region[3]>-1.0f&&region[0]/region[3]<1.0f&&region[1]/region[3]>-1.0f&&region[1]/region[3]<1.0f&&region[2]/region[3]<1.0f;
                }
            }
            if(texels[data+324]!=0) {
                unsigned int first=data+texels[data+325];
                if((texels[first+5]&4)!=0) {
                    float start=__uint_as_float(texels[data+326]),end=__uint_as_float(texels[data+327]);
                    float fade=fminf(1.0f,fmaxf(0.0f,(linearDepth-start)/fmaxf(0.000001f,end-start)));
                    shadowing=shadowing*(1.0f-fade)+fade;
                }
            }
            float shininess=fmaxf(0.0001f,__uint_as_float(texels[data+46]));
            if((features&8192)!=0)shininess=128.0f;
            if((layers&32)!=0)shininess=fmaxf(0.0001f,255.0f*sample_layer(texels,attributes,data+200,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,3));
            for(unsigned int k=0;k<4;k++)diffuse[k]=(mode==2||mode==4)?color[k]:__uint_as_float(texels[data+12+k]);
            for(unsigned int k=0;k<3;k++) {
                ambient[k]=(mode==2||mode==3)?color[k]:__uint_as_float(texels[data+8+k]);
                specular[k]=mode==5?color[k]:__uint_as_float(texels[data+16+k]);
                if((features&536870912u)!=0u&&(layers&16u)!=0u)specular[k]*=sample_layer(texels,attributes,data+176,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,3);
                if((layers&32)!=0)specular[k]=sample_layer(texels,attributes,data+200,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,k);
                if((features&8192)!=0)specular[k]=sample_layer_shifted(texels,attributes,data+224,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,3,offsets[0],offsets[1],offsets[2],offsets[3],offsets[4],offsets[5]);
                lighting[k]=(mode==1?color[k]:__uint_as_float(texels[data+20+k]))*__uint_as_float(texels[data+47]);
                if((features&536870912u)!=0u&&(layers&8u)!=0u)lighting[k]*=sample_layer(texels,attributes,data+152,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,k);
                shine[k]=0.0f;
            }
            unsigned int cell=cluster_cell(texels,cluster,px,(float)height-py,position[2]);
            unsigned int pointCount=cluster!=0?cluster_count(texels,cluster,cell):texels[data+6];
            if((features&(8388608u|268435456u))==0u)for(unsigned int light=0;light<=pointCount;light++) {
                unsigned int record=light==0?data+24:(cluster!=0?cluster_light(texels,cluster,cell,light-1):data+texels[data+7]+(light-1)*16);
                float direction[3],distance=0.0f;
                for(unsigned int k=0;k<3;k++) {direction[k]=__uint_as_float(texels[record+k])-(light==0?0.0f:position[k]);distance+=direction[k]*direction[k];}
                distance=sqrtf(fmaxf(distance,0.000000000001f));
                float attenuation=1.0f;
                if(light!=0) {
                    float radius=__uint_as_float(texels[record+15]);
                    if(((features&1)==0||cluster!=0)&&distance>radius)continue;
                    if(cluster!=0)attenuation*=cluster_distance_fade(texels,cluster,position[2],radius);
                    float denominator=__uint_as_float(texels[record+3])+__uint_as_float(texels[record+7])*distance+__uint_as_float(texels[record+11])*distance*distance;
                    attenuation/=fmaxf(denominator,0.000000000001f);
                    if((features&1)==0||cluster!=0) {
                        float fade=fminf(1.0f,fmaxf(0.0f,(distance/fmaxf(radius,0.000001f)-0.75f)/0.25f));
                        fade=1.0f-fade*fade;attenuation*=fade*fade;
                    }
                }
                float lambert=0.0f,halfLength=0.0f,halfVector[3];
                for(unsigned int k=0;k<3;k++){direction[k]/=distance;lambert+=normal[k]*direction[k];halfVector[k]=direction[k]-eye[k];halfLength+=halfVector[k]*halfVector[k];}
                if((features&67108864)!=0) {
                    float eyeCosine=0.0f;
                    for(unsigned int axis=0;axis<3;axis++)eyeCosine+=normal[axis]*eye[axis];
                    if(lambert<0.0f){lambert=-lambert;eyeCosine=-eyeCosine;}
                    lambert*=fminf(1.0f,fmaxf(0.3f,1.0f-5.6f*eyeCosine));
                }
                halfLength=sqrtf(fmaxf(halfLength,0.000000000001f));
                float spec=0.0f;
                if(lambert>0.0f) {for(unsigned int k=0;k<3;k++)spec+=normal[k]*halfVector[k]/halfLength;spec=render_power(fmaxf(spec,0.0f),shininess);}
                for(unsigned int k=0;k<3;k++) {
                    lighting[k]+=(diffuse[k]*__uint_as_float(texels[record+8+k])*fmaxf(lambert,0.0f)*(light==0?shadowing:1.0f)+ambient[k]*__uint_as_float(texels[record+4+k]))*attenuation;
                    shine[k]+=specular[k]*__uint_as_float(texels[record+12+k])*spec*attenuation*__uint_as_float(texels[data+48])*(light==0?shadowing:1.0f);
                }
            }
            if((features&8388608)!=0)for(unsigned int k=0;k<3;k++) {
                unsigned int la=lighting_offset+(ia/10)*12,lb=lighting_offset+(ib/10)*12,lc=lighting_offset+(ic/10)*12;
                float shaded=a*attributes[la+k]+b*attributes[lb+k]+c*attributes[lc+k];
                float lit=a*attributes[la+6+k]+b*attributes[lb+6+k]+c*attributes[lc+6+k];
                float shadeSpec=a*attributes[la+3+k]+b*attributes[lb+3+k]+c*attributes[lc+3+k];
                float litSpec=a*attributes[la+9+k]+b*attributes[lb+9+k]+c*attributes[lc+9+k];
                lighting[k]=shaded*(1.0f-shadowing)+lit*shadowing;
                shine[k]=shadeSpec*(1.0f-shadowing)+litSpec*shadowing;
            }
            float environment[3];for(unsigned int k=0;k<3;k++)environment[k]=0.0f;
            if((layers&128)!=0) {
                float envUV[2],envDx[2],envDy[2];
                float ix=fmaxf(0.000000000001f,inv+dax+dbx+dcx),iy=fmaxf(0.000000000001f,inv+day+dby+dcy);
                for(unsigned int axis=0;axis<2;axis++) {
                    envUV[axis]=environment_coordinate(texels,attributes,data,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,axis);
                    envDx[axis]=environment_coordinate(texels,attributes,data,ia/10,ib/10,ic/10,(a*inv+dax)/ix,(b*inv+dbx)/ix,(c*inv+dcx)/ix,dax,dbx,dcx,day,dby,dcy,ix,axis)-envUV[axis];
                    envDy[axis]=environment_coordinate(texels,attributes,data,ia/10,ib/10,ic/10,(a*inv+day)/iy,(b*inv+dby)/iy,(c*inv+dcy)/iy,dax,dbx,dcx,day,dby,dcy,iy,axis)-envUV[axis];
                }
                float width=(float)texels[data+249],height=(float)texels[data+250];
                float luma=1.0f;
                if((layers&256)!=0)luma=fminf(1.0f,fmaxf(0.0f,sample_layer(texels,attributes,data+272,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,2)*__uint_as_float(texels[data+77])+__uint_as_float(texels[data+78])));
                for(unsigned int k=0;k<3;k++) {
                    environment[k]=sample_gradient(texels,texels[data+248],texels[data+249],texels[data+250],envUV[0],envUV[1],envDx[0]*width,envDx[1]*height,envDy[0]*width,envDy[1]*height,texels[data+251],k)*__uint_as_float(texels[data+73+k])*luma;
                    if((layers&512)!=0)environment[k]*=sample_layer(texels,attributes,data+296,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,k);
                }
            }
            float decalAlpha=(layers&4)!=0?sample_layer(texels,attributes,data+128,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,3)*diffuse[3]:0.0f;
            for(unsigned int k=0;k<4;k++) {
                float sample=(flags&1)!=0?sample_layer_shifted(texels,attributes,data+224,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,k,offsets[0],offsets[1],offsets[2],offsets[3],offsets[4],offsets[5]):1.0f;
                if(k==3&&(features&5120)!=0)sample=1.0f;
                if((layers&1)!=0)sample*=sample_layer(texels,attributes,data+80,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,k);
                if(k<3) {
                    if((layers&2)!=0)sample*=2.0f*sample_layer(texels,attributes,data+104,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,k);
                    if((layers&4)!=0)sample=sample*(1.0f-decalAlpha)+sample_layer(texels,attributes,data+128,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,k)*decalAlpha;
                    if((features&2048)!=0)sample+=environment[k];
                    color[k]=sample*((features&2)!=0?fminf(1.0f,fmaxf(lighting[k],0.0f)):fmaxf(lighting[k],0.0f))+shine[k];
                    if((features&2048)==0)color[k]+=environment[k];
                    if((features&16384)!=0)color[k]=sample;
                    if((features&268435456u)!=0u)color[k]=sample*diffuse[k];
                    if((layers&8)!=0&&(features&536870912u)==0u)color[k]+=sample_layer(texels,attributes,data+152,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,k);
                } else color[k]=sample*((features&(16384u|1073741824u))!=0u?1.0f:diffuse[k]);
            }
            if((features&67108864)!=0) {
                float depth=a*attributes[(ia/10)*34+9]+b*attributes[(ib/10)*34+9]+c*attributes[(ic/10)*34+9];
                float start=__uint_as_float(texels[data+320]),end=__uint_as_float(texels[data+321]);
                float fade=fminf(1.0f,fmaxf(0.0f,(depth-start)/fmaxf(0.000001f,end-start)));
                color[3]*=1.0f-fade*fade*(3.0f-2.0f*fade);
            }
            if((layers&1024)!=0)color[3]*=sample_layer(texels,attributes,data+328,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,3);
            if((features&64)!=0&&(layers&1)!=0)color[3]*=1.0f+0.25f*sample_layer(texels,attributes,data+80,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,(features&128)!=0?5:4);
            if((features&64)!=0&&(flags&1)!=0&&(features&5120)==0) {
                float coverageLod=sample_layer_shifted(texels,attributes,data+224,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,(features&128)!=0?5:4,offsets[0],offsets[1],offsets[2],offsets[3],offsets[4],offsets[5]);
                color[3]*=1.0f+fmaxf(coverageLod,0.0f)*0.25f;
            }
            if((features&268435456u)!=0u)color[3]*=a*attributes[falloff_offset+(ia/10u)*4u]+b*attributes[falloff_offset+(ib/10u)*4u]+c*attributes[falloff_offset+(ic/10u)*4u];
            if((features&4194304)==0) {
                float reference=__uint_as_float(texels[data+49]);unsigned int function=texels[data+51];
                if((features&134217728)!=0&&(function==1u||function==3u||function==4u||function==6u)) {
                    float quadAlpha[4];
                    for(unsigned int lane=0;lane<4;lane++) {
                        float dx=(float)(x-x%2u+lane%2u)+0.5f-px,dy=(float)(y-y%2u+lane/2u)+0.5f-py;
                        float qi=inv+dx*(dax+dbx+dcx)+dy*(day+dby+dcy);
                        qi=fabsf(qi)>0.000000000001f?qi:0.000000000001f;
                        float qa=(a*inv+dx*dax+dy*day)/qi,qb=(b*inv+dx*dbx+dy*dby)/qi,qc=(c*inv+dx*dcx+dy*dcy)/qi;
                        quadAlpha[lane]=object_alpha(texels,attributes,vertices,data,flags,falloff_offset,ia/10,ib/10,ic/10,qa,qb,qc,dax,dbx,dcx,day,dby,dcy,qi);
                    }
                    unsigned int row=(y%2u)*2u,column=x%2u;
                    float alphaWidth=fabsf(quadAlpha[row+1]-quadAlpha[row])+fabsf(quadAlpha[column+2]-quadAlpha[column]);
                    float coverage=(color[3]-fminf(0.9999f,fmaxf(0.0001f,reference)))/fmaxf(alphaWidth,0.0001f)+0.5f;
                    color[3]=(function==1u||function==3u)?1.0f-coverage:coverage;
                } else if(compare_value(color[3],reference,function)==0)continue;
            }
            if((features&2097152)!=0) {
                float waterNormal[3],footprint[6];
                for(unsigned int k=0;k<3;k++) {
                    float va=attributes[(ia/10)*34+k]-position[k],vb=attributes[(ib/10)*34+k]-position[k],vc=attributes[(ic/10)*34+k]-position[k];
                    footprint[k]=(dax*va+dbx*vb+dcx*vc)/inv;
                    footprint[3+k]=(day*va+dby*vb+dcy*vc)/inv;
                }
                shade_water(texels,data,position,footprint,shadowing,((float)x+0.5f)/(float)width,1.0f-((float)y+0.5f)/(float)height,z,linearDepth,color,waterNormal,cluster,px,(float)height-py);
                for(unsigned int k=0;k<3;k++)fragmentNormal[k]=waterNormal[k]*0.5f+0.5f;
            }
            if((features&4194304)!=0) {
                unsigned int distortion=data+texels[data+79]+40;
                float ratio=fmaxf(0.000001f,__uint_as_float(texels[distortion+5]));
                float sceneDepth=sample_mipped(texels,texels[distortion],texels[distortion+1],texels[distortion+2],
                    ((float)x+0.5f)/(float)width/ratio,(1.0f-((float)y+0.5f)/(float)height)/ratio,0.0f,texels[distortion+3],0);
                for(unsigned int k=0;k<4;k++)color[k]=sample_layer_shifted(texels,attributes,data+224,ia/10,ib/10,ic/10,a,b,c,dax,dbx,dcx,day,dby,dcy,inv,k,offsets[0],offsets[1],offsets[2],offsets[3],offsets[4],offsets[5]);
                color[3]*=diffuse[3];if(color[3]<0.1f)continue;
                unsigned int occluded=(features&65536)!=0?z<sceneDepth:z>sceneDepth;
                float strength=occluded!=0?0.0f:__uint_as_float(texels[distortion+4])*color[3];
                color[0]=(color[0]*2.0f-1.0f)*strength;color[1]=(color[1]*2.0f-1.0f)*strength;color[2]=occluded!=0?1.0f:0.0f;
                writeNormal=0;
            }
            if((features&32)!=0&&(features&4194304)==0) {
                float euclidean=(features&(67112960u|268435456u|536870912u))!=0u?a*attributes[(ia/10)*34+9]+b*attributes[(ib/10)*34+9]+c*attributes[(ic/10)*34+9]:eyeLength;
                float distance=(features&4)!=0?euclidean:fabsf(linearDepth);
                float start=__uint_as_float(texels[data+44]),end=__uint_as_float(texels[data+45]);
                float fog=(features&8)!=0?1.0f-expf(-2.0f*fmaxf(0.0f,distance-start*0.5f)/fmaxf(0.000001f,end-start*0.5f))
                    :fminf(1.0f,fmaxf(0.0f,(distance-start)/fmaxf(0.000001f,end-start)));
                for(unsigned int k=0;k<3;k++)color[k]=color[k]*(1.0f-fog)+((features&16)!=0?0.0f:__uint_as_float(texels[data+40+k])*fog);
                if((features&1048576)!=0) {
                    unsigned int sky=data+texels[data+79]+32;
                    float far=__uint_as_float(texels[sky+4]),begin=__uint_as_float(texels[sky+5]);
                    float fade=fminf(1.0f,fmaxf(0.0f,(far-distance)/fmaxf(0.000001f,far-begin)));fade*=fade;
                    for(unsigned int k=0;k<3;k++) {
                        float background=(features&16)!=0?0.0f:sample_mipped(texels,texels[sky],texels[sky+1],texels[sky+2],
                            ((float)x+0.5f)/(float)width,1.0f-((float)y+0.5f)/(float)height,0.0f,texels[sky+3],k);
                        color[k]=background*(1.0f-fade)+color[k]*fade;
                    }
                }
            }
            if((features&262144)!=0&&(features&4194304)==0) {
                unsigned int particle=data+texels[data+79];
                float sceneDepth=sample_mipped(texels,texels[particle],texels[particle+1],texels[particle+2],((float)x+0.5f)/(float)width,1.0f-((float)y+0.5f)/(float)height,0.0f,texels[particle+3],0);
                if((features&65536)!=0)sceneDepth=1.0f-sceneDepth;
                float near=__uint_as_float(texels[particle+4]),far=__uint_as_float(texels[particle+5]);
                sceneDepth=near*far/((far-near)*sceneDepth-far);
                float size=__uint_as_float(texels[particle+6]),falloff=__uint_as_float(texels[particle+8]);
                float delta=fminf(1.0f,fmaxf(0.0f,(position[2]-sceneDepth)/fmaxf(0.000001f,size*0.33f))),bias=1.0f;
                if(texels[particle+7]!=0) {
                    float dot=0.0f;for(unsigned int k=0;k<3;k++)dot+=eye[k]*normal[k];dot=fminf(1.0f,fabsf(dot));
                    float fade=fminf(1.0f,fmaxf(0.0f,eyeLength/fmaxf(falloff,0.000001f)));fade=1.0f-fade*fade;fade=1.0f-fade*fade;
                    bias=dot*fade*(1.0f-render_power(1.0f-dot,1.3f));
                }
                color[3]*=0.845f*render_power(delta,1.3f)*bias;
            }
            if((features&4194304)==0) {
                if(texels[data+50]!=0)color[3]=1.0f;
                for(unsigned int k=0;k<3;k++)color[k]+=shadowDebug[k];
            }
        }
        if((flags&1024)!=0) {
            unsigned int data=materials[m],pass=texels[data+8];
            if(pass==5) {
                float alpha=sample_gradient(texels,texels[data],texels[data+1],texels[data+2],u,v,dudx,dvdx,dudy,dvdy,texels[data+3],3);
                if(alpha<=0.8f)continue;
                // The query shader defines opaque output; its texture alpha is
                // only a discard threshold. Continue through shared fragment tests.
                for(unsigned int k=0;k<4;k++)color[k]=1.0f;
            }
            float vertexAlpha=color[3],opacity=__uint_as_float(texels[data+9]);
            float phaseAlpha=1.0f,maskAlpha=1.0f,maskScaleX=1.0f,maskScaleY=1.0f;
            if(pass==3) {
                maskScaleX=(float)texels[data+5]/(float)materials[m+1];maskScaleY=(float)texels[data+6]/(float)materials[m+2];
                phaseAlpha=sample_gradient(texels,texels[data],texels[data+1],texels[data+2],u,v,dudx,dvdx,dudy,dvdy,texels[data+3],3);
                maskAlpha=sample_gradient(texels,texels[data+4],texels[data+5],texels[data+6],u,v,dudx*maskScaleX,dvdx*maskScaleY,dudy*maskScaleX,dvdy*maskScaleY,texels[data+7],3)*__uint_as_float(texels[data+17]);
            }
            for(unsigned int k=0;k<4;k++) {
                float emission=__uint_as_float(texels[data+18+k]);
                float sample=1.0f;
                if(pass>=1&&pass<=4)sample=sample_gradient(texels,texels[data],texels[data+1],texels[data+2],u,v,dudx,dvdx,dudy,dvdy,texels[data+3],k);
                if(pass==0)color[k]=emission*(k==3?vertexAlpha:1.0f);
                if(pass==1)color[k]=sample*(k==3?vertexAlpha*opacity:1.0f);
                if(pass==2) {
                    float fog=__uint_as_float(texels[data+26+k]);
                    color[k]=k==3?sample*vertexAlpha*opacity
                        :fog*(1.0f-vertexAlpha)+fminf(1.0f,fmaxf(0.0f,sample*emission))*vertexAlpha;
                }
                if(pass==3) {
                    float mask=sample_gradient(texels,texels[data+4],texels[data+5],texels[data+6],u,v,dudx*maskScaleX,dvdx*maskScaleY,dudy*maskScaleX,dvdy*maskScaleY,texels[data+7],k);
                    color[k]=k==3?maskAlpha:mask*__uint_as_float(texels[data+14+k])*maskAlpha
                        +sample*__uint_as_float(texels[data+10+k])*phaseAlpha*__uint_as_float(texels[data+17]);
                }
                if(pass==4)color[k]=sample*(k==3?__uint_as_float(texels[data+25]):1.0f);
                if(pass==6)color[k]=k==3?__uint_as_float(texels[data+25]):emission;
            }
        }
        if(fixedLit!=0)for(unsigned int k=0;k<3;k++)color[k]=fminf(1.0f,fmaxf(0.0f,color[k]+fixedSpecular[k]));
        if((flags&32768u)!=0u) {
            unsigned int fog=__float_as_uint(attributes[raster+23u]),mode=texels[fog]&3u;
            float position[3];
            for(unsigned int k=0;k<3;k++)position[k]=a*attributes[(ia/10u)*34u+k]+b*attributes[(ib/10u)*34u+k]+c*attributes[(ic/10u)*34u+k];
            float distance=(texels[fog]&4u)!=0u?sqrtf(position[0]*position[0]+position[1]*position[1]+position[2]*position[2]):fabsf(position[2]);
            if((texels[fog]&8u)!=0u)distance=a*attributes[(ia/10u)*34u+9u]+b*attributes[(ib/10u)*34u+9u]+c*attributes[(ic/10u)*34u+9u];
            if((texels[fog]&16u)!=0u)distance=__uint_as_float(texels[fog+8u]);
            float density=__uint_as_float(texels[fog+1u]),start=__uint_as_float(texels[fog+2u]),end=__uint_as_float(texels[fog+3u]);
            float factor=0.0f;
            if(mode==0u)factor=end!=start?(end-distance)/(end-start):(distance<end?1.0f:0.0f);
            else {float exponent=density*distance;if(mode==2u)exponent*=exponent;factor=expf(-exponent);}
            factor=fminf(1.0f,fmaxf(0.0f,factor));
            for(unsigned int k=0;k<3;k++)color[k]=factor*color[k]+(1.0f-factor)*raster_unit_value(__uint_as_float(texels[fog+4u+k]));
        }
        if((flags&256)!=0)for(unsigned int k=0;k<4;k++)color[k]=fminf(1.0f,fmaxf(0.0f,color[k]));
        color[3]*=pointFade;
        if((flags&128)!=0) {if(compare_value(color[3],raster_unit_value(__uint_as_float(materials[m+4])),(control>>4)&15)==0)continue;}
        else if (color[3] < (float)materials[m+4]/255.0f) continue;
        if(multisample!=0u&&(flags&65536u)!=0u) {
            // A stable per-pixel ordering gives monotonic coverage as alpha
            // rises, including fully uncovered alpha0 and fully covered alpha1.
            unsigned int rank=(sample+(x*3u+y*5u)%sample_count)%sample_count;
            float coverage=fminf(1.0f,fmaxf(0.0f,color[3]));
            if(coverage<((float)rank+0.5f)/(float)sample_count)continue;
        }
        // Alpha-to-one follows coverage generation, before blending/storage.
        if(multisample!=0u&&(flags&131072u)!=0u)color[3]=1.0f;
        // Nonpolygon points/lines always use front stencil state. Their
        // support triangles have no API-facing orientation; polygon LINE/POINT
        // draws retain the original polygon facing.
        unsigned int stencilFront=(flags&4194304u)!=0u?1u:front;
        if((flags&8192u)!=0u&&stencil_enabled!=0u)
            if(apply_stencil(target,attributes,raster,pixel,width*height,stencilFront,depth_pass,target_offset)==0u)continue;
        if(depth_pass==0u)continue;
        if((flags&1024u)!=0u&&texels[materials[m]+8u]==5u) {
            atomicAdd(&counts[((width+15u)/16u)*((height+15u)/16u)+1u+m/12u],1u);
            // Sun query geometry has no color, normal or depth side effects.
            continue;
        }
        // Color-less targets still run alpha, coverage and depth tests.
        if(color_channels==0u) {
            if((flags&8u)!=0u)target[pixel]=z;
            continue;
        }
        float alpha=clamp_blend_component(color[3],color_storage);
        float destAlpha=color_channels<4u?1.0f:clamp_blend_component(target[target_offset+pixel*9+3],color_storage);
        for(unsigned int k=0;k<4;k++) {
            // Masks protect stored channels only. Missing components have
            // format-defined values even if the corresponding mask is off.
            if(k<color_channels&&(flags&128)!=0 && ((control>>(17+k))&1)!=0)continue;
            float value=color[k],dest=k>=color_channels?(k==3u?1.0f:0.0f):target[target_offset+pixel*9+k];
            unsigned int logic=(flags&128u)!=0u&&(control&33554432u)!=0u;
            if(logic!=0u&&(color_storage==0u||color_storage==4u)) {
                value=logic_unorm(value,dest,(control>>21u)&15u,color_storage==4u?65535u:255u);
            }
            if((flags&2)!=0&&logic==0u) {
                float sourceBlend=clamp_blend_component(color[k],color_storage);
                float destBlend=clamp_blend_component(dest,color_storage);
                if((flags&128)!=0) {
                    unsigned int factors=materials[m+10]>>(k==3?8:0);
                    float sf=clamp_blend_component(blend_factor(factors&15,sourceBlend,destBlend,alpha,destAlpha,k,attributes[raster+4+k],attributes[raster+7]),color_storage);
                    float df=clamp_blend_component(blend_factor((factors>>4)&15,sourceBlend,destBlend,alpha,destAlpha,k,attributes[raster+4+k],attributes[raster+7]),color_storage);
                    value=blend_value(sourceBlend,destBlend,sf,df,(control>>(k==3?11:8))&7);
                } else value=k==3?alpha+destBlend*(1.0f-alpha):sourceBlend*alpha+destBlend*(1.0f-alpha);
            }
            if((flags&256)!=0)value=fminf(1.0f,fmaxf(0.0f,value));
            target[target_offset+pixel*9+k]=store_color_value(value,k,color_channels,color_storage);
        }
        if ((flags & 8) != 0) target[target_offset+pixel*9+4] = z;
        if(writeNormal!=0&&normal_enabled!=0) {
            unsigned int normal_mask=(flags&128)!=0?(unsigned int)attributes[raster+22u]:0u;
            float normalAlpha=multisample!=0u&&(flags&131072u)!=0u?1.0f:pointFade,normalDestAlpha=normal_channels<4u?1.0f:clamp_blend_component(target[target_offset+pixel*9+8],normal_storage);
            for(unsigned int k=0;k<4;k++)if(k>=normal_channels||(normal_mask&(1u<<k))==0u) {
                float value=k<3u?fragmentNormal[k]:normalAlpha;
                float dest=k>=normal_channels?(k==3u?1.0f:0.0f):target[target_offset+pixel*9+5+k];
                unsigned int logic=(flags&128u)!=0u&&(control&33554432u)!=0u;
                if(logic!=0u&&(normal_storage==0u||normal_storage==4u))value=logic_unorm(value,dest,(control>>21u)&15u,normal_storage==4u?65535u:255u);
                if(logic==0u&&(flags&128u)!=0u&&(control&67108864u)!=0u) {
                    float sourceBlend=clamp_blend_component(value,normal_storage),destBlend=clamp_blend_component(dest,normal_storage);
                    unsigned int factors=materials[m+10]>>(k==3u?8u:0u);
                    float sf=clamp_blend_component(blend_factor(factors&15u,sourceBlend,destBlend,normalAlpha,normalDestAlpha,k,attributes[raster+4u+k],attributes[raster+7u]),normal_storage);
                    float df=clamp_blend_component(blend_factor((factors>>4u)&15u,sourceBlend,destBlend,normalAlpha,normalDestAlpha,k,attributes[raster+4u+k],attributes[raster+7u]),normal_storage);
                    value=blend_value(sourceBlend,destBlend,sf,df,(control>>(k==3u?11u:8u))&7u);
                }
                target[target_offset+pixel*9+5+k]=store_color_value(value,k,normal_channels,normal_storage);
            }
        }
    }
}

// OSG samples render textures in bottom-left UV convention, while the raster
// attachment is stored top-first for browser presentation.
__global__ void depth_to_texture(const float* target,unsigned int* texels,
    unsigned int width,unsigned int height,unsigned int offset) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    texels[offset+(height-1-i/width)*width+i%width]=__float_as_uint(target[i*9+4]);
}
__global__ void copy_depth(const float* source,float* target,unsigned int pixel_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i<pixel_count)target[i*9+4]=source[i*9+4];
}
__global__ void clear_depth(float* target,unsigned int pixel_count,float depth) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i<pixel_count)target[i*9+4]=depth;
}
__global__ void copy_normals(const float* source,float* target,unsigned int pixel_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i<pixel_count)for(unsigned int k=5;k<9;k++)target[i*9+k]=source[i*9+k];
}
__global__ void normals_to_texture(const float* target,unsigned int* texels,
    unsigned int width,unsigned int height,unsigned int offset) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    unsigned int packed=0;
    for(unsigned int k=0;k<4;k++)packed|=((unsigned int)(fminf(1.0f,fmaxf(0.0f,target[i*9+5+k]))*255.0f+0.5f))<<(k*8);
    texels[offset+(height-1-i/width)*width+i%width]=packed;
}

__global__ void target_to_texture(const float* target, unsigned int* texels,
    unsigned int width, unsigned int height, unsigned int offset) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    unsigned int packed=0;
    for(unsigned int c=0;c<4;c++) {
        unsigned int value=(unsigned int)(fminf(1.0f,fmaxf(0.0f,target[i*9+c]))*255.0f+0.5f);
        packed|=value<<(c*8);
    }
    texels[offset+(height-1-i/width)*width+i%width]=packed;
}
__global__ void float_target_to_texture(const float* target,unsigned int* texels,
    unsigned int width,unsigned int height,unsigned int offset) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    for(unsigned int c=0;c<4;c++)texels[offset+((height-1-i/width)*width+i%width)*4+c]=__float_as_uint(target[i*9+c]);
}

__global__ void pack_target(const float* target, unsigned int* pixels,
                             unsigned int width, unsigned int height,
                             unsigned int row_pixels) {
    unsigned int i = (blockIdx.x + blockIdx.y * gridDim.x) * blockDim.x + threadIdx.x;
    if (i >= width * height) return;
    unsigned int r = (unsigned int)(fminf(1.0f, fmaxf(0.0f, target[i * 9])) * 255.0f + 0.5f);
    unsigned int g = (unsigned int)(fminf(1.0f, fmaxf(0.0f, target[i * 9 + 1])) * 255.0f + 0.5f);
    unsigned int b = (unsigned int)(fminf(1.0f, fmaxf(0.0f, target[i * 9 + 2])) * 255.0f + 0.5f);
    unsigned int a = (unsigned int)(fminf(1.0f, fmaxf(0.0f, target[i * 9 + 3])) * 255.0f + 0.5f);
    pixels[(i / width) * row_pixels + i % width] = r | (g << 8) | (b << 16) | (a << 24);
}

__global__ void copy_stencil(const float* source,float* target,unsigned int pixel_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i<pixel_count)target[pixel_count*9u+i]=source[pixel_count*9u+i];
}

// Wide normal attachments retain all four float components in the atlas.
__global__ void float_normals_to_texture(const float* target,unsigned int* texels,
    unsigned int width,unsigned int height,unsigned int offset) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    for(unsigned int c=0;c<4;c++)texels[offset+((height-1-i/width)*width+i%width)*4+c]=__float_as_uint(target[i*9+5+c]);
}
