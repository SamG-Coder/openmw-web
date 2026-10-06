// SPDX-License-Identifier: GPL-3.0-or-later
// Input-only attribute modes 2/3/4 denote billboard-local, billboard-world,
// and fixed particles. Expand in model space before the common transform path.
__global__ void expand_particles(float* source,float* attributes,const float* matrices,
    const unsigned int* matrix_ids,unsigned int vertex_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=vertex_count)return;
    unsigned int d=i*34,m=matrix_ids[i]*32;
    float mode=attributes[d];
    if(mode<2.0f||mode>8.0f||mode==7.0f)return;
    float normal[3];for(unsigned int k=0;k<3;k++)normal[k]=attributes[d+21+k];
    if(mode>=5.0f) {
        source[i*10+7]*=attributes[d+9];
        if(mode==6.0f) {
            float length=0.0f;
            for(unsigned int k=0;k<3;k++)length+=attributes[d+10+k]*attributes[d+10+k];
            length=sqrtf(length);
            float scale=length>0.0f?attributes[d+13]*sqrtf(attributes[d+14])/length:0.0f;
            for(unsigned int k=0;k<3;k++)attributes[d+10+k]*=scale;
        }
        for(unsigned int k=3;k<9;k++)attributes[d+k]=k<6?normal[k-3]:0.0f;
        attributes[d+9]=0.0f;
        return;
    }
    float axes[6];for(unsigned int k=0;k<6;k++)axes[k]=attributes[d+3+k];
    float angle[3];for(unsigned int k=0;k<3;k++)angle[k]=attributes[d+10+k];
    float size=attributes[d+13]*sqrtf(attributes[d+14]);
    for(unsigned int axis=0;axis<2;axis++) {
        float x=axes[axis*3],y=axes[axis*3+1],z=axes[axis*3+2];
        float scale=1.0f;
        if(mode<4.0f) {
            float length2=0.0f;
            for(unsigned int row=0;row<3;row++) {
                float value=matrices[m+row*4]*x+matrices[m+row*4+1]*y+matrices[m+row*4+2]*z;
                length2+=value*value;
            }
            scale=mode==2.0f?1.0f/sqrtf(fmaxf(length2,0.000000000001f)):1.0f/fmaxf(length2,0.000000000001f);
        }
        x*=scale;y*=scale;z*=scale;
        float cx=cosf(angle[0]),sx=sinf(angle[0]),cy=cosf(angle[1]),sy=sinf(angle[1]),cz=cosf(angle[2]),sz=sinf(angle[2]);
        float ry=y*cx-z*sx,rz=y*sx+z*cx;y=ry;z=rz;
        float rx=x*cy+z*sy;rz=-x*sy+z*cy;x=rx;z=rz;
        rx=x*cz-y*sz;ry=x*sz+y*cz;x=rx;y=ry;
        if(mode<4.0f)for(unsigned int row=0;row<3;row++)
            axes[axis*3+row]=matrices[m+row*4]*x+matrices[m+row*4+1]*y+matrices[m+row*4+2]*z;
        else {axes[axis*3]=x;axes[axis*3+1]=y;axes[axis*3+2]=z;}
    }
    for(unsigned int k=0;k<3;k++)source[i*10+k]+=size*(axes[k]*attributes[d+1]+axes[3+k]*attributes[d+2]);
    source[i*10+7]*=attributes[d+9];
    // Carry the source drawable normal through billboard expansion.
    for(unsigned int k=0;k<34;k++)if(k!=16&&k!=17)attributes[d+k]=0.0f;
    for(unsigned int unit=0;unit<4;unit++)attributes[d+27u+unit*2u]=1.0f;
    for(unsigned int k=0;k<3;k++)attributes[d+3+k]=normal[k];
}

