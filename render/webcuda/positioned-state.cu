// SPDX-License-Identifier: GPL-3.0-or-later
// OSG captures row-vector application * inherited-stage matrices. Their raw
// storage is the column-vector transpose, so compose post * application here.
// Each invocation owns one matrix; finish all reads before writing it in place.
__device__ void compose_positioned_matrix(unsigned int* descriptors,unsigned int matrix,
    const unsigned int* positioned,unsigned int post) {
    float result[16];
    for(unsigned int col=0;col<4;col++)for(unsigned int row=0;row<4;row++) {
        float value=0.0f;
        for(unsigned int k=0;k<4;k++)value+=__uint_as_float(positioned[post+k*4+row])
            *__uint_as_float(descriptors[matrix+col*4+k]);
        result[col*4+row]=value;
    }
    for(unsigned int k=0;k<16;k++)descriptors[matrix+k]=__float_as_uint(result[k]);
}
__global__ void prepare_fixed_matrices(unsigned int* descriptors,const unsigned int* positioned,unsigned int draw_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=draw_count*8u)return;
    unsigned int draw=i/8u,light=i%8u,d=draw*368u,table=descriptors[d+3u];
    if(table==0u||(descriptors[d]&(1u<<light))==0u)return;
    unsigned int post=positioned[table-1u+light];
    if(post!=0u)compose_positioned_matrix(descriptors,d+48u+light*40u+24u,positioned,post-1u);
}
__global__ void prepare_texgen_matrices(unsigned int* descriptors,const unsigned int* positioned,unsigned int draw_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=draw_count*4u)return;
    unsigned int d=i*36u,post=descriptors[d+3u];
    if(post==0u||descriptors[d]==0u||descriptors[d+1u]!=5u)return;
    compose_positioned_matrix(descriptors,d+20u,positioned,post-1u);
}
