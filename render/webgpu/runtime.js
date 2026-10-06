// SPDX-License-Identifier: GPL-3.0-or-later
// Direct WebGPU resource, pipeline and command management. WGSL is loaded as
// source; this module has no source-language compiler or native driver bridge.

const B = globalThis.GPUBufferUsage ?? {
  MAP_READ: 1, MAP_WRITE: 2, COPY_SRC: 4, COPY_DST: 8, INDEX: 16,
  VERTEX: 32, UNIFORM: 64, STORAGE: 128, INDIRECT: 256, QUERY_RESOLVE: 512,
};
const COMPUTE = globalThis.GPUShaderStage?.COMPUTE ?? 4;
const MAP_READ = globalThis.GPUMapMode?.READ ?? 1;
const align = (value, alignment) => Math.ceil(value / alignment) * alignment;
const identifier = value => typeof value === 'string' && /^[A-Za-z_][A-Za-z0-9_]*$/.test(value);
const integer = (value, maximum = Number.MAX_SAFE_INTEGER) => Number.isSafeInteger(value) && value >= 0 && value <= maximum;
const scalarChecks = {
  u32: value => integer(value, 0xffffffff),
  i32: value => Number.isInteger(value) && value >= -2147483648 && value <= 2147483647,
  f32: value => typeof value === 'number' && Number.isFinite(value) && Number.isFinite(Math.fround(value)),
};
const optionalFeatures = ['timestamp-query', 'depth-clip-control', 'depth32float-stencil8',
  'float32-blendable', 'texture-formats-tier1'];

function normalizeMetadata(metadata, limits) {
  if (!metadata || !Array.isArray(metadata.bindings) || !Array.isArray(metadata.scalars))
    throw new TypeError('Kernel needs buffer and scalar binding metadata');
  const {uniformSize, uniformBinding, workgroupSize, workgroupStorageBytes = 0} = metadata;
  if (!integer(uniformSize, limits.maxUniformBufferBindingSize ?? 65536) || uniformSize % 16)
    throw new RangeError('Invalid kernel uniform size');
  if (!Array.isArray(workgroupSize) || workgroupSize.length !== 3
      || workgroupSize.some((value, axis) => !integer(value, limits[['maxComputeWorkgroupSizeX',
        'maxComputeWorkgroupSizeY', 'maxComputeWorkgroupSizeZ'][axis]] ?? [256, 256, 64][axis]) || !value)
      || workgroupSize.reduce((product, value) => product * value, 1) > (limits.maxComputeInvocationsPerWorkgroup ?? 256))
    throw new RangeError('Kernel workgroup exceeds device limits');
  if (!integer(workgroupStorageBytes, limits.maxComputeWorkgroupStorageSize ?? 16384))
    throw new RangeError('Kernel workgroup storage exceeds device limits');
  if (metadata.bindings.length > (limits.maxStorageBuffersPerShaderStage ?? 8))
    throw new RangeError('Kernel storage bindings exceed device limits');
  const names = new Set(), locations = new Set(), offsets = new Set();
  const bindingLimit = limits.maxBindingsPerBindGroup ?? 1000;
  const bindings = metadata.bindings.map(binding => {
    if (!identifier(binding.name) || names.has(binding.name) || !integer(binding.binding, bindingLimit - 1)
        || locations.has(binding.binding) || !Object.hasOwn(scalarChecks, binding.elementType)
        || !integer(binding.stride) || binding.stride < 4 || binding.stride % 4
        || typeof binding.readOnly !== 'boolean' || (binding.atomic && binding.readOnly))
      throw new RangeError(`Invalid storage binding ${binding.name}`);
    names.add(binding.name); locations.add(binding.binding);
    return Object.freeze({...binding});
  });
  if (uniformSize && (!integer(uniformBinding, bindingLimit - 1) || locations.has(uniformBinding)))
    throw new RangeError('Invalid uniform binding location');
  const scalars = metadata.scalars.map(scalar => {
    if (!identifier(scalar.name) || names.has(scalar.name) || !Object.hasOwn(scalarChecks, scalar.type)
        || !integer(scalar.offset) || scalar.offset % 4 || offsets.has(scalar.offset)
        || scalar.offset + 4 > uniformSize)
      throw new RangeError(`Invalid scalar layout ${scalar.name}`);
    names.add(scalar.name); offsets.add(scalar.offset);
    return Object.freeze({...scalar});
  });
  return Object.freeze({bindings: Object.freeze(bindings), scalars: Object.freeze(scalars),
    uniformSize, uniformBinding, workgroupSize: Object.freeze([...workgroupSize]), workgroupStorageBytes});
}

