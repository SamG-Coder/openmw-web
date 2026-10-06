#pragma once
#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>
#include <emscripten.h>
#include <components/webcuda/geometrypacket.hpp>

namespace VertexInputReference {
    struct Dim { unsigned int x=0,y=0; };
    static Dim blockIdx,threadIdx,blockDim{1,0},gridDim{1,0};
#define __global__
#define __device__
#include "vertex-input.cu"
#undef __global__
#undef __device__
    inline std::vector<std::uint32_t> fixtures{0x56494e31u,0u};
    template<class T> void record(const std::vector<T>& values) {
        static_assert(sizeof(T)==4);
        const auto first=fixtures.size();fixtures.resize(first+values.size());
        if(!values.empty())std::memcpy(fixtures.data()+first,values.data(),values.size()*4);
    }
    inline void verify(const WebCuda::GeometryPacket& compact,const WebCuda::GeometryPacket& dense) {
        assert(compact.compactVertices&&compact.vertices.empty()&&compact.attributes.empty()&&compact.secondaryColors.empty());
        assert(compact.vertexCount()==dense.vertexCount()&&compact.matrixIds==dense.matrixIds);
        assert(compact.triangles==dense.triangles&&compact.screenPrimitives==dense.screenPrimitives&&compact.flatColors==dense.flatColors);
        assert(compact.morphRanges==dense.morphRanges&&compact.morphOffsets==dense.morphOffsets);
        assert(compact.skinRanges==dense.skinRanges&&compact.skinWeights==dense.skinWeights&&compact.skinBones==dense.skinBones);
        assert(compact.matrices==dense.matrices&&compact.uvMatrices==dense.uvMatrices&&compact.fixedLighting==dense.fixedLighting);
        const auto count=static_cast<unsigned int>(dense.vertexCount());
        std::vector<float> vertices(count*10+4,12345.f),attributes(count*34+4,12345.f),secondary(count*3+4,12345.f);
        for(blockIdx.x=0;blockIdx.x<count+1;blockIdx.x++)
            unpack_vertex_inputs(compact.vertexInputs.data(),compact.vertexLayouts.data(),compact.matrixIds.data(),
                vertices.data(),attributes.data(),secondary.data(),count);
        auto exact=[](const auto& actual,const auto& expected) {
            if(!expected.empty())assert(std::memcmp(actual.data(),expected.data(),expected.size()*4)==0);
            for(std::size_t i=expected.size();i<actual.size();i++)assert(actual[i]==12345.f);
        };
        exact(vertices,dense.vertices);exact(attributes,dense.attributes);exact(secondary,dense.secondaryColors);
        fixtures[1]++;
        fixtures.insert(fixtures.end(),{static_cast<std::uint32_t>(compact.vertexLayouts.size()),static_cast<std::uint32_t>(compact.vertexInputs.size()),
            static_cast<std::uint32_t>(compact.matrixIds.size()),static_cast<std::uint32_t>(dense.vertices.size()),
            static_cast<std::uint32_t>(dense.attributes.size()),static_cast<std::uint32_t>(dense.secondaryColors.size())});
        record(compact.vertexLayouts);record(compact.vertexInputs);record(compact.matrixIds);
        record(dense.vertices);record(dense.attributes);record(dense.secondaryColors);
    }
    inline void append(WebCuda::GeometryPacket& packet,const osg::Geometry& geometry,const WebCuda::DrawContext& context,
        std::uint32_t material,std::uint32_t screen=~0u,std::uint32_t point=~0u) {
        WebCuda::GeometryPacket compact(true),reference;
        bool failed=false;
        try {WebCuda::appendGeometry(compact,geometry,context,material,screen,point);} catch(const std::runtime_error&) {failed=true;}
        if(failed) {
            bool referenceFailed=false;
            try {WebCuda::appendGeometry(reference,geometry,context,material,screen,point);} catch(const std::runtime_error&) {referenceFailed=true;}
            assert(referenceFailed&&compact.vertexCount()==0&&compact.triangles.empty());
            // Preserve the caller's rejection assertions and partial-state check.
            WebCuda::appendGeometry(packet,geometry,context,material,screen,point);
            assert(false);
        }
        WebCuda::appendGeometry(reference,geometry,context,material,screen,point);verify(compact,reference);
        WebCuda::appendGeometry(packet,geometry,context,material,screen,point);
    }
    inline void save() {
        EM_ASM({
            if(process.env.WEBCUDA_VERTEX_FIXTURES)
                require('fs').writeFileSync(process.env.WEBCUDA_VERTEX_FIXTURES,HEAPU8.subarray(Number($0),Number($0)+Number($1)));
        },fixtures.data(),fixtures.size()*4);
        std::printf("Compact CUDA input comparison: %u captured fixtures match every field and guard\n",fixtures[1]);
    }
}
