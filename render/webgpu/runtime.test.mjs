import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {WebGPURuntime} from './runtime.js';
import {kernelManifest, loadKernel} from './kernel-manifest.js';

const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
};
const tick = () => new Promise(setImmediate);

// The fake queue executes encoded copies and one tiny test kernel at submit.
// This exposes ordering and stale-uniform bugs that call-count mocks miss.
function fixture(options = {}) {
  const events = [], allocated = [], dispatches = [], errors = [], lost = deferred();
  let identifier = 0, errorScopes = 0;
  const device = {
    limits: {maxBufferSize: 1024 * 1024, maxStorageBufferBindingSize: 1024 * 1024,
      maxUniformBufferBindingSize: 65536, minUniformBufferOffsetAlignment: 256,
      maxStorageBuffersPerShaderStage: 8, maxBindingsPerBindGroup: 1000,
      maxComputeWorkgroupSizeX: 256, maxComputeWorkgroupSizeY: 256, maxComputeWorkgroupSizeZ: 64,
      maxComputeInvocationsPerWorkgroup: 256, maxComputeWorkgroupStorageSize: 16384,
      maxComputeWorkgroupsPerDimension: 65535, maxTextureDimension2D: 8192},
    features: new Set(['timestamp-query']), lost: lost.promise, mapGate: null, listeners: new Map(), destroyed: false,
    addEventListener(name, callback) { this.listeners.set(name, callback); },
    removeEventListener(name, callback) { if (this.listeners.get(name) === callback) this.listeners.delete(name); },
    pushErrorScope() { errorScopes++; },
    popErrorScope() { errorScopes--; assert(errorScopes >= 0); return Promise.resolve(null); },
    createShaderModule(descriptor) {
      return {...descriptor, async getCompilationInfo() {
        return {messages: descriptor.code === 'invalid' ? [{type: 'error', lineNum: 4, linePos: 7, message: 'Bad WGSL'}] : []};
      }};
    },
    createBindGroupLayout(descriptor) { return descriptor; },
    createPipelineLayout(descriptor) { return descriptor; },
    async createComputePipelineAsync(descriptor) { return descriptor; },
    createBindGroup(descriptor) { return descriptor; },
    createBuffer({size, usage, label}) {
      assert(Number.isSafeInteger(size) && size > 0 && size <= this.limits.maxBufferSize);
      const bytes = new Uint8Array(size), id = ++identifier;
      const buffer = {id, size, usage, label, bytes, destroyed: false, destroyCount: 0, mapState: 'unmapped',
        destroy() { this.destroyed = true; this.destroyCount++; events.push(['destroy', id]); },
        async mapAsync() { this.mapState = 'pending'; if (device.mapGate) await device.mapGate.promise; this.mapState = 'mapped'; },
        getMappedRange() { assert.equal(this.mapState, 'mapped'); assert(!this.destroyed); return this.bytes.buffer; },
        unmap() { assert.equal(this.mapState, 'mapped'); this.mapState = 'unmapped'; },
      };
      allocated.push(buffer); return buffer;
    },
    createCommandEncoder({label} = {}) {
      const commands = [];
      return {
        beginComputePass() {
          let pipeline, group, offsets, closed = false;
          return {
            setPipeline(value) { assert(!closed); pipeline = value; },
            setBindGroup(index, value, dynamicOffsets) { assert(!closed); group = value; offsets = [...dynamicOffsets]; },
            dispatchWorkgroups(...groups) { assert(!closed); commands.push({type: 'dispatch', pipeline, group, offsets, groups}); },
            dispatchWorkgroupsIndirect(buffer, offset) { assert(!closed); commands.push({type: 'dispatch', pipeline, group, offsets, indirect: {buffer, offset}}); },
            end() { assert(!closed); closed = true; },
          };
        },
        copyBufferToBuffer(source, sourceOffset, target, targetOffset, byteLength) {
          commands.push({type: 'copy', source, sourceOffset, target, targetOffset, byteLength});
        },
        copyBufferToTexture(source, target, size) { commands.push({type: 'present', source, target, size}); },
        resolveQuerySet() { commands.push({type: 'resolve'}); },
        finish() { return {label, commands}; },
      };
    },
    destroy() { this.destroyed = true; events.push(['device-destroy']); lost.resolve({reason: 'destroyed', message: ''}); },
  };
  device.queue = {
    writeBuffer(buffer, offset, source, sourceOffset = 0, byteLength = source.byteLength - sourceOffset) {
      assert(!buffer.destroyed);
      const view = ArrayBuffer.isView(source)
        ? new Uint8Array(source.buffer, source.byteOffset + sourceOffset, byteLength)
        : new Uint8Array(source, sourceOffset, byteLength);
      buffer.bytes.set(view, offset); events.push(['write', buffer.id, offset, [...view]]);
    },
    submit(commandBuffers) {
      events.push(['submit', commandBuffers.length]);
      for (const list of commandBuffers) for (const command of list.commands) {
        if (command.type === 'copy') {
          assert(!command.source.destroyed && !command.target.destroyed);
          command.target.bytes.set(command.source.bytes.subarray(command.sourceOffset, command.sourceOffset + command.byteLength), command.targetOffset);
        } else if (command.type === 'dispatch') {
          const storage = command.group.entries.find(entry => entry.binding === 0).resource.buffer;
          const params = command.group.entries.find(entry => entry.binding === 1).resource.buffer;
          assert(!storage.destroyed && !params.destroyed);
          const data = new DataView(params.bytes.buffer, command.offsets[0]);
          const values = [data.getUint32(0, true), data.getInt32(4, true), data.getFloat32(8, true)];
          dispatches.push({values, uniforms: params, offset: command.offsets[0], groups: command.groups});
          new DataView(storage.bytes.buffer).setUint32(0, values[0], true);
        } else if (command.type === 'present') {
          assert(!command.source.buffer.destroyed);
          events.push(['present', command.source.buffer.bytes[0]]);
        }
      }
    },
    onSubmittedWorkDone() { return Promise.resolve(); },
  };
  const runtime = new WebGPURuntime(device, {onError: error => errors.push(error), ...options});
  return {runtime, device, events, allocated, dispatches, errors, lost};
}

