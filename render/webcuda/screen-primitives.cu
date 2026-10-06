// SPDX-License-Identifier: GPL-3.0-or-later
// Expand ordinary point/line geometry after deformation and vertex transforms.
// Inputs refer only to original vertices; each record owns four output vertices.
__global__ void expand_screen_primitives(float* vertices,float* attributes,const unsigned int* records,unsigned int* lighting_origins,float* fixed_lighting,
    unsigned int primitive_count,unsigned int width,unsigned int height,unsigned int track_lighting,unsigned int fixed_enabled,unsigned int sample_count,unsigned int source_point_fade_offset) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=primitive_count)return;
    unsigned int r=i*12u,a=records[r],b=records[r+1u],output=records[r+2u],point=records[r+3u];
    float size=__uint_as_float(records[r+4u]);
    float start[4],finish[4];
    for(unsigned int k=0;k<4;k++){start[k]=vertices[a*10u+k];finish[k]=vertices[b*10u+k];}
    float begin=0.0f,end=1.0f,alpha=1.0f,smoothRadius=0.0f;
    unsigned int visible=1u;
    for(unsigned int plane=0;plane<6;plane++) {
        if(plane>=4u&&(records[r+11u]&32u)!=0u)continue;
        unsigned int axis=plane/2;float sign=(plane%2)==0?1.0f:-1.0f;
        float p=start[3]+sign*start[axis],q=finish[3]+sign*finish[axis];
        if(plane==4u&&(records[r+11u]&512u)!=0u){p=start[2];q=finish[2];}
        if(p<0.0f&&q<0.0f)visible=0u;
        else if(p<0.0f)begin=fmaxf(begin,p/(p-q));
        else if(q<0.0f)end=fminf(end,p/(p-q));
    }
    float first[4],last[4];
    for(unsigned int k=0;k<4;k++){first[k]=start[k]+begin*(finish[k]-start[k]);last[k]=start[k]+end*(finish[k]-start[k]);}
    if(end<begin||first[3]<=0.0f||last[3]<=0.0f)visible=0u;
    float x=0.0f,y=0.0f,nx=0.0f,ny=0.0f,ex=0.0f,ey=0.0f;
    if(visible!=0u) {
        if(point!=0u) {
            float distance=0.0f;
            for(unsigned int k=0;k<3;k++)distance+=attributes[a*34u+k]*attributes[a*34u+k];
            distance=sqrtf(distance);
            float attenuation=__uint_as_float(records[r+8u])+__uint_as_float(records[r+9u])*distance
                +__uint_as_float(records[r+10u])*distance*distance;
            size/=sqrtf(fmaxf(0.000000000001f,attenuation));
            size=fminf(__uint_as_float(records[r+6u]),fmaxf(__uint_as_float(records[r+5u]),size));
            float fade=__uint_as_float(records[r+7u]);
            unsigned int multisample=sample_count>1u&&(records[r+11u]&64u)!=0u?1u:0u;
            if(multisample!=0u&&fade>0.0f&&size<fade){float ratio=size/fade;alpha=ratio*ratio;size=fade;}
            unsigned int pointStyle=records[r+11u]&384u;
            if(multisample==0u&&pointStyle==128u)smoothRadius=size*0.5f;
            if(multisample==0u&&pointStyle==0u)size=fmaxf(1.0f,floorf(size+0.5f));
            float odd=size-2.0f*floorf(size*0.5f);
            x=(first[0]/first[3]*0.5f+0.5f)*(float)width;
            y=(first[1]/first[3]*0.5f+0.5f)*(float)height;
            if(multisample==0u&&pointStyle==0u) {
                x=odd>0.0f?floorf(x)+0.5f:floorf(x+0.5f);
                y=odd>0.0f?floorf(y)+0.5f:floorf(y+0.5f);
            }
        } else {
            float support=fmaxf(size,fmaxf(1.0f,floorf(size+0.5f)))+2.0f;
            float dx=(last[0]/last[3]-first[0]/first[3])*(float)width;
            float dy=(last[1]/last[3]-first[1]/first[3])*(float)height;
            float length=sqrtf(dx*dx+dy*dy);
            if(length<=0.000001f)visible=0u;
            else {nx=-dy/length*support/(float)width;ny=dx/length*support/(float)height;
                ex=dx/length*support/(float)width;ey=dy/length*support/(float)height;}
        }
    }
    for(unsigned int corner=0;corner<4;corner++) {
        unsigned int v=output+corner;
        float t=(corner>=2u?end:begin),side=(corner==0u||corner==3u)?-1.0f:1.0f;
        if(fixed_enabled!=0)for(unsigned int k=0;k<16;k++)fixed_lighting[v*16+k]=fixed_lighting[a*16+k]+t*(fixed_lighting[b*16+k]-fixed_lighting[a*16+k]);
        // Two-sided lighting applies to polygons, not the point/line that
        // this quad represents. Tag the back slot for flat provoking assembly.
        if(fixed_enabled!=0&&fixed_lighting[v*16+7]>0.5f) {
            for(unsigned int k=0;k<7;k++)fixed_lighting[v*16+8+k]=fixed_lighting[v*16+k];
            fixed_lighting[v*16+15]=2.0f;
        }
        if(track_lighting!=0){lighting_origins[v*3]=a;lighting_origins[v*3+1]=b;lighting_origins[v*3+2]=__float_as_uint(t);}
        for(unsigned int k=0;k<10;k++)vertices[v*10u+k]=vertices[a*10u+k]+t*(vertices[b*10u+k]-vertices[a*10u+k]);
        for(unsigned int k=0;k<34;k++)attributes[v*34u+k]=attributes[a*34u+k]+t*(attributes[b*34u+k]-attributes[a*34u+k]);
        if(visible==0u) {for(unsigned int k=0;k<4;k++)vertices[v*10u+k]=0.0f;}
        else if(point!=0u) {
            float horizontal=corner>=2u?1.0f:-1.0f,w=vertices[v*10u+3u];
            vertices[v*10u]=((x+horizontal*(size*0.5f+(smoothRadius>0.0f?0.5f:0.0f)))/(float)width*2.0f-1.0f)*w;
            vertices[v*10u+1u]=((y+side*(size*0.5f+(smoothRadius>0.0f?0.5f:0.0f)))/(float)height*2.0f-1.0f)*w;
            unsigned int metadata=source_point_fade_offset+v*12u;
            attributes[metadata]=alpha;
            attributes[metadata+1u]=horizontal*(size*0.5f+(smoothRadius>0.0f?0.5f:0.0f));
            attributes[metadata+2u]=side*(size*0.5f+(smoothRadius>0.0f?0.5f:0.0f));
            // Negative radius tags sprite metadata; positive radius tags smoothing.
            attributes[metadata+3u]=(records[r+11u]&256u)!=0u?-size*0.5f:smoothRadius;
            // Point-sprite replacement follows texture transformation, as in
            // the raster stage. Origin defaults to upper-left; bit4 flips it.
            unsigned int sprite=records[r+11u];
            float u=horizontal*0.5f+0.5f;
            float textureV=(sprite&16u)!=0u?side*0.5f+0.5f:0.5f-side*0.5f;
            for(unsigned int unit=0;unit<4;unit++)if((sprite&(1u<<unit))!=0u) {
                unsigned int coord=unit==0u?16u:10u+(unit-1u)*2u;
                attributes[v*34u+coord]=u;attributes[v*34u+coord+1u]=textureV;
                attributes[v*34u+26u+unit*2u]=0.0f;attributes[v*34u+27u+unit*2u]=1.0f;
                if(unit==0u){vertices[v*10u+8u]=u;vertices[v*10u+9u]=textureV;}
            }
        } else {
            // Preserve the clipped centreline independently of the support quad.
            // Coverage can then recover original endpoint positions and w after
            // homogeneous clipping and viewport mapping of the quad itself.
            unsigned int metadata=source_point_fade_offset+v*12u;
            attributes[metadata+1u]=corner>=2u?1.0f:0.0f;
            attributes[metadata+2u]=size;
            for(unsigned int k=0u;k<4u;k++) {
                attributes[metadata+4u+k]=first[k];
                attributes[metadata+8u+k]=last[k];
            }
            vertices[v*10u]+=(side*nx+(corner>=2u?ex:-ex))*vertices[v*10u+3u];
            vertices[v*10u+1u]+=(side*ny+(corner>=2u?ey:-ey))*vertices[v*10u+3u];
        }
    }
}