function validateScalars(metadata, values, partial = false) {
  if (!values || typeof values !== 'object' || Array.isArray(values)) throw new TypeError('Expected scalar values');
  for (const [name, value] of Object.entries(values)) {
    const scalar = metadata.scalars.find(item => item.name === name);
    if (!scalar || !scalarChecks[scalar.type](value)) throw new RangeError(`Invalid scalar ${name}`);
  }
  if (!partial) for (const scalar of metadata.scalars)
    if (!Object.hasOwn(values, scalar.name)) throw new Error(`Missing scalar ${scalar.name}`);
}

function snapshotScalars(metadata, values) {
  validateScalars(metadata, values);
  const bytes = new Uint8Array(metadata.uniformSize), view = new DataView(bytes.buffer);
  for (const scalar of metadata.scalars) {
    const method = {u32: 'setUint32', i32: 'setInt32', f32: 'setFloat32'}[scalar.type];
    view[method](scalar.offset, values[scalar.name], true);
  }
  return bytes;
}

function range(resource, offset, byteLength) {
  if (!integer(offset) || !integer(byteLength) || offset % 4 || byteLength % 4
      || offset + byteLength > resource.byteLength)
    throw new RangeError('Invalid buffer transfer range');
}

export class WebGPURuntime {
  static async create({gpu = globalThis.navigator?.gpu, powerPreference = 'high-performance',
    useAdapterBufferLimits = true, requiredFeatures = [], onError = () => {}} = {}) {
    if (!gpu?.requestAdapter) throw new Error('WebGPU is unavailable. Use a browser with WebGPU enabled.');
    const adapter = await gpu.requestAdapter({powerPreference});
    if (!adapter) throw new Error('No WebGPU adapter is available');
    for (const feature of requiredFeatures) if (!adapter.features.has(feature))
      throw new Error(`Required WebGPU feature is unavailable: ${feature}`);
    const features = [...new Set([...requiredFeatures, ...optionalFeatures.filter(feature => adapter.features.has(feature))])];
    const requiredLimits = {};
    if (useAdapterBufferLimits) for (const name of ['maxBufferSize', 'maxStorageBufferBindingSize'])
      requiredLimits[name] = adapter.limits[name];
    const device = await adapter.requestDevice({label: 'OpenMW WebGPU renderer', requiredFeatures: features, requiredLimits});
    try { return new WebGPURuntime(device, {adapter, onError}); }
    catch (error) { device.destroy(); throw error; }
  }

  constructor(device, {adapter = null, onError = () => {}, uniformCapacity = 65536,
    maxPooledUniformBytes = 4 * 1024 * 1024, ownDevice = true} = {}) {
    if (!device?.queue || !device.limits) throw new TypeError('Expected a WebGPU device');
    Object.assign(this, {device, adapter, onError, ownDevice});
    this.backend = 'webgpu';
    this.uniformAlignment = device.limits.minUniformBufferOffsetAlignment ?? 256;
    this.uniformCapacity = Math.min(uniformCapacity, device.limits.maxBufferSize);
    if (!integer(this.uniformAlignment) || !this.uniformAlignment || !integer(this.uniformCapacity)
        || this.uniformCapacity < 16 || this.uniformCapacity % 16 || !integer(maxPooledUniformBytes))
      throw new RangeError('Invalid runtime uniform arena');
    this.maxPooledUniformBytes = maxPooledUniformBytes;
    this.buffers = new Set(); this.kernelCache = new Map(); this.openBatches = new Set();
    this.arenas = new Set(); this.arenaPool = new Map(); this.pooledUniformBytes = 0;
    this.pending = null; this.pendingReads = new Set(); this.failure = null;
    this.disposed = false; this.closing = false;
    this.stats = {pipelineCompiles: 0, pipelineCacheHits: 0, submissions: 0, dispatches: 0,
      recordedBatches: 0, coalescedBatches: 0, dataBytesUploaded: 0, borrowedUploadBytes: 0,
      copiedUploadBytes: 0, readbackBytes: 0, uniformBytesUploaded: 0, uniformAllocations: 0};
    this.onUncapturedError = event => this.fail(event.error ?? new Error('Uncaptured WebGPU error'));
    device.addEventListener?.('uncapturederror', this.onUncapturedError);
    device.lost?.then(info => {
      if (!this.disposed && !this.closing) this.fail(new Error(`WebGPU device lost (${info.reason}): ${info.message}`));
    }).catch(error => this.fail(error));
  }

