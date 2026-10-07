#include "nativewebgpu.hpp"

#ifdef __EMSCRIPTEN__

#include "browserbridge.hpp"
#include "browserframe.hpp"
#include "directwebgpu.hpp"

#include <algorithm>
#include <emscripten/html5.h>
#include <array>
#include <cstring>
#include <limits>
#include <set>
#include <stdexcept>

namespace WebCuda
{
    namespace
    {
        // This shader intentionally reads the engine's compact capture ABI
        // directly.  There is no JS scene unpack, no JS pipeline builder and no
        // JS command encoder between OpenMW and WebGPU.
        constexpr const char* DirectShader = R"WGSL(
struct Params {
  compact: u32,
  width: u32,
  height: u32,
  pad: u32,
}
@group(0) @binding(0) var<storage, read> layouts: array<u32>;
@group(0) @binding(1) var<storage, read> inputs: array<f32>;
@group(0) @binding(2) var<storage, read> legacy_vertices: array<f32>;
@group(0) @binding(3) var<storage, read> matrices: array<f32>;
@group(0) @binding(4) var<storage, read> matrix_ids: array<u32>;
@group(0) @binding(5) var<storage, read> triangles: array<u32>;
@group(0) @binding(6) var<storage, read> materials: array<u32>;
@group(0) @binding(7) var<storage, read> texels: array<u32>;
@group(0) @binding(8) var<uniform> params: Params;

struct SourceVertex {
  position: vec4<f32>,
  color: vec4<f32>,
  uv: vec2<f32>,
}
struct Varyings {
  @builtin(position) position: vec4<f32>,
  @location(0) color: vec4<f32>,
  @location(1) uv: vec2<f32>,
  @location(2) @interpolate(flat) material: u32,
}

fn unorm8(value: f32) -> f32 {
  return clamp(value / 255.0, 0.0, 1.0);
}

fn compact_vertex(index: u32) -> SourceVertex {
  let draw = matrix_ids[index];
  let d = draw * 32u;
  let j = index - layouts[d];
  let kind = layouts[d + 3u];
  var out: SourceVertex;
  out.position = vec4<f32>(0.0, 0.0, 0.0, 1.0);
  out.color = vec4<f32>(1.0);
  out.uv = vec2<f32>(0.0);

  if (kind == 0u) {
    let base = layouts[d + 6u] + j * 10u;
    out.position = vec4<f32>(inputs[base], inputs[base+1u], inputs[base+2u], inputs[base+3u]);
    out.color = vec4<f32>(inputs[base+4u], inputs[base+5u], inputs[base+6u], inputs[base+7u]);
    out.uv = vec2<f32>(inputs[base+8u], inputs[base+9u]);
    return out;
  }

  if (kind == 3u) {
    let base = layouts[d + 6u] + j * 9u;
    out.position = vec4<f32>(inputs[base], inputs[base+1u], inputs[base+2u], 1.0);
    out.color = vec4<f32>(unorm8(inputs[base+3u]), unorm8(inputs[base+4u]),
      unorm8(inputs[base+5u]), unorm8(inputs[base+6u]));
    out.uv = vec2<f32>(inputs[base+7u], inputs[base+8u]);
    return out;
  }

  if (kind == 2u) {
    let base = layouts[d + 6u] + (j / 4u) * 17u;
    let corner = j % 4u;
    let u = select(0.0, 1.0, corner == 1u || corner == 2u);
    let v = select(0.0, 1.0, corner >= 2u);
    out.position = vec4<f32>(inputs[base], inputs[base+1u], inputs[base+2u], 1.0);
    out.color = vec4<f32>(inputs[base+3u], inputs[base+4u], inputs[base+5u], inputs[base+6u]);
    out.uv = vec2<f32>(inputs[base+7u] + u * inputs[base+9u],
                       inputs[base+8u] + v * inputs[base+10u]);
    return out;
  }

  if (j >= layouts[d + 2u]) {
    return out;
  }

  let p = layouts[d + 8u] + j * layouts[d + 9u];
  out.position = vec4<f32>(inputs[p], inputs[p+1u], inputs[p+2u], inputs[p+3u]);

  let c = layouts[d + 10u] + j * layouts[d + 11u];
  let byte_components = layouts[d + 28u];
  var color = vec4<f32>(inputs[c], inputs[c+1u], inputs[c+2u], inputs[c+3u]);
  if (byte_components > 0u) {
    if (byte_components > 0u) { color.x = unorm8(color.x); }
    if (byte_components > 1u) { color.y = unorm8(color.y); }
    if (byte_components > 2u) { color.z = unorm8(color.z); }
    if (byte_components > 3u) { color.w = unorm8(color.w); }
  }
  out.color = color;

  let uv = layouts[d + 20u] + j * layouts[d + 21u];
  out.uv = vec2<f32>(inputs[uv], inputs[uv+1u]);
  return out;
}

fn source_vertex(index: u32) -> SourceVertex {
  if (params.compact != 0u) {
    return compact_vertex(index);
  }
  let base = index * 10u;
  var out: SourceVertex;
  out.position = vec4<f32>(legacy_vertices[base], legacy_vertices[base+1u],
    legacy_vertices[base+2u], legacy_vertices[base+3u]);
  out.color = vec4<f32>(legacy_vertices[base+4u], legacy_vertices[base+5u],
    legacy_vertices[base+6u], legacy_vertices[base+7u]);
  out.uv = vec2<f32>(legacy_vertices[base+8u], legacy_vertices[base+9u]);
  return out;
}

fn mul_matrix(base: u32, value: vec4<f32>) -> vec4<f32> {
  return vec4<f32>(
    matrices[base] * value.x + matrices[base+4u] * value.y + matrices[base+8u] * value.z + matrices[base+12u] * value.w,
    matrices[base+1u] * value.x + matrices[base+5u] * value.y + matrices[base+9u] * value.z + matrices[base+13u] * value.w,
    matrices[base+2u] * value.x + matrices[base+6u] * value.y + matrices[base+10u] * value.z + matrices[base+14u] * value.w,
    matrices[base+3u] * value.x + matrices[base+7u] * value.y + matrices[base+11u] * value.z + matrices[base+15u] * value.w);
}

@vertex
fn vertex_main(@builtin(vertex_index) vertex_index: u32) -> Varyings {
  let triangle = vertex_index / 3u;
  let corner = vertex_index % 3u;
  let source_index = triangles[triangle * 4u + corner];
  let material = triangles[triangle * 4u + 3u];
  let source = source_vertex(source_index);
  let draw = matrix_ids[source_index];
  let matrix_base = draw * 32u;
  let view = mul_matrix(matrix_base, source.position);
  var clip = mul_matrix(matrix_base + 16u, view);

  // OpenMW/OSG supplies OpenGL clip depth [-w,+w]; WebGPU expects [0,+w].
  clip.z = 0.5 * (clip.z + clip.w);

  var out: Varyings;
  out.position = clip;
  out.color = source.color;
  out.uv = source.uv;
  out.material = material;
  return out;
}

fn unpack_rgba8(word: u32) -> vec4<f32> {
  return vec4<f32>(f32(word & 255u), f32((word >> 8u) & 255u),
    f32((word >> 16u) & 255u), f32((word >> 24u) & 255u)) / 255.0;
}

fn simple_texture(material: u32, uv_in: vec2<f32>) -> vec4<f32> {
  let m = material * 12u;
  let flags = materials[m + 3u];

  // Fixed-function/GUI textures use the direct atlas record.  Full GLSL
  // materials keep their larger descriptor ABI and are deliberately left to
  // the next native material stage rather than guessed here.
  if ((flags & 512u) == 0u || (flags & 2048u) != 0u || (materials[m + 11u] & 32768u) != 0u) {
    return vec4<f32>(1.0);
  }

  let base = materials[m];
  let width = materials[m + 1u];
  let height = materials[m + 2u];
  if (width == 0u || height == 0u) {
    return vec4<f32>(1.0);
  }

  let uv = fract(uv_in);
  let x = min(width - 1u, u32(uv.x * f32(width)));
  let y = min(height - 1u, u32(uv.y * f32(height)));
  return unpack_rgba8(texels[base + y * width + x]);
}

@fragment
fn fragment_main(input: Varyings) -> @location(0) vec4<f32> {
  var color = input.color * simple_texture(input.material, input.uv);
  if (color.a <= 0.001) {
    discard;
  }
  return color;
}
)WGSL";

