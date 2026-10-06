// Authored WebCuda implementation of debug and outline shader arithmetic.
__global__ void shade_debug_vertices(float* vertices,const float* attributes,const unsigned int* matrix_ids,
                                    const float* params,unsigned int vertex_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=vertex_count)return;
    unsigned int p=matrix_ids[i]*16u,v=i*10u,kind=(unsigned int)params[p];
    if(kind==0u)return;
    if(kind==2u||kind==3u) {
        for(unsigned int k=0;k<3;k++)vertices[v+k]=vertices[v+k]*params[p+12u+k]+params[p+8u+k];
        vertices[v+3u]=1.0f;
        float lighting=0.5f;
        for(unsigned int k=0;k<3;k++) {
            float normal=kind==3u?1.0f:attributes[i*34u+3u+k];
            float light=k==0u?1.0f:(k==1u?0.5f:2.0f);
            lighting+=normal*light*(0.5f/sqrtf(5.25f));
        }
        for(unsigned int k=0;k<3;k++)vertices[v+4u+k]=(kind==3u?attributes[i*34u+3u+k]:params[p+4u+k])*lighting;
        vertices[v+7u]=1.0f;
    } else if(kind==4u||params[p+1u]==0.0f) {
        for(unsigned int k=0;k<4;k++)vertices[v+4u+k]=params[p+4u+k];
    }
}
