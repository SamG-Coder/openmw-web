// SPDX-License-Identifier: GPL-3.0-or-later
// Four descriptors per draw: enabled components, mode, normal flags, reserved,
// then four plane equations and the eye-plane application matrix (36 words).
// Execute after deformation and before clipping.
__global__ void generate_texture_coordinates(const float* source,const float* source_attributes,
    const float* matrices,const unsigned int* matrix_ids,const unsigned int* descriptors,
    float* attributes,unsigned int vertex_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=vertex_count)return;
    unsigned int draw=matrix_ids[i],v=i*34u,m=draw*32u;
    float normal[3],unitNormal[3],reflected[3],eye[3];
    float a=matrices[m],b=matrices[m+4u],c=matrices[m+8u];
    float d=matrices[m+1u],e=matrices[m+5u],f=matrices[m+9u];
    float g=matrices[m+2u],h=matrices[m+6u],j=matrices[m+10u];
    float determinant=a*(e*j-f*h)-b*(d*j-f*g)+c*(d*h-e*g);
    float inverse=fabsf(determinant)>0.000000000001f?1.0f/determinant:0.0f;
    float nx=source_attributes[v+3u],ny=source_attributes[v+4u],nz=source_attributes[v+5u];
    normal[0]=((e*j-f*h)*nx+(f*g-d*j)*ny+(d*h-e*g)*nz)*inverse;
    normal[1]=((c*h-b*j)*nx+(a*j-c*g)*ny+(b*g-a*h)*nz)*inverse;
    normal[2]=((b*f-c*e)*nx+(c*d-a*f)*ny+(a*e-b*d)*nz)*inverse;
    float length=0.0f,eyeLength=0.0f;
    for(unsigned int k=0;k<3;k++){length+=normal[k]*normal[k];eye[k]=attributes[v+k];eyeLength+=eye[k]*eye[k];}
    length=sqrtf(fmaxf(length,0.000000000001f));eyeLength=sqrtf(fmaxf(eyeLength,0.000000000001f));
    float dot=0.0f;
    for(unsigned int k=0;k<3;k++){unitNormal[k]=normal[k]/length;eye[k]/=eyeLength;dot+=eye[k]*unitNormal[k];}
    for(unsigned int k=0;k<3;k++)reflected[k]=eye[k]-2.0f*dot*unitNormal[k];
    float sphere=2.0f*sqrtf(fmaxf(0.000000000001f,reflected[0]*reflected[0]+reflected[1]*reflected[1]+(reflected[2]+1.0f)*(reflected[2]+1.0f)));
    // RESCALE_NORMAL uses the inverse model-view's third row length.
    float rx=(d*h-e*g)*inverse,ry=(b*g-a*h)*inverse,rz=(a*e-b*d)*inverse;
    float rescale=1.0f/sqrtf(fmaxf(rx*rx+ry*ry+rz*rz,0.000000000001f));
    for(unsigned int unit=0;unit<4;unit++) {
        unsigned int descriptor=draw*144u+unit*36u,mask=descriptors[descriptor],mode=descriptors[descriptor+1u];
        float planePosition[4];
        for(unsigned int k=0;k<4;k++)planePosition[k]=source[i*10u+k];
        if(mode==5u&&mask!=0u) {
            // Solve applicationModelView * position = currentEyePosition.
            // Applying stored eye planes to this position is equivalent to
            // inverse-transposing them at the original state application.
            float system[20];
            for(unsigned int row=0;row<4;row++) {
                float eyePosition=0.0f;
                for(unsigned int col=0;col<4;col++) {
                    system[row*5u+col]=__uint_as_float(descriptors[descriptor+20u+col*4u+row]);
                    eyePosition+=matrices[m+col*4u+row]*source[i*10u+col];
                }
                system[row*5u+4u]=eyePosition;
            }
            unsigned int valid=1u;
            for(unsigned int pivot=0;pivot<4;pivot++) {
                unsigned int selected=pivot;
                for(unsigned int row=pivot+1u;row<4;row++)
                    if(fabsf(system[row*5u+pivot])>fabsf(system[selected*5u+pivot]))selected=row;
                for(unsigned int col=0;col<5;col++) {
                    float saved=system[pivot*5u+col];system[pivot*5u+col]=system[selected*5u+col];system[selected*5u+col]=saved;
                }
                float divisor=system[pivot*5u+pivot];
                if(divisor==0.0f){valid=0u;break;}
                for(unsigned int col=0;col<5;col++)system[pivot*5u+col]/=divisor;
                for(unsigned int row=0;row<4;row++)if(row!=pivot) {
                    float factor=system[row*5u+pivot];
                    for(unsigned int col=0;col<5;col++)system[row*5u+col]-=factor*system[pivot*5u+col];
                }
            }
            for(unsigned int k=0;k<4;k++)planePosition[k]=valid!=0u?system[k*5u+4u]:0.0f;
        }
        for(unsigned int coordinate=0;coordinate<4;coordinate++)if((mask&(1u<<coordinate))!=0u) {
            float value=0.0f;
            if(mode==1u||mode==5u)for(unsigned int k=0;k<4;k++)value+=planePosition[k]*__uint_as_float(descriptors[descriptor+4u+coordinate*4u+k]);
            else if(mode==2u)value=reflected[coordinate]/sphere+0.5f;
            else if(mode==3u) {
                unsigned int flags=descriptors[descriptor+2u];
                value=(flags&1u)!=0u?unitNormal[coordinate]:normal[coordinate]*((flags&2u)!=0u?rescale:1.0f);
            } else value=reflected[coordinate];
            unsigned int offset=coordinate<2u?(unit==0u?16u:10u+(unit-1u)*2u)+coordinate:26u+unit*2u+coordinate-2u;
            attributes[v+offset]=value;
        }
    }
}
