// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW ripple spring equations. Attachments use top-first RGBA/depth/normal;
// simulation coordinates and sampling retain the shader's bottom-left origin.
__device__ float ripple_sample(const float* source,unsigned int width,unsigned int height,float x,float y,unsigned int channel) {
    x-=0.5f;y-=0.5f;
    int ix=(int)floorf(x),iy=(int)floorf(y);
    float fx=x-floorf(x),fy=y-floorf(y),sum=0.0f;
    for(int dy=0;dy<2;dy++)for(int dx=0;dx<2;dx++) {
        int sx=ix+dx,sy=iy+dy;
        sx=sx<0?0:(sx>=(int)width?(int)width-1:sx);
        sy=sy<0?0:(sy>=(int)height?(int)height-1:sy);
        sum+=source[((height-1-(unsigned int)sy)*width+(unsigned int)sx)*9+channel]
            *(dx==0?1.0f-fx:fx)*(dy==0?1.0f-fy:fy);
    }
    return sum;
}
__global__ void ripple_blob(const float* source,float* target,const float* positions,
    unsigned int width,unsigned int height,unsigned int count,float offset_x,float offset_y,float time) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    float x=(float)(i%width)+0.5f,y=(float)(height-1-i/width)+0.5f;
    float color[4];for(unsigned int c=0;c<4;c++)color[c]=ripple_sample(source,width,height,x+offset_x,y+offset_y,c);
    float multiplier=1.0f+0.055f*sinf(16.0f*time)+0.065f*sinf(12.87645f*time);
    for(unsigned int p=0;p<count;p++) {
        float size=multiplier*positions[p*3+2];
        if(size<=0.0f)continue;
        float dx=positions[p*3]+offset_x-x,dy=positions[p*3+1]+offset_y-y;
        float displace=fminf(1.0f,fmaxf(0.0f,0.2f*fabsf(sqrtf(dx*dx+dy*dy)/size-1.0f)+0.8f));
        color[0]=-1.0f+(color[0]+1.0f)*displace;color[1]=-1.0f+(color[1]+1.0f)*displace;
    }
    for(unsigned int c=0;c<4;c++)target[i*9+c]=color[c];
}
__global__ void ripple_simulate(const float* source,float* target,unsigned int width,unsigned int height) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    float x=(float)(i%width)+0.5f,y=(float)(height-1-i/width)+0.5f;
    float n[4],n2[4];
    for(unsigned int k=0;k<4;k++) {
        float dx=k==0?1.0f:(k==1?-1.0f:0.0f),dy=k==2?1.0f:(k==3?-1.0f:0.0f);
        n[k]=ripple_sample(source,width,height,x+dx,y+dy,0);
        n2[k]=ripple_sample(source,width,height,x+dx*1.5f,y+dy*1.5f,0);
    }
    target[i*9]=0.28f*(n[0]+n[1]+n[2]+n[3])+0.8f*source[i*9]-0.96f*source[i*9+1];
    target[i*9+1]=source[i*9];
    target[i*9+2]=2.0f*(n[0]-n[1])+0.5f*(n2[0]-n2[1]);
    target[i*9+3]=2.0f*(n[2]-n[3])+0.5f*(n2[2]-n2[3]);
}
