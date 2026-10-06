// SPDX-License-Identifier: GPL-3.0-or-later
import assert from 'node:assert/strict';
import test from 'node:test';
import {WebGPURuntime} from './runtime.js';
import {ComputeBindGroupCache, ReadbackBufferPool} from './runtime-reuse.js';

const gate = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => {resolve = yes; reject = no;});
  return {promise, resolve, reject};
};
const tick = () => new Promise(setImmediate);

// Execute actual encoded copies and uniform reads, not just API-call counters.
// Mapping/fences can be held open to exercise the two-frames-in-flight lifetime.
function fixture(options = {}) {
  const allocated = [], dispatches = [], groups = [], errors = [], lost = gate();
  const device = {
    limits: {maxBufferSize: 16 * 1024 * 1024, maxStorageBufferBindingSize: 16 * 1024 * 1024,
      maxUniformBufferBindingSize: 65536, minUniformBufferOffsetAlignment: 256,
      maxComputeWorkgroupsPerDimension: 65535, maxTextureDimension2D: 8192},
    features: new Set(), lost: lost.promise, listeners: new Map(), mapGate: null, fenceGate: null,
    addEventListener(name, fn) {this.listeners.set(name, fn);},
    removeEventListener(name) {this.listeners.delete(name);},
    createShaderModule(descriptor) {return {...descriptor, getCompilationInfo: async () => ({messages: []})};},
    createBindGroupLayout(descriptor) {return descriptor;},
    createPipelineLayout(descriptor) {return descriptor;},
    async createComputePipelineAsync(descriptor) {return descriptor;},
    createBindGroup(descriptor) {groups.push(descriptor); return descriptor;},
    createBuffer({size, usage, label}) {
      const buffer = {size, usage, label, data: new Uint8Array(size), destroyed: false,
        mapState: 'unmapped', destroyCount: 0,
        destroy() {this.destroyed = true; this.destroyCount++;},
        async mapAsync(mode, offset = 0, byteLength = this.size - offset) {
          assert.equal(this.mapState, 'unmapped'); this.mapState = 'pending';
          try {if (device.mapGate) await device.mapGate.promise;}
          catch (error) {this.mapState = 'unmapped'; throw error;}
          assert(!this.destroyed); this.mapState = 'mapped'; this.mappedBytes = byteLength;
        },
        getMappedRange(offset = 0, byteLength = this.mappedBytes - offset) {
          assert.equal(this.mapState, 'mapped'); assert(!this.destroyed);
          return this.data.buffer.slice(offset, offset + byteLength);
        },
        unmap() {assert.equal(this.mapState, 'mapped'); this.mapState = 'unmapped';},
      };
      allocated.push(buffer); return buffer;
    },
    createCommandEncoder() {
      const commands = [];
      return {
        copyBufferToBuffer(source, sourceOffset, target, targetOffset, bytes) {
          commands.push(() => {
            assert(!source.destroyed && !target.destroyed);
            assert.equal(target.mapState, 'unmapped');
            target.data.set(source.data.subarray(sourceOffset, sourceOffset + bytes), targetOffset);
          });
        },
        beginComputePass() {
          let group, offsets;
          return {
            setPipeline() {},
            setBindGroup(index, value, dynamic) {group = value; offsets = [...dynamic];},
            dispatchWorkgroups() {
              const savedGroup = group, savedOffsets = offsets;
              commands.push(() => {
                const output = savedGroup.entries.find(entry => entry.binding === 0).resource.buffer;
                const uniform = savedGroup.entries.find(entry => entry.binding === 1).resource.buffer;
                assert(!output.destroyed && !uniform.destroyed);
                const view = new DataView(uniform.data.buffer, savedOffsets[0]);
                const values = [view.getUint32(0, true), view.getInt32(4, true), view.getFloat32(8, true)];
                new DataView(output.data.buffer).setUint32(0, values[0], true);
                dispatches.push({values, group: savedGroup, offset: savedOffsets[0], uniform});
              });
            },
            end() {},
          };
        },
        finish() {return commands;},
      };
    },
    destroy() {lost.resolve({reason: 'destroyed', message: ''});},
  };
  device.queue = {
    writeBuffer(buffer, offset, source, sourceOffset = 0, size = source.byteLength - sourceOffset) {
      assert(!buffer.destroyed);
      const bytes = ArrayBuffer.isView(source)
        ? new Uint8Array(source.buffer, source.byteOffset + sourceOffset, size)
        : new Uint8Array(source, sourceOffset, size);
      buffer.data.set(bytes, offset);
    },
    submit(commandBuffers) {for (const commands of commandBuffers) for (const command of commands) command();},
    onSubmittedWorkDone() {return device.fenceGate?.promise ?? Promise.resolve();},
  };
  return {device, allocated, dispatches, groups, errors, lost,
    runtime: new WebGPURuntime(device, {onError: error => errors.push(error), ...options})};
}