        float wordAsFloat(std::uint32_t word)
        {
            float value;
            std::memcpy(&value, &word, sizeof(value));
            return value;
        }

        std::uint64_t nextCapacity(std::uint64_t bytes)
        {
            std::uint64_t result = 4096;
            while (result < bytes && result <= (std::numeric_limits<std::uint64_t>::max() / 2))
                result *= 2;
            return std::max<std::uint64_t>(4, result);
        }
    }

    NativeWebGPURenderer& NativeWebGPURenderer::instance()
    {
        static NativeWebGPURenderer renderer;
        return renderer;
    }

    void NativeWebGPURenderer::ensureBuffer(BufferSlot& slot, std::uint64_t bytes, const char* label,
        wgpu::BufferUsage usage)
    {
        bytes = std::max<std::uint64_t>(4, (bytes + 3u) & ~std::uint64_t(3u));
        const auto required = usage | wgpu::BufferUsage::CopyDst;
        if (slot.buffer && slot.capacity >= bytes && slot.usage == required)
            return;
        if (slot.buffer)
            slot.buffer.Destroy();

        wgpu::BufferDescriptor descriptor{};
        descriptor.label = label;
        descriptor.size = nextCapacity(bytes);
        descriptor.usage = required;
        slot.buffer = DirectWebGPU::instance().deviceObject().CreateBuffer(&descriptor);
        slot.capacity = descriptor.size;
        slot.usage = required;
        if (!slot.buffer)
            throw std::runtime_error(std::string("Unable to allocate native WebGPU buffer: ") + label);
    }

    void NativeWebGPURenderer::upload(BufferSlot& slot, const void* data, std::uint64_t bytes, const char* label,
        wgpu::BufferUsage usage)
    {
        ensureBuffer(slot, bytes, label, usage);
        static const std::uint32_t zero = 0;
        if (!bytes)
        {
            DirectWebGPU::instance().queueObject().WriteBuffer(slot.buffer, 0, &zero, sizeof(zero));
            return;
        }
        DirectWebGPU::instance().queueObject().WriteBuffer(slot.buffer, 0, data, bytes);
    }

    void NativeWebGPURenderer::ensureSurface(std::uint32_t width, std::uint32_t height)
    {
        auto& direct = DirectWebGPU::instance();
        if (!direct.ready())
            throw std::logic_error("Native WebGPU renderer has no device");
        if (!width || !height)
            throw std::invalid_argument("Native WebGPU surface has zero dimensions");

        if (!mSurface)
        {
            wgpu::EmscriptenSurfaceSourceCanvasHTMLSelector canvas{};
            canvas.selector = "#webgpu-canvas";
            wgpu::SurfaceDescriptor descriptor{};
            descriptor.nextInChain = &canvas;
            mSurface = direct.instanceObject().CreateSurface(&descriptor);
            if (!mSurface)
                throw std::runtime_error("Unable to create WebGPU canvas surface");
        }

        if (mWidth == width && mHeight == height && mSurfaceFormat != wgpu::TextureFormat::Undefined)
            return;

        wgpu::SurfaceCapabilities capabilities{};
        mSurface.GetCapabilities(direct.adapterObject(), &capabilities);
        if (!capabilities.formatCount)
            throw std::runtime_error("WebGPU surface exposes no color formats");

        mSurfaceFormat = capabilities.formats[0];
        for (std::size_t i = 0; i < capabilities.formatCount; ++i)
            if (capabilities.formats[i] == wgpu::TextureFormat::RGBA8Unorm)
            {
                mSurfaceFormat = wgpu::TextureFormat::RGBA8Unorm;
                break;
            }

        wgpu::SurfaceConfiguration configuration{};
        configuration.device = direct.deviceObject();
        configuration.format = mSurfaceFormat;
        configuration.usage = wgpu::TextureUsage::RenderAttachment;
        configuration.width = width;
        configuration.height = height;
        configuration.alphaMode = wgpu::CompositeAlphaMode::Auto;
        configuration.presentMode = wgpu::PresentMode::Fifo;
        // WebGPU surface configuration does not replace the HTML canvas CSS
        // size. Keep its backing store in lockstep with the engine viewport.
        emscripten_set_canvas_element_size("#webgpu-canvas", static_cast<int>(width), static_cast<int>(height));
        mSurface.Configure(&configuration);

        wgpu::TextureDescriptor depth{};
        depth.label = "OpenMW native WebGPU depth";
        depth.usage = wgpu::TextureUsage::RenderAttachment;
        depth.size = {width, height, 1};
        depth.format = wgpu::TextureFormat::Depth24Plus;
        mDepthTexture = direct.deviceObject().CreateTexture(&depth);
        mDepthView = mDepthTexture.CreateView();

        mWidth = width;
        mHeight = height;
        mPipeline = {};
        mPipelineLayout = {};
        mBindGroupLayout = {};
    }

    void NativeWebGPURenderer::ensurePipeline()
    {
        if (mPipeline)
            return;

        auto& device = DirectWebGPU::instance().deviceObject();
        std::array<wgpu::BindGroupLayoutEntry, 9> entries{};
        for (std::uint32_t i = 0; i < 8; ++i)
        {
            entries[i].binding = i;
            entries[i].visibility = wgpu::ShaderStage::Vertex | wgpu::ShaderStage::Fragment;
            entries[i].buffer.type = wgpu::BufferBindingType::ReadOnlyStorage;
            entries[i].buffer.minBindingSize = 4;
        }
        entries[8].binding = 8;
        entries[8].visibility = wgpu::ShaderStage::Vertex | wgpu::ShaderStage::Fragment;
        entries[8].buffer.type = wgpu::BufferBindingType::Uniform;
        entries[8].buffer.minBindingSize = 16;

        wgpu::BindGroupLayoutDescriptor bindLayoutDescriptor{};
        bindLayoutDescriptor.label = "OpenMW native direct layout";
        bindLayoutDescriptor.entryCount = entries.size();
        bindLayoutDescriptor.entries = entries.data();
        mBindGroupLayout = device.CreateBindGroupLayout(&bindLayoutDescriptor);

        wgpu::PipelineLayoutDescriptor pipelineLayoutDescriptor{};
        pipelineLayoutDescriptor.label = "OpenMW native direct pipeline layout";
        pipelineLayoutDescriptor.bindGroupLayoutCount = 1;
        pipelineLayoutDescriptor.bindGroupLayouts = &mBindGroupLayout;
        mPipelineLayout = device.CreatePipelineLayout(&pipelineLayoutDescriptor);

        wgpu::ShaderSourceWGSL source{};
        source.code = DirectShader;
        wgpu::ShaderModuleDescriptor shaderDescriptor{};
        shaderDescriptor.label = "OpenMW native direct shader";
        shaderDescriptor.nextInChain = &source;
        auto shader = device.CreateShaderModule(&shaderDescriptor);

        wgpu::BlendState blend{};
        blend.color.operation = wgpu::BlendOperation::Add;
        blend.color.srcFactor = wgpu::BlendFactor::SrcAlpha;
        blend.color.dstFactor = wgpu::BlendFactor::OneMinusSrcAlpha;
        blend.alpha.operation = wgpu::BlendOperation::Add;
        blend.alpha.srcFactor = wgpu::BlendFactor::One;
        blend.alpha.dstFactor = wgpu::BlendFactor::OneMinusSrcAlpha;

        wgpu::ColorTargetState target{};
        target.format = mSurfaceFormat;
        target.blend = &blend;
        target.writeMask = wgpu::ColorWriteMask::All;

        wgpu::FragmentState fragment{};
        fragment.module = shader;
        fragment.entryPoint = "fragment_main";
        fragment.targetCount = 1;
        fragment.targets = &target;

        wgpu::DepthStencilState depth{};
        depth.format = wgpu::TextureFormat::Depth24Plus;
        depth.depthWriteEnabled = wgpu::OptionalBool::True;
        depth.depthCompare = wgpu::CompareFunction::LessEqual;

        wgpu::RenderPipelineDescriptor pipeline{};
        pipeline.label = "OpenMW native direct renderer";
        pipeline.layout = mPipelineLayout;
        pipeline.vertex.module = shader;
        pipeline.vertex.entryPoint = "vertex_main";
        pipeline.fragment = &fragment;
        pipeline.primitive.topology = wgpu::PrimitiveTopology::TriangleList;
        pipeline.primitive.frontFace = wgpu::FrontFace::CCW;
        pipeline.primitive.cullMode = wgpu::CullMode::None;
        pipeline.depthStencil = &depth;
        pipeline.multisample.count = 1;
        mPipeline = device.CreateRenderPipeline(&pipeline);
        if (!mPipeline)
            throw std::runtime_error("Unable to create native WebGPU render pipeline");
    }

    void NativeWebGPURenderer::renderPass(unsigned int token, const PassState& state,
        std::uint32_t width, std::uint32_t height, const wgpu::TextureView& surfaceView, bool& touched)
    {
        const auto* retained = retainedBrowserPass(token);
        if (!retained)
            throw std::runtime_error("Native WebGPU frame references a released pass");

        const auto& geometry = retained->geometry;
        const auto& table = *retained->table;
        const auto triangleCount = geometry.triangles.size() / 4u;

        // Depth-only/shadow identities occupy the high bit. Their visual result
        // is not a color contribution to the browser surface.
        if ((state.target & 0x80000000u) != 0u)
            return;

        ensurePipeline();

        upload(mLayouts, geometry.vertexLayouts.data(), geometry.vertexLayouts.size() * sizeof(std::uint32_t), "OpenMW layouts");
        upload(mInputs, geometry.vertexInputs.data(), geometry.vertexInputs.size() * sizeof(float), "OpenMW compact vertices");
        upload(mVertices, geometry.vertices.data(), geometry.vertices.size() * sizeof(float), "OpenMW vertices");
        upload(mMatrices, geometry.matrices.data(), geometry.matrices.size() * sizeof(float), "OpenMW matrices");
        upload(mMatrixIds, geometry.matrixIds.data(), geometry.matrixIds.size() * sizeof(std::uint32_t), "OpenMW matrix ids");
        upload(mTriangles, geometry.triangles.data(), geometry.triangles.size() * sizeof(std::uint32_t), "OpenMW triangles");
        upload(mMaterials, table.materials().data(), table.materials().size() * sizeof(std::uint32_t), "OpenMW materials");
        upload(mTexels, table.texels().data(), table.texels().size() * sizeof(std::uint32_t), "OpenMW texture atlas");

        const std::array<std::uint32_t, 4> params{
            geometry.compactVertices ? 1u : 0u, width, height, 0u};
        upload(mParams, params.data(), sizeof(params), "OpenMW native direct params", wgpu::BufferUsage::Uniform);

        const std::array<wgpu::Buffer*, 9> buffers{
            &mLayouts.buffer, &mInputs.buffer, &mVertices.buffer, &mMatrices.buffer,
            &mMatrixIds.buffer, &mTriangles.buffer, &mMaterials.buffer, &mTexels.buffer, &mParams.buffer};
        const std::array<std::uint64_t, 9> sizes{
            std::max<std::uint64_t>(4, geometry.vertexLayouts.size() * 4ull),
            std::max<std::uint64_t>(4, geometry.vertexInputs.size() * 4ull),
            std::max<std::uint64_t>(4, geometry.vertices.size() * 4ull),
            std::max<std::uint64_t>(4, geometry.matrices.size() * 4ull),
            std::max<std::uint64_t>(4, geometry.matrixIds.size() * 4ull),
            std::max<std::uint64_t>(4, geometry.triangles.size() * 4ull),
            std::max<std::uint64_t>(4, table.materials().size() * 4ull),
            std::max<std::uint64_t>(4, table.texels().size() * 4ull),
            16ull};

        std::array<wgpu::BindGroupEntry, 9> bindEntries{};
        for (std::uint32_t i = 0; i < bindEntries.size(); ++i)
        {
            bindEntries[i].binding = i;
            bindEntries[i].buffer = *buffers[i];
            bindEntries[i].offset = 0;
            bindEntries[i].size = sizes[i];
        }
        wgpu::BindGroupDescriptor bindDescriptor{};
        bindDescriptor.label = "OpenMW native direct bindings";
        bindDescriptor.layout = mBindGroupLayout;
        bindDescriptor.entryCount = bindEntries.size();
        bindDescriptor.entries = bindEntries.data();
        auto bindGroup = DirectWebGPU::instance().deviceObject().CreateBindGroup(&bindDescriptor);

        wgpu::RenderPassColorAttachment color{};
        color.view = surfaceView;
        color.loadOp = (!touched || (state.clearMask & 0x00004000u)) ? wgpu::LoadOp::Clear : wgpu::LoadOp::Load;
        color.storeOp = wgpu::StoreOp::Store;
        color.clearValue = {state.clearColor[0], state.clearColor[1], state.clearColor[2], state.clearColor[3]};

        wgpu::RenderPassDepthStencilAttachment depth{};
        depth.view = mDepthView;
        depth.depthLoadOp = (!touched || (state.clearMask & 0x00000100u)) ? wgpu::LoadOp::Clear : wgpu::LoadOp::Load;
        depth.depthStoreOp = wgpu::StoreOp::Store;
        depth.depthClearValue = state.clearDepth;

        wgpu::RenderPassDescriptor passDescriptor{};
        passDescriptor.label = "OpenMW native direct pass";
        passDescriptor.colorAttachmentCount = 1;
        passDescriptor.colorAttachments = &color;
        passDescriptor.depthStencilAttachment = &depth;

        auto encoder = DirectWebGPU::instance().deviceObject().CreateCommandEncoder();
        auto pass = encoder.BeginRenderPass(&passDescriptor);
        pass.SetPipeline(mPipeline);
        pass.SetBindGroup(0, bindGroup);

        const auto viewportWidth = state.viewportWidth ? state.viewportWidth : width;
        const auto viewportHeight = state.viewportHeight ? state.viewportHeight : height;
        pass.SetViewport(static_cast<float>(std::max(0, state.viewportX)),
            static_cast<float>(std::max(0, state.viewportY)),
            static_cast<float>(viewportWidth), static_cast<float>(viewportHeight), 0.f, 1.f);
        if (triangleCount)
            pass.Draw(static_cast<std::uint32_t>(triangleCount * 3u));
        pass.End();

        auto commands = encoder.Finish();
        DirectWebGPU::instance().queueObject().Submit(1, &commands);
        touched = true;
    }

    void NativeWebGPURenderer::submitFrame(const std::vector<std::uint32_t>& commands)
    {
        if (commands.size() < 2 || commands[0] != 0x4f4d5747u || commands[1] != 1u)
            throw std::runtime_error("Invalid native WebGPU frame protocol");

        // The scene normally renders into an offscreen target and is later
        // resolved to the screen. Render only those scene sources plus target 0;
        // shadow/distortion scratch targets must not overwrite the browser.
        std::set<std::uint32_t> visibleTargets{0u};
        for (std::size_t cursor = 2; cursor + 1 < commands.size();)
        {
            const auto opcode = static_cast<BrowserOpcode>(commands[cursor]);
            const auto length = commands[cursor + 1];
            if (length < 2 || cursor + length > commands.size())
                throw std::runtime_error("Corrupt native WebGPU command stream");
            if (opcode == BrowserOpcode::Resolve && length >= 8)
                visibleTargets.insert(commands[cursor + 2]);
            cursor += length;
        }

        PassState state;
        struct QueuedPass { unsigned int token; PassState state; std::uint32_t width; std::uint32_t height; };
        std::vector<QueuedPass> passes;
        std::uint32_t surfaceWidth = 0, surfaceHeight = 0;

        for (std::size_t cursor = 2; cursor + 1 < commands.size();)
        {
            const auto opcode = static_cast<BrowserOpcode>(commands[cursor]);
            const auto length = commands[cursor + 1];
            if (length < 2 || cursor + length > commands.size())
                throw std::runtime_error("Corrupt native WebGPU command stream");

            if (opcode == BrowserOpcode::PassState)
            {
                if (length < 23)
                    throw std::runtime_error("Short native WebGPU pass state");
                state.clearMask = commands[cursor + 2];
                state.clearColor[0] = wordAsFloat(commands[cursor + 3]);
                state.clearColor[1] = wordAsFloat(commands[cursor + 4]);
                state.clearColor[2] = wordAsFloat(commands[cursor + 5]);
                state.clearColor[3] = wordAsFloat(commands[cursor + 6]);
                state.clearDepth = wordAsFloat(commands[cursor + 7]);
                state.target = commands[cursor + 8];
                state.viewportX = static_cast<std::int32_t>(commands[cursor + 17]);
                state.viewportY = static_cast<std::int32_t>(commands[cursor + 18]);
                state.viewportWidth = commands[cursor + 19];
                state.viewportHeight = commands[cursor + 20];
            }
            else if (opcode == BrowserOpcode::Pass)
            {
                if (length < 6)
                    throw std::runtime_error("Short native WebGPU pass command");
                const auto token = commands[cursor + 2];
                const auto width = commands[cursor + 4];
                const auto height = commands[cursor + 5];
                if (visibleTargets.count(state.target))
                {
                    passes.push_back({token, state, width, height});
                    surfaceWidth = std::max(surfaceWidth, width);
                    surfaceHeight = std::max(surfaceHeight, height);
                }
            }
            cursor += length;
        }

        if (passes.empty())
            return;

        ensureSurface(surfaceWidth, surfaceHeight);
        wgpu::SurfaceTexture surfaceTexture{};
        mSurface.GetCurrentTexture(&surfaceTexture);
        if (!surfaceTexture.texture)
            throw std::runtime_error("WebGPU surface did not provide a frame texture");
        auto surfaceView = surfaceTexture.texture.CreateView();

        bool touched = false;
        for (const auto& pass : passes)
            renderPass(pass.token, pass.state, pass.width, pass.height, surfaceView, touched);
    }

    void NativeWebGPURenderer::shutdown() noexcept
    {
        for (auto* slot : {&mLayouts, &mInputs, &mVertices, &mMatrices, &mMatrixIds,
                 &mTriangles, &mMaterials, &mTexels, &mParams, &mDummy})
        {
            if (slot->buffer)
                slot->buffer.Destroy();
            slot->buffer = {};
            slot->capacity = 0;
            slot->usage = wgpu::BufferUsage::None;
        }
        mPipeline = {};
        mPipelineLayout = {};
        mBindGroupLayout = {};
        mDepthView = {};
        mDepthTexture = {};
        mSurface = {};
        mSurfaceFormat = wgpu::TextureFormat::Undefined;
        mWidth = mHeight = 0;
    }
}

#endif
