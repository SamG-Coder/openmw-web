// SPDX-License-Identifier: GPL-3.0-or-later
// Groundcover instance/wind/stomp port of compatibility/groundcover.vert.
// records: vertex, instance, parameter-block. instances: offset.xyz, scale,
// rotation.xyz. params40: viewToInvert16, view16, wind, time, player.xyz,
// stompMode, stompIntensity, fadeEnd. Matrix IDs address ordinary MV/P32.
__global__ void deform_groundcover(float* vertices,float* attributes,const unsigned int* records,
    const float* instances,const float* params,const float* matrices,const unsigned int* matrix_ids,
    unsigned int record_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=record_count)return;
    unsigned int vertex=records[i*3],instance=records[i*3+1]*7,p=records[i*3+2]*40;
    unsigned int v=vertex*10,a=vertex*34,m=matrix_ids[vertex]*32;
    float sx=sinf(instances[instance+4]),cx=cosf(instances[instance+4]);
    float sy=sinf(instances[instance+5]),cy=cosf(instances[instance+5]);
    float sz=sinf(instances[instance+6]),cz=cosf(instances[instance+6]);
    float rotation[9];
    rotation[0]=cz*cy+sx*sy*sz;rotation[1]=-sz*cx;rotation[2]=cz*sy+sz*sx*cy;
    rotation[3]=sz*cy+cz*sx*sy;rotation[4]=cz*cx;rotation[5]=sz*sy-cz*sx*cy;
    rotation[6]=-sy*cx;rotation[7]=sx;rotation[8]=cx*cy;
    float height=vertices[v+2],position[4],normal[3],tangent[3];
    for(unsigned int row=0;row<3;row++) {
        position[row]=instances[instance+row];normal[row]=0.0f;tangent[row]=0.0f;
        for(unsigned int col=0;col<3;col++) {
            position[row]+=rotation[col*3+row]*instances[instance+3]*vertices[v+col];
            normal[row]+=rotation[col*3+row]*attributes[a+3+col];
            // The original tangent expression is a row-vector times rotation.
            tangent[row]+=attributes[a+6+col]*rotation[row*3+col];
        }
    }
    position[3]=1.0f;
    float view[4],world[4],center[4];
    for(unsigned int row=0;row<4;row++) {
        view[row]=0.0f;center[row]=matrices[m+12+row];
        for(unsigned int col=0;col<4;col++)view[row]+=matrices[m+col*4+row]*position[col];
        for(unsigned int col=0;col<3;col++)center[row]+=matrices[m+col*4+row]*instances[instance+col];
    }
    float distance=sqrtf(center[0]*center[0]+center[1]*center[1]+center[2]*center[2]+center[3]*center[3]);
    if(distance>params[p+39]) {
        // Collapse every vertex of this instance to the same position. The
        // reference shader also emits a degenerate primitive beyond fadeEnd.
        for(unsigned int row=0;row<3;row++)vertices[v+row]=instances[instance+row];
        vertices[v+3]=1.0f;return;
    }
    float va=params[p],vb=params[p+4],vc=params[p+8];
    float vd=params[p+1],ve=params[p+5],vf=params[p+9];
    float vg=params[p+2],vh=params[p+6],vj=params[p+10];
    float viewDet=va*(ve*vj-vf*vh)-vb*(vd*vj-vf*vg)+vc*(vd*vh-ve*vg);
    float viewInverse=fabsf(viewDet)>0.000000000001f?1.0f/viewDet:0.0f;
    float vx=view[0]-params[p+12]*view[3],vy=view[1]-params[p+13]*view[3],vz=view[2]-params[p+14]*view[3];
    world[0]=((ve*vj-vf*vh)*vx+(vc*vh-vb*vj)*vy+(vb*vf-vc*ve)*vz)*viewInverse;
    world[1]=((vf*vg-vd*vj)*vx+(va*vj-vc*vg)*vy+(vc*vd-va*vf)*vz)*viewInverse;
    world[2]=((vd*vh-ve*vg)*vx+(vb*vg-va*vh)*vy+(va*ve-vb*vd)*vz)*viewInverse;
    world[3]=view[3];
    float wind=params[p+32],time=params[p+33];
    float speed=sqrtf(2.0f*wind*wind+1.0f);
    float dx=world[0]-params[p+34],dy=world[1]-params[p+35];
    float footDistance=sqrtf(dx*dx+dy*dy),stomp=0.0f;
    if(params[p+37]>0.5f) {
        float range=params[p+38]<0.5f?50.0f:(params[p+38]<1.5f?80.0f:150.0f);
        float reach=params[p+38]<0.5f?20.0f:(params[p+38]<1.5f?40.0f:60.0f);
        if(footDistance>0.0f&&footDistance<range)stomp=reach/footDistance-reach/range;
        if(params[p+37]>1.5f) {
            float relative=height!=0.0f?(world[2]-params[p+36])/height:0.0f;
            stomp*=fminf(1.0f,fmaxf(0.0f,relative));
        }
    }
    float bend=fminf(1.0f,fmaxf(0.0f,0.02f*height));
    for(unsigned int axis=0;axis<2;axis++) {
        float coordinate=world[axis];
        float harmonics=(1.0f-0.10f*speed)*sinf(time+coordinate/1100.0f)
            +(1.0f-0.04f*speed)*cosf(2.0f*time+coordinate/750.0f)
            +(1.0f+0.14f*speed)*sinf(3.0f*time+coordinate/500.0f)
            +(1.0f+0.28f*speed)*sinf(5.0f*time+coordinate/200.0f);
        world[axis]+=bend*(harmonics*(2.0f*wind+0.1f)+stomp*(axis==0?dx:dy));
    }
    for(unsigned int row=0;row<4;row++) {
        view[row]=0.0f;
        for(unsigned int col=0;col<4;col++)view[row]+=params[p+16+col*4+row]*world[col];
    }
    // Return to model coordinates for the shared lighting/shadow/clip path.
    // Inverting the affine MV is rendering arithmetic and stays on the GPU.
    float aa=matrices[m],b=matrices[m+4],c=matrices[m+8];
    float d=matrices[m+1],e=matrices[m+5],f=matrices[m+9];
    float g=matrices[m+2],h=matrices[m+6],j=matrices[m+10];
    float det=aa*(e*j-f*h)-b*(d*j-f*g)+c*(d*h-e*g);
    float inverse=fabsf(det)>0.000000000001f?1.0f/det:0.0f;
    float x=view[0]-matrices[m+12]*view[3],y=view[1]-matrices[m+13]*view[3],z=view[2]-matrices[m+14]*view[3];
    vertices[v]=((e*j-f*h)*x+(c*h-b*j)*y+(b*f-c*e)*z)*inverse;
    vertices[v+1]=((f*g-d*j)*x+(aa*j-c*g)*y+(c*d-aa*f)*z)*inverse;
    vertices[v+2]=((d*h-e*g)*x+(b*g-aa*h)*y+(aa*e-b*d)*z)*inverse;
    vertices[v+3]=view[3];
    for(unsigned int axis=0;axis<3;axis++){attributes[a+3+axis]=normal[axis];attributes[a+6+axis]=tangent[axis];}
}
