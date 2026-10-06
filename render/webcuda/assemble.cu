// SPDX-License-Identifier: GPL-3.0-or-later
// Packed material vertices: position xyzw, color RGBA, UV. Each draw matrix
// record holds column-major model-view then projection (32 floats).
__global__ void transform_material(const float* source, const float* matrices,
                                  const unsigned int* matrix_ids, float* vertices,
                                  unsigned int vertex_count) {
    unsigned int i = (blockIdx.x + blockIdx.y * gridDim.x) * blockDim.x + threadIdx.x;
    if (i >= vertex_count) return;
    unsigned int m = matrix_ids[i] * 32;
    float view[4];
    for (unsigned int row = 0; row < 4; row++) {
        view[row] = 0.0f;
        for (unsigned int col = 0; col < 4; col++)
            view[row] += matrices[m + col*4 + row] * source[i*10+col];
    }
    for (unsigned int row = 0; row < 4; row++) {
        float sum = 0.0f;
        for (unsigned int col = 0; col < 4; col++) sum += matrices[m+16+col*4+row] * view[col];
        vertices[i*10+row] = sum;
    }
    for (unsigned int k = 4; k < 10; k++) vertices[i*10+k] = source[i*10+k];
}

// Reconstruct attributes at newly clipped vertices from the original-vertex
__global__ void transform_uv(float* vertices, const float* uv_matrices,
    const unsigned int* matrix_ids, unsigned int vertex_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=vertex_count)return;
    unsigned int m=matrix_ids[i]*16;
    float u=vertices[i*10+8],v=vertices[i*10+9];
    vertices[i*10+8]=uv_matrices[m]*u+uv_matrices[m+4]*v+uv_matrices[m+12];
    vertices[i*10+9]=uv_matrices[m+1]*u+uv_matrices[m+5]*v+uv_matrices[m+13];
}

// Reconstruct attributes at newly clipped vertices from the original-vertex
// weights emitted by clip_triangles. Fixed seven output slots per input triangle
// keep order stable. Invalid slots are w=0 so binning rejects them explicitly.
__global__ void assemble_material(const float* source, const unsigned int* triangles,
                                 const float* positions, const float* weights,
                                 const unsigned int* valid, float* vertices,
                                 unsigned int* output_triangles,const unsigned int* flat_colors, unsigned int slot_count) {
    unsigned int slot = (blockIdx.x + blockIdx.y * gridDim.x) * blockDim.x + threadIdx.x;
    if (slot >= slot_count) return;
    unsigned int original = slot / 7;
    output_triangles[slot*4+3] = triangles[original*4+3];
    for (unsigned int v = 0; v < 3; v++) {
        unsigned int dst = (slot*3+v)*10;
        output_triangles[slot*4+v] = slot*3+v;
        for (unsigned int k = 0; k < 10; k++) vertices[dst+k] = 0.0f;
        if (valid[slot] == 0) continue;
        for (unsigned int k = 0; k < 4; k++) vertices[dst+k] = positions[slot*12+v*4+k];
        for (unsigned int k = 4; k < 10; k++) {
            float value = 0.0f;
            for (unsigned int corner = 0; corner < 3; corner++)
                value += weights[slot*12+v*4+corner] * source[triangles[original*4+corner]*10+k];
            if(k<8u&&flat_colors[original]!=0xffffffffu)value=source[flat_colors[original]*10u+k];
            vertices[dst+k] = value;
        }
    }
}

// Apply the window viewport only after homogeneous frustum clipping. Keeping
// w unchanged preserves perspective interpolation and clip-depth semantics.
__global__ void map_viewport(float* vertices,float* attributes,unsigned int point_fade_offset,unsigned int vertex_count,
    unsigned int width,unsigned int height,int viewport_x,int viewport_y,
    unsigned int viewport_width,unsigned int viewport_height) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=vertex_count)return;
    unsigned int v=i*10;float w=vertices[v+3];
    vertices[v]=vertices[v]*(float)viewport_width/(float)width
        +w*((2.0f*(float)viewport_x+(float)viewport_width)/(float)width-1.0f);
    vertices[v+1]=vertices[v+1]*(float)viewport_height/(float)height
        +w*((2.0f*(float)viewport_y+(float)viewport_height)/(float)height-1.0f);
    // Centreline endpoint records are constant over each expanded line quad.
    // Map them with the same affine homogeneous transform as its support mesh.
    unsigned int metadata=point_fade_offset+i*12u;
    if(attributes[metadata+7u]>0.0f&&attributes[metadata+11u]>0.0f)
        for(unsigned int endpoint=0u;endpoint<2u;endpoint++) {
            unsigned int base=metadata+4u+endpoint*4u;
            float endpointW=attributes[base+3u];
            attributes[base]=attributes[base]*(float)viewport_width/(float)width
                +endpointW*((2.0f*(float)viewport_x+(float)viewport_width)/(float)width-1.0f);
            attributes[base+1u]=attributes[base+1u]*(float)viewport_height/(float)height
                +endpointW*((2.0f*(float)viewport_y+(float)viewport_height)/(float)height-1.0f);
        }
}
