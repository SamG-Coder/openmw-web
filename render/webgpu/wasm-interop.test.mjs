// SPDX-License-Identifier: GPL-3.0-or-later
// Execute the actual C++ EM_JS bodies. The import probe crosses a real Wasm
// i64 boundary, so a Number returned where wasm64 needs a BigInt really fails.
// This does not replace compiling the Emscripten port or browser GPU validation.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const directSource = await readFile(new URL('../../openmw/components/webcuda/directwebgpu.cpp', import.meta.url), 'utf8');
const bridgeSource = await readFile(new URL('../../openmw/components/webcuda/browserbridge.cpp', import.meta.url), 'utf8');
const frameSource = await readFile(new URL('../../openmw/components/webcuda/browserframe.cpp', import.meta.url), 'utf8');

function bodyEnd(source) {
  let depth = 1, quote = null, comment = null;
  for (let i = 0; i < source.length; i++) {
    const current = source[i], next = source[i + 1];
    if (comment === 'line') {
      if (current === '\n') comment = null;
    } else if (comment === 'block') {
      if (current === '*' && next === '/') { comment = null; i++; }
    } else if (quote) {
      if (current === '\\') i++;
      else if (current === quote) quote = null;
    } else if (current === '/' && next === '/') { comment = 'line'; i++; }
    else if (current === '/' && next === '*') { comment = 'block'; i++; }
    else if (current === '"' || current === "'" || current === '`') quote = current;
    else if (current === '{') depth++;
    else if (current === '}' && --depth === 0) return i;
  }
  assert.fail('Unclosed EM_JS function body');
}

function emJs(source, name, globals, {memory64 = true} = {}) {
  const declaration = new RegExp(`EM_JS\\s*\\([^,]+,\\s*${name}\\s*,\\s*\\(([\\s\\S]*?)\\)\\s*,\\s*\\{`).exec(source);
  assert(declaration, `Missing EM_JS helper ${name}`);
  const afterOpening = source.slice(declaration.index + declaration[0].length);
  const closing = bodyEnd(afterOpening);
  assert(/^\s*\)/.test(afterOpening.slice(closing + 1)), `Missing end of EM_JS helper ${name}`);
  const parameters = declaration[1].trim() ? declaration[1].split(',').map(parameter => {
    const name = /([A-Za-z_]\w*)\s*$/.exec(parameter)?.[1];
    assert(name, `Unsupported EM_JS parameter ${parameter}`);
    return {name, pointer: /\*|\bsize_t\b|\buintptr_t\b|\bWGPU\w+\b/.test(parameter)};
  }) : [];
  const lines = [];
  const conditions = [];
  let active = true;
  for (const line of afterOpening.slice(0, closing).split('\n')) {
    if (/^\s*#\s*(?:if\s+(?:__wasm64__|defined\s*\(\s*__wasm64__\s*\))|ifdef\s+__wasm64__)\s*$/.test(line)) {
      conditions.push({parent: active, branch: memory64});
      active = active && memory64;
    } else if (/^\s*#\s*else\s*$/.test(line)) {
      assert(conditions.length, 'Unexpected #else in EM_JS');
      const current = conditions.at(-1);
      current.branch = !current.branch;
      active = current.parent && current.branch;
    } else if (/^\s*#\s*endif\s*$/.test(line)) {
      assert(conditions.length, 'Unexpected #endif in EM_JS');
      active = conditions.pop().parent;
    } else {
      assert(!/^\s*#/.test(line), `Unsupported preprocessor directive in EM_JS: ${line}`);
      if (active) lines.push(line);
    }
  }
  assert.equal(conditions.length, 0, 'Unclosed preprocessor directive in EM_JS');
  const invoke = vm.runInNewContext(`(function(${parameters.map(parameter => parameter.name).join(',')}) {\n${lines.join('\n')}\n})`, globals);
  return {
    invoke,
    call(values = {}) {
      return invoke(...parameters.map(parameter => Object.hasOwn(values, parameter.name)
        ? values[parameter.name] : memory64 && parameter.pointer ? 0n : 0));
    },
  };
}

