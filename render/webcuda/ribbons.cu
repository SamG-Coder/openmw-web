// SPDX-License-Identifier: GPL-3.0-or-later
// ConnectedParticleSystem preparation. Input follows linked-list order:
// position xyz, size, color rgba, alpha, S texture coordinate (10 floats).
// Output is compact pairs of packed position4/color4/UV2 vertices. Thin-line
// pairs coincide; the downstream line raster path expands them in screen space.
// summary: selected particle count, thin-line flag, singular-matrix status.
__global__ void prepare_ribbon(const float* particles,const float* matrices,
    float* vertices,unsigned int* summary,unsigned int particle_count,
    unsigned int max_skip,unsigned int width,unsigned int height) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i!=0u)return;
    summary[0]=0u;summary[1]=0u;summary[2]=0u;
    if(particle_count==0u)return;
    // OSG matrices are row-major; their uploaded representation is consumed
    // as column-major by the common transform kernels.
    float p00=matrices[16]*((float)width*0.5f);
    float p20=(matrices[24]+matrices[27])*((float)width*0.5f);
    float p11=matrices[21]*((float)height*0.5f);
    float p21=(matrices[25]+matrices[27])*((float)height*0.5f);
    float magnitude=0.0f;
    for(unsigned int k=0;k<3;k++) {
        float a=matrices[k*4]*p00+matrices[k*4+2]*p20;
        float b=matrices[k*4+1]*p11+matrices[k*4+2]*p21;
        magnitude+=a*a+b*b;
    }
    if(magnitude<=0.0f){summary[2]=1u;return;}
    float ratio=0.7071067811f/sqrtf(magnitude);
    float inverse_pixel=matrices[14]*matrices[27]+matrices[15]*matrices[31];
    for(unsigned int k=0;k<3;k++)inverse_pixel+=particles[k]*matrices[k*4+2]*matrices[27];
    inverse_pixel*=ratio;
    float error2=inverse_pixel*inverse_pixel;
    unsigned int thin=fabsf(inverse_pixel)>particles[3]?1u:0u;
    summary[1]=thin;
    float eye[3];for(unsigned int k=0;k<3;k++)eye[k]=0.0f;
    if(thin==0u) {
        float augmented[32];
        for(unsigned int row=0;row<4;row++)for(unsigned int col=0;col<4;col++) {
            augmented[row*8+col]=matrices[col*4+row];
            augmented[row*8+4+col]=row==col?1.0f:0.0f;
        }
        for(unsigned int col=0;col<4;col++) {
            unsigned int pivot=col;float largest=fabsf(augmented[col*8+col]);
            for(unsigned int row=col+1;row<4;row++)if(fabsf(augmented[row*8+col])>largest){pivot=row;largest=fabsf(augmented[row*8+col]);}
            if(largest<0.000000000001f){summary[2]=1u;return;}
            if(pivot!=col)for(unsigned int k=0;k<8;k++){float temp=augmented[col*8+k];augmented[col*8+k]=augmented[pivot*8+k];augmented[pivot*8+k]=temp;}
            float divisor=augmented[col*8+col];for(unsigned int k=0;k<8;k++)augmented[col*8+k]/=divisor;
            for(unsigned int row=0;row<4;row++)if(row!=col) {
                float factor=augmented[row*8+col];
                for(unsigned int k=0;k<8;k++)augmented[row*8+k]-=factor*augmented[col*8+k];
            }
        }
        float w=augmented[31];
        if(fabsf(w)<0.000000000001f){summary[2]=1u;return;}
        for(unsigned int k=0;k<3;k++)eye[k]=augmented[k*8+7]/w;
    }
    float delta[3];delta[0]=0.0f;delta[1]=0.0f;delta[2]=1.0f;
    unsigned int current=0u,selected=0u;
    while(current<particle_count) {
        unsigned int next=current+1u;
        if(next<particle_count) {
            float direction[3],length2=0.0f;
            for(unsigned int k=0;k<3;k++){delta[k]=particles[next*10u+k]-particles[current*10u+k];direction[k]=delta[k];length2+=delta[k]*delta[k];}
            if(length2>0.0f)for(unsigned int k=0;k<3;k++)direction[k]/=sqrtf(length2);
            float distance2=0.0f;
            for(unsigned int skipped=0;skipped<max_skip&&distance2<error2&&next+1u<particle_count;skipped++) {
                next++;
                for(unsigned int k=0;k<3;k++)delta[k]=particles[next*10u+k]-particles[current*10u+k];
                float x=delta[1]*direction[2]-delta[2]*direction[1];
                float y=delta[2]*direction[0]-delta[0]*direction[2];
                float z=delta[0]*direction[1]-delta[1]*direction[0];distance2=x*x+y*y+z*z;
            }
        }
        float offset[3];for(unsigned int k=0;k<3;k++)offset[k]=0.0f;
        if(thin==0u) {
            float eye_direction[3];for(unsigned int k=0;k<3;k++)eye_direction[k]=particles[current*10u+k]-eye[k];
            offset[0]=delta[1]*eye_direction[2]-delta[2]*eye_direction[1];
            offset[1]=delta[2]*eye_direction[0]-delta[0]*eye_direction[2];
            offset[2]=delta[0]*eye_direction[1]-delta[1]*eye_direction[0];
            float length=sqrtf(offset[0]*offset[0]+offset[1]*offset[1]+offset[2]*offset[2]);
            if(length>0.0f)for(unsigned int k=0;k<3;k++)offset[k]*=particles[current*10u+3u]/length;
        }
        for(unsigned int side=0;side<2;side++) {
            unsigned int out=(selected*2u+side)*10u;
            for(unsigned int k=0;k<3;k++)vertices[out+k]=particles[current*10u+k]+offset[k]*(side==0u?-1.0f:1.0f);
            vertices[out+3u]=1.0f;
            for(unsigned int c=0;c<4;c++)vertices[out+4u+c]=particles[current*10u+4u+c];
            vertices[out+7u]*=particles[current*10u+8u];
            vertices[out+8u]=particles[current*10u+9u];vertices[out+9u]=thin!=0u?0.5f:(float)side;
        }
        selected++;current=next;
    }
    summary[0]=selected;
}

