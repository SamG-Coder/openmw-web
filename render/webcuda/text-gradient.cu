// Bounds and bilinear text colors stay on the GPU. One disjoint glyph group
// per invocation; no CPU bounds reduction or vertex-color interpolation.
__global__ void shade_text_gradient(float* vertices,const unsigned int* ranges,const float* colors,unsigned int range_count) {
    unsigned int r=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(r>=range_count)return;
    unsigned int first=ranges[r*3u],count=ranges[r*3u+1u],p=ranges[r*3u+2u]*16u;
    if(count==0u)return;
    float minx=3.402823466e38f,miny=3.402823466e38f,maxx=1.175494351e-38f,maxy=1.175494351e-38f;
    for(unsigned int n=0;n<count;n++) {
        unsigned int v=(first+n)*10u;
        minx=fminf(minx,vertices[v]);maxx=fmaxf(maxx,vertices[v]);
        miny=fminf(miny,vertices[v+1u]);maxy=fmaxf(maxy,vertices[v+1u]);
    }
    for(unsigned int n=0;n<count;n++) {
        unsigned int v=(first+n)*10u;
        float x=maxx!=minx?(vertices[v]-minx)/(maxx-minx):0.0f;
        float y=maxy!=miny?(vertices[v+1u]-miny)/(maxy-miny):0.0f;
        for(unsigned int k=0;k<4;k++) {
            float left=colors[p+4u+k]*(1.0f-y)+colors[p+k]*y;
            float right=colors[p+8u+k]*(1.0f-y)+colors[p+12u+k]*y;
            vertices[v+4u+k]=left*(1.0f-x)+right*x;
        }
    }
}