  assertAlive() {
    if (this.failure) throw this.failure;
    if (this.disposed || this.closing) throw new Error('WebGPU renderer is disposed');
  }

  fail(error) {
    if (this.disposed || this.failure) return;
    this.failure = error instanceof Error ? error : new Error(String(error));
    const group = this.pending; this.pending = null;
    if (group) {
      for (const arena of group.arenas) this.releaseArena(arena, false);
      group.reject(this.failure);
    }
    try { this.onError(this.failure); } catch { /* Reporting cannot conceal the GPU error. */ }
  }

  checkResource(resource) {
    this.assertAlive();
    if (!resource || resource.runtime !== this || !this.buffers.has(resource) || resource.destroyed)
      throw new Error('GPU buffer is destroyed or belongs to another runtime');
  }

  createBuffer(dataOrBytes, {label = 'OpenMW GPU buffer', usage = 0} = {}) {
    this.assertAlive();
    const data = ArrayBuffer.isView(dataOrBytes) ? dataOrBytes : null;
    const byteLength = data ? data.byteLength : dataOrBytes;
    const limit = Math.min(this.device.limits.maxBufferSize, this.device.limits.maxStorageBufferBindingSize);
    if (!integer(byteLength, limit) || byteLength % 4) throw new RangeError('Invalid GPU buffer size');
    if (!integer(usage, 1023) || (usage & (B.MAP_READ | B.MAP_WRITE)))
      throw new RangeError('Renderer buffers cannot be mapped; use read() for an ordered readback');
    const size = Math.max(4, byteLength);
    const bufferUsage = B.STORAGE | B.COPY_SRC | B.COPY_DST | B.VERTEX | B.INDEX | B.INDIRECT | usage;
    const gpuBuffer = this.device.createBuffer({label, size, usage: bufferUsage});
    const resource = {runtime: this, gpuBuffer, byteLength, size, label, usage: bufferUsage, destroyed: false};
    this.buffers.add(resource);
    try { if (data?.byteLength) this.write(resource, data); }
    catch (error) { this.buffers.delete(resource); resource.destroyed = true; gpuBuffer.destroy(); throw error; }
    return resource;
  }

  growBuffer(previous, byteLength, {label = previous?.label, usage = 0} = {}) {
    this.checkResource(previous);
    if (!integer(byteLength) || byteLength <= previous.byteLength) throw new RangeError('Buffer growth must increase size');
    const replacement = this.createBuffer(byteLength, {label, usage});
    try {
      if (previous.byteLength) this.batch().copy(previous, replacement, {byteLength: previous.byteLength}).submit();
      return replacement;
    } catch (error) { this.destroyBuffer(replacement); throw error; }
  }

  write(resource, data, offset = 0) {
    this.checkResource(resource);
    if (!ArrayBuffer.isView(data)) throw new TypeError('Expected a buffer upload view');
    range(resource, offset, data.byteLength);
    if (!data.byteLength) return;
    this.flush();
    // writeBuffer snapshots the supplied bytes immediately. Passing the WASM
    // heap directly avoids an additional WASM -> JavaScript array copy.
    let copied = false;
    try { this.device.queue.writeBuffer(resource.gpuBuffer, offset, data.buffer, data.byteOffset, data.byteLength); }
    catch (error) {
      // Older implementations may reject SharedArrayBuffer as a BufferSource.
      if (!(error instanceof TypeError) || typeof SharedArrayBuffer === 'undefined'
          || !(data.buffer instanceof SharedArrayBuffer)) throw error;
      const copy = new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice();
      this.device.queue.writeBuffer(resource.gpuBuffer, offset, copy.buffer);
      this.stats.copiedUploadBytes += copy.byteLength; copied = true;
    }
    if (!copied && typeof SharedArrayBuffer !== 'undefined' && data.buffer instanceof SharedArrayBuffer)
      this.stats.borrowedUploadBytes += data.byteLength;
    this.stats.dataBytesUploaded += data.byteLength;
  }