__global__ void assemble_ribbon(const float* prepared,const unsigned int* summary,
    float* vertices,float* attributes,unsigned int* triangles,unsigned int* status,unsigned int* flat_colors,
    unsigned int segment_count,unsigned int vertex_base,unsigned int triangle_base,
    unsigned int material,unsigned int line_material,float line_width,
    float normal_x,float normal_y,float normal_z,unsigned int status_index,unsigned int flat_color,unsigned int point_flags) {
    unsigned int segment=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(segment>=segment_count)return;
    if(summary[2]!=0u){atomicExch(&status[status_index],1u);return;}
    unsigned int first=vertex_base+segment*4u,t=(triangle_base+segment*2u)*4u,thin=summary[1];
    triangles[t]=first;triangles[t+1u]=first+1u;triangles[t+2u]=first+2u;triangles[t+3u]=thin!=0u?line_material:material;
    triangles[t+4u]=first;triangles[t+5u]=first+2u;triangles[t+6u]=first+3u;triangles[t+7u]=triangles[t+3u];
    flat_colors[triangle_base+segment*2]=flat_color!=0u?first+2u:0xffffffffu;
    flat_colors[triangle_base+segment*2+1]=flat_colors[triangle_base+segment*2];
    for(unsigned int corner=0;corner<4;corner++) {
        unsigned int p=(first+corner)*10u,a=(first+corner)*34u;
        for(unsigned int k=0;k<10;k++)vertices[p+k]=0.0f;
        for(unsigned int k=0;k<34;k++)attributes[a+k]=0.0f;
        for(unsigned int unit=0;unit<4;unit++)attributes[a+27u+unit*2u]=1.0f;
        if(segment+1u>=summary[0])continue;
        unsigned int point=segment+(corner>=2u?1u:0u),side=(corner==1u||corner==2u)?1u:0u;
        unsigned int src=(point*2u+side)*10u;
        for(unsigned int k=0;k<10;k++)vertices[p+k]=prepared[src+k];
        attributes[a+3u]=normal_x;attributes[a+4u]=normal_y;attributes[a+5u]=normal_z;
        if(thin!=0u) {
            unsigned int start=segment*20u,end=(segment+1u)*20u;
            for(unsigned int k=0;k<10;k++)vertices[p+k]=prepared[start+k];
            attributes[a+24u]=(float)flat_color;attributes[a+25u]=(float)point_flags;
            attributes[a]=7.0f;attributes[a+1u]=corner>=2u?1.0f:-1.0f;attributes[a+2u]=side!=0u?1.0f:-1.0f;
            for(unsigned int k=0;k<3;k++)attributes[a+10u+k]=prepared[end+k]-prepared[start+k];
            for(unsigned int k=0;k<4;k++)attributes[a+18u+k]=prepared[end+4u+k];
            attributes[a+22u]=prepared[end+8u];attributes[a+15u]=line_width;
        }
        // Both vertices of the selected final particle have the same RGBA.
        // Setting both line endpoints also preserves flat color after clipping.
        if(flat_color!=0u)for(unsigned int k=0;k<4;k++)vertices[p+4u+k]=prepared[(segment+1u)*20u+4u+k];
        attributes[a+16u]=vertices[p+8u];attributes[a+17u]=vertices[p+9u];
    }
}