const artifact = {
  name: 'write_value', entryPoint: 'main', wgsl: '// test shader supplied by the fake device',
  metadata: {workgroupSize: [64, 1, 1], workgroupStorageBytes: 0,
    bindings: [{name: 'target', binding: 0, elementType: 'u32', stride: 4, readOnly: false, atomic: false}],
    scalars: [{name: 'value', type: 'u32', offset: 0}, {name: 'index', type: 'i32', offset: 4},
      {name: 'weight', type: 'f32', offset: 8}], uniformBinding: 1, uniformSize: 16},
  defaults: {index: -3, weight: .25},
};

test('dispatch scalar values are immutable snapshots with correct WGSL signed and float layouts', async () => {
  const f = fixture(), r = f.runtime, target = r.createBuffer(4), result = r.createBuffer(8);
  const kernel = await r.kernel(artifact), values = {value: 17};
  const invocation = kernel.bind({target}, values), batch = r.batch();
  batch.dispatch(invocation, [1, 1, 1]).copy(target, result, {byteLength: 4});
  values.value = 999;
  invocation.setScalars({value: 23, index: -9, weight: -.75});
  batch.dispatch(invocation, [2, 1, 1]).copy(target, result, {targetOffset: 4, byteLength: 4});
  invocation.scalars.value = 1000;
  batch.submit();
  assert.deepEqual(await r.read(result, Uint32Array), new Uint32Array([17, 23]));
  assert.deepEqual(f.dispatches.map(dispatch => dispatch.values), [[17, -3, .25], [23, -9, -.75]]);
  assert.deepEqual(f.dispatches.map(dispatch => dispatch.offset), [0, 256]);
  assert.equal(f.dispatches[0].uniforms, f.dispatches[1].uniforms);
  assert.equal(f.dispatches[0].uniforms.size, 512, 'Small batches do not allocate a full 64 KiB arena');
  assert.equal(f.dispatches[0].uniforms.bytes[12], 0, 'WGSL padding stays zero');
  await r.dispose();
});

test('consecutive batches coalesce without overwriting another dispatch uniform buffer', async () => {
  const f = fixture(), r = f.runtime, target = r.createBuffer(4), result = r.createBuffer(12), kernel = await r.kernel(artifact);
  const completions = [];
  for (let value = 1; value <= 3; value++) completions.push(r.batch()
    .dispatch(kernel.bind({target}, {value}), [1, 1, 1])
    .copy(target, result, {byteLength: 4, targetOffset: (value - 1) * 4}).submit());
  assert.equal(completions[0], completions[1]);
  assert.equal(f.events.filter(event => event[0] === 'submit').length, 0);
  await Promise.all(completions);
  assert.equal(r.stats.submissions, 1); assert.equal(r.stats.coalescedBatches, 2);
  assert.deepEqual(await r.read(result, Uint32Array), new Uint32Array([1, 2, 3]));
  assert.equal(new Set(f.dispatches.map(dispatch => dispatch.uniforms)).size, 3);
  await r.dispose();
});

