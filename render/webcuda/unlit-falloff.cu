// Endpoint record (six floats): angle0, raw view normal XYZ, angle1, fraction.
// Material falloff is evaluated at endpoints before line clipping interpolation.
__global__ void prepare_bethesda_vertices(const float* vertices,const float* attributes,const float* matrices,
    const unsigned int* matrix_ids,const float* varyings,float* output,unsigned int vertex_count,
    unsigned int track_world_particles,unsigned int world_particle_offset) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=vertex_count)return;
    unsigned int m=matrix_ids[i]*32u;
    float view[3],normal[3],length=0.0f;
    for(unsigned int k=0;k<3;k++) {
        normal[k]=attributes[i*34u+3u+k];length+=normal[k]*normal[k];
        view[k]=0.0f;for(unsigned int col=0;col<4;col++)view[k]+=matrices[m+col*4u+k]*vertices[i*10u+col];
    }
    float normalScale=length>0.0f?1.0f/sqrtf(length):0.0f;
    float a=matrices[m],b=matrices[m+4],c=matrices[m+8],d=matrices[m+1],e=matrices[m+5],f=matrices[m+9],g=matrices[m+2],h=matrices[m+6],j=matrices[m+10];
    float det=a*(e*j-f*h)-b*(d*j-f*g)+c*(d*h-e*g);
    float inverse=det!=0.0f?1.0f/det:0.0f;
    float nx=((e*j-f*h)*normal[0]+(f*g-d*j)*normal[1]+(d*h-e*g)*normal[2])*inverse;
    float ny=((c*h-b*j)*normal[0]+(a*j-c*g)*normal[1]+(b*g-a*h)*normal[2])*inverse;
    float nz=((b*f-c*e)*normal[0]+(c*d-a*f)*normal[1]+(a*e-b*d)*normal[2])*inverse;
    output[i*6u+1u]=nx;output[i*6u+2u]=ny;output[i*6u+3u]=nz;
    float viewLength=sqrtf(view[0]*view[0]+view[1]*view[1]+view[2]*view[2]);
    float angle=viewLength>0.0f?fabsf((nx*view[0]+ny*view[1]+nz*view[2])*normalScale/viewLength):0.0f;
    output[i*6u]=angle;output[i*6u+4u]=angle;output[i*6u+5u]=0.0f;
    unsigned int particle=world_particle_offset+i*24u;
    if(track_world_particles!=0u&&varyings[particle]>0.5f) {
        for(unsigned int endpoint=0;endpoint<2;endpoint++) {
            float depth=0.0f,dot=0.0f;
            for(unsigned int axis=0;axis<3;axis++) {
                float position=varyings[particle+2u+endpoint*3u+axis];
                depth+=position*position;dot+=output[i*6u+1u+axis]*position;
            }
            depth=sqrtf(depth);
            output[i*6u+endpoint*4u]=depth>0.0f?fabsf(dot*normalScale/depth):0.0f;
        }
        output[i*6u+5u]=varyings[particle+1u];
    }
}
__device__ float bethesda_falloff(const unsigned int* texels,unsigned int data,float angle) {
    if((texels[data+4u]&268435456u)==0u||texels[data+80u]==0u)return 1.0f;
    float start=__uint_as_float(texels[data+81u]),end=__uint_as_float(texels[data+82u]);
    float t=end!=start?fminf(1.0f,fmaxf(0.0f,(angle-start)/(end-start))):(angle>=end?1.0f:0.0f);
    t=t*t*(3.0f-2.0f*t);
    float opacityStart=fminf(__uint_as_float(texels[data+83u]),1.0f),opacityEnd=fmaxf(__uint_as_float(texels[data+84u]),0.0f);
    return opacityStart+(opacityEnd-opacityStart)*t;
}
__global__ void shade_unlit_falloff(const float* endpoints,const unsigned int* origins,
    const unsigned int* triangles,const unsigned int* materials,const unsigned int* texels,float* output,
    unsigned int triangle_count,unsigned int track_origins) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=triangle_count*3u)return;
    unsigned int vertex=triangles[(i/3u)*4u+i%3u],mat=triangles[(i/3u)*4u+3u]*12u,data=materials[mat];
    output[i*4u]=1.0f;for(unsigned int k=1;k<4;k++)output[i*4u+k]=0.0f;
    if((materials[mat+3u]&2048u)==0u||(texels[data+4u]&(268435456u|536870912u))==0u)return;
    unsigned int a=vertex,b=vertex;float t=0.0f;
    if(track_origins!=0u){a=origins[vertex*3u];b=origins[vertex*3u+1u];t=__uint_as_float(origins[vertex*3u+2u]);}
    float first=bethesda_falloff(texels,data,endpoints[a*6u]);
    float firstEnd=bethesda_falloff(texels,data,endpoints[a*6u+4u]);
    first+=endpoints[a*6u+5u]*(firstEnd-first);
    float last=bethesda_falloff(texels,data,endpoints[b*6u]);
    float lastEnd=bethesda_falloff(texels,data,endpoints[b*6u+4u]);
    last+=endpoints[b*6u+5u]*(lastEnd-last);
    output[i*4u]=first+t*(last-first);
    for(unsigned int k=1;k<4;k++)output[i*4u+k]=endpoints[a*6u+k]+t*(endpoints[b*6u+k]-endpoints[a*6u+k]);
}
__global__ void assemble_unlit_falloff(const float* source,const float* weights,const unsigned int* valid,float* attributes,
    unsigned int slot_count,unsigned int falloff_offset) {
    unsigned int slot=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(slot>=slot_count)return;
    unsigned int sourceSlot=(valid[slot]&0x80000000u)!=0u?valid[slot]&0x7fffffffu:slot;
    for(unsigned int vertex=0;vertex<3;vertex++)for(unsigned int channel=0;channel<4;channel++) {
        float value=0.0f;
        if(valid[slot]!=0u)for(unsigned int corner=0;corner<3;corner++)value+=weights[sourceSlot*12u+vertex*4u+corner]*source[((sourceSlot/7u)*3u+corner)*4u+channel];
        attributes[falloff_offset+(slot*3u+vertex)*4u+channel]=value;
    }
}