  writeBorrowed(resource, data, offset = 0) { return this.write(resource, data, offset); }

  read(resource, Type = Float32Array, byteLength = resource.byteLength, offset = 0) {
    this.checkResource(resource);
    if (![Float32Array, Uint32Array, Int32Array].includes(Type)) throw new TypeError('Readback supports 32-bit arrays');
    range(resource, offset, byteLength);
    if (!byteLength) return Promise.resolve(new Type());
    this.flush();
    const readback = this.device.createBuffer({label: 'OpenMW readback', size: byteLength, usage: B.COPY_DST | B.MAP_READ});
    let mapped = false;
    const task = (async () => {
      try {
        const encoder = this.device.createCommandEncoder({label: 'OpenMW ordered readback'});
        encoder.copyBufferToBuffer(resource.gpuBuffer, offset, readback, 0, byteLength);
        this.device.queue.submit([encoder.finish()]); this.stats.submissions++;
        await readback.mapAsync(MAP_READ);
        mapped = true;
        if (this.failure) throw this.failure;
        const bytes = readback.getMappedRange().slice(0);
        this.stats.readbackBytes += byteLength;
        return new Type(bytes);
      } finally { if (mapped) readback.unmap(); readback.destroy(); }
    })();
    this.pendingReads.add(task);
    task.then(() => this.pendingReads.delete(task), () => this.pendingReads.delete(task));
    return task;
  }

  async kernel(artifact) {
    this.assertAlive();
    if (!artifact || typeof artifact.wgsl !== 'string' || !artifact.wgsl.trim() || artifact.native)
      throw new TypeError('Expected standalone WGSL source and binding metadata');
    const entryPoint = artifact.entryPoint ?? 'main';
    if (!identifier(entryPoint)) throw new TypeError('Invalid WGSL entry point');
    const metadata = normalizeMetadata(artifact.metadata, this.device.limits);
    if (metadata.uniformSize > this.uniformCapacity) throw new RangeError('Kernel exceeds uniform arena capacity');
    const defaults = {...artifact.defaults}; validateScalars(metadata, defaults, true);
    const key = JSON.stringify([entryPoint, metadata, defaults, artifact.wgsl]);
    if (this.kernelCache.has(key)) { this.stats.pipelineCacheHits++; return this.kernelCache.get(key); }
    const compile = (async () => {
      const label = artifact.name ?? entryPoint, device = this.device;
      device.pushErrorScope?.('validation');
      let module, moduleError;
      try { module = device.createShaderModule({label, code: artifact.wgsl}); }
      finally { moduleError = device.popErrorScope?.(); }
      const [information, validation] = await Promise.all([module.getCompilationInfo?.(), moduleError]);
      const errors = information?.messages?.filter(message => message.type === 'error') ?? [];
      if (validation || errors.length) throw new Error(`WGSL ${label} failed: ${validation?.message ?? ''}\n` +
        errors.map(message => `${message.lineNum}:${message.linePos} ${message.message}`).join('\n'));
      this.assertAlive();
      const entries = metadata.bindings.map(binding => ({binding: binding.binding, visibility: COMPUTE,
        buffer: {type: binding.readOnly ? 'read-only-storage' : 'storage', minBindingSize: binding.stride}}));
      if (metadata.uniformSize) entries.push({binding: metadata.uniformBinding, visibility: COMPUTE,
        buffer: {type: 'uniform', hasDynamicOffset: true, minBindingSize: metadata.uniformSize}});
      const bindGroupLayout = device.createBindGroupLayout({label, entries});
      const layout = device.createPipelineLayout({label, bindGroupLayouts: [bindGroupLayout]});
      const descriptor = {label, layout, compute: {module, entryPoint}};
      const pipeline = device.createComputePipelineAsync
        ? await device.createComputePipelineAsync(descriptor) : device.createComputePipeline(descriptor);
      this.assertAlive();
      const runtime = this;
      const kernel = {runtime, pipeline, bindGroupLayout, artifact: Object.freeze({name: label, entryPoint, metadata}),
        bind(resources, scalars = {}) {
          runtime.checkBindings(metadata, resources);
          const values = {...defaults, ...scalars}; validateScalars(metadata, values);
          const invocation = {kernel, resources: Object.freeze({...resources}), scalars: values,
            setScalars(updates) { validateScalars(metadata, updates, true); Object.assign(this.scalars, updates); return this; }};
          return invocation;
        }};
      this.stats.pipelineCompiles++;
      return kernel;
    })();
    this.kernelCache.set(key, compile);
    try { return await compile; }
    catch (error) { if (this.kernelCache.get(key) === compile) this.kernelCache.delete(key); throw error; }
  }