test('an upload ends pending submissions before its new buffer contents become visible', async () => {
  const f = fixture(), r = f.runtime, target = r.createBuffer(4), result = r.createBuffer(8), kernel = await r.kernel(artifact);
  r.batch().dispatch(kernel.bind({target}, {value: 7}), [1, 1, 1]).copy(target, result, {byteLength: 4}).submit();
  const upload = new Uint32Array([91]); r.write(target, upload); upload[0] = 999;
  r.batch().copy(target, result, {targetOffset: 4, byteLength: 4}).submit();
  assert.deepEqual(await r.read(result, Uint32Array), new Uint32Array([7, 91]));
  const submit = f.events.findIndex(event => event[0] === 'submit');
  const write = f.events.findIndex(event => event[0] === 'write' && event[1] === target.gpuBuffer.id);
  assert(submit < write); await r.dispose();
});

test('shared WASM heap views upload using their byte offset and snapshot before caller mutation', async () => {
  const f = fixture(), r = f.runtime, target = r.createBuffer(16), heap = new Uint32Array(new SharedArrayBuffer(32));
  heap.set([81, 82, 83, 84], 2); r.writeBorrowed(target, heap.subarray(3, 5), 4); heap.fill(999);
  assert.deepEqual(await r.read(target, Uint32Array), new Uint32Array([0, 82, 83, 0]));
  assert.equal(r.stats.dataBytesUploaded, 8); assert.equal(r.stats.borrowedUploadBytes, 8);
  assert.equal(r.stats.copiedUploadBytes, 0); await r.dispose();
});

test('direct WASM buffer ranges copy and read at their absolute GPU offset without host reuploads',async()=>{
  const f=fixture(),r=f.runtime;
  const owner=f.device.createBuffer({size:1024,usage:128|4|8,label:'WASM frame owner'});
  f.device.queue.writeBuffer(owner,256,new Uint32Array([17,23,31]));
  const direct=r.importExternalBuffer(owner,12,{offset:256});
  const destination=r.createBuffer(16),uploads=r.stats.dataBytesUploaded;
  r.batch().copy(direct,destination,{sourceOffset:4,targetOffset:4,byteLength:8}).submit();
  assert.deepEqual(await r.read(destination,Uint32Array),new Uint32Array([0,23,31,0]));
  assert.deepEqual(await r.read(direct,Uint32Array,4,8),new Uint32Array([31]));
  assert.equal(r.stats.dataBytesUploaded,uploads);
  const readonly={...artifact,metadata:{...artifact.metadata,
    bindings:artifact.metadata.bindings.map(binding=>({...binding,readOnly:true}))}};
  const kernel=await r.kernel(readonly);
  assert.doesNotThrow(()=>kernel.bind({target:direct},{value:0}));
  const group=r.bindGroupCache.get(kernel,{target:direct},f.device.createBuffer({size:256,usage:64|8}));
  const binding=group.entries.find(entry=>entry.binding===0).resource;
  assert.equal(binding.buffer,owner);assert.equal(binding.offset,256);assert.equal(binding.size,12);
  r.releaseExternalBuffer(direct);r.releaseExternalBuffer(direct);
  assert.equal(owner.destroyCount,0);assert.equal(r.buffers.has(direct),false);
  await r.dispose();assert.equal(owner.destroyCount,0);
});

test('WASM-owned buffers cannot be mutated or destroyed through imported aliases',async()=>{
  const f=fixture(),r=f.runtime,owner=f.device.createBuffer({size:1024,usage:128|4|8});
  const first=r.importExternalBuffer(owner,4),second=r.importExternalBuffer(owner,4,{offset:256});
  const kernel=await r.kernel(artifact),source=r.createBuffer(4);
  assert.throws(()=>kernel.bind({target:first},{value:5}),/immutable/);
  assert.throws(()=>r.write(first,new Uint32Array([5])),/immutable/);
  const batch=r.batch();assert.throws(()=>batch.copy(source,first),/immutable/);batch.discard();
  r.destroyBuffer(first);r.destroyBufferCompleted(second);
  assert.equal(owner.destroyCount,0);assert.equal(r.buffers.size,1);
  r.importExternalBuffer(owner,4,{offset:512});
  await r.dispose();assert.equal(owner.destroyCount,0);
});

