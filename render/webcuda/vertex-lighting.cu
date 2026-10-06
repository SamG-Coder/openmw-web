#include "cluster-lighting.cuh"
// SPDX-License-Identifier: GPL-3.0-or-later
// Four RGB varyings per corner: shaded diffuse, shaded specular,
// unshadowed diffuse, unshadowed specular. Evaluate before polygon clipping.
// A triangle owns its results so shared vertices with different materials
// never race. No lighting arithmetic is performed by the host.
__global__ void shade_vertex_lighting(const float* vertices,const float* attributes,
    const unsigned int* triangles,const unsigned int* materials,const unsigned int* texels,
    const unsigned int* lighting_origins,float* output,unsigned int triangle_count,unsigned int track_lighting,unsigned int cluster_offset,unsigned int track_world_particles,unsigned int world_particle_offset) {
    unsigned int corner=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(corner>=triangle_count*3)return;
    unsigned int triangle=corner/3,inputVertex=triangles[triangle*4+corner%3];
    unsigned int material=triangles[triangle*4+3]*12,destination=corner*12;
    for(unsigned int k=0;k<12;k++)output[destination+k]=0.0f;
    if((materials[material+3]&2048)==0)return;
    unsigned int data=materials[material],features=texels[data+4],mode=texels[data+5];
    if((features&8388608)==0)return;
    unsigned int cluster=(features&16777216)!=0?texels[cluster_offset+material/12]:0;
    unsigned int first=track_lighting!=0?lighting_origins[inputVertex*3]:inputVertex;
    unsigned int last=track_lighting!=0?lighting_origins[inputVertex*3+1]:inputVertex;
    float fraction=track_lighting!=0?__uint_as_float(lighting_origins[inputVertex*3+2]):0.0f;
    unsigned int particle=world_particle_offset+inputVertex*24;
    unsigned int projected=track_world_particles!=0&&attributes[particle]>0.5f;
    unsigned int endpoints=first==last?1u:2u;
    if(projected!=0) {
        first=inputVertex;last=inputVertex;
        endpoints=attributes[particle]>1.5f?2u:1u;fraction=attributes[particle+1];
    }
    // Expanded lines must interpolate already evaluated endpoint lighting.
    // Evaluating at their near-plane intersection changes Gouraud shading.
    for(unsigned int endpoint=0;endpoint<endpoints;endpoint++) {
        unsigned int vertex=endpoint==0?first:last;
        float weight=endpoints==1u?1.0f:(endpoint==0?1.0f-fraction:fraction);
        float position[3],normal[3],eye[3],diffuse[3],ambient[3],specular[3],emission[3];
        float shaded[3],shadeSpec[3],sunDiffuse[3],sunSpec[3];
        float eyeLength=0.0f,normalLength=0.0f;
        for(unsigned int k=0;k<3;k++) {
            position[k]=projected!=0?attributes[particle+2+endpoint*3+k]:attributes[vertex*34+k];normal[k]=attributes[vertex*34+23+k];
            eyeLength+=position[k]*position[k];normalLength+=normal[k]*normal[k];
            float color=projected!=0?attributes[particle+14+endpoint*4+k]:vertices[vertex*10+4+k];
            diffuse[k]=(mode==2||mode==4)?color:__uint_as_float(texels[data+12+k]);
            ambient[k]=(mode==2||mode==3)?color:__uint_as_float(texels[data+8+k]);
            specular[k]=mode==5?color:__uint_as_float(texels[data+16+k]);
            emission[k]=(mode==1?color:__uint_as_float(texels[data+20+k]))*__uint_as_float(texels[data+47]);
            shaded[k]=emission[k];shadeSpec[k]=0.0f;sunDiffuse[k]=0.0f;sunSpec[k]=0.0f;
        }
        eyeLength=sqrtf(fmaxf(eyeLength,0.000000000001f));
        normalLength=sqrtf(fmaxf(normalLength,0.000000000001f));
        for(unsigned int k=0;k<3;k++){eye[k]=position[k]/eyeLength;normal[k]/=normalLength;}
        float shininess=fmaxf(0.0001f,__uint_as_float(texels[data+46]));
        float strength=__uint_as_float(texels[data+48]);
        unsigned int cell=0xffffffffu,pointCount=texels[data+6];
        if(cluster!=0) {
            float sw=__uint_as_float(texels[cluster+5]),sh=__uint_as_float(texels[cluster+6]);
            float clipX=projected!=0?attributes[particle+8+endpoint*3]:vertices[vertex*10];
            float clipY=projected!=0?attributes[particle+9+endpoint*3]:vertices[vertex*10+1];
            float w=projected!=0?attributes[particle+10+endpoint*3]:vertices[vertex*10+3];
            if(fabsf(w)>0.000000000001f) {
                float sx=fminf(sw-1.0f,fmaxf(0.0f,(clipX/w*0.5f+0.5f)*sw));
                float sy=fminf(sh-1.0f,fmaxf(0.0f,(clipY/w*0.5f+0.5f)*sh));
                cell=cluster_cell(texels,cluster,sx,sy,position[2]);
            }
            pointCount=(features&33554432)!=0?0u:cluster_count(texels,cluster,cell);
        }
        for(unsigned int light=0;light<=pointCount;light++) {
            unsigned int record=light==0?data+24:(cluster!=0?cluster_light(texels,cluster,cell,light-1):data+texels[data+7]+(light-1)*16);
            float direction[3],distance=0.0f;
            for(unsigned int k=0;k<3;k++) {
                direction[k]=__uint_as_float(texels[record+k])-(light==0?0.0f:position[k]);
                distance+=direction[k]*direction[k];
            }
            distance=sqrtf(fmaxf(distance,0.000000000001f));
            float attenuation=1.0f;
            if(light!=0) {
                float radius=__uint_as_float(texels[record+15]);
                if(((features&1)==0||cluster!=0)&&distance>radius)continue;
                if(cluster!=0)attenuation*=cluster_distance_fade(texels,cluster,position[2],radius);
                float denominator=__uint_as_float(texels[record+3])+__uint_as_float(texels[record+7])*distance
                    +__uint_as_float(texels[record+11])*distance*distance;
                attenuation/=fmaxf(denominator,0.000000000001f);
                if((features&1)==0||cluster!=0) {
                    float fade=fminf(1.0f,fmaxf(0.0f,(distance/fmaxf(radius,0.000001f)-0.75f)/0.25f));
                    fade=1.0f-fade*fade;attenuation*=fade*fade;
                }
            }
            float lambert=0.0f,halfLength=0.0f,halfVector[3];
            for(unsigned int k=0;k<3;k++) {
                direction[k]/=distance;lambert+=normal[k]*direction[k];
                halfVector[k]=direction[k]-eye[k];halfLength+=halfVector[k]*halfVector[k];
            }
            if((features&67108864)!=0) {
                float eyeCosine=0.0f;
                for(unsigned int axis=0;axis<3;axis++)eyeCosine+=normal[axis]*eye[axis];
                if(lambert<0.0f){lambert=-lambert;eyeCosine=-eyeCosine;}
                lambert*=fminf(1.0f,fmaxf(0.3f,1.0f-5.6f*eyeCosine));
            }
            halfLength=sqrtf(fmaxf(halfLength,0.000000000001f));
            float spec=0.0f;
            if(lambert>0.0f) {
                for(unsigned int k=0;k<3;k++)spec+=normal[k]*halfVector[k]/halfLength;
                spec=powf(fmaxf(spec,0.0f),shininess);
            }
            for(unsigned int k=0;k<3;k++) {
                float d=diffuse[k]*__uint_as_float(texels[record+8+k])*fmaxf(lambert,0.0f)*attenuation;
                float a=ambient[k]*__uint_as_float(texels[record+4+k])*attenuation;
                float s=specular[k]*__uint_as_float(texels[record+12+k])*spec*attenuation*strength;
                shaded[k]+=a;
                if(light==0){sunDiffuse[k]=d;sunSpec[k]=s;}
                else {shaded[k]+=d;shadeSpec[k]+=s;}
            }
        }
        for(unsigned int k=0;k<3;k++) {
            float lit=fmaxf(0.0f,shaded[k]+sunDiffuse[k]);
            float shade=fmaxf(0.0f,shaded[k]);
            if((features&2)!=0){lit=fminf(1.0f,lit);shade=fminf(1.0f,shade);}
            output[destination+k]+=weight*shade;output[destination+3+k]+=weight*shadeSpec[k];
            output[destination+6+k]+=weight*lit;output[destination+9+k]+=weight*(shadeSpec[k]+sunSpec[k]);
        }
    }
}

__global__ void assemble_vertex_lighting(const float* source,const float* weights,
    const unsigned int* valid,float* attributes,unsigned int slot_count,unsigned int lighting_offset) {
    unsigned int slot=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(slot>=slot_count)return;
    unsigned int original=slot/7;
    for(unsigned int vertex=0;vertex<3;vertex++)for(unsigned int channel=0;channel<12;channel++) {
        float value=0.0f;
        if(valid[slot]!=0)for(unsigned int corner=0;corner<3;corner++)
            value+=weights[slot*12+vertex*4+corner]*source[(original*3+corner)*12+channel];
        attributes[lighting_offset+(slot*3+vertex)*12+channel]=value;
    }
}