const artifact = {
  name: 'reuse-test', wgsl: `struct P { value:u32, index:i32, weight:f32, pad:u32 }
@group(0) @binding(0) var<storage,read_write> dst:array<u32>;
@group(0) @binding(1) var<uniform> p:P;
@compute @workgroup_size(1) fn main(){dst[0]=p.value;}`,
  metadata: {bindings: [{name: 'output', binding: 0, readOnly: false, stride: 4, elementType: 'u32'}],
    scalars: [{name: 'value', type: 'u32', offset: 0}, {name: 'index', type: 'i32', offset: 4},
      {name: 'weight', type: 'f32', offset: 8}], uniformSize: 16, uniformBinding: 1, workgroupSize: [1, 1, 1]},
  defaults: {index: -3, weight: 0.25},
};

async function runWorkload(options = {}, frameCount = 100) {
  const f = fixture(options), r = f.runtime, output = r.createBuffer(4);
  const kernels = await Promise.all(Array.from({length: 24}, (_, index) =>
    r.kernel({...artifact, wgsl: artifact.wgsl + `\n// variant ${index}`})));
  for (let frame = 0; frame < frameCount; frame++) {
    const batch = r.batch();
    for (let index = 0; index < kernels.length; index++)
      batch.dispatch(kernels[index].bind({output}, {value: frame * 24 + index}), [1, 1, 1]);
    await batch.submit();
    assert.deepEqual(await r.read(output, Uint32Array), new Uint32Array([frame * 24 + 23]));
  }
  const stats = {...r.stats}; await r.dispose();
  assert(f.allocated.every(buffer => buffer.destroyCount === 1));
  return stats;
}

test('steady 24-kernel workload reuses groups and staging storage with identical results', async () => {
  const cached = await runWorkload(), uncached = await runWorkload({maxCachedBindGroups: 0, maxPooledReadbackBytes: 0});
  assert.equal(cached.dispatches, 2400); assert.equal(cached.bindGroupCreations, 24);
  assert.equal(cached.bindGroupCacheHits, 2376); assert.equal(uncached.bindGroupCreations, 2400);
  assert.equal(cached.readbackAllocations, 1); assert.equal(cached.readbackPoolHits, 99);
  assert.equal(uncached.readbackAllocations, 100);
  assert.equal(cached.submissions, uncached.submissions, 'No command reordering or extra queue submissions');
});

test('cached group retains independent dynamic uniform offsets and immutable scalar snapshots', async () => {
  const f = fixture(), r = f.runtime, output = r.createBuffer(4), results = r.createBuffer(8);
  const kernel = await r.kernel(artifact), invocation = kernel.bind({output}, {value: 7});
  const batch = r.batch().dispatch(invocation, [1, 1, 1]).copy(output, results, {byteLength: 4});
  invocation.setScalars({value: 9, index: -8, weight: -0.5});
  batch.dispatch(invocation, [1, 1, 1]).copy(output, results, {byteLength: 4, targetOffset: 4});
  invocation.scalars.value = 99;
  await batch.submit();
  assert.deepEqual(await r.read(results, Uint32Array), new Uint32Array([7, 9]));
  assert.equal(f.dispatches[0].group, f.dispatches[1].group);
  assert.deepEqual(f.dispatches.map(item => item.offset), [0, 256]);
  assert.deepEqual(f.dispatches.map(item => item.values), [[7, -3, 0.25], [9, -8, -0.5]]);
  await r.dispose();
});

test('replacement/growth and completed destruction invalidate old groups', async () => {
  const f = fixture(), r = f.runtime, kernel = await r.kernel(artifact);
  const old = r.createBuffer(4);
  await r.batch().dispatch(kernel.bind({output: old}, {value: 2}), [1, 1, 1]).submit();
  const replacement = r.growBuffer(old, 16);
  await r.fence(); r.destroyBufferCompleted(old);
  assert.equal(r.bindGroupCache.entries.size, 0);
  await r.batch().dispatch(kernel.bind({output: replacement}, {value: 8}), [1, 1, 1]).submit();
  assert.notEqual(f.dispatches[0].group, f.dispatches[1].group);
  assert.throws(() => kernel.bind({output: old}, {value: 0}), /destroyed/);
  await r.dispose();
});