// Project fixed-width particles after the ordinary vertex/attribute transforms.
// The CPU uploads only primitive parameters; clipping and expansion stay here.
__global__ void project_particles(const float* source,const float* attributes,const float* matrices,
    const unsigned int* matrix_ids,float* vertices,float* varyings,float* fixed_lighting,const float* fixed_endpoints,
    unsigned int vertex_count,unsigned int width,unsigned int height,unsigned int fixed_enabled,unsigned int track_world_particles,unsigned int world_particle_offset,unsigned int source_point_fade_offset,unsigned int sample_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=vertex_count)return;
    unsigned int d=i*34,p=i*10,m=matrix_ids[i]*32,lighting=world_particle_offset+i*24;
    if(track_world_particles!=0)varyings[lighting]=0.0f;
    unsigned int point_flags=(unsigned int)attributes[d+25];
    unsigned int depth_clamp=point_flags&1u;
    unsigned int zero_to_one=point_flags&16u;
    float mode=attributes[d];if(mode!=5.0f&&mode!=6.0f&&mode!=7.0f&&mode!=8.0f)return;
    float side=attributes[d+2],endpoint=(attributes[d+1]+1.0f)*0.5f;
    float size=attributes[d+15];
    if(mode==5.0f||mode==8.0f) {
        if(mode==8.0f&&attributes[d+24]>0.0f
            &&(-varyings[d+2]<=0.0f||-varyings[d+2]>=attributes[d+24])) {
            for(unsigned int k=0;k<4;k++)vertices[p+k]=0.0f;return;
        }
        float w=vertices[p+3];
        if(w<=0.0f||fabsf(vertices[p])>w||fabsf(vertices[p+1])>w||(depth_clamp==0u&&(vertices[p+2]>w||vertices[p+2]<(zero_to_one!=0u?0.0f:-w)))) {
            for(unsigned int k=0;k<4;k++)vertices[p+k]=0.0f;return;
        }
        if(track_world_particles!=0) {
            varyings[lighting]=1.0f;varyings[lighting+1]=0.0f;
            for(unsigned int axis=0;axis<3;axis++) {
                varyings[lighting+2+axis]=varyings[d+axis];varyings[lighting+5+axis]=varyings[d+axis];
                float clip=vertices[p+(axis==2?3:axis)];
                varyings[lighting+8+axis]=clip;varyings[lighting+11+axis]=clip;
            }
            for(unsigned int channel=0;channel<4;channel++) {
                varyings[lighting+14+channel]=source[p+4+channel];varyings[lighting+18+channel]=source[p+4+channel];
            }
        }
        float distance=sqrtf(varyings[d]*varyings[d]+varyings[d+1]*varyings[d+1]+varyings[d+2]*varyings[d+2]);
        float attenuation=attributes[d+10]+attributes[d+11]*distance+attributes[d+12]*distance*distance;
        size/=sqrtf(fmaxf(0.000000000001f,attenuation));
        size=fminf(attributes[d+19],fmaxf(attributes[d+18],size));
        float fade=attributes[d+20];
        unsigned int multisample=sample_count>1u&&(point_flags&2u)!=0u?1u:0u;
        if(multisample!=0u&&size<fade&&fade>0.0f) {
            float ratio=size/fade;varyings[source_point_fade_offset+i*12u]=ratio*ratio;size=fade;
        }
        unsigned int pointStyle=point_flags&12u;
        float smoothRadius=multisample==0u&&pointStyle==4u?size*0.5f:0.0f;
        if(multisample==0u&&pointStyle==0u)size=fmaxf(1.0f,floorf(size+0.5f));
        float odd=size-2.0f*floorf(size*0.5f);
        float x=(vertices[p]/w*0.5f+0.5f)*(float)width;
        float y=(vertices[p+1]/w*0.5f+0.5f)*(float)height;
        if(multisample==0u&&pointStyle==0u) {
            x=odd>0.0f?floorf(x)+0.5f:floorf(x+0.5f);
            y=odd>0.0f?floorf(y)+0.5f:floorf(y+0.5f);
        }
        float halfExtent=size*0.5f+(smoothRadius>0.0f?0.5f:0.0f);
        varyings[source_point_fade_offset+i*12u+1u]=attributes[d+1]*halfExtent;
        varyings[source_point_fade_offset+i*12u+2u]=side*halfExtent;
        varyings[source_point_fade_offset+i*12u+3u]=(point_flags&8u)!=0u?-size*0.5f:smoothRadius;
        vertices[p]=((x+attributes[d+1]*halfExtent)/(float)width*2.0f-1.0f)*w;
        vertices[p+1]=((y+side*halfExtent)/(float)height*2.0f-1.0f)*w;
        return;
    }
    float view0[4],view1[4],clip0[4],clip1[4];
    float motion=0.0f;for(unsigned int k=0;k<3;k++)motion+=attributes[d+10+k]*attributes[d+10+k];
    for(unsigned int row=0;row<4;row++) {
        view0[row]=0.0f;view1[row]=0.0f;
        for(unsigned int col=0;col<4;col++) {
            float a=source[p+col],b=a+(col<3?attributes[d+10+col]:0.0f);
            view0[row]+=matrices[m+col*4+row]*a;view1[row]+=matrices[m+col*4+row]*b;
        }
    }
    for(unsigned int row=0;row<4;row++) {
        clip0[row]=0.0f;clip1[row]=0.0f;
        for(unsigned int col=0;col<4;col++) {
            clip0[row]+=matrices[m+16+col*4+row]*view0[col];
            clip1[row]+=matrices[m+16+col*4+row]*view1[col];
        }
    }
    float begin=0.0f,end=1.0f;
    for(unsigned int plane=0;plane<6;plane++) {
        if(plane>=4u&&depth_clamp!=0u)continue;
        unsigned int axis=plane/2;float sign=(plane%2)==0?1.0f:-1.0f;
        float a=clip0[3]+sign*clip0[axis],b=clip1[3]+sign*clip1[axis];
        if(plane==4u&&zero_to_one!=0u){a=clip0[2];b=clip1[2];}
        if(a<0.0f&&b<0.0f)end=-1.0f;
        else if(a<0.0f)begin=fmaxf(begin,a/(a-b));
        else if(b<0.0f)end=fminf(end,a/(a-b));
    }
    float c0[4],c1[4];
    for(unsigned int k=0;k<4;k++){c0[k]=clip0[k]+begin*(clip1[k]-clip0[k]);c1[k]=clip0[k]+end*(clip1[k]-clip0[k]);}
    if(end<begin||motion==0.0f||c0[3]<=0.0f||c1[3]<=0.0f) {
        for(unsigned int k=0;k<4;k++)vertices[p+k]=0.0f;return;
    }
    float dx=(c1[0]/c1[3]-c0[0]/c0[3])*(float)width;
    float dy=(c1[1]/c1[3]-c0[1]/c0[3])*(float)height;
    float length=sqrtf(dx*dx+dy*dy);
    if(length<=0.000001f){for(unsigned int k=0;k<4;k++)vertices[p+k]=0.0f;return;}
    unsigned int lineMetadata=source_point_fade_offset+i*12u;
    varyings[lineMetadata+1u]=endpoint;varyings[lineMetadata+2u]=size;
    for(unsigned int k=0u;k<4u;k++) {
        varyings[lineMetadata+4u+k]=c0[k];
        varyings[lineMetadata+8u+k]=c1[k];
    }
    float t=begin+endpoint*(end-begin);
    if(track_world_particles!=0) {
        varyings[lighting]=2.0f;varyings[lighting+1]=t;
        for(unsigned int axis=0;axis<3;axis++) {
            varyings[lighting+2+axis]=view0[axis];varyings[lighting+5+axis]=view1[axis];
            varyings[lighting+8+axis]=clip0[axis==2?3:axis];varyings[lighting+11+axis]=clip1[axis==2?3:axis];
        }
        for(unsigned int channel=0;channel<4;channel++) {
            varyings[lighting+14+channel]=source[p+4+channel];
            varyings[lighting+18+channel]=mode==7.0f?attributes[d+18+channel]:source[p+4+channel];
        }
    }
    if(fixed_enabled!=0) {
        float lightingT=mode==7.0f&&attributes[d+24]!=0.0f?1.0f:t;
        for(unsigned int channel=0;channel<16;channel++)fixed_lighting[i*16+channel]
            =fixed_endpoints[i*32+channel]*(1.0f-lightingT)+fixed_endpoints[i*32+16+channel]*lightingT;
    }
    for(unsigned int k=0;k<4;k++)vertices[p+k]=clip0[k]+t*(clip1[k]-clip0[k]);
    float support=fmaxf(size,fmaxf(1.0f,floorf(size+0.5f)))+2.0f;
    float endSide=endpoint*2.0f-1.0f;
    vertices[p]+=(-dy*side+dx*endSide)/length*support/(float)width*vertices[p+3];
    vertices[p+1]+=(dx*side+dy*endSide)/length*support/(float)height*vertices[p+3];
    for(unsigned int k=0;k<3;k++)varyings[d+k]=view0[k]+t*(view1[k]-view0[k]);
    // Shader euclideanDepth is evaluated at each original endpoint, then
    // interpolated by clipping. Length of the clipped position is different.
    float depth0=0.0f,depth1=0.0f,positionLength=0.0f;
    for(unsigned int k=0;k<3;k++) {
        depth0+=view0[k]*view0[k];depth1+=view1[k]*view1[k];
        positionLength+=varyings[d+k]*varyings[d+k];
    }
    depth0=sqrtf(depth0);depth1=sqrtf(depth1);
    varyings[d+9]=depth0+t*(depth1-depth0);
    // Sphere mapping instead requires the actual clipped-position direction.
    float eyeLength=fmaxf(sqrtf(positionLength),0.000000000001f),dot=0.0f;
    float eye[3],normal[3],reflected[3];
    for(unsigned int k=0;k<3;k++) {
        eye[k]=varyings[d+k]/eyeLength;normal[k]=varyings[d+23+k];dot+=eye[k]*normal[k];
    }
    for(unsigned int k=0;k<3;k++)reflected[k]=eye[k]-2.0f*dot*normal[k];
    float denominator=2.0f*sqrtf(fmaxf(0.000000000001f,reflected[0]*reflected[0]+reflected[1]*reflected[1]
        +(reflected[2]+1.0f)*(reflected[2]+1.0f)));
    varyings[d+21]=reflected[0]/denominator+0.5f;varyings[d+22]=reflected[1]/denominator+0.5f;
    if(mode==7.0f) {
        for(unsigned int k=0;k<4;k++)vertices[p+4+k]=source[p+4+k]+t*(attributes[d+18+k]-source[p+4+k]);
        float u=source[p+8]+t*(attributes[d+22]-source[p+8]);
        vertices[p+8]=u;vertices[p+9]=0.5f;varyings[d+16]=u;varyings[d+17]=0.5f;
    } else {vertices[p+8]=t;vertices[p+9]=t;varyings[d+16]=t;varyings[d+17]=t;}
}
