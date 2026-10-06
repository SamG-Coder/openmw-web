// SPDX-License-Identifier: GPL-3.0-or-later
// Real WebGPU integration checks, independent of retail game data and Emscripten.
// npm install --no-save webgpu
// node render/webgpu/gpu-check.mjs
// OPENMW_WEBGPU_MODULE can point to an existing Dawn module. To run on a
// software Vulkan device, set VK_ICD_FILENAMES to its ICD JSON file.
// OPENMW_WEBGPU_CHECK limits execution to test names containing that string.
import assert from 'node:assert/strict';
import {readFile, readdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {kernelManifest} from './kernel-manifest.js';
import {prepareTrianglesArtifact} from './prepare-triangles.js';
import {GUARD, rasterParameters, quadVertices, targetPixels, rasterFixture, pipelineFixture} from './gpu-fixtures.mjs';

const directory = new URL('./', import.meta.url);
const summary = {backend: process.env.OPENMW_WEBGPU_BACKEND ?? 'vulkan', shaders: [], checks: [], skipped: [], failures: []};
const nativeFetch = globalThis.fetch;

// Production modules fetch their own WGSL. Preserve that exact loading path
// while providing file: support in Node; no HTTP server or mocked GPU is used.
globalThis.fetch = async (resource, options) => {
  const url = resource instanceof URL ? resource : new URL(typeof resource === 'string' ? resource : resource.url, directory);
  if (url.protocol !== 'file:') return nativeFetch(resource, options);
  try { return new Response(await readFile(fileURLToPath(url)), {status: 200, headers: {'content-type': 'text/plain'}}); }
  catch (error) {
    if (error.code === 'ENOENT') return new Response('File not found', {status: 404});
    throw error;
  }
};

function close(actual, expected, label, tolerance = 0.00002) {
  assert(Number.isFinite(actual), `${label}: non-finite value ${actual}`);
  assert(Math.abs(actual - expected) <= tolerance, `${label}: expected ${expected}, received ${actual}`);
}
function unchangedGuard(output, label) {
  for (let word = output.length - 4; word < output.length; word++) close(output[word], GUARD, `${label} trailing guard ${word}`);
}
function pixel(output, fixture, x, y, sample = 0) {
  const index = sample * fixture.width * fixture.height * 10 + (y * fixture.width + x) * 9;
  return output.subarray(index, index + 9);
}
function everyPixel(output, fixture, verify) {
  for (let sample = 0; sample < fixture.samples; sample++) for (let y = 0; y < fixture.height; y++) for (let x = 0; x < fixture.width; x++) {
    verify(pixel(output, fixture, x, y, sample), x, y, sample);
  }
}
function colorEquals(actual, expected, label) {
  for (let channel = 0; channel < 4; channel++) close(actual[channel], expected[channel], `${label} channel ${channel}`);
}

async function check(name, fn) {
  if (process.env.OPENMW_WEBGPU_CHECK && !name.toLowerCase().includes(process.env.OPENMW_WEBGPU_CHECK.toLowerCase())) {
    summary.skipped.push(name);
    return;
  }
  const started = performance.now();
  try {
    await fn();
    summary.checks.push({name, milliseconds: Math.round(performance.now() - started)});
    console.log(`PASS ${name}`);
  } catch (error) {
    summary.failures.push({name, message: String(error.stack ?? error)});
    console.error(`FAIL ${name}: ${error.stack ?? error}`);
  }
}

async function validateModule(device, name, code) {
  const module = device.createShaderModule({label: name, code});
  const {messages} = await module.getCompilationInfo();
  const errors = messages.filter(message => message.type === 'error');
  assert.equal(errors.length, 0, `${name}: ${errors.map(message => `${message.lineNum}:${message.linePos} ${message.message}`).join('\n')}`);
  summary.shaders.push({name, warnings: messages.filter(message => message.type === 'warning').length});
  return module;
}

async function compileKernels(runtime) {
  const kernels = {};
  for (const descriptor of kernelManifest) {
    const wgsl = await readFile(new URL(descriptor.file, directory), 'utf8');
    await validateModule(runtime.device, descriptor.entry, wgsl);
    kernels[descriptor.entry] = await runtime.kernel({...descriptor, name: descriptor.entry, wgsl});
  }
  const wgsl = await readFile(new URL('./shaders/prepare-triangles.wgsl', directory), 'utf8');
  await validateModule(runtime.device, 'prepare_triangles', wgsl);
  kernels.prepare_triangles = await runtime.kernel({...prepareTrianglesArtifact, wgsl});
  console.log(`Compiled ${Object.keys(kernels).length} production compute pipelines`);
  return kernels;
}

async function checkIdentityAssembly(runtime, kernels) {
  const source = new Float32Array(60);
  for (let vertex = 0; vertex < 6; vertex++) source.set([vertex - 2, vertex * 0.25, -vertex * 0.1, vertex + 1, vertex / 8, 0.5, 0.75, 1, vertex / 7, vertex / 9], vertex * 10);
  const triangles = new Uint32Array([2, 0, 1, 1, 4, 5, 3, 0]);
  const source_point_fade_offset = 6 * 34;
  const attributes = new Float32Array(source_point_fade_offset + 6 * 12);
  for (let vertex = 0; vertex < 6; vertex++) {
    for (let channel = 0; channel < 34; channel++) attributes[vertex * 34 + channel] = vertex + channel / 64;
    for (let channel = 0; channel < 12; channel++) attributes[source_point_fade_offset + vertex * 12 + channel] = vertex + channel / 16;
  }
  const buffers = {};
  const own = (name, data) => (buffers[name] = runtime.createBuffer(data, {label: `identity ${name}`}));
  try {
    own('source', source); own('indices', triangles); own('edges', new Uint32Array([5, 3]));
    own('positions', 24 * 4); own('weights', 24 * 4); own('valid', 2 * 4);
    own('vertices', 60 * 4); own('triangles', 8 * 4); own('flat_colors', new Uint32Array([0xffffffff, 0xffffffff]));
    own('sourceAttributes', attributes); own('attributes', attributes.byteLength + 6 * 4);
    const boundary_offset = 6 * 34, point_fade_offset = boundary_offset + 6;
    runtime.batch()
      .dispatch(kernels.prepare_triangles.bind({clip: buffers.source, indices: buffers.indices, polygon_edges: buffers.edges,
        positions: buffers.positions, weights: buffers.weights, valid: buffers.valid}, {triangle_count: 2}), [1, 1, 1])
      .dispatch(kernels.assemble_material.bind({source: buffers.source, triangles: buffers.indices, positions: buffers.positions,
        weights: buffers.weights, valid: buffers.valid, vertices: buffers.vertices, output_triangles: buffers.triangles,
        flat_colors: buffers.flat_colors}, {slot_count: 2}), [1, 1, 1])
      .dispatch(kernels.assemble_attributes.bind({source: buffers.sourceAttributes, triangles: buffers.indices, weights: buffers.weights,
        valid: buffers.valid, output: buffers.attributes}, {slot_count: 2, boundary_offset, point_fade_offset, source_point_fade_offset}), [1, 1, 1])
      .submit();
    const [positions, weights, valid, vertices, outputTriangles, outputAttributes] = await Promise.all([
      runtime.read(buffers.positions), runtime.read(buffers.weights), runtime.read(buffers.valid, Uint32Array),
      runtime.read(buffers.vertices), runtime.read(buffers.triangles, Uint32Array), runtime.read(buffers.attributes),
    ]);
    assert.deepEqual(Array.from(valid), [1, 1]);
    assert.deepEqual(Array.from(outputTriangles), [0, 1, 2, 1, 3, 4, 5, 0]);
    for (let triangle = 0; triangle < 2; triangle++) for (let corner = 0; corner < 3; corner++) {
      const input = triangles[triangle * 4 + corner], output = triangle * 3 + corner;
      for (let channel = 0; channel < 10; channel++) close(vertices[output * 10 + channel], source[input * 10 + channel], 'assembled vertex');
      for (let channel = 0; channel < 4; channel++) close(positions[triangle * 12 + corner * 4 + channel], source[input * 10 + channel], 'homogeneous position');
      for (let channel = 0; channel < 3; channel++) close(weights[triangle * 12 + corner * 4 + channel], channel === corner ? 1 : 0, 'identity barycentric weight');
      const edge = ((triangle === 0 ? 5 : 3) >> corner) & 1;
      close(weights[triangle * 12 + corner * 4 + 3], edge, 'boundary weight');
      close(outputAttributes[boundary_offset + output], edge, 'assembled boundary');
      for (let channel = 0; channel < 34; channel++) close(outputAttributes[output * 34 + channel], attributes[input * 34 + channel], 'assembled varying');
      for (let channel = 0; channel < 12; channel++) close(outputAttributes[point_fade_offset + output * 12 + channel], attributes[source_point_fade_offset + input * 12 + channel], 'assembled point fade');
    }
  } finally {
    await runtime.idle();
    for (const buffer of Object.values(buffers)) runtime.destroyBuffer(buffer);
  }
}

async function checkRaster(runtime, rasterizer) {
  async function draw(fixture, pass = {}) {
    const buffers = {};
    try {
      for (const [name, input] of Object.entries(fixture.inputs)) buffers[name] = runtime.createBuffer(input, {label: `raster fixture ${name}`});
      runtime.device.pushErrorScope('validation');
      let error;
      try {
        await rasterizer.render(buffers, fixture.params, {scene: fixture.scene, pass, triangleCount: fixture.scene.triangles.length / 4});
        await runtime.idle();
      } finally {error = await runtime.device.popErrorScope();}
      assert.equal(error, null, error?.message);
      const output = await runtime.read(buffers.target, Float32Array, fixture.initial.byteLength);
      if (fixture.inspectQueries) fixture.outputCounts = await runtime.read(buffers.counts, Uint32Array);
      unchangedGuard(output, 'raster');
      return output;
    } finally {
      await runtime.idle();
      for (const buffer of Object.values(buffers)) runtime.destroyBuffer(buffer);
    }
  }

  await check('hardware unlit quad writes color and depth exactly once', async () => {
    const fixture = rasterFixture();
    everyPixel(await draw(fixture), fixture, value => {colorEquals(value, [1, 0, 0, 1], 'unlit'); close(value[4], 0.5, 'depth');});
  });
  await check('hardware texture sampling preserves UV origin and four quadrants', async () => {
    const fixture = rasterFixture({color: [1, 1, 1, 1], texels: new Uint32Array([0xff0000ff, 0xff00ff00, 0xffff0000, 0xffffffff])});
    fixture.scene.materials.set([0, 2, 2, 1 | 4 | 8], 0);
    everyPixel(await draw(fixture), fixture, (value, x, y) => {
      const expected = y < fixture.height / 2 ? (x < fixture.width / 2 ? [1, 0, 0, 1] : [0, 1, 0, 1]) : (x < fixture.width / 2 ? [0, 0, 1, 1] : [1, 1, 1, 1]);
      colorEquals(value, expected, `texel ${x},${y}`);
    });
  });
  await check('hardware perspective interpolation divides by homogeneous w once', async () => {
    const fixture = rasterFixture({width: 8, height: 8,
      vertices: new Float32Array([-1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 2, 2, 0, 2, 0, 1, 0, 1, 1, 0, -4, -4, 0, 4, 0, 0, 1, 1, 0, 1]),
      triangles: new Uint32Array([0, 1, 2, 0])});
    const output = await draw(fixture);
    for (const [x, y] of [[1, 1], [3, 1], [1, 3]]) {
      const b = (x + 0.5) / 8, c = (y + 0.5) / 8, a = 1 - b - c;
      const inverse = a + b / 2 + c / 4;
      colorEquals(pixel(output, fixture, x, y), [a / inverse, b / 2 / inverse, c / 4 / inverse, 1], 'perspective color');
    }
  });
  await check('hardware homogeneous near clipping rejects outside samples and retains visible depth', async () => {
    const fixture = rasterFixture({width: 8, height: 8,
      vertices: new Float32Array([-1, 1, -2, 1, 1, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, -1, -1, 0, 1, 1, 0, 0, 1, 0, 1]),
      triangles: new Uint32Array([0, 1, 2, 0])});
    const output = await draw(fixture);
    colorEquals(pixel(output, fixture, 0, 0), [0, 0, 0, 1], 'near-clipped pixel');
    close(pixel(output, fixture, 0, 0)[4], 1, 'near-clipped depth');
    colorEquals(pixel(output, fixture, 3, 3), [1, 0, 0, 1], 'visible clipped polygon');
    close(pixel(output, fixture, 3, 3)[4], 0.375, 'clipped polygon depth');
  });
  await check('hardware clipping retains colors, UVs and depth across zero and negative vertex w', async () => {
    for (const w of [0, -1]) {
      const fixture = rasterFixture({width: 8, height: 8,
        vertices: new Float32Array([-1, 1, 0, w, 1, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, -1, -1, 0, 1, 1, 0, 0, 1, 0, 1]),
        triangles: new Uint32Array([0, 1, 2, 0])});
      const output = await draw(fixture);
      colorEquals(pixel(output, fixture, 1, 1), [1, 0, 0, 1], `eye-plane crossing w=${w}`);
      close(pixel(output, fixture, 1, 1)[4], 0.5, 'eye-plane crossing depth');
      for (const value of output) assert(Number.isFinite(value), 'Eye-plane clipping must not write non-finite values');
      // At NDC(-0.625,+0.625), the last two original weights are equal.
      // Solve -a/(a*w + 1-a)=-0.625 without dividing by the zero-w vertex.
      const a = 0.625 / (1.625 - 0.625 * w), b = (1 - a) / 2;
      for (let vertex = 0; vertex < 3; vertex++) fixture.scene.vertices.set([vertex === 0 ? 1 : 0, vertex === 1 ? 1 : 0, vertex === 2 ? 1 : 0, 1], vertex * 10 + 4);
      colorEquals(pixel(await draw(fixture), fixture, 1, 1), [a, b, b, 1], 'eye-plane color interpolation');
      for (let vertex = 0; vertex < 3; vertex++) fixture.scene.vertices.fill(1, vertex * 10 + 4, vertex * 10 + 8);
      fixture.scene.texels = fixture.inputs.texels = new Uint32Array([0xff000000, 0xff0000ff, 0xff00ff00, 0xff00ffff]);
      // The atlas-sampler flag selects the explicit bilinear sampler ABI.
      fixture.scene.materials.set([0, 2, 2, 1 | 4 | 8 | 512], 0); fixture.scene.materials[11] = 32 | 256;
      colorEquals(pixel(await draw(fixture), fixture, 1, 1), [2 * b - 0.5, 2 * b - 0.5, 0, 1], 'eye-plane UV interpolation');
    }
  });
  await check('hardware depth ordering is independent of submission order', async () => {
    for (const reversed of [false, true]) {
      const vertices = new Float32Array([...quadVertices([1, 0, 0, 1], 0.5), ...quadVertices([0, 1, 0, 1], -0.5)]);
      const far = [0, 1, 2, 0, 0, 2, 3, 0], near = [4, 5, 6, 0, 4, 6, 7, 0];
      const fixture = rasterFixture({vertices, triangles: new Uint32Array(reversed ? [...near, ...far] : [...far, ...near])});
      everyPixel(await draw(fixture), fixture, value => {colorEquals(value, [0, 1, 0, 1], 'nearest surface');close(value[4], 0.25, 'nearest depth');});
    }
  });
  await check('hardware transparency preserves interleaved material submission order', async () => {
    const vertices = new Float32Array([...quadVertices([1, 0, 0, 0.5]), ...quadVertices([0, 0, 1, 0.5]), ...quadVertices([1, 0, 0, 0.5])]);
    const materials = new Uint32Array([0, 1, 1, 2, 0, 0, 0, 8, 6, 0, 0, 0, 0, 1, 1, 2, 0, 0, 0, 8, 6, 0, 0, 0]);
    const triangles = new Uint32Array([0, 1, 2, 0, 0, 2, 3, 0, 4, 5, 6, 1, 4, 6, 7, 1, 8, 9, 10, 0, 8, 10, 11, 0]);
    const fixture = rasterFixture({vertices, triangles, materials});
    everyPixel(await draw(fixture), fixture, value => colorEquals(value, [0.625, 0, 0.25, 1], 'ordered A/B/A blend'));
  });
  await check('hardware alpha rejection preserves color and depth attachments', async () => {
    const fixture = rasterFixture({color: [1, 0, 0, 0.5]});
    fixture.scene.materials[4] = 200;
    assert.deepEqual(await draw(fixture), fixture.initial);
  });
  await check('hardware per-channel color masks preserve disabled channels', async () => {
    const fixture = rasterFixture({color: [0.75, 0.875, 0.625, 0.5], background: [0.125, 0.25, 0.375, 1]});
    fixture.scene.materials[3] = 128;
    fixture.scene.materials[9] = 7 | (7 << 4) | (1 << 18) | (1 << 20);
    everyPixel(await draw(fixture), fixture, value => colorEquals(value, [0.75, 0.25, 0.625, 1], 'color write mask'));
  });
  await check('hardware logical RGB attachments use alpha one for destination-alpha blending and export', async () => {
    const fixture = rasterFixture({color: [0.5, 0.25, 0.125, 0.5], background: [0, 0, 0, 0.25]});
    fixture.params.color_channels = 3;
    fixture.scene.materials[3] = 128 | 2;
    fixture.scene.materials[9] = 7 | (7 << 4);
    fixture.scene.materials[10] = 6 | (1 << 8); // RGB source factor DST_ALPHA; destination factor ZERO.
    everyPixel(await draw(fixture), fixture, value => colorEquals(value, [0.5, 0.25, 0.125, 1], 'logical RGB destination alpha'));
  });
  await check('hardware culling honors the captured front-face winding', async () => {
    for (const clockwiseFront of [false, true]) {
      const fixture = rasterFixture();
      fixture.scene.materials[3] |= 128;
      fixture.scene.materials[9] = 1 | (7 << 4) | (2 << 14) | (clockwiseFront ? 65536 : 0);
      everyPixel(await draw(fixture), fixture, value => colorEquals(value, clockwiseFront ? [1, 0, 0, 1] : [0, 0, 0, 1], 'front-face culling'));
    }
  });
  await check('hardware scissor limits both color and depth writes', async () => {
    const fixture = rasterFixture();
    fixture.scene.materials.set([2, 1, 3, 2], 5);
    everyPixel(await draw(fixture), fixture, (value, x, y) => {
      const inside = x >= 2 && x < 5 && y >= 1 && y < 3;
      colorEquals(value, inside ? [1, 0, 0, 1] : [0, 0, 0, 1], 'scissor');
      close(value[4], inside ? 0.5 : 1, 'scissor depth');
    });
  });
  await check('hardware compact depth supports alpha rejection and guard boundaries', async () => {
    for (const threshold of [0, 200]) {
      const fixture = rasterFixture({compactDepth: true, color: [1, 0, 0, 0.5]});
      fixture.scene.materials[4] = threshold;
      const output = await draw(fixture);
      for (let pixel = 0; pixel < fixture.width * fixture.height; pixel++) close(output[pixel], threshold ? 1 : 0.5, 'compact depth');
    }
  });
  await check('hardware 4x MSAA preserves all sample planes', async () => {
    const fixture = rasterFixture({samples: 4});
    fixture.params.color_storage = 0;
    everyPixel(await draw(fixture), fixture, value => {colorEquals(value, [1, 0, 0, 1], 'MSAA sample');close(value[4], 0.5, 'MSAA depth');});
  });
  await check('hardware stencil import, masked replacement and export retain stencil bits', async () => {
    const params = rasterParameters();
    for (const face of [8, 15]) params.set([7, 0x3c, 255, 0x0f, 0, 0, 2], face);
    const fixture = rasterFixture({stencil: 0xa5, rasterParams: params});
    fixture.scene.materials[3] |= 128 | 8192;
    fixture.scene.materials[9] = 1 | (7 << 4);
    const output = await draw(fixture), pixels = fixture.width * fixture.height;
    for (let p = 0; p < pixels; p++) close(output[pixels * 9 + p], 0xac, 'masked stencil replace');
  });
  await check('hardware stencil comparison rejects color and depth writes on mismatched pixels', async () => {
    const params = rasterParameters();
    for (const face of [8, 15]) params.set([2, 17, 255, 255, 0, 0, 0], face);
    const fixture = rasterFixture({rasterParams: params});
    fixture.scene.materials[3] |= 128 | 8192;
    fixture.scene.materials[9] = 1 | (7 << 4);
    const pixels = fixture.width * fixture.height;
    for (let p = 0; p < pixels; p++) fixture.initial[pixels * 9 + p] = p % 2 ? 3 : 17;
    const output = await draw(fixture);
    everyPixel(output, fixture, (value, x, y) => {
      const accepted = (y * fixture.width + x) % 2 === 0;
      colorEquals(value, accepted ? [1, 0, 0, 1] : [0, 0, 0, 1], 'stencil test');
      close(value[4], accepted ? 0.5 : 1, 'stencil depth');
    });
  });
  await check('hardware unlit materials preserve a previously stored normal attachment', async () => {
    const expected = [0.125, 0.25, 0.375, 1];
    const fixture = rasterFixture({normal: expected}); fixture.params.normal_enabled = 1;
    everyPixel(await draw(fixture), fixture, value => colorEquals(value.subarray(5), expected, 'unlit normal preservation'));
  });
  await check('hardware object material writes encoded normals through MRT', async () => {
    const data = 1, texels = new Uint32Array(data + 352), floats = new Float32Array(texels.buffer);
    texels[data + 4] = 131072 | 16384; texels[data + 7] = 352; texels[data + 51] = 7;
    floats[data + 15] = floats[data + 47] = floats[data + 48] = floats[data + 71] = 1;
    for (let k = 0; k < 4; k++) floats[data + 52 + k * 5] = 1;
    const fixture = rasterFixture({texels});
    fixture.scene.materials[0] = data; fixture.scene.materials[3] |= 2048; fixture.params.normal_enabled = 1;
    everyPixel(await draw(fixture), fixture, value => colorEquals(value.subarray(5), [0.5, 0.5, 1, 1], 'encoded object normal'));
  });
  await check('hardware logical RGB normal attachments export absent alpha as one', async () => {
    const data = 1, texels = new Uint32Array(data + 352), floats = new Float32Array(texels.buffer);
    texels[data + 4] = 131072 | 16384; texels[data + 7] = 352; texels[data + 51] = 7;
    floats[data + 15] = floats[data + 47] = floats[data + 48] = floats[data + 71] = 1;
    for (let k = 0; k < 4; k++) floats[data + 52 + k * 5] = 1;
    const fixture = rasterFixture({texels, normal: [0, 0, 0, 0.25]});
    fixture.scene.materials[0] = data; fixture.scene.materials[3] |= 2048;
    fixture.params.normal_enabled = 1; fixture.params.normal_channels = 3;
    everyPixel(await draw(fixture), fixture, value => colorEquals(value.subarray(5), [0.5, 0.5, 1, 1], 'logical RGB normal alpha'));
  });
  await check('hardware fixed-function linear fog combines surface and fog colors', async () => {
    const texels = new Uint32Array(10), floats = new Float32Array(texels.buffer), params = rasterParameters();
    texels[1] = 16;
    floats.set([0.5, 0, 2, 0, 0, 1, 1, 1], 2);
    new Uint32Array(params.buffer)[23] = 1;
    const fixture = rasterFixture({texels, rasterParams: params});
    fixture.scene.materials[3] |= 32768;
    everyPixel(await draw(fixture), fixture, value => colorEquals(value, [0.5, 0, 0.5, 1], 'linear fog'));
  });
  await check('hardware atmosphere material uses the authored sky emission color', async () => {
    const data = 1, texels = new Uint32Array(data + 30), floats = new Float32Array(texels.buffer);
    floats.set([0.25, 0.5, 0.75, 1], data + 18);
    const fixture = rasterFixture({texels});
    fixture.scene.materials[0] = data; fixture.scene.materials[3] |= 1024;
    everyPixel(await draw(fixture), fixture, value => colorEquals(value, [0.25, 0.5, 0.75, 1], 'sky emission'));
  });
  await check('hardware sky occlusion queries count visible samples without attachment writes', async () => {
    for (const coverage of ['full', 'half', 'none']) {
      const data = 1, texels = new Uint32Array(data + 30);
      texels[0] = 0xffffffff;
      texels.set([0, 1, 1, 0], data); texels[data + 8] = 5; texels[data + 9] = 77;
      const fixture = rasterFixture({texels, depth: coverage === 'none' ? 0.25 : 1});
      if (coverage === 'half') for (let y = 0; y < fixture.height; y++) for (let x = fixture.width / 2; x < fixture.width; x++) {
        fixture.initial[(y * fixture.width + x) * 9 + 4] = 0.25;
      }
      fixture.scene.materials[0] = data; fixture.scene.materials[3] |= 1024; fixture.inspectQueries = true;
      assert.deepEqual(await draw(fixture), fixture.initial, 'Occlusion probes must leave every attachment unchanged');
      const offset = Math.ceil(fixture.width / 16) * Math.ceil(fixture.height / 16) + 1;
      // OpenMW divides visible by total samples for fractional sun glare.
      // A boolean "some sample passed" result cannot preserve that contract.
      const expected = fixture.width * fixture.height * (coverage === 'full' ? 1 : coverage === 'half' ? 0.5 : 0);
      assert.equal(fixture.outputCounts[offset], expected, `${coverage} sky visibility sample count`);
    }
  });
  await check('hardware sky sample counters retain overlap across bounded additive chunks and MSAA', async () => {
    for (const samples of [1, 4]) for (const quads of [2, 513]) {
      const data = 1, texels = new Uint32Array(data + 30);
      texels[0] = 0xffffffff;
      texels.set([0, 1, 1, 0], data); texels[data + 8] = 5; texels[data + 9] = 77;
      const triangles = new Uint32Array(quads * 8);
      for (let quad = 0; quad < quads; quad++) triangles.set([0, 1, 2, 0, 0, 2, 3, 0], quad * 8);
      const fixture = rasterFixture({texels, triangles, samples});
      if (samples > 1) fixture.params.color_storage = 0;
      fixture.scene.materials[0] = data; fixture.scene.materials[3] |= 1024; fixture.inspectQueries = true;
      assert.deepEqual(await draw(fixture), fixture.initial, 'Overlapping query fragments must preserve scene attachments');
      const offset = Math.ceil(fixture.width / 16) * Math.ceil(fixture.height / 16) + 1;
      assert.equal(fixture.outputCounts[offset], fixture.width * fixture.height * quads * samples,
        `${quads} overlapping quads, ${samples} samples per pixel`);
    }
  });
}

async function checkPipeline(runtime, kernels, rasterizer) {
  const {MaterialPipeline} = await import('./pipeline.js');
  const pipeline = new MaterialPipeline(runtime, kernels, rasterizer);
  const width = 8, height = 6;
  const initial = targetPixels(width, height);
  const target = runtime.createBuffer(initial, {label: 'production packet target'});
  async function render(scene, pass = {}) {
    runtime.write(target, initial);
    const result = await pipeline.render(scene, width, height, null, {target, colorFormat: 0x8814,
      depthFormat: 0x8cad, stencilBits: 8, clearMask: 0, deferCompletion: true, ...pass});
    assert(result, 'Production pipeline must accept an idle packet');
    const completion = await result.queryCompletion;
    if (completion.error) throw completion.error;
    await runtime.idle(); pipeline.collectRetired();
    const output = await runtime.read(target, Float32Array, initial.byteLength);
    unchangedGuard(output, 'production pipeline');
    return {output, completion};
  }
  try {
    await check('production MaterialPipeline transforms and assembles the retained packet before hardware rasterization', async () => {
      const {output, completion} = await render(pipelineFixture({width, height}));
      for (let p = 0; p < width * height; p++) {colorEquals(output.subarray(p * 9), [1, 0, 0, 1], 'production color');close(output[p * 9 + 4], 0.5, 'production depth');}
      assert.equal(completion.diagnostic.packedTriangles, 2, 'Exactly one prepared slot per triangle');
      assert(completion.diagnostic.hardwareDrawCalls > 0, 'A GPU draw must be recorded');
    });
    await check('production MaterialPipeline maps a partial camera viewport without touching surrounding pixels', async () => {
      const viewport = [2, 1, 4, 3];
      const {output} = await render(pipelineFixture({width, height}), {viewport});
      for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
        const inside = x >= 2 && x < 6 && y >= height - 4 && y < height - 1;
        colorEquals(output.subarray((y * width + x) * 9), inside ? [1, 0, 0, 1] : [0, 0, 0, 1], 'camera viewport');
      }
    });
    await check('production empty camera clears only its viewport and completes without a draw', async () => {
      const scene = pipelineFixture({width, height});
      scene.vertices = new Float32Array(); scene.matrixIds = new Uint32Array(); scene.triangles = new Uint32Array(); scene.materials = new Uint32Array();
      const {output, completion} = await render(scene, {viewport: [2, 1, 4, 3], clearMask: 16384 | 256, clearColor: [0.25, 0.5, 0.75, 1], clearDepth: 0.25});
      for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
        const inside = x >= 2 && x < 6 && y >= height - 4 && y < height - 1, value = output.subarray((y * width + x) * 9);
        colorEquals(value, inside ? [0.25, 0.5, 0.75, 1] : [0, 0, 0, 1], 'empty camera clear'); close(value[4], inside ? 0.25 : 1, 'empty camera depth');
      }
      assert.equal(completion.diagnostic.hardwareDrawCalls, 0);
    });
    await check('production MaterialPipeline 4x MSAA resolves native raster sample storage', async () => {
      const samples = runtime.createBuffer(targetPixels(width, height, {samples: 4}));
      try {
        const {output} = await render(pipelineFixture({width, height}), {sampleCount: 4, sampleTarget: samples, colorFormat: 0x8058});
        for (let p = 0; p < width * height; p++) colorEquals(output.subarray(p * 9), [1, 0, 0, 1], 'production MSAA resolve');
      } finally {runtime.destroyBuffer(samples);}
    });
  } finally {
    await runtime.idle(); pipeline.dispose(); runtime.destroyBuffer(target);
  }
}