test('direct imports enforce device storage alignment, limits and actual buffer usage',async()=>{
  const f=fixture(),r=f.runtime,owner=f.device.createBuffer({size:1024,usage:128|4|8});
  for(const [bytes,options] of [[4,{offset:4}],[0,{}],[3,{}],[8,{offset:1024}],[1028,{}]])
    assert.throws(()=>r.importExternalBuffer(owner,bytes,options),/external WebGPU buffer range/);
  assert.throws(()=>r.importExternalBuffer({...owner,usage:8},4),/external/);
  f.device.limits.minStorageBufferOffsetAlignment=512;
  assert.throws(()=>r.importExternalBuffer(owner,4,{offset:256}),/external/);
  assert.doesNotThrow(()=>r.importExternalBuffer(owner,4,{offset:512}));
  await r.dispose();assert.equal(owner.destroyCount,0);
});

test('the shared-buffer compatibility fallback reports copied bytes without counting direct uploads', async () => {
  const f = fixture(), r = f.runtime, target = r.createBuffer(8), heap = new Uint32Array(new SharedArrayBuffer(16));
  const write = f.device.queue.writeBuffer;
  f.device.queue.writeBuffer = (buffer, offset, source, ...rest) => {
    if (source instanceof SharedArrayBuffer) throw new TypeError('Shared source unsupported');
    return write(buffer, offset, source, ...rest);
  };
  heap.set([7, 8], 1); r.writeBorrowed(target, heap.subarray(1, 3)); heap.fill(999);
  assert.deepEqual(await r.read(target, Uint32Array), new Uint32Array([7, 8]));
  assert.equal(r.stats.dataBytesUploaded, 8); assert.equal(r.stats.borrowedUploadBytes, 0);
  assert.equal(r.stats.copiedUploadBytes, 8); await r.dispose();
});

test('destroying a pending resource submits its earlier work first and rejects later use', async () => {
  const f = fixture(), r = f.runtime, target = r.createBuffer(4), kernel = await r.kernel(artifact);
  r.batch().dispatch(kernel.bind({target}, {value: 5}), [1, 1, 1]).submit();
  r.destroyBuffer(target);
  assert.deepEqual(f.dispatches[0].values, [5, -3, .25]);
  assert.equal(target.gpuBuffer.destroyCount, 1); r.destroyBuffer(target);
  assert.equal(target.gpuBuffer.destroyCount, 1);
  assert.throws(() => r.write(target, new Uint32Array([0])), /destroyed/);
  assert.throws(() => kernel.bind({target}, {value: 0}), /destroyed/);
  await r.dispose();
});

test('buffer growth preserves previous bytes and GPU usage supports hardware vertex/index input', async () => {
  const f = fixture(), r = f.runtime, previous = r.createBuffer(new Uint32Array([5, 6]));
  const replacement = r.growBuffer(previous, 16);
  r.destroyBuffer(previous);
  assert.deepEqual(await r.read(replacement, Uint32Array), new Uint32Array([5, 6, 0, 0]));
  assert.equal(replacement.gpuBuffer.usage & (16 | 32 | 256), 16 | 32 | 256);
  await r.dispose();
});

test('binding, dispatch, scalar and byte-range limits reject invalid work before submission', async () => {
  const f = fixture({uniformCapacity: 256}), r = f.runtime, target = r.createBuffer(4), kernel = await r.kernel(artifact);
  for (const value of [NaN, Infinity, -1, 1.5, 0x100000000]) assert.throws(() => kernel.bind({target}, {value}), /Invalid scalar/);
  assert.throws(() => kernel.bind({target}, {value: 1, typo: 7}), /Invalid scalar/);
  assert.throws(() => kernel.bind({target}, {value: 1, weight: 1e100}), /Invalid scalar/);
  assert.throws(() => kernel.bind({target}, {}), /Missing scalar/);
  assert.throws(() => kernel.bind({target, extra: target}, {value: 1}), /Unknown buffer/);
  const invocation = kernel.bind({target}, {value: 1});
  for (const groups of [[65536, 1, 1], [-1, 1, 1], [1, 1], [1.5, 1, 1]]) {
    const batch = r.batch(); assert.throws(() => batch.dispatch(invocation, groups), /Dispatch/); batch.discard();
  }
  const overflow = r.batch().dispatch(invocation, [1, 1, 1]);
  assert.throws(() => overflow.dispatch(invocation, [1, 1, 1]), /arena capacity/); overflow.discard();
  for (const size of [-4, 3, Infinity, f.device.limits.maxBufferSize + 4]) assert.throws(() => r.createBuffer(size), /size/);
  assert.throws(() => r.createBuffer(4, {usage: 1}), /mapped/);
  assert.throws(() => r.write(target, new Uint32Array([1]), 1), /range/);
  assert.throws(() => r.read(target, Uint32Array, 8), /range/);
  const copy = r.batch(); assert.throws(() => copy.copy(target, target), /distinct/); copy.discard();
  const foreign = fixture(), other = foreign.runtime.createBuffer(4);
  assert.throws(() => kernel.bind({target: other}, {value: 1}), /another runtime/);
  assert.equal(f.events.filter(event => event[0] === 'submit').length, 0);
  await foreign.runtime.dispose(); await r.dispose();
});