  checkBindings(metadata, resources) {
    this.assertAlive();
    if (!resources || typeof resources !== 'object' || Array.isArray(resources)) throw new TypeError('Expected GPU buffers');
    for (const name of Object.keys(resources)) if (!metadata.bindings.some(binding => binding.name === name))
      throw new Error(`Unknown buffer ${name}`);
    const seen = new Map();
    for (const binding of metadata.bindings) {
      const resource = resources[binding.name]; this.checkResource(resource);
      if (resource.size < binding.stride || resource.size > this.device.limits.maxStorageBufferBindingSize)
        throw new RangeError(`Storage buffer size is invalid for ${binding.name}`);
      if (seen.has(resource.gpuBuffer) && (!binding.readOnly || !seen.get(resource.gpuBuffer)))
        throw new RangeError('Writable storage bindings must not alias');
      seen.set(resource.gpuBuffer, binding.readOnly);
    }
  }

  batch(options = {}) { this.assertAlive(); return new WebGPUBatch(this, options); }

  acquireArena(bytes) {
    const size = Math.min(this.uniformCapacity, Math.max(16, 2 ** Math.ceil(Math.log2(bytes))));
    const pool = this.arenaPool.get(size), cached = pool?.pop();
    if (cached) { this.pooledUniformBytes -= size; return cached; }
    const arena = this.device.createBuffer({label: 'OpenMW dispatch uniforms', size, usage: B.UNIFORM | B.COPY_DST});
    this.arenas.add(arena); this.stats.uniformAllocations++;
    return arena;
  }

  releaseArena(arena, reuse = true) {
    if (!this.arenas.has(arena)) return;
    if (reuse && !this.closing && !this.disposed && !this.failure
        && this.pooledUniformBytes + arena.size <= this.maxPooledUniformBytes) {
      let pool = this.arenaPool.get(arena.size);
      if (!pool) this.arenaPool.set(arena.size, pool = []);
      pool.push(arena); this.pooledUniformBytes += arena.size;
    } else { this.arenas.delete(arena); arena.destroy(); }
  }

  enqueue(command, arenas, immediate = false) {
    this.assertAlive(); this.stats.recordedBatches++;
    let group = this.pending;
    if (group) this.stats.coalescedBatches++;
    else {
      group = {commands: [], arenas: [], resolve: null, reject: null};
      group.promise = new Promise((resolve, reject) => Object.assign(group, {resolve, reject}));
      group.promise.catch(() => {});
      this.pending = group;
      queueMicrotask(() => { if (this.pending === group) try { this.flush(); } catch (error) { this.fail(error); } });
    }
    group.commands.push(command); group.arenas.push(...arenas);
    if (immediate) this.flush();
    return group.promise;
  }

  // Call before any externally authored queue write/submit. Runtime uploads,
  // readbacks, destruction and presentation already establish this boundary.
  flush() {
    this.assertAlive();
    const group = this.pending;
    if (!group) return;
    this.pending = null;
    try {
      this.device.queue.submit(group.commands); this.stats.submissions++;
      this.device.queue.onSubmittedWorkDone().then(() => {
        for (const arena of group.arenas) this.releaseArena(arena);
        if (this.failure) group.reject(this.failure); else group.resolve();
      }, error => {
        for (const arena of group.arenas) this.releaseArena(arena, false);
        group.reject(error); this.fail(error);
      });
    } catch (error) {
      for (const arena of group.arenas) this.releaseArena(arena, false);
      group.reject(error); this.fail(error); throw error;
    }
  }

