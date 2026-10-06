#include <cassert>
#include <cstdio>
#include <memory>
#include <osg/BlendFunc>
#include <emscripten.h>
#include <components/webcuda/browserbridge.hpp>
namespace {
    std::weak_ptr<const WebCuda::MaterialTable> rejectedTable;
    WebCuda::GeometryPacket triangle(float x=1.f) {
        WebCuda::GeometryPacket geometry;
        geometry.vertices={x,2,3,1,1,1,1,1,0,0};
        geometry.matrixIds={0};geometry.matrices.resize(32);
        geometry.triangles={0,0,0,0};
        return geometry;
    }
}
extern "C" EMSCRIPTEN_KEEPALIVE int submitThrowingConsumer() {
    auto table=std::make_shared<WebCuda::MaterialTable>(16,8);
    table->encode(WebCuda::DrawContext{});rejectedTable=table;
    return WebCuda::submitBrowserPass(triangle(),std::move(table),16,8);
}
int main() {
    auto geometry=triangle();
    const auto* originalVertices=geometry.vertices.data();
    auto table=std::make_shared<WebCuda::MaterialTable>(16,8);
    WebCuda::DrawContext context;table->encode(context);
    const auto* originalTable=table.get();
    std::weak_ptr<const WebCuda::MaterialTable> firstTable=table;
    EM_ASM({Module.packets=[];Module.webcudaSubmitPass=packet=>{Module.packets.push(packet);return true;};});
    assert(WebCuda::submitBrowserPass(std::move(geometry),table,16,8));
    assert(EM_ASM_INT({
        const p=Module.packets[0];
        return p.version===2 && p.storage==='wasm-retained' && typeof p.release==='function'
            && p.width===16 && p.height===8 && p.scene.vertices instanceof Float32Array
            && p.scene.triangles instanceof Uint32Array && p.scene.vertices[0]===1
            && p.scene.materials.length===12 && p.scene.texels[0]===4294967295
            && p.scene.vertices.byteOffset===Number($0)
            && p.scene.texelWordCount===p.scene.texels.length
            && Object.values(p.scene).filter(ArrayBuffer.isView).every(view=>view.buffer===HEAPU32.buffer);
    },originalVertices));
    // New geometry and material encoding cannot overwrite a delayed pass.
    geometry=triangle(99.f);
    osg::ref_ptr<osg::StateSet> blended=new osg::StateSet;
    blended->setMode(GL_BLEND,osg::StateAttribute::ON);
    blended->setAttribute(new osg::BlendFunc(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA));
    context.states.push_back(blended);
    WebCuda::writableMaterialTable(table).encode(context,nullptr,true);
    assert(table.get()!=originalTable && !firstTable.expired());
    const auto nextTableWords=table->materials().size();
    assert(nextTableWords>12);
    assert(WebCuda::submitBrowserPass(std::move(geometry),table,16,8));
    std::weak_ptr<const WebCuda::MaterialTable> secondTable=table;
    table.reset();
    assert(EM_ASM_INT({
        return Module.packets[0].scene.vertices[0]===1 && Module.packets[0].scene.materials.length===12
            && Module.packets[1].scene.vertices[0]===99 && Module.packets[1].scene.materials.length===Number($0)
            && Module.webcudaTransportStats.retainedPasses===2;
    },nextTableWords));
    EM_ASM({Module.packets[0].release();Module.packets[0].release();});
    assert(firstTable.expired()&&!secondTable.expired());
    assert(EM_ASM_INT({return Module.webcudaTransportStats.retainedPasses===1;}));
    EM_ASM({Module.packets[1].release();});
    assert(secondTable.expired());
    // An empty pass retains only its tiny empty table, not the prior atlas.
    table=std::make_shared<WebCuda::MaterialTable>(16,8);table->encode(context);
    assert(WebCuda::submitBrowserPass({},table,16,8));
    assert(table.use_count()==1 && table->materials().size()==12);
    assert(EM_ASM_INT({
        const scene=Module.packets[2].scene;
        return scene.triangles.length===0 && scene.materials.length===0 && scene.texels.length===1
            && scene.compressedBlocks.length===0 && scene.textureDecodes.length===0
            && scene.textureCopies.length===0 && scene.rasterParams.length===0 && scene.clusterRecords.length===0;
    }));
    EM_ASM({Module.packets[2].release();Module.webcudaSubmitPass=()=>false;});
    rejectedTable=table;
    assert(!WebCuda::submitBrowserPass(triangle(),std::move(table),16,8));
    assert(rejectedTable.expired());
    // A synchronous JS exception also releases ownership before propagation.
    assert(EM_ASM_INT({
        Module.webcudaSubmitPass=()=>{throw Error('deliberate consumer failure');};
        try {_submitThrowingConsumer();return 0;}
        catch(error){return error.message==='deliberate consumer failure';}
    }));
    assert(rejectedTable.expired());
    // The packet describes the full GPU atlas while its shared WASM view owns
    // only the small CPU prefix; deferred attachment addresses are resolved.
    table=std::make_shared<WebCuda::MaterialTable>(16,8);
    osg::ref_ptr<osg::Texture2D> attachment=new osg::Texture2D;
    attachment->setTextureSize(64,64);attachment->setInternalFormat(0x81A6);
    attachment->setFilter(osg::Texture::MIN_FILTER,osg::Texture::NEAREST);
    table->setRenderTextureResolver([](const osg::Texture2D*){return 0x80000001u;});
    table->encode(WebCuda::DrawContext{},attachment,true);
    EM_ASM({Module.webcudaSubmitPass=packet=>{Module.compactPacket=packet;return true;};});
    assert(WebCuda::submitBrowserPass(triangle(),table,16,8));
    assert(table.use_count()==1);
    assert(EM_ASM_INT({
        const s=Module.compactPacket.scene;
        return s.texels.length<64 && s.texelWordCount===s.texels.length+64*64
            && s.textureCopies[1]===s.texels.length && s.depthMipSources[0]===s.texels.length
            && s.texels[s.materials[0]]===s.texels.length && s.texels.buffer===HEAPU32.buffer;
    }));
    EM_ASM({Module.compactPacket.release();delete Module.compactPacket;});
    geometry=WebCuda::GeometryPacket(true);geometry.capturedVertexCount=1;geometry.matrixIds={0};geometry.matrices.resize(32);
    geometry.triangles={0,0,0,0};geometry.vertexLayouts.resize(32);geometry.vertexInputs={2.f,3.f,4.f};
    const auto* compactInputs=geometry.vertexInputs.data();const auto* compactLayouts=geometry.vertexLayouts.data();
    geometry.vertexResources={99,0,3};const auto* compactResources=geometry.vertexResources.data();
    EM_ASM({Module.webcudaSubmitPass=packet=>{Module.vertexPacket=packet;return true;};});
    assert(WebCuda::submitBrowserPass(std::move(geometry),table,16,8));
    assert(EM_ASM_INT({
        const s=Module.vertexPacket.scene;
        return s.vertexEncoding===1&&s.vertices.length===0&&s.attributes.length===0&&s.vertexInputs[2]===4
            &&s.vertexInputs.byteOffset===Number($0)&&s.vertexLayouts.byteOffset===Number($1)
            &&s.vertexResources.byteOffset===Number($2)&&s.vertexResources[0]===99&&s.vertexResources.buffer===HEAPU32.buffer
            &&s.vertexInputs.buffer===HEAPF32.buffer&&s.vertexLayouts.buffer===HEAPU32.buffer;
    },compactInputs,compactLayouts,compactResources));
    EM_ASM({Module.vertexPacket.release();delete Module.vertexPacket;});
    EM_ASM({Module.webcudaSubmitPass=packet=>{Module.compactPacket=packet;return true;};});
    osg::ref_ptr<osg::Image> image=new osg::Image;
    image->allocateImage(1,1,1,GL_RGBA,GL_UNSIGNED_BYTE);
    std::fill_n(image->data(),4,255);
    osg::ref_ptr<osg::Texture2D> imageTexture=new osg::Texture2D(image);
    table=std::make_shared<WebCuda::MaterialTable>(16,8);
    table->encode(WebCuda::DrawContext{},imageTexture,true);
    assert(WebCuda::submitBrowserPass(triangle(),table,16,8));
    assert(EM_ASM_INT({
        const s=Module.compactPacket.scene;const r=s.textureResources;
        return r instanceof Uint32Array && r.buffer===HEAPU32.buffer && r.length===3
            && r[0]>0 && r[2]===1 && s.texels[r[1]]===4294967295;
    }));
    EM_ASM({Module.compactPacket.release();delete Module.compactPacket;});
    assert(EM_ASM_INT({
        const s=Module.webcudaTransportStats;
        return s.capturedPasses===s.releasedPasses && s.retainedPasses===0
            && s.retainedViewBytes===0 && s.copiedSceneBytes===0;
    }));
    std::puts("WebCuda browser bridge: direct shared-WASM views, moved geometry, immutable material snapshots, delayed release, rejection and JS exception cleanup passed");
}