test('metadata rejects overlapping layouts and device binding/workgroup limits', async () => {
  const f = fixture(), r = f.runtime;
  const reject = async (metadata, pattern) => assert.rejects(r.kernel({...artifact, metadata}), pattern);
  await reject({...artifact.metadata, uniformSize: 12}, /uniform size/);
  await reject({...artifact.metadata, uniformBinding: 0}, /binding location/);
  await reject({...artifact.metadata, scalars: [...artifact.metadata.scalars, {name: 'extra', type: 'u32', offset: 4}]}, /scalar layout/);
  await reject({...artifact.metadata, workgroupSize: [257, 1, 1]}, /workgroup/);
  await reject({...artifact.metadata, workgroupStorageBytes: 20000}, /storage/);
  await reject({...artifact.metadata, bindings: Array.from({length: 9}, (_, binding) =>
    ({...artifact.metadata.bindings[0], name: `b${binding}`, binding}))}, /bindings exceed/);
  assert.equal(r.stats.pipelineCompiles, 0); await r.dispose();
});

test('shader errors include WGSL locations and failed pipelines do not poison the cache', async () => {
  const f = fixture(), r = f.runtime;
  await assert.rejects(r.kernel({...artifact, wgsl: 'invalid'}), /4:7 Bad WGSL/);
  assert.equal(r.kernelCache.size, 0);
  const [first, second] = await Promise.all([r.kernel(artifact), r.kernel(artifact)]);
  assert.equal(first, second); assert.equal(r.stats.pipelineCompiles, 1); assert.equal(r.stats.pipelineCacheHits, 1);
  await assert.rejects(r.kernel({...artifact, native: {}}), /standalone WGSL/);
  await r.dispose();
});

test('timed batches submit before query readbacks and presentation flushes preceding compute', async () => {
  const f = fixture(), r = f.runtime, target = r.createBuffer(256), kernel = await r.kernel(artifact);
  const timed = r.batch({timestampWrites: {querySet: {}, beginningOfPassWriteIndex: 0, endOfPassWriteIndex: 1}});
  timed.dispatch(kernel.bind({target}, {value: 31}), [1, 1, 1]); timed.endPass(); timed.encoder.resolveQuerySet(); timed.submit();
  assert.equal(f.events.filter(event => event[0] === 'submit').length, 1);
  r.batch().dispatch(kernel.bind({target}, {value: 42}), [1, 1, 1]).submit();
  r.presentBuffer(target, {getCurrentTexture: () => ({})}, 1, 1, 64);
  assert.deepEqual(f.events.filter(event => event[0] === 'present'), [['present', 42]]);
  await r.dispose();
});

test('dispose finishes accepted mappings and destroys pending batches and every owned allocation', async () => {
  const f = fixture(), r = f.runtime, target = r.createBuffer(new Uint32Array([73])), kernel = await r.kernel(artifact);
  const abandoned = r.batch().dispatch(kernel.bind({target}, {value: 8}), [1, 1, 1]); abandoned.endPass();
  f.device.mapGate = deferred();
  const read = r.read(target, Uint32Array), dispose = r.dispose();
  await tick(); assert(!target.destroyed); assert(!f.device.destroyed);
  assert.throws(() => r.createBuffer(4), /disposed/);
  f.device.mapGate.resolve();
  assert.deepEqual(await read, new Uint32Array([73])); await dispose;
  assert.equal(r.buffers.size, 0); assert.equal(r.openBatches.size, 0); assert.equal(r.arenas.size, 0);
  assert(f.allocated.every(buffer => buffer.destroyCount === 1));
  assert.equal(r.dispose(), dispose); assert(f.device.destroyed); assert.equal(f.errors.length, 0);
});

