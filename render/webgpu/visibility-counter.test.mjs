import assert from 'node:assert/strict';
import test from 'node:test';
import {ExactVisibilityCounter, MAX_VISIBILITY_TRIANGLES} from './visibility-counter.js';

function harness({compile = async () => {}} = {}) {
  const textures = [], groups = [], passes = [];
  const device = {
    limits: {maxTextureDimension2D: 8192, minUniformBufferOffsetAlignment: 256,
      maxStorageBufferBindingSize: 128 * 1024 * 1024},
    queue: {
      writeBuffer() { assert.fail('Visibility reduction must not rewrite per-draw uniforms'); },
      submit() { assert.fail('Visibility reduction must stay in the caller encoder'); },
    },
    createShaderModule(descriptor) {
      return {descriptor, async getCompilationInfo() { return {messages: []}; }};
    },
    async createComputePipelineAsync(descriptor) {
      await compile(); return {descriptor, getBindGroupLayout: () => ({})};
    },
    createTexture(descriptor) {
      const texture = {descriptor, destroyed: false,
        createView() { return {texture}; }, destroy() { this.destroyed = true; }};
      textures.push(texture); return texture;
    },
    createBindGroup(descriptor) { groups.push(descriptor); return descriptor; },
  };
  const runtime = {device, failure: null, assertAlive() { if (this.failure) throw this.failure; }};
  const encoder = {beginComputePass() {
    const pass = {setPipeline(value) { this.pipeline = value; },
      setBindGroup(index, value) { this.bindGroup = value; },
      dispatchWorkgroups(...groups) { this.groups = groups; }, end() { this.ended = true; }};
    passes.push(pass); return pass;
  }};
  const buffer = (size, usage) => ({size, usage, destroy() {}});
  return {runtime, encoder, textures, groups, passes, buffer};
}

test('visibility reduction binds immutable per-draw uniforms without queue writes or readbacks', async () => {
  const h = harness(), counter = await ExactVisibilityCounter.create(h.runtime);
  try {
    assert.equal(MAX_VISIBILITY_TRIANGLES, 1024);
    const target = counter.target({width: 33, height: 17, samples: 4});
    assert.equal(target.texture.descriptor.format, 'rgba16float');
    assert.equal(target.texture.descriptor.sampleCount, 4);
    const uniforms = h.buffer(768, 64), counts = h.buffer(128, 128);
    counter.encode(h.encoder, target, {counts, uniforms, uniformOffset: 256});
    counter.encode(h.encoder, target, {counts, uniforms, uniformOffset: 512});
    assert.deepEqual(h.groups.map(group => group.entries[2].resource), [
      {buffer: uniforms, offset: 256, size: 80}, {buffer: uniforms, offset: 512, size: 80},
    ]);
    assert(h.groups.every(group => group.entries[0].resource === target.view
      && group.entries[1].resource.buffer === counts));
    assert.deepEqual(h.passes.map(pass => pass.groups), [[3, 2, 1], [3, 2, 1]]);
    assert(h.passes.every(pass => pass.ended));
  } finally { counter.dispose(); }
});

test('invalid visibility ranges fail before recording any GPU work', async () => {
  const h = harness(), counter = await ExactVisibilityCounter.create(h.runtime);
  try {
    assert.throws(() => counter.target({width: 8193, height: 1}), /dimensions/);
    assert.throws(() => counter.target({width: 8, height: 6, samples: 2}), /sample count/);
    const target = counter.target({width: 8, height: 6});
    const valid = {counts: h.buffer(12, 128), uniforms: h.buffer(512, 64)};
    assert.throws(() => counter.encode(h.encoder, target, {...valid, uniformOffset: 4}), /aligned/);
    assert.throws(() => counter.encode(h.encoder, target, {...valid, uniformOffset: 512}), /uniform/);
    assert.throws(() => counter.encode(h.encoder, target, {...valid, counts: h.buffer(8, 128)}), /counter/);
    assert.throws(() => counter.encode(h.encoder, target, {...valid, counts: h.buffer(12, 64)}), /counter/);
    assert.throws(() => counter.encode(h.encoder, {...target, owner: {}}, valid), /target/);
    assert.equal(h.groups.length, 0); assert.equal(h.passes.length, 0);
    h.runtime.failure = new Error('lost device');
    assert.throws(() => counter.encode(h.encoder, target, valid), /lost device/);
  } finally { counter.dispose(); }
});

test('visibility texture reuse, eviction, and loss during compilation release owned state', async () => {
  const h = harness(), counter = await ExactVisibilityCounter.create(h.runtime);
  const first = counter.target({width: 8, height: 6});
  assert.equal(counter.target({width: 8, height: 6}), first);
  for (const width of [9, 10, 11, 12]) counter.target({width, height: 6});
  assert(first.texture.destroyed);
  assert.throws(() => counter.encode(h.encoder, first, {}), /target/);
  counter.dispose(); counter.dispose();
  assert(h.textures.every(texture => texture.destroyed));
  assert.equal(counter.targets.size, 0); assert.equal(counter.pipelines.size, 0);
  assert.throws(() => counter.target({width: 8, height: 6}), /disposed/);

  // One shared gate lets both pipeline compiles complete after device loss.
  let unblock;
  const gate = new Promise(resolve => { unblock = resolve; });
  const compiling = harness({compile: () => gate});
  const pending = ExactVisibilityCounter.create(compiling.runtime);
  await Promise.resolve(); await Promise.resolve();
  compiling.runtime.failure = new Error('lost during compile'); unblock();
  await assert.rejects(pending, /lost during compile/);
  assert.equal(compiling.textures.length, 0);
});
