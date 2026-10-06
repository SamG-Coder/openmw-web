// SPDX-License-Identifier: GPL-3.0-or-later
// Exact sample counts for OpenMW sun visibility. Native occlusion queries may
// report only a boolean on some WebGPU backends. An additive color attachment
// records fragments that pass the native depth/stencil tests instead.

// Binary16 represents every integer through 2048 exactly. Limiting a chunk to
// 1024 triangles leaves headroom while preserving every overlapping fragment:
// one triangle contributes at most one unit to a given pixel/sample.
export const MAX_VISIBILITY_TRIANGLES = 1024;

const PARAM_BYTES = 80;
const TILE_SIZE = 16;
const WORKGROUP_SIZE = TILE_SIZE * TILE_SIZE;
const BUFFER_USAGE = globalThis.GPUBufferUsage ?? {UNIFORM: 64, STORAGE: 128};
const TEXTURE_USAGE = globalThis.GPUTextureUsage ?? {TEXTURE_BINDING: 4, RENDER_ATTACHMENT: 16};

function reductionSource(samples) {
  const textureType = samples === 1 ? 'texture_2d<f32>' : 'texture_multisampled_2d<f32>';
  const contribution = Array.from({length: samples}, (_, sample) =>
    `u32(textureLoad(visibility, vec2<i32>(index.xy), ${sample}).r)`).join(' + ');
  return `
// This layout matches the renderer's existing per-draw RasterParams uniform.
struct RasterParams {
  width:u32, height:u32, capacity:u32, raster_offset:u32,
  boundary_offset:u32, point_fade_offset:u32, lighting_offset:u32, cluster_offset:u32,
  fixed_offset:u32, falloff_offset:u32, fixed_enabled:u32, normal_enabled:u32,
  normal_channels:u32, normal_storage:u32, color_channels:u32, color_storage:u32,
  depth_bits:u32, stencil_enabled:u32, sample_count:u32, draw_material:u32,
}
@group(0) @binding(0) var visibility:${textureType};
@group(0) @binding(1) var<storage,read_write> counts:array<atomic<u32>>;
@group(0) @binding(2) var<uniform> params:RasterParams;
var<workgroup> partial:array<u32,${WORKGROUP_SIZE}>;

@compute @workgroup_size(${TILE_SIZE},${TILE_SIZE},1)
fn reduce_visibility(@builtin(global_invocation_id) index:vec3<u32>,
                     @builtin(local_invocation_index) lane:u32) {
  var total=0u;
  if(index.x<params.width && index.y<params.height) {
    // Each float is an exact integer. Summation is integer arithmetic before
    // the workgroup reduction, including independent multisample values.
    total=${contribution};
  }
  partial[lane]=total;
  workgroupBarrier();
  var stride=${WORKGROUP_SIZE / 2}u;
  loop {
    if(lane<stride){partial[lane]+=partial[lane+stride];}
    workgroupBarrier();
    if(stride==1u){break;}
    stride/=2u;
  }
  if(lane==0u && partial[0]>0u) {
    let tiles=((params.width+15u)/16u)*((params.height+15u)/16u);
    // Atomic u32 addition also preserves the existing counter overflow ABI.
    atomicAdd(&counts[tiles+1u+params.draw_material],partial[0]);
  }
}`;
}

function bufferRange(buffer, usage, offset, size, label) {
  if (!buffer || typeof buffer.destroy !== 'function' || !Number.isSafeInteger(buffer.size)
      || !(buffer.usage & usage) || !Number.isSafeInteger(offset) || offset < 0
      || offset + size > buffer.size)
    throw RangeError(`Invalid visibility ${label} buffer range`);
}

export class ExactVisibilityCounter {
  static async create(runtime) {
    const counter = new ExactVisibilityCounter(runtime);
    try {
      await Promise.all([1, 4].map(async samples => {
        const module = counter.device.createShaderModule({
          label: `OpenMW exact visibility reduction ${samples}x`, code: reductionSource(samples),
        });
        const information = await module.getCompilationInfo();
        const errors = information.messages.filter(message => message.type === 'error');
        if (errors.length) throw Error(errors.map(message =>
          `Visibility reduction:${message.lineNum}:${message.linePos} ${message.message}`).join('\n'));
        counter.assertAlive();
        const pipeline = await counter.device.createComputePipelineAsync({
          label: `OpenMW exact visibility reduction ${samples}x`, layout: 'auto',
          compute: {module, entryPoint: 'reduce_visibility'},
        });
        counter.assertAlive();
        counter.pipelines.set(samples, pipeline);
      }));
      return counter;
    } catch (error) { counter.dispose(); throw error; }
  }