async function main() {
  const {create, globals} = await import(process.env.OPENMW_WEBGPU_MODULE ?? 'webgpu');
  Object.assign(globalThis, globals);
  const gpu = create([`backend=${summary.backend}`]);
  const {WebGPURuntime} = await import('./runtime.js');
  const errors = [];
  const runtime = await WebGPURuntime.create({gpu, onError: error => errors.push(String(error?.message ?? error))});
  try {
    summary.adapter = {vendor: runtime.adapter?.info?.vendor, architecture: runtime.adapter?.info?.architecture,
      description: runtime.adapter?.info?.description, features: Array.from(runtime.device.features)};
    const kernels = await compileKernels(runtime);
    await check('identity triangle preparation and assembly preserve two distinct materials and all vertex attributes', () => checkIdentityAssembly(runtime, kernels));
    if (!process.argv.includes('--kernels-only')) {
      const shaderDirectory = new URL('./shaders/', directory);
      for (const name of await readdir(shaderDirectory)) if (name.endsWith('.wgsl') && name !== 'prepare-triangles.wgsl') {
        await validateModule(runtime.device, name, await readFile(new URL(name, shaderDirectory), 'utf8'));
      }
      const {HardwareRasterizer} = await import('./rasterizer.js');
      const rasterizer = await HardwareRasterizer.create(runtime);
      try {
        await checkRaster(runtime, rasterizer);
        await checkPipeline(runtime, kernels, rasterizer);
      } finally {rasterizer.dispose();}
    }
    await runtime.idle();
    if (errors.length) summary.failures.push({name: 'uncaptured GPU errors', message: errors.join('\n')});
  } finally {
    await runtime.dispose();
    globalThis.fetch = nativeFetch;
  }
  console.log(JSON.stringify(summary, null, 2));
  if (summary.failures.length) throw Error(`${summary.failures.length} GPU checks failed`);
  if (!summary.checks.length) throw Error('No GPU checks matched OPENMW_WEBGPU_CHECK');
  console.log(`PASS ${summary.shaders.length} WGSL modules and ${summary.checks.length} real GPU checks`);
}

main().catch(error => {console.error(error.stack ?? error); process.exitCode = 1;});
