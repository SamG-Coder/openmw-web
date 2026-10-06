// SPDX-License-Identifier: GPL-3.0-or-later
// Descriptor12: grid XYZ, near/far, screen WH, light count, grid/list/light
// atlas bases, capacity. Float-valued fields are transported as uint bits.
__device__ unsigned int cluster_cell(const unsigned int* texels,unsigned int descriptor,
    float screen_x,float screen_y,float view_z) {
    if(descriptor==0)return 0xffffffffu;
    float near=__uint_as_float(texels[descriptor+3]),far=__uint_as_float(texels[descriptor+4]);
    float z=fmaxf(fabsf(view_z),0.000000000001f);
    float tx=screen_x/__uint_as_float(texels[descriptor+5])*(float)texels[descriptor];
    float ty=screen_y/__uint_as_float(texels[descriptor+6])*(float)texels[descriptor+1];
    float tz=log2f(z/near)/log2f(far/near)*(float)texels[descriptor+2];
    // Undefined out-of-grid SSBO accesses in the GL path become an empty list.
    if(tx<0.0f||ty<0.0f||tz<0.0f||tx>=(float)texels[descriptor]
        ||ty>=(float)texels[descriptor+1]||tz>=(float)texels[descriptor+2])return 0xffffffffu;
    return (unsigned int)tx+(unsigned int)ty*texels[descriptor]
        +(unsigned int)tz*texels[descriptor]*texels[descriptor+1];
}
__device__ unsigned int cluster_count(const unsigned int* texels,unsigned int descriptor,unsigned int cell) {
    return cell==0xffffffffu?0u:texels[texels[descriptor+8]+cell*2+1];
}
__device__ unsigned int cluster_light(const unsigned int* texels,unsigned int descriptor,unsigned int cell,unsigned int ordinal) {
    unsigned int first=texels[texels[descriptor+8]+cell*2];
    unsigned int index=texels[texels[descriptor+9]+first+ordinal];
    return texels[descriptor+10]+index*16;
}
__device__ float cluster_distance_fade(const unsigned int* texels,unsigned int descriptor,float view_z,float radius) {
    float far=__uint_as_float(texels[descriptor+4]);
    float t=fminf(1.0f,fmaxf(0.0f,(-view_z-(far-radius))/fmaxf(radius,0.000000000001f)));
    float fade=1.0f-t*t;return fade*fade;
}
