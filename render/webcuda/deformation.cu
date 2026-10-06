// SPDX-License-Identifier: GPL-3.0-or-later
// One thread owns each morphed vertex, preserving authored target order.
__global__ void morph_vertices(float* vertices,const unsigned int* ranges,const float* offsets,unsigned int range_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=range_count)return;
    unsigned int vertex=ranges[i*3]*10,first=ranges[i*3+1],count=ranges[i*3+2];
    for(unsigned int k=0;k<3;k++) {
        float value=vertices[vertex+k];
        for(unsigned int j=0;j<count;j++)value+=offsets[(first+j)*4+k]*offsets[(first+j)*4+3];
        vertices[vertex+k]=value;
    }
}
__global__ void skin_vertices(float* vertices,float* attributes,const unsigned int* ranges,
    const unsigned int* weights,const float* bones,const float* transforms,unsigned int range_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=range_count)return;
    unsigned int vertex=ranges[i*4],first=ranges[i*4+1],count=ranges[i*4+2],transform=ranges[i*4+3]*32;
    float matrix[16];for(unsigned int k=0;k<16;k++)matrix[k]=k==15?1.0f:0.0f;
    for(unsigned int influence=0;influence<count;influence++) {
        unsigned int bone=weights[(first+influence)*2]*32;
        float weight=__uint_as_float(weights[(first+influence)*2+1]);
        for(unsigned int row=0;row<4;row++)for(unsigned int col=0;col<3;col++) {
            float value=0.0f;
            for(unsigned int k=0;k<4;k++)value+=bones[bone+row*4+k]*bones[bone+16+k*4+col];
            matrix[row*4+col]+=value*weight;
        }
    }
    for(unsigned int stage=0;stage<2;stage++) {
        float result[16];
        for(unsigned int row=0;row<4;row++)for(unsigned int col=0;col<4;col++) {
            float value=0.0f;for(unsigned int k=0;k<4;k++)value+=matrix[row*4+k]*transforms[transform+stage*16+k*4+col];
            result[row*4+col]=value;
        }
        for(unsigned int k=0;k<16;k++)matrix[k]=result[k];
    }
    float position[3],normal[3],tangent[3];
    float w=matrix[15];for(unsigned int k=0;k<3;k++)w+=vertices[vertex*10+k]*matrix[k*4+3];
    for(unsigned int col=0;col<3;col++) {
        position[col]=matrix[12+col];normal[col]=0.0f;tangent[col]=0.0f;
        for(unsigned int row=0;row<3;row++) {
            position[col]+=vertices[vertex*10+row]*matrix[row*4+col];
            normal[col]+=attributes[vertex*34+3+row]*matrix[row*4+col];
            tangent[col]+=attributes[vertex*34+6+row]*matrix[row*4+col];
        }
    }
    for(unsigned int k=0;k<3;k++) {
        vertices[vertex*10+k]=position[k]/w;
        attributes[vertex*34+3+k]=normal[k];attributes[vertex*34+6+k]=tangent[k];
    }
}