  presentBuffer(resource, context, width, height, rowPixels) {
    this.checkResource(resource);
    if (![width, height].every(value => integer(value, this.device.limits.maxTextureDimension2D) && value)
        || !integer(rowPixels) || rowPixels < width || rowPixels * 4 % 256
        || (height - 1) * rowPixels * 4 + width * 4 > resource.byteLength)
      throw new RangeError('Invalid presentation buffer layout');
    this.flush();
    const encoder = this.device.createCommandEncoder({label: 'OpenMW canvas presentation'});
    encoder.copyBufferToTexture({buffer: resource.gpuBuffer, bytesPerRow: rowPixels * 4, rowsPerImage: height},
      {texture: context.getCurrentTexture()}, [width, height, 1]);
    this.device.queue.submit([encoder.finish()]); this.stats.submissions++;
  }

  destroyBuffer(resource) {
    if (!resource || resource.runtime !== this) throw new Error('GPU buffer belongs to another runtime');
    if (resource.destroyed) return;
    // Destruction remains available for cleanup after device loss.
    if (!this.failure && !this.closing && !this.disposed) this.flush();
    resource.destroyed = true; this.buffers.delete(resource); resource.gpuBuffer.destroy();
  }

  async idle() { this.assertAlive(); this.flush(); await this.device.queue.onSubmittedWorkDone(); this.assertAlive(); }
  describe() { return {backend: this.backend, adapter: this.adapter?.info ?? null,
    features: [...(this.device.features ?? [])], limits: this.device.limits}; }

  dispose() {
    if (this.disposal) return this.disposal;
    let flushError;
    try { if (!this.failure) this.flush(); } catch (error) { flushError = error; }
    this.closing = true;
    this.disposal = (async () => {
      try {
        await Promise.allSettled([...this.pendingReads]);
        await this.device.queue.onSubmittedWorkDone();
        if (flushError) throw flushError;
      } finally {
        for (const batch of this.openBatches) batch.discard();
        for (const resource of this.buffers) this.destroyBuffer(resource);
        for (const arena of this.arenas) arena.destroy();
        this.arenas.clear(); this.arenaPool.clear(); this.pooledUniformBytes = 0;
        this.kernelCache.clear(); this.disposed = true;
        this.device.removeEventListener?.('uncapturederror', this.onUncapturedError);
        if (this.ownDevice) this.device.destroy();
      }
    })();
    return this.disposal;
  }
}

class WebGPUBatch {
  constructor(runtime, {label = 'OpenMW compute batch', timestampWrites} = {}) {
    Object.assign(this, {runtime, label, timestampWrites});
    this.operations = []; this.resources = new Set(); this.uniformBytes = 0;
    this.arenas = []; this.encoded = 0; this.pass = null; this.hadPass = false; this.ended = false;
    runtime.openBatches.add(this);
  }

  open() { if (this.ended) throw new Error('GPU batch is closed'); this.runtime.assertAlive(); }

  dispatch(invocation, groups, indirect = null) {
    this.open();
    const {runtime} = this, kernel = invocation?.kernel;
    if (kernel?.runtime !== runtime) throw new Error('Kernel belongs to another runtime');
    if (!Array.isArray(groups) || groups.length !== 3
        || groups.some(value => !integer(value, runtime.device.limits.maxComputeWorkgroupsPerDimension)))
      throw new RangeError('Dispatch exceeds device workgroup limits');
    const metadata = kernel.artifact.metadata;
    runtime.checkBindings(metadata, invocation.resources);
    const uniforms = snapshotScalars(metadata, invocation.scalars);
    if (indirect) {
      runtime.checkResource(indirect.buffer); range(indirect.buffer, indirect.offset ?? 0, 12);
      if (!(indirect.buffer.usage & B.INDIRECT)) throw new RangeError('Indirect dispatch needs an INDIRECT buffer');
    } else if (groups.some(value => value === 0)) return this;
    const bytes = metadata.uniformSize ? align(this.uniformBytes, runtime.uniformAlignment) + metadata.uniformSize : this.uniformBytes;
    if (bytes > runtime.uniformCapacity) throw new RangeError('Batch exceeds uniform arena capacity; use boundedBatch');
    this.uniformBytes = bytes;
    const resources = {...invocation.resources};
    for (const resource of Object.values(resources)) this.resources.add(resource);
    if (indirect) this.resources.add(indirect.buffer);
    this.operations.push({type: 'dispatch', kernel, resources, uniforms, groups: [...groups],
      indirect: indirect ? {buffer: indirect.buffer, offset: indirect.offset ?? 0} : null});
    return this;
  }

