// SPDX-License-Identifier: GPL-3.0-or-later
// Resolve OSG's implicit inverse-view uniform in GPU-owned material storage.
// status is the extra word after the tile counts, checked before rasterization.
__global__ void resolve_camera(unsigned int* texels,const unsigned int* materials,
    unsigned int* status,unsigned int material_count,unsigned int status_index) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=material_count||(materials[i*12+3]&2048)==0)return;
    unsigned int data=materials[i*12];
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
