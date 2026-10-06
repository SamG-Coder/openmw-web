#include "browserbridge.hpp"
#include <stdexcept>
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
namespace
{
    struct RetainedPass
    {
        WebCuda::GeometryPacket geometry;
        std::shared_ptr<const WebCuda::MaterialTable> table;
    };
    std::map<unsigned int, RetainedPass> retainedPasses;
    unsigned int nextPassToken=0;
}
extern "C" EMSCRIPTEN_KEEPALIVE void omw_webcuda_release_pass(unsigned int token)
{
    retainedPasses.erase(token);
}
EM_JS(int, omw_webcuda_submit_pass, (unsigned int token, unsigned int vertexEncoding,
    const unsigned int* vertexLayouts, size_t vertexLayoutWords, const float* vertexInputs, size_t vertexInputFloats,
    const float* vertices, size_t vertexFloats,
    const float* matrices, size_t matrixFloats, const unsigned int* matrixIds, size_t matrixCount,
    const unsigned int* triangles, size_t triangleWords, const unsigned int* materials, size_t materialWords,
    const unsigned int* texels, size_t texelCount, size_t texelWordCount, const unsigned int* blocks, size_t blockWords,
    const unsigned int* decodes, size_t decodeWords, const unsigned int* copies, size_t copyWords,
    const unsigned int* textureResources,size_t textureResourceWords,
    const float* uvMatrices, size_t uvFloats, const unsigned int* mips, size_t mipWords,
    const float* attributes, size_t attributeFloats,const float* rasterParams,size_t rasterFloats,
    const unsigned int* morphRanges,size_t morphRangeWords,const float* morphOffsets,size_t morphOffsetFloats,
    const unsigned int* skinRanges,size_t skinRangeWords,const unsigned int* skinWeights,size_t skinWeightWords,
    const float* skinBones,size_t skinBoneFloats,const float* skinTransforms,size_t skinTransformFloats,
    const unsigned int* ribbonRanges,size_t ribbonRangeWords,const float* ribbonParticles,size_t ribbonParticleFloats,
    const unsigned int* screenPrimitives,size_t screenPrimitiveWords,
    const unsigned int* flatColors,size_t flatColorWords,
    const unsigned int* polygonEdges,size_t polygonEdgeWords,
    const unsigned int* texgen,size_t texgenWords,
    const unsigned int* fixedLighting,size_t fixedLightingWords,
    const unsigned int* textGradientRanges,size_t textGradientRangeWords,const float* textGradientColors,size_t textGradientColorFloats,
    const float* localTransforms,size_t localTransformFloats,
    const float* debugParams,size_t debugParamFloats,
    const float* secondaryColors,size_t secondaryColorFloats,
    const unsigned int* groundcoverRanges,size_t groundcoverRangeWords,
    const float* groundcoverInstances,size_t groundcoverInstanceFloats,const float* groundcoverParams,size_t groundcoverParamFloats,
    const unsigned int* depthMipSources,size_t depthMipWords,
    const unsigned int* clusterRecords,size_t clusterRecordWords,const unsigned int* clusterMaterials,size_t clusterMaterialWords,
    const float* clusterLights,size_t clusterLightFloats,const float* clusterProjections,size_t clusterProjectionFloats,
    unsigned int width, unsigned int height), {
    let released=false,accounted=false,viewBytes=0;
    const stats=Module.webcudaTransportStats??={capturedPasses:0,releasedPasses:0,retainedPasses:0,retainedViewBytes:0,copiedSceneBytes:0,heapCapacityBytes:0};
    const release=()=>{
        if(released)return;
        released=true;
        _omw_webcuda_release_pass(token);
        if(accounted){stats.releasedPasses++;stats.retainedPasses--;stats.retainedViewBytes-=viewBytes;}
    };
    try {
    if (typeof Module.webcudaSubmitPass !== 'function') throw Error('WebCuda browser pass consumer is not installed');
    // MEMORY64 pointers must not pass through JS's signed 32-bit shift operators.
    function view(heap, pointer, count) {
        const start=Number(pointer)/4, length=Number(count);
        if (!Number.isSafeInteger(start)||!Number.isSafeInteger(length)||start<0||length<0||start+length>heap.length)
            throw RangeError('Invalid WebCuda WASM buffer range');
        viewBytes+=length*4;
        return heap.subarray(start,start+length);
    }
    const packet={version:2,storage:'wasm-retained',release,width:width,height:height,scene:{
        vertexEncoding:vertexEncoding,vertexLayouts:view(HEAPU32,vertexLayouts,vertexLayoutWords),vertexInputs:view(HEAPF32,vertexInputs,vertexInputFloats),
        vertices:view(HEAPF32,vertices,vertexFloats),matrices:view(HEAPF32,matrices,matrixFloats),
        matrixIds:view(HEAPU32,matrixIds,matrixCount),triangles:view(HEAPU32,triangles,triangleWords),
        materials:view(HEAPU32,materials,materialWords),texels:view(HEAPU32,texels,texelCount),texelWordCount:Number(texelWordCount),
        compressedBlocks:view(HEAPU32,blocks,blockWords),textureDecodes:view(HEAPU32,decodes,decodeWords),
        textureCopies:view(HEAPU32,copies,copyWords),textureResources:view(HEAPU32,textureResources,textureResourceWords)
        ,uvMatrices:view(HEAPF32,uvMatrices,uvFloats),mipGenerations:view(HEAPU32,mips,mipWords),
        groundcoverRanges:view(HEAPU32,groundcoverRanges,groundcoverRangeWords),
        groundcoverInstances:view(HEAPF32,groundcoverInstances,groundcoverInstanceFloats),groundcoverParams:view(HEAPF32,groundcoverParams,groundcoverParamFloats),
        textGradientRanges:view(HEAPU32,textGradientRanges,textGradientRangeWords),textGradientColors:view(HEAPF32,textGradientColors,textGradientColorFloats),
        localTransforms:view(HEAPF32,localTransforms,localTransformFloats),
        debugParams:view(HEAPF32,debugParams,debugParamFloats),
        secondaryColors:view(HEAPF32,secondaryColors,secondaryColorFloats),
        attributes:view(HEAPF32,attributes,attributeFloats),rasterParams:view(HEAPF32,rasterParams,rasterFloats),
        morphRanges:view(HEAPU32,morphRanges,morphRangeWords),morphOffsets:view(HEAPF32,morphOffsets,morphOffsetFloats),
        skinRanges:view(HEAPU32,skinRanges,skinRangeWords),skinWeights:view(HEAPU32,skinWeights,skinWeightWords),
        skinBones:view(HEAPF32,skinBones,skinBoneFloats),skinTransforms:view(HEAPF32,skinTransforms,skinTransformFloats),
        ribbonRanges:view(HEAPU32,ribbonRanges,ribbonRangeWords),ribbonParticles:view(HEAPF32,ribbonParticles,ribbonParticleFloats),
        screenPrimitives:view(HEAPU32,screenPrimitives,screenPrimitiveWords),flatColors:view(HEAPU32,flatColors,flatColorWords),polygonEdges:view(HEAPU32,polygonEdges,polygonEdgeWords),texgen:view(HEAPU32,texgen,texgenWords),fixedLighting:view(HEAPU32,fixedLighting,fixedLightingWords),depthMipSources:view(HEAPU32,depthMipSources,depthMipWords),
        clusterRecords:view(HEAPU32,clusterRecords,clusterRecordWords),clusterMaterials:view(HEAPU32,clusterMaterials,clusterMaterialWords),
        clusterLights:view(HEAPF32,clusterLights,clusterLightFloats),clusterProjections:view(HEAPF32,clusterProjections,clusterProjectionFloats)
    }};
    stats.capturedPasses++;stats.retainedPasses++;stats.retainedViewBytes+=viewBytes;
    stats.heapCapacityBytes=HEAPU32.buffer.byteLength;accounted=true;
    if(Module.webcudaSubmitPass(packet)===false){release();return 0;}
    return 1;
    } catch(error) {release();throw error;}
})
#endif
namespace WebCuda
{
    bool submitBrowserPass(GeometryPacket sourceGeometry,std::shared_ptr<const MaterialTable> sourceTable,
        std::uint32_t width,std::uint32_t height)
    {
#ifdef __EMSCRIPTEN__
        // Depth/resolve boundaries may submit no geometry while retaining the
        // preceding scene's atlas. A clear-only pass cannot sample that atlas.
        // Keep the pass itself so its clear and attachment ordering still run.
        if(!sourceTable)throw std::invalid_argument("Missing WebCuda material table");
        static const auto emptyTable=std::make_shared<const MaterialTable>(1,1);
        do { ++nextPassToken; } while(!nextPassToken||retainedPasses.count(nextPassToken));
        const auto token=nextPassToken;
        auto tableOwner=sourceGeometry.triangles.empty()?emptyTable:captureMaterialTable(std::move(sourceTable));
        const auto& retained=retainedPasses.emplace(token,RetainedPass{std::move(sourceGeometry),std::move(tableOwner)}).first->second;
        const auto& geometry=retained.geometry;
        const auto& table=*retained.table;
        // The JS wrapper owns release on success, rejection and JS exceptions.
        return omw_webcuda_submit_pass(token,geometry.compactVertices?1u:0u,
            geometry.vertexLayouts.data(),geometry.vertexLayouts.size(),geometry.vertexInputs.data(),geometry.vertexInputs.size(),
            geometry.vertices.data(),geometry.vertices.size(),
            geometry.matrices.data(),geometry.matrices.size(),geometry.matrixIds.data(),geometry.matrixIds.size(),
            geometry.triangles.data(),geometry.triangles.size(),table.materials().data(),table.materials().size(),
            table.texels().data(),table.texels().size(),table.texelWordCount(),table.compressedBlocks().data(),table.compressedBlocks().size(),
            table.textureDecodes().data(),table.textureDecodes().size(),
            table.textureCopies().data(),table.textureCopies().size(),
            table.textureResources().data(),table.textureResources().size(),
            geometry.uvMatrices.data(),geometry.uvMatrices.size(),table.mipGenerations().data(),table.mipGenerations().size(),
            geometry.attributes.data(),geometry.attributes.size(),table.rasterParams().data(),table.rasterParams().size(),
            geometry.morphRanges.data(),geometry.morphRanges.size(),geometry.morphOffsets.data(),geometry.morphOffsets.size(),
            geometry.skinRanges.data(),geometry.skinRanges.size(),geometry.skinWeights.data(),geometry.skinWeights.size(),
            geometry.skinBones.data(),geometry.skinBones.size(),geometry.skinTransforms.data(),geometry.skinTransforms.size(),
            geometry.ribbonRanges.data(),geometry.ribbonRanges.size(),geometry.ribbonParticles.data(),geometry.ribbonParticles.size(),
            geometry.screenPrimitives.data(),geometry.screenPrimitives.size(),geometry.flatColors.data(),geometry.flatColors.size(),geometry.polygonEdges.data(),geometry.polygonEdges.size(),geometry.texgen.data(),geometry.texgen.size(),geometry.fixedLighting.data(),geometry.fixedLighting.size(),geometry.textGradientRanges.data(),geometry.textGradientRanges.size(),geometry.textGradientColors.data(),geometry.textGradientColors.size(),geometry.localTransforms.data(),geometry.localTransforms.size(),geometry.debugParams.data(),geometry.debugParams.size(),geometry.secondaryColors.data(),geometry.secondaryColors.size(),geometry.groundcoverRanges.data(),geometry.groundcoverRanges.size(),geometry.groundcoverInstances.data(),geometry.groundcoverInstances.size(),geometry.groundcoverParams.data(),geometry.groundcoverParams.size(),table.depthMipSources().data(),table.depthMipSources().size(),
            table.clusterRecords().data(),table.clusterRecords().size(),table.clusterMaterials().data(),table.clusterMaterials().size(),
            table.clusterLights().data(),table.clusterLights().size(),table.clusterProjections().data(),table.clusterProjections().size(),width,height)!=0;
#else
        throw std::runtime_error("WebCuda browser transport requires WebAssembly");
#endif
    }
}
