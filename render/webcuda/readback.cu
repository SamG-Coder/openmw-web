// Crop, bilinear resize and byte conversion for screenshot/readback images.
// Output is packed RGBA8 in bottom-up row order for osg::Image consumers.
__device__ float capture_component(const float* source,unsigned int width,unsigned int height,int x,int y,unsigned int c) {
    if(x<0||y<0||x>=(int)width||y>=(int)height)return 0.0f;
    return source[((unsigned int)y*width+(unsigned int)x)*9u+c];
}
__global__ void capture_image(const float* source,unsigned int* pixels,
    unsigned int source_width,unsigned int source_height,unsigned int width,unsigned int height,
    int region_x,int region_y,unsigned int region_width,unsigned int region_height) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=width*height)return;
    float aspect=(float)width/(float)height;
    int left=(int)((float)region_width-(float)region_height*aspect)/2;
    int top=(int)((float)region_height-(float)region_width/aspect)/2;
    if(left<0)left=0;if(top<0)top=0;
    unsigned int crop_width=region_width-2u*(unsigned int)left,crop_height=region_height-2u*(unsigned int)top;
    float x=(float)left+((float)(i%width)+0.5f)*(float)crop_width/(float)width-0.5f;
    float y=(float)top+((float)(height-1u-i/width)+0.5f)*(float)crop_height/(float)height-0.5f;
    x=fminf((float)(region_width-1u-(unsigned int)left),fmaxf((float)left,x));
    y=fminf((float)(region_height-1u-(unsigned int)top),fmaxf((float)top,y));
    int local_x=(int)floorf(x),local_y=(int)floorf(y);
    float fx=x-(float)local_x,fy=y-(float)local_y;
    int x0=region_x+local_x,y0=(int)source_height-region_y-(int)region_height+local_y;
    int x1=local_x+1<(int)region_width?x0+1:x0;
    int y1=local_y+1<(int)region_height?y0+1:y0;
    unsigned int packed=0u;
    for(unsigned int c=0;c<4;c++) {
        float a=capture_component(source,source_width,source_height,x0,y0,c),b=capture_component(source,source_width,source_height,x1,y0,c);
        float d=capture_component(source,source_width,source_height,x0,y1,c),e=capture_component(source,source_width,source_height,x1,y1,c);
        float value=(a+(b-a)*fx)*(1.0f-fy)+(d+(e-d)*fx)*fy;
        unsigned int byte=(unsigned int)floorf(fminf(1.0f,fmaxf(0.0f,value))*255.0f+0.5f);
        packed|=byte<<(c*8u);
    }
    pixels[i]=packed;
}
