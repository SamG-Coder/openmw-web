// Drawable placement before shared model-view/projection. All placement math
// is authored here; the host only captures OSG layout and camera parameters.
__global__ void transform_local_vertices(float* vertices,const unsigned int* matrix_ids,const float* transforms,
                                        const float* matrices,unsigned int vertex_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=vertex_count)return;
    unsigned int id=matrix_ids[i],p=id*35u,m=id*32u;
    if(transforms[p]==0.0f)return;
    float source[4];for(unsigned int k=0;k<4;k++)source[k]=vertices[i*10u+k];
    if(transforms[p]==1.0f) {
        for(unsigned int row=0;row<4;row++) {
            float value=0.0f;
            for(unsigned int col=0;col<4;col++)value+=transforms[p+1u+col*4u+row]*source[col];
            vertices[i*10u+row]=value;
        }
        return;
    }
    unsigned int d=p+17u;
    // Invert the translation-free model-view, matching TextBase::computeMatrix.
    float work[32];
    for(unsigned int row=0;row<4;row++)for(unsigned int col=0;col<8;col++) {
        float value=col<4u?matrices[m+col*4u+row]:(col-4u==row?1.0f:0.0f);
        if(col==3u&&row<3u)value=0.0f;
        work[row*8u+col]=value;
    }
    unsigned int invertible=1u;
    for(unsigned int col=0;col<4;col++) {
        unsigned int pivot=col;
        for(unsigned int row=col+1u;row<4;row++)if(fabsf(work[row*8u+col])>fabsf(work[pivot*8u+col]))pivot=row;
        if(work[pivot*8u+col]==0.0f){invertible=0u;break;}
        for(unsigned int k=0;k<8;k++){float temp=work[col*8u+k];work[col*8u+k]=work[pivot*8u+k];work[pivot*8u+k]=temp;}
        float divisor=work[col*8u+col];
        for(unsigned int k=0;k<8;k++)work[col*8u+k]/=divisor;
        for(unsigned int row=0;row<4;row++)if(row!=col) {
            float factor=work[row*8u+col];
            for(unsigned int k=0;k<8;k++)work[row*8u+k]-=factor*work[col*8u+k];
        }
    }
    float inverse[16];
    for(unsigned int row=0;row<4;row++)for(unsigned int col=0;col<4;col++)
        inverse[col*4u+row]=invertible!=0u?work[row*8u+col+4u]:(row==col?1.0f:0.0f);
    float position[3];
    for(unsigned int k=0;k<3;k++)position[k]=source[k]-transforms[d+6u+k];
    // OSG quaternion rotation, applied before dynamic character scaling.
    float qx=transforms[d+12],qy=transforms[d+13],qz=transforms[d+14],qw=transforms[d+15];
    float tx=2.0f*(qy*position[2]-qz*position[1]);
    float ty=2.0f*(qz*position[0]-qx*position[2]);
    float tz=2.0f*(qx*position[1]-qy*position[0]);
    position[0]+=qw*tx+qy*tz-qz*ty;
    position[1]+=qw*ty+qz*tx-qx*tz;
    position[2]+=qw*tz+qx*ty-qy*tx;
    if(transforms[d]!=0.0f) {
        float projected[9];
        for(unsigned int point=0;point<3;point++) {
            float local[4],view[4],clip[4];
            for(unsigned int row=0;row<4;row++)local[row]=inverse[12u+row]+(point==0u?0.0f:inverse[(point-1u)*4u+row]);
            for(unsigned int k=0;k<3;k++)local[k]+=transforms[d+9u+k]*local[3];
            for(unsigned int row=0;row<4;row++) {
                view[row]=0.0f;for(unsigned int col=0;col<4;col++)view[row]+=matrices[m+col*4u+row]*local[col];
            }
            for(unsigned int row=0;row<4;row++) {
                clip[row]=0.0f;for(unsigned int col=0;col<4;col++)clip[row]+=matrices[m+16u+col*4u+row]*view[col];
            }
            float reciprocal=clip[3]!=0.0f?1.0f/clip[3]:1.0f;
            for(unsigned int k=0;k<3;k++)projected[point*3u+k]=clip[k]*reciprocal*(k<2u?transforms[d+16u+k]*0.5f:1.0f);
        }
        float lx=0.0f,ly=0.0f;
        for(unsigned int k=0;k<3;k++) {float x=projected[3u+k]-projected[k],y=projected[6u+k]-projected[k];lx+=x*x;ly+=y*y;}
        float sx=lx>0.0f?1.0f/sqrtf(lx):1.0f,sy=ly>0.0f?1.0f/sqrtf(ly):1.0f;
        if(transforms[d+2]!=0.0f) {
            position[0]*=transforms[d+3]/transforms[d+4];position[1]*=transforms[d+3];position[2]*=transforms[d+3];
        }
        if(transforms[d]==1.0f){position[0]*=sx;position[1]*=sy;position[2]*=sx;}
        else {
            float pixelHeight=transforms[d+3]/sy;if(pixelHeight==0.0f)pixelHeight=1.0f;
            if(pixelHeight>transforms[d+5])for(unsigned int k=0;k<3;k++)position[k]*=transforms[d+5]/pixelHeight;
        }
    }
    if(transforms[d+1]!=0.0f) {
        float rotated[3];
        for(unsigned int row=0;row<3;row++){rotated[row]=inverse[12u+row];for(unsigned int col=0;col<3;col++)rotated[row]+=inverse[col*4u+row]*position[col];}
        for(unsigned int k=0;k<3;k++)position[k]=rotated[k];
    }
    for(unsigned int k=0;k<3;k++)vertices[i*10u+k]=position[k]+transforms[d+9u+k];
    vertices[i*10u+3u]=1.0f;
}