  constructor(runtime) {
    if (!runtime?.device) throw TypeError('ExactVisibilityCounter requires a WebGPU runtime');
    this.runtime = runtime; this.device = runtime.device;
    this.targets = new Map(); this.pipelines = new Map(); this.disposed = false;
    this.assertAlive();
  }

  assertAlive() {
    if (this.disposed) throw Error('Exact visibility counter has been disposed');
    this.runtime.assertAlive?.();
  }

  /** Acquire before recording a render. Clear this view to zero for every
   * <= MAX_VISIBILITY_TRIANGLES chunk; draw with additive one/one blending and
   * the original depth/stencil attachment, then immediately call encode(). */
  target({width, height, samples = 1}) {
    this.assertAlive();
    if (![width, height].every(value => Number.isInteger(value) && value > 0
        && value <= this.device.limits.maxTextureDimension2D) || ![1, 4].includes(samples))
      throw RangeError('Invalid exact visibility target dimensions or sample count');
    const key = `${width}:${height}:${samples}`;
    let target = this.targets.get(key);
    if (target) { this.targets.delete(key); this.targets.set(key, target); return target; }
    const pipeline = this.pipelines.get(samples);
    if (!pipeline) throw Error('Exact visibility pipelines are not initialized');
    const texture = this.device.createTexture({
      label: 'OpenMW exact visibility counter', size: [width, height], sampleCount: samples,
      format: 'rgba16float', usage: TEXTURE_USAGE.RENDER_ATTACHMENT | TEXTURE_USAGE.TEXTURE_BINDING,
    });
    try {
      target = {texture, view: texture.createView(), pipeline, width, height, samples, owner: this};
    } catch (error) { texture.destroy(); throw error; }
    this.targets.set(key, target);
    // Render calls submit before acquiring a different target. Keep the common
    // screen/MSAA sizes without retaining a full-size texture for every camera.
    if (this.targets.size > 4) {
      const [retiredKey, retired] = this.targets.entries().next().value;
      this.targets.delete(retiredKey); retired.texture.destroy(); retired.retired = true;
    }
    return target;
  }

  /** Record the reduction in the same encoder, after ending the counter pass.
   * Uniforms are the immutable 80-byte RasterParams slice for this query run.
   * Neither queue submission nor CPU readback is needed between chunks. */
  encode(encoder, target, {counts, uniforms, uniformOffset = 0}) {
    this.assertAlive();
    if (target?.owner !== this || target.retired) throw Error('Invalid exact visibility target');
    const alignment = this.device.limits.minUniformBufferOffsetAlignment;
    if (!Number.isSafeInteger(uniformOffset) || uniformOffset < 0 || uniformOffset % alignment)
      throw RangeError('Visibility uniform offset is not aligned');
    bufferRange(uniforms, BUFFER_USAGE.UNIFORM, uniformOffset, PARAM_BYTES, 'uniform');
    const tiles = Math.ceil(target.width / TILE_SIZE) * Math.ceil(target.height / TILE_SIZE);
    bufferRange(counts, BUFFER_USAGE.STORAGE, 0, (tiles + 2) * 4, 'counter');
    if (counts.size > this.device.limits.maxStorageBufferBindingSize)
      throw RangeError('Visibility counter exceeds storage binding limit');
    const group = this.device.createBindGroup({
      label: 'OpenMW exact visibility buffers', layout: target.pipeline.getBindGroupLayout(0), entries: [
        {binding: 0, resource: target.view},
        {binding: 1, resource: {buffer: counts}},
        {binding: 2, resource: {buffer: uniforms, offset: uniformOffset, size: PARAM_BYTES}},
      ],
    });
    const pass = encoder.beginComputePass({label: 'OpenMW reduce exact visible samples'});
    pass.setPipeline(target.pipeline); pass.setBindGroup(0, group);
    pass.dispatchWorkgroups(Math.ceil(target.width / TILE_SIZE), Math.ceil(target.height / TILE_SIZE), 1);
    pass.end();
  }

  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    for (const target of this.targets.values()) { target.texture.destroy(); target.retired = true; }
    this.targets.clear(); this.pipelines.clear();
  }
}