  copy(source, target, selection) {
    this.open(); this.runtime.checkResource(source); this.runtime.checkResource(target);
    if (source.gpuBuffer === target.gpuBuffer) throw new RangeError('Copy requires distinct buffers');
    if (selection === undefined && source.byteLength !== target.byteLength)
      throw new RangeError('Whole-buffer copy requires equal sizes');
    const {sourceOffset = 0, targetOffset = 0, byteLength = source.byteLength} = selection ?? {};
    range(source, sourceOffset, byteLength); range(target, targetOffset, byteLength);
    if (byteLength) {
      this.operations.push({type: 'copy', source, target, sourceOffset, targetOffset, byteLength});
      this.resources.add(source); this.resources.add(target);
    }
    return this;
  }

  encodePending() {
    this.open();
    const {runtime} = this, device = runtime.device;
    for (const resource of this.resources) runtime.checkResource(resource);
    this.commandEncoder ??= device.createCommandEncoder({label: this.label});
    const pending = this.operations.slice(this.encoded);
    let bytes = 0;
    for (const operation of pending) if (operation.uniforms?.length)
      bytes = align(bytes, runtime.uniformAlignment) + operation.uniforms.length;
    let arena, data, cursor = 0;
    if (bytes) {
      arena = runtime.acquireArena(bytes); data = new Uint8Array(bytes);
      this.arenas.push({buffer: arena, data});
    }
    for (const operation of pending) {
      if (operation.type === 'copy') {
        this.closePass();
        this.commandEncoder.copyBufferToBuffer(operation.source.gpuBuffer, operation.sourceOffset,
          operation.target.gpuBuffer, operation.targetOffset, operation.byteLength);
        continue;
      }
      if (!this.pass) {
        if (this.timestampWrites && this.hadPass) throw new Error('A timed batch must contain one compute pass');
        this.pass = this.commandEncoder.beginComputePass({label: this.label,
          ...(this.timestampWrites ? {timestampWrites: this.timestampWrites} : {})});
        this.hadPass = true;
      }
      const {kernel, resources, uniforms} = operation, metadata = kernel.artifact.metadata;
      const entries = metadata.bindings.map(binding => ({binding: binding.binding,
        resource: {buffer: resources[binding.name].gpuBuffer, size: resources[binding.name].size}}));
      let offsets = [];
      if (uniforms.length) {
        cursor = align(cursor, runtime.uniformAlignment); data.set(uniforms, cursor);
        entries.push({binding: metadata.uniformBinding, resource: {buffer: arena, size: metadata.uniformSize}});
        offsets = [cursor]; cursor += uniforms.length;
      }
      const group = device.createBindGroup({label: kernel.artifact.name, layout: kernel.bindGroupLayout, entries});
      this.pass.setPipeline(kernel.pipeline); this.pass.setBindGroup(0, group, offsets);
      if (operation.indirect) this.pass.dispatchWorkgroupsIndirect(operation.indirect.buffer.gpuBuffer, operation.indirect.offset);
      else this.pass.dispatchWorkgroups(...operation.groups);
      runtime.stats.dispatches++;
    }
    this.encoded = this.operations.length;
  }

  get encoder() { this.encodePending(); return this.commandEncoder; }
  closePass() { if (this.pass) { this.pass.end(); this.pass = null; } }
  endPass() { this.encodePending(); this.closePass(); return this; }

  submit() {
    this.open();
    try {
      this.endPass();
      for (const arena of this.arenas) {
        this.runtime.device.queue.writeBuffer(arena.buffer, 0, arena.data.buffer);
        this.runtime.stats.uniformBytesUploaded += arena.data.byteLength;
      }
      const command = this.commandEncoder.finish();
      const promise = this.runtime.enqueue(command, this.arenas.map(arena => arena.buffer), Boolean(this.timestampWrites));
      this.arenas = []; this.ended = true; this.runtime.openBatches.delete(this); this.operations = [];
      return promise;
    } catch (error) { this.discard(); throw error; }
  }

  discard() {
    if (this.ended) return;
    this.ended = true; this.operations = [];
    for (const arena of this.arenas) this.runtime.releaseArena(arena.buffer, false);
    this.arenas = []; this.runtime.openBatches.delete(this);
  }
}
