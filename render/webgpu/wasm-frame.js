// SPDX-License-Identifier: GPL-3.0-or-later
// One application handoff per frame. The engine owns camera/effect ordering and
// all scene arrays; this adapter only decodes fixed-width descriptors. WebGPU's
// browser binding and the existing GPU preparation/render pipelines run here.
export const WASM_FRAME_MAGIC = 0x4f4d5747;
export const WASM_FRAME_VERSION = 1;
export const SCENE_VIEWS = Object.freeze([
  ['vertexLayouts', 'u'], ['vertexInputs', 'f'], ['vertexResources', 'u'],
  ['vertices', 'f'], ['matrices', 'f'], ['matrixIds', 'u'], ['triangles', 'u'],
  ['materials', 'u'], ['texels', 'u'], ['compressedBlocks', 'u'],
  ['textureDecodes', 'u'], ['textureCopies', 'u'], ['textureResources', 'u'],
  ['uvMatrices', 'f'], ['mipGenerations', 'u'], ['attributes', 'f'], ['rasterParams', 'f'],
  ['morphRanges', 'u'], ['morphOffsets', 'f'], ['skinRanges', 'u'], ['skinWeights', 'u'],
  ['skinBones', 'f'], ['skinTransforms', 'f'], ['ribbonRanges', 'u'], ['ribbonParticles', 'f'],
  ['screenPrimitives', 'u'], ['flatColors', 'u'], ['polygonEdges', 'u'], ['texgen', 'u'],
  ['fixedLighting', 'u'], ['positionedState', 'u'], ['textGradientRanges', 'u'],
  ['textGradientColors', 'f'], ['localTransforms', 'f'], ['debugParams', 'f'],
  ['secondaryColors', 'f'], ['groundcoverRanges', 'u'], ['groundcoverInstances', 'f'],
  ['groundcoverParams', 'f'], ['depthMipSources', 'u'], ['clusterRecords', 'u'],
  ['clusterMaterials', 'u'], ['clusterLights', 'f'], ['clusterProjections', 'f'],
]);
export const DIRECT_GPU_NAMES = Object.freeze([
  'vertexLayouts', 'vertexInputs', 'vertices', 'matrices', 'matrixIds', 'triangles', 'materials', 'attributes',
  'morphRanges', 'morphOffsets', 'skinRanges', 'skinWeights', 'skinBones', 'skinTransforms', 'groundcoverRanges',
  'groundcoverInstances', 'groundcoverParams', 'debugParams', 'textGradientRanges', 'textGradientColors', 'localTransforms',
  'positionedState', 'fixedLighting', 'secondaryColors', 'texgen', 'uvMatrices', 'screenPrimitives', 'flatColors',
  'polygonEdges', 'compressedBlocks', 'vertexResources',
]);

const nonnegative = value => Number.isSafeInteger(value) && value >= 0;
function captureImage(Module, id, width, height, finalScreen) {
  const results = Module.webcudaImageResults ??= new Map();
  const pending = {pending: true};
  results.set(id, pending);
  const finish = value => { if (results.get(id) === pending) results.set(id, value); };
  try {
    Module.webcudaCaptureImage(width, height, finalScreen).then(
      image => finish({image}), error => finish({error: String(error)}));
  } catch (error) { finish({error: String(error)}); }
}