test('device loss rejects pending work and keeps cleanup usable', async () => {
  const f = fixture(), r = f.runtime, target = r.createBuffer(4), kernel = await r.kernel(artifact);
  const completion = r.batch().dispatch(kernel.bind({target}, {value: 8}), [1, 1, 1]).submit();
  f.device.listeners.get('uncapturederror')({error: new Error('GPU failed')});
  await assert.rejects(completion, /GPU failed/);
  assert.throws(() => r.batch(), /GPU failed/); assert.equal(f.errors.length, 1);
  r.destroyBuffer(target); await r.dispose();
  assert(f.allocated.every(buffer => buffer.destroyCount === 1));
});

test('device loss while a readback is mapping rejects the read and releases staging memory', async () => {
  const f = fixture(), r = f.runtime, target = r.createBuffer(new Uint32Array([8]));
  f.device.mapGate = deferred();
  const read = r.read(target, Uint32Array);
  // Attach the rejection assertion before either promise can settle.
  const rejected = assert.rejects(read, /device lost/);
  f.lost.resolve({reason: 'unknown', message: 'Adapter removed'});
  await tick(); f.device.mapGate.resolve(); await rejected;
  assert.equal(f.errors.length, 1);
  assert.throws(() => r.batch(), /Adapter removed/);
  await r.dispose();
  assert(f.allocated.every(buffer => buffer.destroyCount === 1));
});

test('adapter feature negotiation enables optional hardware paths without requiring unavailable features', async () => {
  const f = fixture(), supported = new Set(['timestamp-query', 'depth-clip-control', 'float32-blendable']);
  let request;
  const adapter = {features: supported, limits: f.device.limits,
    async requestDevice(options) { request = options; return f.device; }};
  const gpu = {async requestAdapter(options) { assert.equal(options.powerPreference, 'high-performance'); return adapter; }};
  const runtime = await WebGPURuntime.create({gpu});
  assert.deepEqual(new Set(request.requiredFeatures), supported);
  assert.equal(request.requiredLimits.maxStorageBufferBindingSize, f.device.limits.maxStorageBufferBindingSize);
  await assert.rejects(WebGPURuntime.create({gpu, requiredFeatures: ['depth32float-stencil8']}), /unavailable/);
  await runtime.dispose(); await f.runtime.dispose();
});

test('every compute manifest entry binds a standalone WGSL source with matching storage/uniform declarations', async () => {
  const names = new Set();
  for (const entry of kernelManifest) {
    assert(!names.has(entry.entry)); names.add(entry.entry);
    assert(entry.file.endsWith('.wgsl')); assert(!Object.hasOwn(entry, 'native'));
    const source = await readFile(new URL(entry.file, import.meta.url), 'utf8');
    assert(source.includes('@compute')); assert(!source.includes('__global__'));
    assert(!source.includes('CUDA WebShader'));
    for (const binding of entry.metadata.bindings) {
      const access = binding.readOnly ? 'read' : 'read_write';
      assert(new RegExp(`@binding\\(${binding.binding}\\)\\s+var<storage,\\s*${access}>`).test(source), `${entry.entry}.${binding.name}`);
    }
    assert(new RegExp(`@binding\\(${entry.metadata.uniformBinding}\\)\\s+var<uniform>`).test(source), entry.entry);
    const loaded = await loadKernel({kernel: async value => value}, entry.entry, {
      fetch: async url => ({ok: true, text: async () => readFile(url, 'utf8')}),
    });
    assert.equal(loaded.wgsl, source); assert.equal(loaded.metadata, entry.metadata);
  }
  for (const excluded of ['raster_material', 'clip_triangles', 'bin_triangles', 'bin_triangle_bounds', 'sort_tile_candidates'])
    assert(!names.has(excluded), `${excluded} must be handled by the hardware pipeline`);
  for (const name of ['assemble_material', 'assemble_attributes', 'assemble_fixed_lighting', 'assemble_unlit_falloff', 'assemble_vertex_lighting']) {
    const source = await readFile(new URL(`kernels/${name}.wgsl`, import.meta.url), 'utf8');
    assert(!/v_sourceSlot\s*\//.test(source), `${name} must use one input triangle per slot`);
  }
  await assert.rejects(loadKernel({}, 'missing'), /Unknown/);
});
