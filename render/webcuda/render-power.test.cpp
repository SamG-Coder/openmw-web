#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#define __device__
unsigned int __float_as_uint(float v){unsigned int b;std::memcpy(&b,&v,4);return b;}
float __uint_as_float(unsigned int b){float v;std::memcpy(&v,&b,4);return v;}
#include "precision.cuh"
int main(){
    assert(render_power(0,0)==1 && render_power(0,2)==0);
    assert(render_power(1,256)==1);
    std::mt19937 random(731);
    std::uniform_real_distribution<float> bases(0.00001f,4.f), exponents(0.f,256.f);
    float worst=0;
    for(unsigned i=0;i<100000;i++){
        float base=bases(random),exponent=exponents(random);
        if(i%2==0)base/=4.f;
        float expected=std::pow(base,exponent),actual=render_power(base,exponent);
        if(std::isinf(expected)){assert(std::isinf(actual));continue;}
        // GPU float pow is approximate. Ignore subnormal relative error, but
        // retain a tight absolute bound there and a 5e-5 relative bound elsewhere.
        float error=std::fabs(expected-actual)/std::max(1e-30f,std::fabs(expected));
        worst=std::max(worst,error);assert(error<=5e-5f);
    }
    for(unsigned i=0;i<=65535;i++){
        float x=float(i)/65535.f;
        float decoded=x<=.04045f?x/12.92f:std::pow((x+.055f)/1.055f,2.4f);
        assert(std::fabs(srgb_to_linear(x)-decoded)<3e-7f);
        assert(std::fabs(linear_to_srgb(srgb_to_linear(x))-x)<5e-7f);
    }
    std::printf("Float render power: 100000 cases, max normalized error %.9g; 65536 sRGB round trips passed\n",worst);
}
