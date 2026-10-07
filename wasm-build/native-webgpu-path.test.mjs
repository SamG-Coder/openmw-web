// SPDX-License-Identifier: GPL-3.0-or-later
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

function read(path) { return fs.readFileSync(new URL('../' + path, import.meta.url), 'utf8'); }

test('browser renderer is owned by WASM/C++', () => {
  const direct = read('openmw/components/webcuda/directwebgpu.cpp');
  const frame = read('openmw/components/webcuda/browserframe.cpp');
  const native = read('openmw/components/webcuda/nativewebgpu.cpp');
  const page = read('play/index.html');

  assert.doesNotMatch(direct, /importJsDevice|webcudaJsDevice/);
  assert.doesNotMatch(frame, /webgpuSubmitFrame|EM_JS/);
  assert.doesNotMatch(page, /webgpu\/game-host\.js|installWebGPU/);

  assert.match(direct, /RequestAdapter/);
  assert.match(direct, /RequestDevice/);
  assert.match(native, /EmscriptenSurfaceSourceCanvasHTMLSelector/);
  assert.match(native, /CreateSurface/);
  assert.match(native, /BeginRenderPass/);
  assert.match(native, /\.Submit\(1, &commands\)/);
  assert.match(page, /id="webgpu-canvas"/);
});
