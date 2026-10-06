// SPDX-License-Identifier: GPL-3.0-or-later
// Port of OpenMW's core/lighting/{cluster,cull}.comp. Cluster construction
// reconstructs the symmetric perspective used by LightManager or the local
// map's orthographic camera from the raw projection. Reverse-Z changes depth
// coefficients, not these XY scales. Both use the same logarithmic depth slices.
// Cluster records are eight floats: min xyz/pad, max xyz/pad.
__global__ void prepare_cluster_lights(float* lights,const float* inputs,unsigned int light_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=light_count)return;
    unsigned int record=i*20u,fade=20u+i*5u;
    float position[4];for(unsigned int k=0;k<4;k++)position[k]=lights[record+k];
    for(unsigned int row=0;row<4;row++) {
        float value=0.0f;
        for(unsigned int col=0;col<4;col++)value+=inputs[col*4u+row]*position[col];
        lights[record+row]=value;
    }
    float amount=1.0f,end=inputs[fade+4u];
    if(end!=0.0f) {
        float distance=0.0f;
        for(unsigned int k=0;k<3;k++)distance+=inputs[fade+k]*inputs[fade+k];
        amount=1.0f-fminf(1.0f,fmaxf(0.0f,(sqrtf(distance)-inputs[fade+3u])/(end-inputs[fade+3u])));
    }
    for(unsigned int k=0;k<4;k++){lights[record+4u+k]*=amount;lights[record+12u+k]*=amount;}
    lights[record+19u]*=inputs[16];
}

__global__ void build_light_clusters(const float* projection,float* clusters,
    unsigned int grid_x,unsigned int grid_y,unsigned int grid_z,float near_distance,float far_distance) {
    unsigned int tile=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(tile>=grid_x*grid_y*grid_z)return;
    unsigned int x=tile%grid_x,y=(tile/grid_x)%grid_y,z=tile/(grid_x*grid_y);
    float planeNear=near_distance*powf(far_distance/near_distance,(float)z/(float)grid_z);
    float planeFar=near_distance*powf(far_distance/near_distance,(float)(z+1)/(float)grid_z);
    // Orthographic rays stay parallel: XY bounds do not grow with depth.
    float shiftX=0.0f,shiftY=0.0f,scaleNear=planeNear,scaleFar=planeFar;
    if(projection[15]>0.5f) {
        shiftX=projection[12];shiftY=projection[13];scaleNear=1.0f;scaleFar=1.0f;
    }
    float minX=(2.0f*(float)x/(float)grid_x-1.0f-shiftX)/projection[0];
    float maxX=(2.0f*(float)(x+1)/(float)grid_x-1.0f-shiftX)/projection[0];
    float minY=(2.0f*(float)y/(float)grid_y-1.0f-shiftY)/projection[5];
    float maxY=(2.0f*(float)(y+1)/(float)grid_y-1.0f-shiftY)/projection[5];
    clusters[tile*8]=fminf(minX*scaleNear,minX*scaleFar);
    clusters[tile*8+1]=fminf(minY*scaleNear,minY*scaleFar);
    clusters[tile*8+2]=-planeFar;clusters[tile*8+3]=0.0f;
    clusters[tile*8+4]=fmaxf(maxX*scaleNear,maxX*scaleFar);
    clusters[tile*8+5]=fmaxf(maxY*scaleNear,maxY*scaleFar);
    clusters[tile*8+6]=-planeNear;clusters[tile*8+7]=0.0f;
}

// PointLight uses the engine's 20-float std430 layout: position, diffuse,
// ambient, specular, then constant/linear/quadratic attenuation and radius.
// Each invocation owns its fixed list segment. Stable source ordering avoids
// atomics and preserves reproducibility for lighting accumulation. Grid offsets
// and counts still have the same meaning as the engine's compact GPU list.
__global__ void cull_cluster_lights(const float* clusters,const float* lights,
    unsigned int* grid,unsigned int* indices,unsigned int* overflow,
    unsigned int cluster_count,unsigned int light_count,unsigned int capacity) {
    unsigned int tile=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(tile>=cluster_count)return;
    unsigned int count=0;
    for(unsigned int light=0;light<light_count;light++) {
        float distance=0.0f;
        for(unsigned int axis=0;axis<3;axis++) {
            float center=lights[light*20+axis];
            float closest=fminf(clusters[tile*8+4+axis],fmaxf(clusters[tile*8+axis],center));
            float delta=closest-center;distance+=delta*delta;
        }
        float radius=lights[light*20+19];
        if(distance<=radius*radius) {
            if(count<capacity)indices[tile*capacity+count]=light;
            count++;
        }
    }
    grid[tile*2]=tile*capacity;
    grid[tile*2+1]=count<capacity?count:capacity;
    // Preserve the required capacity, not merely a boolean. The host can grow
    // the list and redispatch before any shader consumes a truncated cluster.
    overflow[tile]=count>capacity?count:0u;
}

// Repack std430 PointLight into the renderer's common 16-word light record.
__global__ void pack_cluster_lights(const float* source,unsigned int* target,
    unsigned int light_count,unsigned int destination) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=light_count)return;
    for(unsigned int k=0;k<3;k++) {
        target[destination+i*16+k]=__float_as_uint(source[i*20+k]);
        target[destination+i*16+4+k]=__float_as_uint(source[i*20+8+k]);
        target[destination+i*16+8+k]=__float_as_uint(source[i*20+4+k]);
        target[destination+i*16+12+k]=__float_as_uint(source[i*20+12+k]);
    }
    target[destination+i*16+3]=__float_as_uint(source[i*20+16]);
    target[destination+i*16+7]=__float_as_uint(source[i*20+17]);
    target[destination+i*16+11]=__float_as_uint(source[i*20+18]);
    target[destination+i*16+15]=__float_as_uint(source[i*20+19]);
}
