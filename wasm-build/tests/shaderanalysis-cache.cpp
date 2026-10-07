// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone CPU test; no OSG/Steam files or GPU required.
// c++ -std=c++17 -O2 -pthread wasm-build/tests/shaderanalysis-cache.cpp -o /tmp/shaderanalysis-cache
#include "../../openmw/components/webcuda/shaderanalysis.hpp"
#include <algorithm>
#include <cassert>
#include <chrono>
#include <iostream>
#include <random>
#include <thread>
#include <vector>

using WebCuda::ShaderAnalysisDetail::ContainsCache;
using WebCuda::ShaderAnalysisDetail::contains;
const std::string needle="gl_Position=modelToClip(";
std::string shader(unsigned lines=128)
{
    std::string s;
    for(unsigned i=0;i<lines;++i)s+="vec4 fog = lighting + gl_Normal;\n";
    return s+"gl_Position = modelToClip(vertex);\n";
}
int main(int argc,char** argv)
{
    unsigned passed=0;
    {
        ContainsCache cache;const auto source=shader();
        assert(cache.contains(source,needle));assert(cache.contains(source,needle));
        assert(cache.stats().hits==1);assert(cache.stats().misses==1);
        ++passed;std::cout<<"PASS repeated source reuses analysis\n";
    }
    {
        ContainsCache cache;auto source=shader();auto* address=source.data();auto size=source.size();
        assert(cache.contains(source,needle));
        const auto at=source.find("modelToClip");source[at]='v';
        assert(source.data()==address && source.size()==size);
        assert(!cache.contains(source,needle));source[at]='m';
        assert(cache.contains(source,needle));
        ++passed;std::cout<<"PASS same-address same-size edits invalidate analysis\n";
    }
    {
        ContainsCache cache;auto source=shader();
        std::string query=needle;auto* address=query.data();
        assert(cache.contains(source,query));query[12]='x';
        assert(query.data()==address);assert(!cache.contains(source,query));
        ++passed;std::cout<<"PASS changed query contents invalidate analysis\n";
    }
    {
        ContainsCache cache;auto source=shader();source.resize(6000,' ');
        std::fill(source.begin(),source.end(),' ');
        assert(!cache.contains(source,needle));assert(!cache.contains(source,needle));
        source.replace(100,needle.size(),needle);assert(cache.contains(source,needle));
        ++passed;std::cout<<"PASS negative results and later matches stay correct\n";
    }
    {
        ContainsCache cache;const std::string shortSource="gl_Position = modelToClip(x);";
        const auto longSource=shader(1000);
        assert(cache.contains(shortSource,needle));assert(cache.contains(longSource,needle));
        assert(cache.contains(longSource,""));assert(cache.stats().bypasses==3);
        auto unicode=shader();unicode[0]=char(0xe9);
        for(int i=0;i<2;i++)assert(cache.contains(unicode,needle)==contains(unicode,needle));
        assert(cache.stats().hits==0);
        ++passed;std::cout<<"PASS short oversized empty and non-ASCII inputs bypass safely\n";
    }
    {
        ContainsCache cache;std::vector<std::string> sources;
        for(unsigned i=0;i<512;i++)sources.push_back(shader(20+i%100)+std::to_string(i));
        for(unsigned round=0;round<3;round++)for(auto& source:sources)
            assert(cache.contains(source,needle)==contains(source,needle));
        ++passed;std::cout<<"PASS cache collisions and eviction preserve results\n";
    }
    {
        ContainsCache cache;std::mt19937 rng(317);
        for(unsigned run=0;run<2000;run++) {
            std::string source(512+rng()%4096,' ');
            constexpr std::string_view alphabet="g abc_()\t\n\v\r\f=";
            for(char& c:source)c=alphabet[rng()%alphabet.size()];
            std::string query="ab=";
            if(run%3==0)source.replace(rng()%(source.size()-10),7,"a \tb = ");
            assert(cache.contains(source,query)==contains(source,query));
            assert(cache.contains(source,query)==contains(source,query));
        }
        ++passed;std::cout<<"PASS 2000 randomized whitespace/source comparisons\n";
    }
    {
        std::vector<std::thread> threads;
        for(int i=0;i<4;i++)threads.emplace_back([] {
            auto source=shader();for(int j=0;j<1000;j++)assert(WebCuda::compactShaderContains(source,needle));
        });
        for(auto& thread:threads)thread.join();
        ++passed;std::cout<<"PASS separate thread-local caches\n";
    }
    {
        assert(WebCuda::compactShaderEquals(" a \t b\n", "ab"));
        assert(!WebCuda::compactShaderEquals("abx", "ab"));
        assert(WebCuda::compactShaderContains("a\tb\n", "ab"));
        ++passed;std::cout<<"PASS original short-source and equality behavior\n";
    }
    std::cout<<passed<<" tests passed\n";
    if(argc>1 && std::string_view(argv[1])=="--benchmark") {
        // Deliberately synthetic CPU source-classification workload, not an
        // engine frame or GPU measurement. Warm/uncached results must agree.
        auto source=shader();ContainsCache cache;cache.contains(source,needle);
        volatile unsigned result=0;
        const auto run=[&](bool cached) {
            const auto begin=std::chrono::steady_clock::now();
            for(unsigned i=0;i<50000;i++)result+=cached?cache.contains(source,needle):contains(source,needle);
            return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
        };
        std::vector<double> oldTimes,newTimes;
        for(int i=0;i<5;i++) { oldTimes.push_back(run(false));newTimes.push_back(run(true)); }
        std::sort(oldTimes.begin(),oldTimes.end());std::sort(newTimes.begin(),newTimes.end());
        std::cout<<"SYNTHETIC CPU median of 5 runs, 50000 checks of "<<source.size()<<" bytes:\n"
            <<"uncached "<<oldTimes[2]<<" ms; exact-content cache "<<newTimes[2]<<" ms\n";
        assert(result==500000);
    }
}
