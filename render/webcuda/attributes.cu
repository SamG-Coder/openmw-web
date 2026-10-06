// SPDX-License-Identifier: GPL-3.0-or-later
// Attribute ABI: 34 floats. Existing view/basis/UV fields occupy0..25;
// UV0..3 homogeneous R/Q pairs occupy26..33 and survive clipping unchanged.
// The normal uses inverse-transpose, including non-uniform model scaling.
__global__ void transform_attributes(const float* source,const float* attributes,
    const float* matrices,const unsigned int* matrix_ids,float* output,unsigned int* lighting_origins,unsigned int vertex_count,unsigned int track_lighting,unsigned int source_point_fade_offset) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=vertex_count)return;
    for(unsigned int k=0;k<12;k++)output[source_point_fade_offset+i*12+k]=k==0?1.0f:0.0f;
    if(track_lighting!=0){lighting_origins[i*3]=i;lighting_origins[i*3+1]=i;lighting_origins[i*3+2]=0;}
    unsigned int m=matrix_ids[i]*32,d=i*34;
    for(unsigned int k=0;k<34;k++)output[d+k]=attributes[d+k];
    if(attributes[d]>=5.0f&&attributes[d]<=8.0f)
        for(unsigned int k=10;k<16;k++)output[d+k]=0.0f;
    for(unsigned int row=0;row<3;row++) {
        float value=0.0f;
        for(unsigned int col=0;col<4;col++)value+=matrices[m+col*4+row]*source[i*10+col];
        output[d+row]=value;
    }
    float a=matrices[m],b=matrices[m+4],c=matrices[m+8];
    float e=matrices[m+1],f=matrices[m+5],g=matrices[m+9];
    float h=matrices[m+2],j=matrices[m+6],k=matrices[m+10];
    float determinant=a*(f*k-g*j)-b*(e*k-g*h)+c*(e*j-f*h);
    float inv=fabsf(determinant)>0.000000000001f?1.0f/determinant:0.0f;
    float nx=attributes[d+3],ny=attributes[d+4],nz=attributes[d+5];
    output[d+3]=((f*k-g*j)*nx+(g*h-e*k)*ny+(e*j-f*h)*nz)*inv;
    output[d+4]=((c*j-b*k)*nx+(a*k-c*h)*ny+(b*h-a*j)*nz)*inv;
    output[d+5]=((b*g-c*f)*nx+(c*e-a*g)*ny+(a*f-b*e)*nz)*inv;
    // Match generateTangentSpace: normalize the model-space basis first,
    // then transform every column by the normal matrix before interpolation.
    float nl=sqrtf(fmaxf(nx*nx+ny*ny+nz*nz,0.000000000001f));
    float tx=attributes[d+6],ty=attributes[d+7],tz=attributes[d+8];
    float tl=sqrtf(fmaxf(tx*tx+ty*ty+tz*tz,0.000000000001f));
    tx/=tl;ty/=tl;tz/=tl;nx/=nl;ny/=nl;nz/=nl;
    float handed=attributes[d+9];
    float bx=(ny*tz-nz*ty)*handed,by=(nz*tx-nx*tz)*handed,bz=(nx*ty-ny*tx)*handed;
    if(attributes[d]==1.0f) {
        // terrain.vert builds from +X then rederives an orthogonal tangent.
        bx=0.0f;by=nz;bz=-ny;
        tx=-(ny*bz-nz*by);ty=-(nz*bx-nx*bz);tz=-(nx*by-ny*bx);
        float length=sqrtf(fmaxf(tx*tx+ty*ty+tz*tz,0.000000000001f));tx/=length;ty/=length;tz/=length;
    }
    for(unsigned int basis=0;basis<3;basis++) {
        float x=basis==0?tx:(basis==1?bx:nx);
        float y=basis==0?ty:(basis==1?by:ny);
        float z=basis==0?tz:(basis==1?bz:nz);
        unsigned int offset=basis==0?6:(basis==1?18:3);
        output[d+offset]=((f*k-g*j)*x+(g*h-e*k)*y+(e*j-f*h)*z)*inv;
        output[d+offset+1]=((c*j-b*k)*x+(a*k-c*h)*y+(b*h-a*j)*z)*inv;
        output[d+offset+2]=((b*g-c*f)*x+(c*e-a*g)*y+(a*f-b*e)*z)*inv;
    }
    float eye[3],normal[3],eyeLength=0.0f,normalLength=0.0f,dot=0.0f;
    for(unsigned int row=0;row<3;row++) {eye[row]=output[d+row];normal[row]=output[d+3+row];eyeLength+=eye[row]*eye[row];normalLength+=normal[row]*normal[row];}
    eyeLength=sqrtf(fmaxf(eyeLength,0.000000000001f));normalLength=sqrtf(fmaxf(normalLength,0.000000000001f));
    output[d+9]=eyeLength; // Handedness has been consumed; this varying is terrain euclideanDepth.
    for(unsigned int row=0;row<3;row++){eye[row]/=eyeLength;normal[row]/=normalLength;dot+=eye[row]*normal[row];output[d+23+row]=normal[row];}
    float reflected[3];for(unsigned int row=0;row<3;row++)reflected[row]=eye[row]-2.0f*dot*normal[row];
    float denominator=2.0f*sqrtf(fmaxf(0.000000000001f,reflected[0]*reflected[0]+reflected[1]*reflected[1]+(reflected[2]+1.0f)*(reflected[2]+1.0f)));
    output[d+21]=reflected[0]/denominator+0.5f;output[d+22]=reflected[1]/denominator+0.5f;
    // Fixed-function explicit fog owns this varying only for input mode -1.
    // World materials retain the Euclidean depth stored above.
    if(attributes[d]==-1.0f)output[d+9]=attributes[d+2];
}

__global__ void assemble_attributes(const float* source,const unsigned int* triangles,
    const float* weights,const unsigned int* valid,float* output,unsigned int slot_count,unsigned int boundary_offset,unsigned int point_fade_offset,unsigned int source_point_fade_offset) {
    unsigned int slot=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(slot>=slot_count)return;
    unsigned int original=slot/7;
    // Keep discrete perimeter flags separate from interpolated vertex attributes.
    // The rasterizer shares this buffer, avoiding a ninth storage binding.
    for(unsigned int vertex=0;vertex<3;vertex++)
        output[boundary_offset+slot*3+vertex]=valid[slot]!=0?weights[slot*12+vertex*4+3]:0.0f;
    for(unsigned int vertex=0;vertex<3;vertex++)for(unsigned int channel=0;channel<12;channel++) {
        float fade=0.0f;
        if(valid[slot]!=0u)for(unsigned int corner=0;corner<3;corner++)
            fade+=weights[slot*12+vertex*4+corner]*source[source_point_fade_offset+triangles[original*4+corner]*12+channel];
        output[point_fade_offset+(slot*3+vertex)*12+channel]=fade;
    }
    for(unsigned int vertex=0;vertex<3;vertex++)for(unsigned int channel=0;channel<34;channel++) {
        float value=0.0f;
        if(valid[slot]!=0)for(unsigned int corner=0;corner<3;corner++)
            value+=weights[slot*12+vertex*4+corner]*source[triangles[original*4+corner]*34+channel];
        output[(slot*3+vertex)*34+channel]=value;
    }
}