// (module (import "env" "getPointer" (func $getPointer (result i64)))
//   (func (export "probe") (result i64) call $getPointer))
const pointerModule = new WebAssembly.Module(Uint8Array.from([
  0,97,115,109,1,0,0,0,
  1,5,1,96,0,1,126,
  2,18,1,3,101,110,118,10,103,101,116,80,111,105,110,116,101,114,0,0,
  3,2,1,0,
  7,9,1,5,112,114,111,98,101,0,1,
  10,6,1,4,0,16,0,11,
]));

function callAsWasm64(helper) {
  return new WebAssembly.Instance(pointerModule, {env: {getPointer: helper.invoke}}).exports.probe();
}

test('device import returns a wasm64 null pointer while browser initialization is pending', () => {
  const helper = emJs(directSource, 'omw_webgpu_import_boot_device', {Module: {}, WebGPU: undefined});
  assert.equal(callAsWasm64(helper), 0n);
});

test('device import preserves pointer values above 4 GiB through the actual Wasm ABI', () => {
  const device = {queue: {}};
  for (const pointer of [4096, 0x100000000 + 64]) {
    const imports = [];
    const helper = emJs(directSource, 'omw_webgpu_import_boot_device', {
      Module: {webcudaJsDevice: device},
      WebGPU: {importJsDevice(value) { imports.push(value); return pointer; }},
    });
    assert.equal(callAsWasm64(helper), BigInt(pointer));
    assert.deepEqual(imports, [device]);
  }
});

test('device import reports missing Emdawnwebgpu bindings once a device exists', () => {
  const helper = emJs(directSource, 'omw_webgpu_import_boot_device', {
    Module: {webcudaJsDevice: {queue: {}}}, WebGPU: undefined,
  });
  assert.throws(() => callAsWasm64(helper), /interop is unavailable/);
});

test('the same import helper retains the wasm32 Number return ABI', () => {
  const pending = emJs(directSource, 'omw_webgpu_import_boot_device', {
    Module: {}, WebGPU: undefined,
  }, {memory64: false});
  assert.equal(pending.call(), 0);
  const ready = emJs(directSource, 'omw_webgpu_import_boot_device', {
    Module: {webcudaJsDevice: {queue: {}}}, WebGPU: {importJsDevice: () => 4096},
  }, {memory64: false});
  assert.equal(ready.call(), 4096);
});

function legacyPassFixture(accept = () => true) {
  const heap = new ArrayBuffer(1024);
  const HEAPU32 = new Uint32Array(heap), HEAPF32 = new Float32Array(heap);
  const bufferHandle = 0x100000000 + 64;
  const gpuBuffer = {size: 4096};
  const released = [], exportedHandles = [], packets = [];
  HEAPU32.set([256, 16], 64); // First direct range, stored at byte offset 256.
  const Module = {webcudaSubmitPass(packet) { packets.push(packet); return accept(packet); }};
  const helper = emJs(bridgeSource, 'omw_webcuda_submit_pass', {
    Module, HEAPU32, HEAPF32,
    WebGPU: {getJsObject(handle) {
      assert.equal(typeof handle, 'number', 'Normalize a Wasm pointer before JS object lookup');
      assert.equal(handle, bufferHandle, 'Do not truncate the handle to 32 bits');
      exportedHandles.push(handle);
      return gpuBuffer;
    }},
    _omw_webcuda_release_pass(token) { released.push(token); },
  });
  return {
    Module, gpuBuffer, packets, released, exportedHandles,
    submit() { return helper.call({
      token: 17, vertexEncoding: 0, width: 16, height: 8,
      directBuffer: BigInt(bufferHandle), directBytes: 4096n,
      directRanges: 256n, directRangeWords: 62n,
    }); },
  };
}

