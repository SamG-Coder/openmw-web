// Build mutable shader inputs from captured source streams. A stride of zero
// means one constant value for the draw; no vertex transforms run on the host.
__device__ float vertex_unorm8(float value) {
    unsigned int byte=(unsigned int)value;
    // Replicate the byte into Q0.32. For 1..254 the truncated value lies at
    // or above a float midpoint; +1 resolves the midpoint upward. Exact
    // power-of-two scaling avoids the native fast-math reciprocal error.
    unsigned int repeated=(byte<<24u)|(byte<<16u)|(byte<<8u)|byte;
    if(byte>0u&&byte<255u)repeated+=1u;
    return (float)repeated*0.00000000023283064365386962890625f;
}
__global__ void unpack_vertex_inputs(const float* inputs,const unsigned int* layouts,const unsigned int* matrix_ids,
                                    float* vertices,float* attributes,float* secondary_colors,unsigned int vertex_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=vertex_count)return;
    unsigned int d=matrix_ids[i]*32u,j=i-layouts[d],v=i*10u,a=i*34u;
    if(layouts[d+3u]==0u) {
        for(unsigned int k=0;k<10;k++)vertices[v+k]=inputs[layouts[d+6u]+j*10u+k];
        for(unsigned int k=0;k<34;k++)attributes[a+k]=inputs[layouts[d+7u]+j*34u+k];
        for(unsigned int k=0;k<3;k++) {
            float value=inputs[layouts[d+8u]+j*3u+k];
            secondary_colors[i*3u+k]=layouts[d+29u]!=0u?vertex_unorm8(value):value;
        }
        return;
    }
    for(unsigned int k=0;k<34;k++)attributes[a+k]=0.0f;
    if(layouts[d+3u]==3u) {
        // MyGUI supplies XYZ, RGBA bytes and UV. Keep byte normalization and
        // all expanded shader defaults on the GPU, in the original RGBA order.
        unsigned int p=layouts[d+6u]+j*9u,c=layouts[d+7u];
        for(unsigned int k=0;k<3;k++) {
            vertices[v+k]=inputs[p+k];secondary_colors[i*3u+k]=inputs[c+k];
        }
        vertices[v+3u]=1.0f;
        for(unsigned int k=0;k<4;k++)vertices[v+4u+k]=vertex_unorm8(inputs[p+3u+k]);
        for(unsigned int k=0;k<2;k++){vertices[v+8u+k]=inputs[p+7u+k];attributes[a+16u+k]=inputs[p+7u+k];}
        for(unsigned int unit=0;unit<4;unit++)attributes[a+27u+unit*2u]=1.0f;
        return;
    }
    if(layouts[d+3u]==2u) {
        // Raw particle state is captured once; authored CUDA constructs each
        // corner, texture coordinate and shared attribute before deformation.
        unsigned int p=layouts[d+6u]+(j/4u)*17u,c=layouts[d+7u],corner=j%4u;
        float u=corner==1u||corner==2u?1.0f:0.0f,t=corner>=2u?1.0f:0.0f,mode=inputs[p+16u];
        for(unsigned int k=0;k<3;k++)vertices[v+k]=inputs[p+k];vertices[v+3u]=1.0f;
        for(unsigned int k=0;k<4;k++)vertices[v+4u+k]=inputs[p+3u+k];
        float s=inputs[p+7u]+u*inputs[p+9u],r=inputs[p+8u]+t*inputs[p+10u];
        if(mode==5.0f){s=0.5f;r=0.5f;}
        if(mode==6.0f){s=u;r=u;}
        if(mode==8.0f){s=u;r=1.0f-t;attributes[a+24u]=inputs[c+15u];}
        vertices[v+8u]=s;vertices[v+9u]=r;
        attributes[a]=mode;attributes[a+1u]=u*2.0f-1.0f;attributes[a+2u]=t*2.0f-1.0f;
        for(unsigned int k=0;k<3;k++) {
            attributes[a+3u+k]=inputs[c+k];attributes[a+6u+k]=inputs[c+3u+k];
            attributes[a+10u+k]=inputs[p+13u+k];attributes[a+21u+k]=inputs[c+17u+k];
            float value=inputs[c+20u+k];
            secondary_colors[i*3u+k]=layouts[d+29u]!=0u?vertex_unorm8(value):value;
        }
        attributes[a+9u]=inputs[p+11u];attributes[a+13u]=inputs[p+12u];attributes[a+14u]=inputs[c+6u];
        if(mode==5.0f||mode==6.0f||mode==8.0f) {
            attributes[a+15u]=inputs[c+(mode==6.0f?8u:7u)];
            if(mode!=6.0f)for(unsigned int k=0;k<3;k++)attributes[a+10u+k]=inputs[c+9u+k];
            for(unsigned int k=0;k<3;k++)attributes[a+18u+k]=inputs[c+12u+k];
        }
        attributes[a+16u]=s;attributes[a+17u]=r;attributes[a+25u]=inputs[c+16u];
        for(unsigned int unit=0;unit<4;unit++)attributes[a+27u+unit*2u]=1.0f;
        return;
    }
    if(j>=layouts[d+2u]) {
        // Space reserved for CUDA-generated screen primitives has the same
        // initial state as a dense packet, including its current color input.
        for(unsigned int k=0;k<10;k++)vertices[v+k]=0.0f;
        for(unsigned int k=0;k<3;k++) {
            float value=inputs[layouts[d+5u]+k];
            secondary_colors[i*3u+k]=layouts[d+30u]!=0u?vertex_unorm8(value):value;
        }
        return;
    }
    unsigned int position=layouts[d+8u]+j*layouts[d+9u],color=layouts[d+10u]+j*layouts[d+11u];
    unsigned int secondary=layouts[d+12u]+j*layouts[d+13u],normal=layouts[d+14u]+j*layouts[d+15u];
    unsigned int tangent=layouts[d+16u]+j*layouts[d+17u],fog=layouts[d+18u]+j*layouts[d+19u];
    for(unsigned int k=0;k<4;k++) {
        vertices[v+k]=inputs[position+k];attributes[a+6u+k]=inputs[tangent+k];
        float value=inputs[color+k];vertices[v+4u+k]=k<layouts[d+28u]?vertex_unorm8(value):value;
    }
    for(unsigned int k=0;k<3;k++) {
        float value=inputs[secondary+k];secondary_colors[i*3u+k]=layouts[d+29u]!=0u?vertex_unorm8(value):value;
        attributes[a+3u+k]=inputs[normal+k];
    }
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