test('different kernels, binding extents and uniform arenas cannot reuse the wrong group', async () => {
  const f = fixture(), r = f.runtime, k = await r.kernel(artifact), other = await r.kernel({...artifact, wgsl: artifact.wgsl + '\n// other'});
  const output = r.createBuffer(16), arena = r.acquireArena(16), arena2 = r.acquireArena(16);
  const a = r.bindGroupCache.get(k, {output}, arena);
  assert.equal(a, r.bindGroupCache.get(k, {output}, arena));
  assert.notEqual(a, r.bindGroupCache.get(k, {output}, arena2));
  assert.notEqual(a, r.bindGroupCache.get(other, {output}, arena));
  assert.notEqual(a, r.bindGroupCache.get(k, {output: {...output, size: 4}}, arena));
  r.releaseArena(arena, false); r.releaseArena(arena2, false);
  assert.equal(r.bindGroupCache.entries.size, 0);
  await r.dispose();
});

test('cache evicts least recently used entries and releases buffer reference bookkeeping', async () => {
  const f = fixture({maxCachedBindGroups: 2}), r = f.runtime, kernel = await r.kernel(artifact);
  const a = r.createBuffer(4), b = r.createBuffer(4), c = r.createBuffer(4), arena = r.acquireArena(16);
  const groupA = r.bindGroupCache.get(kernel, {output: a}, arena);
  r.bindGroupCache.get(kernel, {output: b}, arena);
  assert.equal(r.bindGroupCache.get(kernel, {output: a}, arena), groupA);
  r.bindGroupCache.get(kernel, {output: c}, arena);
  assert.equal(r.bindGroupCache.entries.size, 2); assert.equal(r.stats.bindGroupCacheEvictions, 1);
  assert.equal(r.bindGroupCache.references.get(b.gpuBuffer), undefined);
  r.destroyBuffer(a); assert.equal(r.bindGroupCache.entries.size, 1);
  r.releaseArena(arena, false); assert.equal(r.bindGroupCache.entries.size, 0);
  await r.dispose();
});

test('concurrent readbacks never alias a pending or mapped buffer', async () => {
  const f = fixture(), r = f.runtime, source = r.createBuffer(new Uint32Array([7]));
  f.device.mapGate = gate();
  const first = r.read(source, Uint32Array);
  r.write(source, new Uint32Array([9])); const second = r.read(source, Uint32Array);
  assert.equal(r.stats.readbackAllocations, 2); assert.equal(r.stats.readbacksInUse, 2);
  f.device.mapGate.resolve();
  assert.deepEqual(await first, new Uint32Array([7])); assert.deepEqual(await second, new Uint32Array([9]));
  assert.equal(r.stats.readbacksInUse, 0);
  await r.dispose();
});

test('pooled capacity never exposes tail bytes and returned arrays survive reuse', async () => {
  const f = fixture(), r = f.runtime, source = r.createBuffer(new Uint32Array([1, 2, 3, 4]));
  const full = await r.read(source, Uint32Array, 16);
  r.write(source, new Uint32Array([8, 9, 10, 11]));
  const one = await r.read(source, Uint32Array, 4, 8);
  assert.equal(r.stats.readbackAllocations, 1); assert.equal(one.byteLength, 4);
  assert.deepEqual(one, new Uint32Array([10])); assert.deepEqual(full, new Uint32Array([1, 2, 3, 4]));
  await r.dispose();
});

test('failed mapping is not recycled and a later read uses fresh storage', async () => {
  const f = fixture(), r = f.runtime, source = r.createBuffer(4);
  f.device.mapGate = gate(); const failed = r.read(source, Uint32Array);
  f.device.mapGate.reject(new Error('mapping failed'));
  await assert.rejects(failed, /mapping failed/);
  assert.equal(r.stats.pooledReadbackBytes, 0); assert.equal(r.stats.readbacksInUse, 0);
  f.device.mapGate = null; await r.read(source, Uint32Array);
  assert.equal(r.stats.readbackAllocations, 2); await r.dispose();
});

