// SPDX-License-Identifier: GPL-3.0-or-later
// Resolve OSG's implicit inverse-view uniform in GPU-owned material storage.
// status is the extra word after the tile counts, checked before rasterization.
__global__ void resolve_camera(unsigned int* texels,const unsigned int* materials,
    unsigned int* status,unsigned int material_count,unsigned int status_index) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=material_count||(materials[i*12+3]&2048)==0)return;
    unsigned int data=materials[i*12];
    if((texels[data+4u]&2147483648u)!=0u) {
        // Raw light metadata precedes the ordinary light records. Resolve it
        // once per material, before vertex/fragment lighting consumes the atlas.
        unsigned int flags=texels[data+352u];
        if((flags&1u)!=0u) {
            float position[4];for(unsigned int k=0;k<4;k++)position[k]=__uint_as_float(texels[data+24u+k]);
            for(unsigned int row=0;row<4;row++) {
                float value=0.0f;
                for(unsigned int col=0;col<4;col++)value+=__uint_as_float(texels[data+354u+col*4u+row])*position[col];
                texels[data+24u+row]=__float_as_uint(value);
            }
        }
        if((flags&2u)!=0u)for(unsigned int light=0;light<texels[data+6u];light++) {
            unsigned int record=data+texels[data+7u]+light*16u,fade=data+388u+light*5u;
            float position[3];for(unsigned int k=0;k<3;k++)position[k]=__uint_as_float(texels[record+k]);
            for(unsigned int row=0;row<3;row++) {
                float value=__uint_as_float(texels[data+382u+row]);
                for(unsigned int col=0;col<3;col++)value+=__uint_as_float(texels[data+370u+col*4u+row])*position[col];
                texels[record+row]=__float_as_uint(value);
            }
            float amount=1.0f,end=__uint_as_float(texels[fade+4u]);
            if(end!=0.0f) {
                float distance=0.0f;
                for(unsigned int k=0;k<3;k++){float value=__uint_as_float(texels[fade+k]);distance+=value*value;}
                float start=__uint_as_float(texels[fade+3u]);
                amount=1.0f-fminf(1.0f,fmaxf(0.0f,(sqrtf(distance)-start)/(end-start)));
            }
            for(unsigned int k=0;k<3;k++) {
                texels[record+8u+k]=__float_as_uint(__uint_as_float(texels[record+8u+k])*amount);
                texels[record+12u+k]=__float_as_uint(__uint_as_float(texels[record+12u+k])*amount);
            }
            texels[record+15u]=__float_as_uint(__uint_as_float(texels[record+15u])*__uint_as_float(texels[data+353u]));
        }
        texels[data+4u]&=~2147483648u;
    }
    for(unsigned int kind=0;kind<2;kind++) {
    if(kind==0&&(texels[data+4]&32768)==0)continue;
    if(kind==1&&(texels[data+4]&2097152)==0)continue;
    unsigned int matrix=kind==0?data+52:data+texels[data+321]+40;
    float augmented[32];
    for(unsigned int row=0;row<4;row++)for(unsigned int col=0;col<4;col++) {
        augmented[row*8+col]=__uint_as_float(texels[matrix+col*4+row]);
        augmented[row*8+4+col]=row==col?1.0f:0.0f;
    }
    for(unsigned int col=0;col<4;col++) {
        unsigned int pivot=col;float largest=fabsf(augmented[col*8+col]);
        for(unsigned int row=col+1;row<4;row++)if(fabsf(augmented[row*8+col])>largest){pivot=row;largest=fabsf(augmented[row*8+col]);}
        if(largest<0.000000000001f){atomicExch(&status[status_index],1);return;}
        if(pivot!=col)for(unsigned int k=0;k<8;k++){float temp=augmented[col*8+k];augmented[col*8+k]=augmented[pivot*8+k];augmented[pivot*8+k]=temp;}
        float divisor=augmented[col*8+col];
        for(unsigned int k=0;k<8;k++)augmented[col*8+k]/=divisor;
        for(unsigned int row=0;row<4;row++)if(row!=col) {
            float factor=augmented[row*8+col];
            for(unsigned int k=0;k<8;k++)augmented[row*8+k]-=factor*augmented[col*8+k];
        }
    }
    for(unsigned int row=0;row<4;row++)for(unsigned int col=0;col<4;col++)texels[matrix+col*4+row]=__float_as_uint(augmented[row*8+4+col]);
    if(kind==0)texels[data+4]&=~32768u;
    }
}