export function submitWasmFrame(Module, heap, byteOffset, wordCount, directBuffer, directBytes, releasePass) {
  if (!nonnegative(byteOffset) || byteOffset % 4 || !nonnegative(wordCount) || wordCount < 2
      || !nonnegative(directBytes) || typeof releasePass !== 'function'
      || byteOffset + wordCount * 4 > heap.byteLength)
    throw RangeError('Invalid WASM frame command range');
  if (directBytes && (!directBuffer || directBytes > directBuffer.size))
    throw RangeError('WASM frame GPU buffer is missing or too small');
  const words = new Uint32Array(heap, byteOffset, wordCount);
  const floats = new Float32Array(heap, byteOffset, wordCount);
  const data = new DataView(heap, byteOffset, wordCount * 4);
  if (words[0] !== WASM_FRAME_MAGIC || words[1] !== WASM_FRAME_VERSION)
    throw Error('Unsupported WASM frame command version');
  const stats = Module.webcudaTransportStats ??= {};
  for (const key of ['capturedPasses', 'releasedPasses', 'retainedPasses', 'retainedViewBytes',
    'copiedSceneBytes', 'directGpuPasses', 'directGpuBytes', 'frameSubmissions', 'frameCommands', 'directGpuUploads'])
    stats[key] ??= 0;
  stats.heapCapacityBytes = heap.byteLength;
  let cursor = 2, end = 2, commandCount = 0;
  const passTokens = new Set();
  const exact = count => { if (end - cursor !== count) throw Error('Invalid WASM frame command size'); };
  const u32 = () => words[cursor++];
  const i32 = () => words[cursor++] | 0;
  const f32 = () => floats[cursor++];
  const f64 = () => { const value = data.getFloat64(cursor * 4, true); cursor += 2; return value; };
  const u64 = () => {
    const value = u32() + u32() * 4294967296;
    if (!nonnegative(value)) throw RangeError('WASM address/count exceeds JavaScript exact integer range');
    return value;
  };
  const floatArray = count => { const value = floats.slice(cursor, cursor + count); cursor += count; return value; };

  while (cursor < wordCount) {
    const start = cursor;
    if (wordCount - start < 2) throw Error('Truncated WASM frame command');
    const opcode = u32(), length = u32();
    end = start + length;
    if (length < 2 || end > wordCount) throw Error('Invalid WASM frame command length');
    switch (opcode) {
      case 1: { // Camera/pass state: exclusively supplied by the WASM viewer.
        exact(21);
        const clearMask = u32(), clearColor = [f32(), f32(), f32(), f32()], clearDepth = f32();
        const targetId = u32(), depthTargetId = u32(), normalTargetId = u32(), colorFormat = u32(), depthFormat = u32();
        const clearStencil = i32(), stencilBits = u32(), stencilTargetId = u32(), clearColorMask = u32();
        const viewport = [i32(), i32(), u32(), u32()], sampleCount = u32(), normalFormat = u32();
        Module.webcudaPassState({clearMask, clearColor, clearDepth, targetId, depthTargetId, normalTargetId,
          colorFormat, depthFormat, clearStencil, stencilBits, stencilTargetId, clearColorMask, viewport, sampleCount, normalFormat});
        break;
      }
      case 2: {
        exact(8 + SCENE_VIEWS.length * 4 + DIRECT_GPU_NAMES.length * 2);
        const token = u32(), vertexEncoding = u32(), width = u32(), height = u32(), texelWordCount = u64();
        if (!token || u32() !== SCENE_VIEWS.length || u32() !== DIRECT_GPU_NAMES.length)
          throw Error('Invalid WASM scene descriptor');
        if (passTokens.has(token)) throw Error('Duplicate WASM pass token');
        passTokens.add(token);
        const scene = {vertexEncoding, texelWordCount, directGPU: null};
        let viewBytes = 0;
        for (const [name, type] of SCENE_VIEWS) {
          const address = u64(), count = u64(), bytes = count * 4;
          if (address % 4 || !nonnegative(bytes) || address + bytes > heap.byteLength)
            throw RangeError(`Invalid WASM ${name} view`);
          scene[name] = type === 'f' ? new Float32Array(heap, address, count) : new Uint32Array(heap, address, count);
          viewBytes += bytes;
        }
        const ranges = {};
        for (const name of DIRECT_GPU_NAMES) {
          const offset = u32(), bytes = u32();
          if (bytes) {
            if (!directBuffer || offset + bytes > directBytes) throw RangeError(`Invalid WASM GPU ${name} range`);
            ranges[name] = {offset, bytes};
          }
        }
        if (Object.keys(ranges).length) {
          scene.directGPU = {buffer: directBuffer, byteLength: directBytes, ranges};
          stats.directGpuPasses++;
        }
        let released = false;
        const packet = {version: 2, storage: 'wasm-retained', width, height, scene, release() {
          if (released) return;
          released = true;
          try { releasePass(token); }
          finally {
            stats.releasedPasses++;
            stats.retainedPasses--;
            stats.retainedViewBytes -= viewBytes;
          }
        }};
        stats.capturedPasses++; stats.retainedPasses++; stats.retainedViewBytes += viewBytes;
        try {
          if (Module.webcudaSubmitPass(packet) === false) throw Error('WASM camera pass was rejected');
        } catch (error) { packet.release(); throw error; }
        break;
      }
      case 3: {
        exact(10);
        const sourceId = u32(), targetId = u32(), plane = u32(), format = u32(), width = u32(), height = u32();
        Module.webcudaResolveAttachment({sourceId, targetId, plane, format, width, height, viewport: [i32(), i32(), u32(), u32()]});
        break;
      }
      case 4: exact(1); Module.webcudaRetireTarget(u32()); break;
      case 5: exact(2); Module.webcudaDepthIsolation(Boolean(u32()), f32()); break;
      case 6: {
        exact(22);
        const depth = u32(), normals = u32(), flags = u32();
        Module.webcudaDebugScene(depth, normals, flags, floatArray(19)); break;
      }
      case 7: {
        exact(13);
        const depth = u32(), reverse = Boolean(u32());
        Module.webcudaBloomScene(depth, floatArray(11), reverse); break;
      }
      case 8: {
        exact(11);
        const sourceId = u32(), width = u32(), height = u32(), sx = f32(), sy = f32(), speed = f32();
        const reset = Boolean(u32()), time = f64(), viewportWidth = u32(), viewportHeight = u32();
        Module.webcudaSceneLuminance({sourceId, width, height, sx, sy, speed, reset, time, viewportWidth, viewportHeight}); break;
      }
      case 9: exact(1); Module.webcudaDistortScene(u32()); break;
      case 10: exact(2); Module.webcudaAdjustScene(f32(), f32()); break;
      case 11: exact(6); Module.webcudaResolveScene(u32(), u32(), u32(), u32(), f32(), f32()); break;
      case 12: exact(3); Module.webcudaCaptureDepth(u32(), u32(), u32()); break;
      case 13: exact(4); Module.webcudaColorTarget(Boolean(u32()), u32(), u32(), u32()); break;
      case 14: {
        if (end - cursor < 8) throw Error('Truncated WASM ripple command');
        const targetId = u32(), width = u32(), height = u32(), count = u32();
        if (count > 100) throw RangeError('Invalid WASM ripple count');
        exact(4 + count * 3);
        const ox = f32(), oy = f32(), time = f32(), simulate = Boolean(u32());
        Module.webcudaSubmitRipple({kind: 'ripples', targetId, width, height, ox, oy, time, simulate, positions: floatArray(count * 3)}); break;
      }
      case 15: exact(3); Module.webcudaSnapshotPreviousFrame(u32(), u32(), u32()); break;
      case 16: exact(4); captureImage(Module, u32(), u32(), u32(), Boolean(u32())); break;
      case 17: {
        exact(16);
        Module.webcudaCaptureTimings = {materialCopyMs: f64(), materialEncodeMs: f64(), geometryEncodeMs: f64(), atlasResizeMs: f64(),
          materialCopies: f64(), materialEncodes: f64(), geometryEncodes: f64(), atlasResizes: f64()}; break;
      }
      case 18: {
        exact(6);
        Module.webcudaShaderAnalysisStats = {hits: f64(), misses: f64(), bypasses: f64()}; break;
      }
      default: throw Error(`Unknown WASM frame opcode ${opcode}`);
    }
    if (cursor !== end) throw Error('WASM frame command did not consume its descriptor');
    commandCount++;
  }
  Module.webcudaEndFrame(true);
  stats.frameSubmissions++;
  stats.frameCommands += commandCount;
  stats.lastFrameCommands = commandCount;
  if (directBytes) { stats.directGpuUploads++; stats.directGpuBytes += directBytes; }
}