test('readback pool budget and buffer-count limit stay bounded', () => {
  const f = fixture(), stats = {}, pool = new ReadbackBufferPool(f.device, stats, {maxBytes: 512, maxBuffers: 1});
  const a = pool.acquire(4), b = pool.acquire(4), large = pool.acquire(1024);
  pool.release(a); pool.release(b); pool.release(large);
  assert.equal(pool.count, 1); assert.equal(stats.pooledReadbackBytes, 256);
  assert(b.destroyed && large.destroyed); pool.dispose(); assert(a.destroyed);
  assert.throws(() => pool.release(a), /not leased/);
});

test('dispose waits for pending maps; failure/disposal cannot repopulate caches', async () => {
  const f = fixture(), r = f.runtime, source = r.createBuffer(4);
  f.device.mapGate = gate(); const read = r.read(source);
  let complete = false; const disposal = r.dispose().then(() => {complete = true;});
  await tick(); assert(!complete);
  assert(f.allocated.filter(b => b.label === 'OpenMW readback').every(b => !b.destroyed));
  f.device.mapGate.resolve(); await read; await disposal;
  assert.equal(r.readbackPool.count, 0); assert.equal(r.bindGroupCache.entries.size, 0);
  assert(f.allocated.every(b => b.destroyCount === 1));
});

test('two in-flight dispatch batches retain distinct uniform arenas until their fence', async () => {
  const f = fixture(), r = f.runtime, kernel = await r.kernel(artifact), output = r.createBuffer(4);
  f.device.fenceGate = gate();
  const first = r.batch().dispatch(kernel.bind({output}, {value: 1}), [1, 1, 1]).submit(); r.flush();
  const second = r.batch().dispatch(kernel.bind({output}, {value: 2}), [1, 1, 1]).submit(); r.flush();
  assert.notEqual(f.dispatches[0].uniform, f.dispatches[1].uniform);
  assert.deepEqual(f.dispatches.map(item => item.values[0]), [1, 2]);
  f.device.fenceGate.resolve(); await Promise.all([first, second]); await r.dispose();
});

test('scalar validation remains strict after metadata is indexed', async () => {
  const f = fixture(), r = f.runtime, k = await r.kernel(artifact), output = r.createBuffer(4);
  for (const value of [NaN, Infinity, -1, 0.5, 4294967296])
    assert.throws(() => k.bind({output}, {value}), /Invalid scalar/);
  assert.throws(() => k.bind({output}, {}), /Missing scalar/);
  assert.throws(() => k.bind({output}, {value: 1, typo: 2}), /Invalid scalar/);
  assert.throws(() => k.bind({output}, {value: 1, weight: 1e100}), /Invalid scalar/);
  assert.throws(() => k.bind({output, extra: output}, {value: 1}), /Unknown buffer/);
  const invocation = k.bind({output}, {value: 1});
  invocation.scalars.value = NaN;
  const batch = r.batch(); assert.throws(() => batch.dispatch(invocation, [1, 1, 1]), /Invalid scalar/); batch.discard();
  await r.dispose();
});

test('foreign/destroyed buffers still reject before a cached group is used', async () => {
  const f = fixture(), other = fixture(), r = f.runtime, k = await r.kernel(artifact);
  assert.throws(() => k.bind({output: other.runtime.createBuffer(4)}, {value: 1}), /another runtime/);
  const output = r.createBuffer(4), invocation = k.bind({output}, {value: 1});
  await r.batch().dispatch(invocation, [1, 1, 1]).submit(); r.destroyBuffer(output);
  const batch = r.batch(); assert.throws(() => batch.dispatch(invocation, [1, 1, 1]), /destroyed/); batch.discard();
  await r.dispose(); await other.runtime.dispose();
});

test('device loss while mapping discards staging storage', async () => {
  const f = fixture(), r = f.runtime, source = r.createBuffer(4);
  f.device.mapGate = gate(); const read = r.read(source);
  f.lost.resolve({reason: 'unknown', message: 'test loss'}); await tick();
  f.device.mapGate.resolve(); await assert.rejects(read, /device lost/);
  assert.equal(r.stats.pooledReadbackBytes, 0); await r.dispose();
});

test('invalid pool/cache budgets are rejected', () => {
  const f = fixture();
  for (const maximum of [-1, NaN, 1.5]) {
    assert.throws(() => new ComputeBindGroupCache(f.device, {}, maximum), /capacity/);
    assert.throws(() => new ReadbackBufferPool(f.device, {}, {maxBytes: maximum}), /capacity/);
  }
});
