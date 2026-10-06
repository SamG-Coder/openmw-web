// SPDX-License-Identifier: GPL-3.0-or-later
// Storage-format conversion, authored once for native CUDA and WebCuda.
// Rendering power bases and exponents are nonnegative. Spell out the float operation so
// WebCuda does not pull software f64 integer-power emulation into every shader.
// Zero is handled before log2, including the material convention pow(0,0)=1.
// Like GPU shader pow, this is approximate; it is not a general libm replacement.
__device__ float render_power(float base,float exponent) {
    if(exponent==0.0f||base==1.0f)return 1.0f;
    if(base==0.0f)return 0.0f;
    return exp2f(exponent*log2f(base));
}

__device__ unsigned int expand_half(unsigned int value) {
    unsigned int sign=(value&32768u)<<16,exponent=(value>>10)&31u,mantissa=value&1023u;
    if(exponent==31u)return sign|2139095040u|(mantissa<<13);
    if(exponent==0u) {
        if(mantissa==0u)return sign;
        unsigned int shift=0u;
        while((mantissa&1024u)==0u){mantissa=mantissa<<1;shift++;}
        return sign|((113u-shift)<<23)|((mantissa&1023u)<<13);
    }
    return sign|((exponent+112u)<<23)|(mantissa<<13);
}

__device__ unsigned int contract_half(float value) {
    unsigned int bits=__float_as_uint(value),sign=(bits>>16)&32768u;
    unsigned int exponent=(bits>>23)&255u,mantissa=bits&8388607u;
    if(exponent==255u)return sign|31744u|(mantissa!=0u?512u|(mantissa>>13):0u);
    int adjusted=(int)exponent-112;
    if(adjusted>=31)return sign|31744u;
    if(adjusted<=0) {
        if(adjusted< -10)return sign;
        mantissa|=8388608u;
        unsigned int shift=(unsigned int)(14-adjusted),rounded=mantissa>>shift;
        unsigned int remainder=mantissa&((1u<<shift)-1u),halfway=1u<<(shift-1u);
        if(remainder>halfway||(remainder==halfway&&(rounded&1u)!=0u))rounded++;
        return sign|rounded;
    }
    unsigned int rounded=mantissa+4095u+((mantissa>>13)&1u);
    if((rounded&8388608u)!=0u){rounded=0u;adjusted++;}
    if(adjusted>=31)return sign|31744u;
    return sign|((unsigned int)adjusted<<10)|(rounded>>13);
}
__device__ float round_half(float value) {
    return __uint_as_float(expand_half(contract_half(value)));
}

// sRGB atlas values are stored decoded, so filtering operates in linear space.
__device__ float srgb_to_linear(float value) {
    value=fminf(1.0f,fmaxf(0.0f,value));
    return value<=0.04045f?value/12.92f:render_power((value+0.055f)/1.055f,2.4f);
}
__device__ float linear_to_srgb(float value) {
    value=fminf(1.0f,fmaxf(0.0f,value));
    return value<=0.0031308f?value*12.92f:1.055f*render_power(value,1.0f/2.4f)-0.055f;
}

__device__ float store_color_value(float value,unsigned int channel,unsigned int channels,unsigned int storage) {
    if(channel>=channels)return channel==3u?1.0f:0.0f;
    if(storage==0u)return floorf(fminf(1.0f,fmaxf(0.0f,value))*255.0f+0.5f)/255.0f;
    if(storage==1u)return round_half(value);
    if(storage==4u)return floorf(fminf(1.0f,fmaxf(0.0f,value))*65535.0f+0.5f)/65535.0f;
    if(storage==5u||storage==6u) {
        float maximum=storage==5u?127.0f:32767.0f;
        return floorf(fminf(1.0f,fmaxf(-1.0f,value))*maximum+0.5f)/maximum;
    }
    if(storage==3u) {
        float encoded=channel<3u?linear_to_srgb(value):fminf(1.0f,fmaxf(0.0f,value));
        encoded=floorf(encoded*255.0f+0.5f)/255.0f;
        return channel<3u?srgb_to_linear(encoded):encoded;
    }
    return value;
}

__device__ float store_depth_value(float value,unsigned int bits) {
    value=fminf(1.0f,fmaxf(0.0f,value));
    if(bits==0u)return value;
    float maximum=bits==16u?65535.0f:16777215.0f;
    return fminf(1.0f,floorf(value*maximum+0.5f)/maximum);
}