test('wasm64 size_t metadata selects the direct GPU buffer instead of silently bypassing it', () => {
  const f = legacyPassFixture();
  assert.equal(f.submit(), 1);
  assert.equal(f.packets.length, 1);
  const packet = f.packets[0];
  assert(packet.scene.directGPU, 'BigInt range counts must enable direct GPU transport');
  assert.equal(packet.scene.directGPU.buffer, f.gpuBuffer);
  assert.equal(packet.scene.directGPU.byteLength, 4096);
  assert.equal(packet.scene.directGPU.ranges.vertexLayouts.offset, 256);
  assert.equal(packet.scene.directGPU.ranges.vertexLayouts.bytes, 16);
  assert.equal(f.exportedHandles.length, 1);
  assert.equal(f.Module.webcudaTransportStats.directGpuPasses, 1);
  assert.equal(f.Module.webcudaTransportStats.copiedSceneBytes, 0);
  assert.deepEqual(f.released, [], 'Keep retained heap ranges alive until consumer release');
  packet.release();
  packet.release();
  assert.deepEqual(f.released, [17], 'Release retained C++ state exactly once');
  assert.equal(f.Module.webcudaTransportStats.retainedPasses, 0);
  assert.equal(f.Module.webcudaTransportStats.retainedViewBytes, 0);
});

test('direct GPU pass rejection releases retained ownership exactly once', () => {
  const f = legacyPassFixture(() => false);
  assert.equal(f.submit(), 0);
  assert.equal(f.exportedHandles.length, 1);
  assert.deepEqual(f.released, [17]);
  f.packets[0].release();
  assert.deepEqual(f.released, [17]);
  assert.equal(f.Module.webcudaTransportStats.retainedPasses, 0);
});

function frameFixture() {
  const memory = new WebAssembly.Memory({initial: 1, maximum: 2, shared: true});
  const heap = memory.buffer;
  const gpuBuffer = {size: 4096}, bufferHandle = 0x100000000 + 128;
  const calls = [], exportedHandles = [], released = [], errors = [];
  const Module = {webcudaTransportStats: {}, webgpuSubmitFrame(...args) { calls.push(args); }};
  const helper = emJs(frameSource, 'omw_webgpu_submit_frame', {
    Module, HEAPU32: new Uint32Array(heap),
    WebGPU: {getJsObject(handle) {
      assert.equal(typeof handle, 'number');
      assert.equal(handle, bufferHandle);
      exportedHandles.push(handle);
      return gpuBuffer;
    }},
    _omw_webcuda_release_pass(token) { released.push(token); },
    console: {error(...args) { errors.push(args); }},
  });
  return {Module, heap, gpuBuffer, calls, exportedHandles, released, errors,
    submit(values = {}) { return helper.call({
      commands: 4096n, wordCount: 128n, directBuffer: BigInt(bufferHandle), directBytes: 2048n,
      allocations: 3, reuses: 7, ...values,
    }); },
  };
}

test('batched frame handoff passes shared WASM memory and the GPU buffer in one consumer call', () => {
  const f = frameFixture();
  assert.equal(f.submit(), 1);
  assert.equal(f.calls.length, 1);
  const [heap, byteOffset, wordCount, gpuBuffer, directBytes, releasePass] = f.calls[0];
  assert(heap instanceof SharedArrayBuffer);
  assert.equal(heap, f.heap, 'Forward the actual WASM memory without a JS payload copy');
  assert.equal(byteOffset, 4096);
  assert.equal(wordCount, 128);
  assert.equal(gpuBuffer, f.gpuBuffer);
  assert.equal(directBytes, 2048);
  assert.equal(f.exportedHandles.length, 1);
  assert.deepEqual(f.released, []);
  releasePass(41);
  assert.deepEqual(f.released, [41]);
  assert.equal(f.Module.webcudaTransportStats.directBufferAllocations, 3);
  assert.equal(f.Module.webcudaTransportStats.directBufferReuses, 7);
});

test('a frame without dynamic uploads crosses the bridge without a GPU handle lookup', () => {
  const f = frameFixture();
  assert.equal(f.submit({directBuffer: 0n, directBytes: 0n}), 1);
  assert.equal(f.calls.length, 1);
  assert.equal(f.calls[0][3], null);
  assert.equal(f.calls[0][4], 0);
  assert.deepEqual(f.exportedHandles, []);
});

test('failed frame submission reports the error and leaves unreleased tokens for C++ abort', () => {
  const f = frameFixture();
  f.Module.webgpuSubmitFrame = () => { throw Error('deliberate descriptor rejection'); };
  assert.equal(f.submit(), 0);
  assert.match(f.Module.webgpuSubmissionError, /deliberate descriptor rejection/);
  assert.equal(f.errors.length, 1);
  assert.deepEqual(f.released, []);
});
