// SPDX-License-Identifier: GPL-3.0-or-later
// Included in material.cu after texture sampling helpers. Water payload at
// object[321]: five descriptors, parameters, node/player positions and matrices.
__device__ float water_sample(const unsigned int* texels,unsigned int descriptor,float u,float v,unsigned int channel) {
    return sample_mipped(texels,texels[descriptor],texels[descriptor+1],texels[descriptor+2],u,v,0.0f,texels[descriptor+3],channel);
}
__device__ float water_unit(float x) {return fminf(1.0f,fmaxf(0.0f,x));}
__device__ float water_smooth(float a,float b,float x) {float t=water_unit((x-a)/(b-a));return t*t*(3.0f-2.0f*t);}
__device__ float water_depth(float depth,float near,float far,unsigned int reverse) {
    if(reverse!=0)depth=1.0f-depth;
    return near*far/fmaxf(0.000001f,far-depth*(far-near));
}
__device__ void water_normalize(float* v) {
    float length=sqrtf(fmaxf(0.000000000001f,v[0]*v[0]+v[1]*v[1]+v[2]*v[2]));
    for(unsigned int k=0;k<3;k++)v[k]/=length;
}
__device__ float water_fract(float x) {return x-floorf(x);}
__device__ float water_scramble(float x,float power) {return water_fract(render_power(water_fract(x)*3.0f+1.0f,power));}
__device__ float water_blip(float x) {float n=fmaxf(0.0f,1.0f-x*x);return n*n*n;}
__device__ void water_rain_circle(float x,float y,float cellX,float cellY,float time,unsigned int detail,float* output) {
    for(unsigned int k=0;k<4;k++)output[k]=0.0f;
    float seed=water_fract(floorf(time)/1000.0f);
    float cx=cellX*cellY/8.0f+cellY*0.3f+cellX*0.2f,cy=cellX*cellY/14.0f+cellY*0.5f+cellX*0.7f;
    cx=water_fract(cx*(water_scramble(water_scramble(seed+cx/1000.0f,4.0f),3.0f)+1.0f));
    cy=water_fract(cy*(water_scramble(water_scramble(seed+cy/1000.0f,3.5f),3.0f)+1.0f));
    float dx=x-(0.5f+0.3f*(2.0f*cx-1.0f)),dy=y-(0.5f+0.3f*(2.0f*cy-1.0f));
    float distance=sqrtf(dx*dx+dy*dy),phase=water_fract(time),ring=(phase-distance/0.2f)*6.0f-1.0f;
    if(ring < -1.0f||ring>(detail!=0?1.0f:0.5f))return;
    float energy=1.0f-phase,height=water_blip(ring*2.0f+0.5f);
    output[3]=height*energy*energy;
    if(detail==0)return;
    if(distance>1.0f){dx/=distance;dy/=distance;}
    float t=fminf(1.0f,fmaxf(-1.0f,ring)),n=t*t-1.0f,derivative=-6.0f*t*n*n;
    output[0]=-dx*derivative*5.0f*energy*energy;output[1]=-dy*derivative*5.0f*energy*energy;output[2]=0.5f;
    water_normalize(output);
    float limit=water_blip(fminf(0.0f,ring));
    for(unsigned int k=0;k<3;k++)output[k]*=energy*limit;
    output[2]*=limit;
}
__device__ void water_rain(float u,float v,float time,unsigned int detail,float* output) {
    float x=u*10.0f,y=v*10.0f,cx=floorf(x),cy=floorf(y);
    float adjusted=time*1.2f+water_fract(cx*cy/(cx+cy+0.1f));
    for(unsigned int k=0;k<4;k++)output[k]=0.0f;
    unsigned int rings=detail!=0?4:1;
    for(unsigned int ring=0;ring<rings;ring++) {
        float value[4];water_rain_circle(water_fract(x),water_fract(y),cx,cy,adjusted-(float)ring/6.0f,detail,value);
        float weight=ring==0?1.0f:(ring==1?0.5f:(ring==2?0.25f:0.125f));
        for(unsigned int k=0;k<3;k++)output[k]+=value[k]*weight*((k<2&&ring%2!=0)?-1.0f:1.0f);
        if(ring==0)output[3]+=value[3]*1.5f;
        if(ring==2)output[3]+=value[3]*0.1875f;
    }
}
__device__ void water_rain_combined(float u,float v,float time,unsigned int detail,float* output) {
    for(unsigned int k=0;k<4;k++)output[k]=0.0f;
    unsigned int layers=detail==2?5:2;
    for(unsigned int layer=0;layer<layers;layer++) {
        float x=u,y=v,value[4];
        if(layer==1){x=u*0.4f-v*0.7f+1.2f;y=u*0.7f+v*0.4f+3.0f;}
        if(layer==2){x=u*0.75f+3.7f;y=v*0.75f+18.9f;}
        if(layer==3){x=u*0.9f+5.7f;y=v*0.9f+30.1f;}
        if(layer==4){x=u+10.5f;y=v+5.7f;}
        water_rain(x,y,time,detail,value);
        for(unsigned int k=0;k<4;k++)output[k]+=value[k];
    }
}
__device__ void water_wave(const unsigned int* texels,unsigned int descriptor,float u,float v,
    float scale,float speed,float time,float tx,float ty,const float* previous,float* output) {
    float denominator=fabsf(previous[2])>0.000001f?previous[2]:1.0f;
    u=u*75.0f*scale+0.5f*time*0.2f*speed-previous[0]/denominator*0.05f+time*tx;
    v=v*75.0f*scale-0.8f*time*0.2f*speed-previous[1]/denominator*0.05f+time*ty;
    for(unsigned int k=0;k<3;k++)output[k]=2.0f*water_sample(texels,descriptor,u,v,k)-1.0f;
}
__device__ void water_wave_chain(const unsigned int* texels,unsigned int descriptor,float u,float v,float time,
    float dudx,float dvdx,float dudy,float dvdy,float* waves) {
    float previous[9];for(unsigned int k=0;k<9;k++)previous[k]=0.0f;
    for(unsigned int layer=0;layer<6;layer++) {
        float scale=layer==0?0.05f:(layer==1?0.1f:(layer==2?0.25f:(layer==3?0.5f:(layer==4?1.0f:2.0f))));
        float speed=layer==0?0.04f:(layer==1?0.08f:(layer==2?0.07f:(layer==3?0.09f:(layer==4?0.4f:0.7f))));
        float tx=layer==0?-0.015f:(layer==1?0.02f:(layer==2?-0.04f:(layer==3?0.03f:(layer==4?-0.02f:0.1f))));
        float ty=layer==0?-0.005f:(layer==1?0.015f:(layer==2?-0.03f:(layer==3?0.04f:(layer==4?0.1f:-0.06f))));
        float coords[6];
        for(unsigned int sample=0;sample<3;sample++) {
            float denominator=fabsf(previous[sample*3+2])>0.000001f?previous[sample*3+2]:1.0f;
            coords[sample*2]=(u+(sample==1?dudx:(sample==2?dudy:0.0f)))*75.0f*scale+time*(0.1f*speed+tx)-previous[sample*3]/denominator*0.05f;
            coords[sample*2+1]=(v+(sample==1?dvdx:(sample==2?dvdy:0.0f)))*75.0f*scale+time*(-0.16f*speed+ty)-previous[sample*3+1]/denominator*0.05f;
        }
        float dx=(coords[2]-coords[0])*(float)texels[descriptor+1],dy=(coords[3]-coords[1])*(float)texels[descriptor+2];
        float ex=(coords[4]-coords[0])*(float)texels[descriptor+1],ey=(coords[5]-coords[1])*(float)texels[descriptor+2];
        float lod=0.5f*log2f(fmaxf(0.00000001f,fmaxf(dx*dx+dy*dy,ex*ex+ey*ey)));
        for(unsigned int sample=0;sample<3;sample++)for(unsigned int k=0;k<3;k++)
            previous[sample*3+k]=2.0f*sample_mipped(texels,texels[descriptor],texels[descriptor+1],texels[descriptor+2],coords[sample*2],coords[sample*2+1],lod,texels[descriptor+3],k)-1.0f;
        for(unsigned int k=0;k<3;k++)waves[layer*3+k]=previous[k];
    }
}
__device__ void shade_water(const unsigned int* texels,unsigned int object,const float* viewPosition,const float* viewFootprint,
    float shadow,float sx,float sy,float depth,float linearDepth,float* color,float* viewNormal,
    unsigned int cluster,float clusterScreenX,float clusterScreenY) {
    unsigned int p=object+texels[object+321],flags=texels[p+24],reverse=texels[object+4]&65536;
    float position[3],camera[3],sun[3],eye[3];
    for(unsigned int row=0;row<3;row++) {
        camera[row]=__uint_as_float(texels[p+52+row]);position[row]=camera[row];sun[row]=0.0f;
        for(unsigned int col=0;col<3;col++) {
            position[row]+=__uint_as_float(texels[p+40+col*4+row])*viewPosition[col];
            sun[row]+=__uint_as_float(texels[p+40+col*4+row])*__uint_as_float(texels[object+24+col]);
        }
        eye[row]=position[row]-camera[row];
    }
    water_normalize(eye);water_normalize(sun);
    float time=__uint_as_float(texels[p+20]),rain=__uint_as_float(texels[p+23]);
    float u=(position[0]+__uint_as_float(texels[p+32]))*3.0f/40960.0f;
    float v=(position[1]+__uint_as_float(texels[p+33]))*3.0f/40960.0f;
    float waves[18],footprint[4];
    for(unsigned int axis=0;axis<2;axis++)for(unsigned int row=0;row<2;row++) {
        footprint[axis*2+row]=0.0f;
        for(unsigned int col=0;col<3;col++)footprint[axis*2+row]+=__uint_as_float(texels[p+40+col*4+row])*viewFootprint[axis*3+col]*3.0f/40960.0f;
    }
    water_wave_chain(texels,p,u,v,time,footprint[0],footprint[1],footprint[2],footprint[3],waves);
    float extent=__uint_as_float(texels[p+26])*__uint_as_float(texels[p+27]);
    float ru=(position[0]+__uint_as_float(texels[p+32])-__uint_as_float(texels[p+36]))/extent+0.5f;
    float rv=(position[1]+__uint_as_float(texels[p+33])-__uint_as_float(texels[p+37]))/extent+0.5f;
    float distance=sqrtf((ru-0.5f)*(ru-0.5f)+(rv-0.5f)*(rv-0.5f));
    float blend=water_smooth(0.001f,0.02f,distance)*(1.0f-water_smooth(0.3f,0.4f,distance));
    float ripple[3],normal[3],specNormal[3];
    ripple[0]=2.0f*water_sample(texels,p+16,ru,rv,2)*blend;ripple[1]=2.0f*water_sample(texels,p+16,ru,rv,3)*blend;ripple[2]=0.0f;
    float rainRipple[4];for(unsigned int k=0;k<4;k++)rainRipple[k]=0.0f;
    if(rain>0.01f)water_rain_combined(position[0]/1000.0f,position[1]/1000.0f,time,texels[p+28],rainRipple);
    for(unsigned int k=0;k<4;k++)rainRipple[k]*=water_unit(rain);
    for(unsigned int k=0;k<3;k++)ripple[k]+=rainRipple[k]*10.0f;
    float bump=0.5f+2.0f*rain;
    for(unsigned int k=0;k<3;k++) {
        normal[k]=(waves[k]+waves[3+k])*0.1f+(waves[6+k]+waves[9+k])*(0.1f+rain*0.1f)+(waves[12+k]+waves[15+k])*(0.1f+rain*0.2f)+ripple[k];
        if(k<2)normal[k]*=-bump;
    }
    water_normalize(normal);
    float dot=0.0f;for(unsigned int k=0;k<3;k++)dot+=eye[k]*normal[k];dot=fabsf(dot);
    float eta=camera[2]>0.0f?1.333f:1.0f/1.333f,g=eta*eta-1.0f+dot*dot,fresnel=1.0f;
    if(g>0.0f){g=sqrtf(g);float a=(g-dot)/(g+dot),b=(dot*(g+dot)-1.0f)/(dot*(g-dot)+1.0f);fresnel=water_unit(0.5f*a*a*(1.0f+b*b));}
    for(unsigned int k=0;k<3;k++)specNormal[k]=normal[k]*(k<2?5.0f:1.0f);water_normalize(specNormal);
    dot=0.0f;for(unsigned int k=0;k<3;k++)dot+=eye[k]*specNormal[k];
    float phong=0.0f;for(unsigned int k=0;k<3;k++)phong+=(eye[k]-2.0f*dot*specNormal[k])*sun[k];
    float sunAlpha=fminf(1.0f,__uint_as_float(texels[object+39])/0.15f);
    float specular=water_unit(render_power(atan2f(fmaxf(phong,0.0f)*1.55f,1.0f),256.0f)*1.5f)*shadow*sunAlpha;
    float sunFade=0.0f;for(unsigned int k=0;k<3;k++){float a=__uint_as_float(texels[object+28+k]);sunFade+=a*a;}sunFade=sqrtf(sunFade);
    float ox=normal[0]*0.1f,oy=normal[1]*0.1f;
    float near=__uint_as_float(texels[p+21]),far=__uint_as_float(texels[p+22]);
    float surface=water_depth(depth,near,far,reverse),realDepth=0.0f,distorted=0.0f;
    if((flags&1)!=0) {
        realDepth=water_depth(water_sample(texels,p+12,sx,sy,0),near,far,reverse)-surface;
        distorted=fmaxf(0.0f,water_depth(water_sample(texels,p+12,sx-ox,sy-oy,0),near,far,reverse)-surface);
        float fade=water_unit(realDepth/300.0f);ox*=fade;oy*=fade;
    }
    float reflection[3];
    for(unsigned int k=0;k<3;k++) {
        reflection[k]=water_sample(texels,p+4,sx+ox,sy+oy,k);
        if((flags&8)!=0) {
            reflection[k]*=0.4f;float radius=__uint_as_float(texels[p+25]);
            for(unsigned int tap=0;tap<4;tap++)reflection[k]+=0.15f*water_sample(texels,p+4,sx+ox+(tap%2==0?-radius:radius),sy+oy+(tap<2?-radius:radius),k);
        }
    }
    if(camera[2]>0.0f&&realDepth<=3750.0f&&distorted>3750.0f){ox=0.0f;oy=0.0f;}
    float transparency=water_unit(fresnel*6.0f+specular);
    if((flags&1)!=0) {
        distorted=fmaxf(0.0f,water_depth(water_sample(texels,p+12,sx-ox,sy-oy,0),near,far,reverse)-surface);
        distorted=distorted+(realDepth-distorted)*fminf(surface/3000.0f,1.0f);
    }
    float scatterNormal[3];
    for(unsigned int k=0;k<3;k++) {
        scatterNormal[k]=(waves[k]+waves[3+k])*0.05f+(waves[6+k]+waves[9+k])*(0.1f+rain*0.1f)*0.2f+(waves[12+k]+waves[15+k])*(0.1f+rain*0.2f)*0.1f+ripple[k];
        if(k<2)scatterNormal[k]*=-bump;
    }
    water_normalize(scatterNormal);
    float scatterDot=0.0f;for(unsigned int k=0;k<3;k++)scatterDot+=sun[k]*scatterNormal[k];
    float scatterAngle=0.0f;for(unsigned int k=0;k<3;k++)scatterAngle+=(sun[k]-2.0f*scatterDot*scatterNormal[k])*eye[k];
    float scatter=fmaxf(scatterDot*0.7f+0.3f,0.0f)*fmaxf(scatterAngle*2.0f-1.2f,0.0f)*0.3f*sunFade*sunAlpha*fmaxf(1.0f-expf(-sun[2]),0.0f);
    float shore=1.0f;
    if((flags&5)==5) {
        float waveA[3],waveB[3],previousA[3],previousB[3];
        for(unsigned int k=0;k<3;k++){previousA[k]=waves[9+k];previousB[k]=waves[12+k];}
        water_wave(texels,p,u,v,2.0f,2.7f,-time,0.05f,0.1f,previousA,waveA);
        water_wave(texels,p,u,v,2.0f,2.7f,time,0.04f,-0.13f,previousB,waveB);
        float viewFactor=fabsf(eye[2])*0.8f+0.2f;
        shore=(realDepth*viewFactor-(waves[6]+rain*(waveA[0]+waveB[0])*0.5f+0.15f)*8.0f)*fminf(1.0f,1000.0f/fmaxf(surface,0.000001f))*viewFactor;
        shore=water_unit(shore+(1.0f-shore)*water_unit(linearDepth/6200.0f));
    }
    float pointSpecular[3];for(unsigned int k=0;k<3;k++)pointSpecular[k]=0.0f;
    if(cluster!=0) {
        float viewSpecNormal[3],viewEye[3];
        for(unsigned int row=0;row<3;row++) {
            viewSpecNormal[row]=0.0f;viewEye[row]=viewPosition[row];
            for(unsigned int col=0;col<3;col++)viewSpecNormal[row]+=__uint_as_float(texels[p+40+row*4+col])*specNormal[col];
        }
        water_normalize(viewSpecNormal);water_normalize(viewEye);
        unsigned int cell=cluster_cell(texels,cluster,clusterScreenX,clusterScreenY,viewPosition[2]);
        unsigned int count=cluster_count(texels,cluster,cell);
        for(unsigned int light=0;light<count;light++) {
            unsigned int record=cluster_light(texels,cluster,cell,light);
            float direction[3],distance=0.0f;
            for(unsigned int k=0;k<3;k++){direction[k]=__uint_as_float(texels[record+k])-viewPosition[k];distance+=direction[k]*direction[k];}
            distance=sqrtf(fmaxf(distance,0.000000000001f));
            float radius=__uint_as_float(texels[record+15]);
            float fade=water_unit((distance/fmaxf(radius,0.000000000001f)-0.75f)/0.25f);fade=1.0f-fade*fade;
            float denominator=__uint_as_float(texels[record+3])+__uint_as_float(texels[record+7])*distance
                +__uint_as_float(texels[record+11])*distance*distance;
            float attenuation=fade*fade*cluster_distance_fade(texels,cluster,viewPosition[2],radius)/fmaxf(denominator,0.000000000001f);
            float lambert=0.0f,halfVector[3];
            for(unsigned int k=0;k<3;k++){direction[k]/=distance;lambert+=viewSpecNormal[k]*direction[k];halfVector[k]=direction[k]-viewEye[k];}
            water_normalize(halfVector);float spec=0.0f;
            if(lambert>0.0f){for(unsigned int k=0;k<3;k++)spec+=viewSpecNormal[k]*halfVector[k];spec=render_power(fmaxf(spec,0.0f),50.0f);}
            for(unsigned int k=0;k<3;k++)pointSpecular[k]+=1.5f*__uint_as_float(texels[record+12+k])*spec*attenuation;
        }
    }
    for(unsigned int k=0;k<3;k++) {
        float waterColor=(k==0?0.090195f:(k==1?0.115685f:0.12745f))*sunFade;
        float rawRefraction=0.0f;
        if((flags&1)!=0) {
            float refraction=water_sample(texels,p+8,sx-ox,sy-oy,k);
            rawRefraction=refraction;
            if(camera[2]<0.0f)refraction=water_unit(refraction*1.5f);
            else {float correction=sqrtf(1.09f),factor=water_unit(0.0225f/(-0.5f*correction+0.5f-distorted/2500.0f)+0.5f*correction+0.5f);refraction+=(waterColor-refraction)*factor;}
            if((flags&2)!=0) {
                float tint=k==0?0.0f:(k==1?1.0f:0.95f),warm=k==0?1.0f:(k==1?0.4f:0.0f),extinction=k==0?0.45f:(k==1?0.55f:0.68f);
                float scatterColor=tint*(warm+(1.0f-warm)*fmaxf(1.0f-expf(-sun[2]*extinction),0.0f));
                refraction+=(scatterColor-refraction)*scatter;
            }
            color[k]=refraction*(1.0f-fresnel)+reflection[k]*fresnel;
        } else color[k]=waterColor*(1.0f-fresnel)*0.5f+reflection[k]*(1.0f+fresnel)*0.5f;
        color[k]+=specular*__uint_as_float(texels[object+36+k])+pointSpecular[k];
        float skyEstimate=fmaxf(0.0f,-0.3f+1.3f*sunFade);
        color[k]+=fabsf(rainRipple[3])*(skyEstimate*0.95f+0.05f)*0.5f*((flags&1)!=0?transparency:1.0f);
        if((flags&5)==5)color[k]=rawRefraction+(color[k]-rawRefraction)*shore;
        viewNormal[k]=0.0f;for(unsigned int col=0;col<3;col++)viewNormal[k]+=__uint_as_float(texels[p+40+k*4+col])*normal[col];
    }
    water_normalize(viewNormal);color[3]=(flags&1)!=0?1.0f:transparency;
}
