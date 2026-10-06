// Build mutable shader inputs from captured source streams. A stride of zero
// means one constant value for the draw; no vertex transforms run on the host.
__global__ void unpack_vertex_inputs(const float* inputs,const unsigned int* layouts,const unsigned int* matrix_ids,
                                    float* vertices,float* attributes,float* secondary_colors,unsigned int vertex_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=vertex_count)return;
    unsigned int d=matrix_ids[i]*32u,j=i-layouts[d],v=i*10u,a=i*34u;
    if(layouts[d+3u]==0u) {
        for(unsigned int k=0;k<10;k++)vertices[v+k]=inputs[layouts[d+6u]+j*10u+k];
        for(unsigned int k=0;k<34;k++)attributes[a+k]=inputs[layouts[d+7u]+j*34u+k];
        for(unsigned int k=0;k<3;k++)secondary_colors[i*3u+k]=inputs[layouts[d+8u]+j*3u+k];
        return;
    }
    for(unsigned int k=0;k<34;k++)attributes[a+k]=0.0f;
    if(j>=layouts[d+2u]) {
        // Space reserved for CUDA-generated screen primitives has the same
        // initial state as a dense packet, including its current color input.
        for(unsigned int k=0;k<10;k++)vertices[v+k]=0.0f;
        for(unsigned int k=0;k<3;k++)secondary_colors[i*3u+k]=inputs[layouts[d+5u]+k];
        return;
    }
    unsigned int position=layouts[d+8u]+j*layouts[d+9u],color=layouts[d+10u]+j*layouts[d+11u];
    unsigned int secondary=layouts[d+12u]+j*layouts[d+13u],normal=layouts[d+14u]+j*layouts[d+15u];
    unsigned int tangent=layouts[d+16u]+j*layouts[d+17u],fog=layouts[d+18u]+j*layouts[d+19u];
    for(unsigned int k=0;k<4;k++){vertices[v+k]=inputs[position+k];vertices[v+4u+k]=inputs[color+k];attributes[a+6u+k]=inputs[tangent+k];}
    for(unsigned int k=0;k<3;k++){secondary_colors[i*3u+k]=inputs[secondary+k];attributes[a+3u+k]=inputs[normal+k];}
    attributes[a]=layouts[d+4u]==2u?-1.0f:(layouts[d+4u]==1u?1.0f:0.0f);
    if(layouts[d+4u]==2u)attributes[a+2u]=inputs[fog];
    for(unsigned int unit=0;unit<4;unit++) {
        unsigned int coordinate=layouts[d+20u+unit*2u]+j*layouts[d+21u+unit*2u];
        unsigned int uv=unit==0u?16u:8u+unit*2u;
        attributes[a+uv]=inputs[coordinate];attributes[a+uv+1u]=inputs[coordinate+1u];
        attributes[a+26u+unit*2u]=inputs[coordinate+2u];attributes[a+27u+unit*2u]=inputs[coordinate+3u];
        if(unit==0u){vertices[v+8u]=inputs[coordinate];vertices[v+9u]=inputs[coordinate+1u];}
    }
}
