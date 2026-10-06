// SPDX-License-Identifier: GPL-3.0-or-later
// Compatibility lighting. Descriptor368 is transported without evaluating
// positions, normals, attenuation or colors on the CPU.
__device__ float fixed_unit(float value){return fminf(1.0f,fmaxf(0.0f,value));}
__device__ void fixed_normalize(float* v) {
    float length=sqrtf(fmaxf(v[0]*v[0]+v[1]*v[1]+v[2]*v[2],0.000000000001f));
    for(unsigned int k=0;k<3;k++)v[k]/=length;
}
__global__ void shade_fixed_vertices(const float* vertices,const float* attributes,const float* matrices,
    const unsigned int* matrix_ids,const unsigned int* descriptors,const float* secondary_colors,float* output,float* endpoints,unsigned int vertex_count,unsigned int capture_endpoints) {
    unsigned int vertex=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(vertex>=vertex_count)return;
    unsigned int draw=matrix_ids[vertex],m=draw*32,d=draw*368,flags=descriptors[d+1],mode=descriptors[d+2];
    for(unsigned int k=0;k<16;k++)output[vertex*16+k]=0.0f;
    if(capture_endpoints!=0)for(unsigned int k=0;k<32;k++)endpoints[vertex*32+k]=0.0f;
    if((flags&160)==0)return;
    if((flags&128)==0) {
        float primitive=attributes[vertex*34];
        unsigned int line=primitive==6.0f||primitive==7.0f;
        for(unsigned int endpoint=0;endpoint<(line!=0?2u:1u);endpoint++) {
            for(unsigned int face=0;face<2;face++) {
                unsigned int destination=vertex*16+face*8;
                for(unsigned int channel=0;channel<4;channel++) {
                    float color=primitive==7.0f&&endpoint!=0?attributes[vertex*34+18+channel]:vertices[vertex*10+4+channel];
                    output[destination+channel]=fixed_unit(color);
                }
                for(unsigned int channel=0;channel<3;channel++)output[destination+4+channel]=fixed_unit(secondary_colors[vertex*3+channel]);
                output[destination+7]=1.0f;
            }
            if(line!=0&&capture_endpoints!=0)for(unsigned int channel=0;channel<16;channel++)
                endpoints[vertex*32+endpoint*16+channel]=output[vertex*16+channel];
        }
        return;
    }
    float primitive=attributes[vertex*34];
    unsigned int line=primitive==6.0f||primitive==7.0f;
    unsigned int screenPrimitive=primitive==5.0f||primitive==6.0f||primitive==7.0f||primitive==8.0f;
    for(unsigned int endpoint=0;endpoint<(line!=0?2u:1u);endpoint++) {
    float position[4];
    for(unsigned int row=0;row<4;row++) {
        position[row]=0.0f;
        for(unsigned int col=0;col<4;col++)position[row]+=matrices[m+col*4+row]*(vertices[vertex*10+col]+(line!=0&&endpoint!=0&&col<3?attributes[vertex*34+10+col]:0.0f));
    }
    if(fabsf(position[3])>0.000000000001f)for(unsigned int k=0;k<3;k++)position[k]/=position[3];
    float a=matrices[m],b=matrices[m+4],c=matrices[m+8];
    float e=matrices[m+1],f=matrices[m+5],g=matrices[m+9];
    float h=matrices[m+2],j=matrices[m+6],k=matrices[m+10];
    float determinant=a*(f*k-g*j)-b*(e*k-g*h)+c*(e*j-f*h);
    float inverse=fabsf(determinant)>0.000000000001f?1.0f/determinant:0.0f;
    float nmatrix[9];
    nmatrix[0]=(f*k-g*j)*inverse;nmatrix[1]=(g*h-e*k)*inverse;nmatrix[2]=(e*j-f*h)*inverse;
    nmatrix[3]=(c*j-b*k)*inverse;nmatrix[4]=(a*k-c*h)*inverse;nmatrix[5]=(b*h-a*j)*inverse;
    nmatrix[6]=(b*g-c*f)*inverse;nmatrix[7]=(c*e-a*g)*inverse;nmatrix[8]=(a*f-b*e)*inverse;
    float normal[3],viewer[3];
    for(unsigned int row=0;row<3;row++) {
        normal[row]=0.0f;for(unsigned int col=0;col<3;col++)normal[row]+=nmatrix[row*3+col]*attributes[vertex*34+3+col];
        viewer[row]=(flags&2)!=0?-position[row]:(row==2?1.0f:0.0f);
    }
    fixed_normalize(viewer);
    if((flags&8)!=0)fixed_normalize(normal);
    else if((flags&16)!=0) {
        float scale=sqrtf(fmaxf(nmatrix[2]*nmatrix[2]+nmatrix[5]*nmatrix[5]+nmatrix[8]*nmatrix[8],0.000000000001f));
        for(unsigned int axis=0;axis<3;axis++)normal[axis]/=scale;
    }
    for(unsigned int face=0;face<2;face++) {
        unsigned int side=(flags&1)!=0&&screenPrimitive==0?face:0,material=d+8+side*17,destination=vertex*16+face*8;
        float ambient[3],diffuse[4],specular[3],primary[3],secondary[3];
        for(unsigned int axis=0;axis<4;axis++) {
            float color=primitive==7.0f&&endpoint!=0?attributes[vertex*34+18+axis]:vertices[vertex*10+4+axis];
            diffuse[axis]=(mode==2||mode==4)?color:__uint_as_float(descriptors[material+4+axis]);
            if(axis<3) {
                ambient[axis]=(mode==2||mode==3)?color:__uint_as_float(descriptors[material+axis]);
                specular[axis]=mode==5?color:__uint_as_float(descriptors[material+8+axis]);
                float emission=mode==1?color:__uint_as_float(descriptors[material+12+axis]);
                primary[axis]=emission+ambient[axis]*__uint_as_float(descriptors[d+4+axis]);secondary[axis]=0.0f;
            }
        }
        for(unsigned int light=0;light<8;light++)if((descriptors[d]&(1u<<light))!=0) {
            unsigned int l=d+48+light*40;
            float lightPosition[4],spot[3];
            for(unsigned int row=0;row<4;row++) {
                lightPosition[row]=0.0f;
                for(unsigned int col=0;col<4;col++)lightPosition[row]+=__uint_as_float(descriptors[l+24+col*4+row])*__uint_as_float(descriptors[l+col]);
                if(row<3) {
                    spot[row]=0.0f;
                    // GL2.1 section2.14.2 transforms spotlight directions by Mu.
                    for(unsigned int col=0;col<3;col++)spot[row]+=__uint_as_float(descriptors[l+24+col*4+row])*__uint_as_float(descriptors[l+16+col]);
                }
            }
            float direction[3],distance=0.0f;
            for(unsigned int axis=0;axis<3;axis++) {
                direction[axis]=lightPosition[3]==0.0f?lightPosition[axis]:lightPosition[axis]/lightPosition[3]-position[axis];
                distance+=direction[axis]*direction[axis];
            }
            distance=sqrtf(fmaxf(distance,0.000000000001f));
            for(unsigned int axis=0;axis<3;axis++)direction[axis]/=distance;
            float attenuation=1.0f;
            if(lightPosition[3]!=0.0f)attenuation=1.0f/fmaxf(0.000000000001f,__uint_as_float(descriptors[l+19])
                +__uint_as_float(descriptors[l+20])*distance+__uint_as_float(descriptors[l+21])*distance*distance);
            float cutoff=__uint_as_float(descriptors[l+23]);
            if(cutoff!=180.0f) {
                fixed_normalize(spot);float cosine=0.0f;
                for(unsigned int axis=0;axis<3;axis++)cosine-=direction[axis]*spot[axis];
                if(cosine<cosf(cutoff*0.017453292519943295f))attenuation=0.0f;
                else {float exponent=__uint_as_float(descriptors[l+22]);attenuation*=exponent==0.0f?1.0f:powf(fmaxf(cosine,0.0f),exponent);}
            }
            float halfVector[3],lambert=0.0f,spec=0.0f;
            for(unsigned int axis=0;axis<3;axis++){lambert+=normal[axis]*direction[axis]*(side==1?-1.0f:1.0f);halfVector[axis]=direction[axis]+viewer[axis];}
            fixed_normalize(halfVector);
            if(lambert>0.0f) {
                for(unsigned int axis=0;axis<3;axis++)spec+=normal[axis]*halfVector[axis]*(side==1?-1.0f:1.0f);
                float shininess=__uint_as_float(descriptors[material+16]);spec=shininess==0.0f?1.0f:powf(fmaxf(spec,0.0f),shininess);
            }
            for(unsigned int axis=0;axis<3;axis++) {
                primary[axis]+=(ambient[axis]*__uint_as_float(descriptors[l+4+axis])+diffuse[axis]*__uint_as_float(descriptors[l+8+axis])*fmaxf(lambert,0.0f))*attenuation;
                float shine=specular[axis]*__uint_as_float(descriptors[l+12+axis])*spec*attenuation;
                if((flags&4)!=0)secondary[axis]+=shine;else primary[axis]+=shine;
            }
        }
        for(unsigned int axis=0;axis<3;axis++){output[destination+axis]=fixed_unit(primary[axis]);output[destination+4+axis]=fixed_unit(secondary[axis]);}
        output[destination+3]=fixed_unit(diffuse[3]);output[destination+7]=1.0f;
    }
    if(line!=0&&capture_endpoints!=0)for(unsigned int channel=0;channel<16;channel++)endpoints[vertex*32+endpoint*16+channel]=output[vertex*16+channel];
    }
}

__global__ void assemble_fixed_lighting(const float* source,const unsigned int* triangles,const unsigned int* flat_colors,
    const float* weights,const unsigned int* valid,float* output,unsigned int slot_count,unsigned int fixed_offset) {
    unsigned int slot=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(slot>=slot_count)return;
    unsigned int sourceSlot=(valid[slot]&0x80000000u)!=0u?valid[slot]&0x7fffffffu:slot;
    unsigned int original=sourceSlot/7,provoking=flat_colors[original];
    unsigned int frontOnly=source[triangles[original*4]*16+15]>1.5f;
    for(unsigned int vertex=0;vertex<3;vertex++)for(unsigned int channel=0;channel<16;channel++) {
        float value=0.0f;
        if(valid[slot]!=0) {
            if(provoking!=0xffffffffu)value=source[provoking*16+(frontOnly!=0&&channel>=8?channel-8:channel)];
            else for(unsigned int corner=0;corner<3;corner++)value+=weights[sourceSlot*12+vertex*4+corner]*source[triangles[original*4+corner]*16+channel];
        }
        output[fixed_offset+(slot*3+vertex)*16+channel]=value;
    }
}
