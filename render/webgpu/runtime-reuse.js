// SPDX-License-Identifier: GPL-3.0-or-later
// Bounded, device-local reuse. Neither cache changes submission order or waits
// for the GPU. In-flight readbacks are never available for reuse.

export class ComputeBindGroupCache {
  constructor(device, stats, maxEntries = 1024) {
    if (!Number.isSafeInteger(maxEntries) || maxEntries < 0)
      throw new RangeError('Invalid bind group cache capacity');
    this.device = device; this.stats = stats; this.maxEntries = maxEntries;
    this.entries = new Map(); this.ids = new WeakMap(); this.nextId = 1;
    this.references = new WeakMap();
    Object.assign(stats, {bindGroupCreations: 0, bindGroupCacheHits: 0,
      bindGroupCacheEvictions: 0, bindGroupCacheEntries: 0});
  }

  id(object) {
    let value = this.ids.get(object);
    if (value === undefined) { value = this.nextId++; this.ids.set(object, value); }
    return value;
  }

  get(kernel, resources, arena) {
    const metadata = kernel.artifact.metadata;
    // Kernel identity includes its exact layout. Buffer identity AND binding
    // extent are part of the key; a grown/replaced buffer cannot hit an old group.
    // Dynamic uniform offsets are intentionally not part of a bind group.
    let key = `${this.id(kernel)}`;
    for (const binding of metadata.bindings) {
      const resource = resources[binding.name];
      key += `/${this.id(resource.gpuBuffer)}:${resource.size}`;
    }
    if (metadata.uniformSize) key += `/u${this.id(arena)}`;
    const hit = this.entries.get(key);
    if (hit) {
      this.entries.delete(key); this.entries.set(key, hit);
      this.stats.bindGroupCacheHits++;
      return hit.group;
    }
    const entries = metadata.bindings.map(binding => ({binding: binding.binding,
      resource: {buffer: resources[binding.name].gpuBuffer, size: resources[binding.name].size}}));
    if (metadata.uniformSize) entries.push({binding: metadata.uniformBinding,
      resource: {buffer: arena, size: metadata.uniformSize}});
    const group = this.device.createBindGroup({label: kernel.artifact.name,
      layout: kernel.bindGroupLayout, entries});
    this.stats.bindGroupCreations++;
    if (!this.maxEntries) return group;
    if (this.entries.size >= this.maxEntries) {
      this.remove(this.entries.keys().next().value); this.stats.bindGroupCacheEvictions++;
    }
    const buffers = new Set(entries.map(entry => entry.resource.buffer));
    this.entries.set(key, {group, buffers});
    for (const buffer of buffers) {
      let references = this.references.get(buffer);
      if (!references) this.references.set(buffer, references = new Set());
      references.add(key);
    }
    this.stats.bindGroupCacheEntries = this.entries.size;
    return group;
  }

  remove(key) {
    const entry = this.entries.get(key);
    if (!entry) return;
    this.entries.delete(key);
    for (const buffer of entry.buffers) {
      const references = this.references.get(buffer);
      references?.delete(key);
      if (!references?.size) this.references.delete(buffer);
    }
    this.stats.bindGroupCacheEntries = this.entries.size;
  }

  invalidate(buffer) {
    const references = this.references.get(buffer);
    // Removing an entry also removes it from this set. Set iteration permits it.
    if (references) for (const key of references) this.remove(key);
  }

  clear() {
    this.entries.clear(); this.references = new WeakMap(); this.ids = new WeakMap();
    this.nextId = 1; this.stats.bindGroupCacheEntries = 0;
  }
}

export class ReadbackBufferPool {
  constructor(device, stats, {maxBytes = 1024 * 1024, maxBuffers = 8} = {}) {
    if (!Number.isSafeInteger(maxBytes) || maxBytes < 0 || !Number.isSafeInteger(maxBuffers) || maxBuffers < 0)
      throw new RangeError('Invalid readback pool capacity');
    this.device = device; this.stats = stats; this.maxBytes = maxBytes; this.maxBuffers = maxBuffers;
    this.pool = new Map(); this.leased = new Set(); this.bytes = 0; this.count = 0; this.disposed = false;
    Object.assign(stats, {readbackAllocations: 0, readbackPoolHits: 0,
      pooledReadbackBytes: 0, readbacksInUse: 0});
  }

  acquire(byteLength) {
    if (this.disposed) throw new Error('Readback pool is disposed');
    if (!Number.isSafeInteger(byteLength) || byteLength <= 0 || byteLength % 4 || byteLength > this.device.limits.maxBufferSize)
      throw new RangeError('Invalid readback size');
    // Pool common small result sizes, not arbitrarily large screenshot buffers.
    const rounded = Math.max(256, 2 ** Math.ceil(Math.log2(byteLength)));
    const size = rounded <= this.maxBytes && rounded <= this.device.limits.maxBufferSize ? rounded : byteLength;
    const bucket = this.pool.get(size);
    let buffer = bucket?.pop();
    if (buffer) {
      if (!bucket.length) this.pool.delete(size);
      this.bytes -= size; this.count--; this.stats.readbackPoolHits++;
    } else {
      buffer = this.device.createBuffer({label: 'OpenMW readback', size,
        usage: (globalThis.GPUBufferUsage?.COPY_DST ?? 8) | (globalThis.GPUBufferUsage?.MAP_READ ?? 1)});
      this.stats.readbackAllocations++;
    }
    this.leased.add(buffer);
    this.stats.readbacksInUse = this.leased.size; this.stats.pooledReadbackBytes = this.bytes;
    return buffer;
  }

  release(buffer, reusable = true) {
    if (!this.leased.delete(buffer)) throw new Error('Readback buffer was not leased');
    if (reusable && !this.disposed && buffer.mapState === 'unmapped'
        && this.count < this.maxBuffers && this.bytes + buffer.size <= this.maxBytes) {
      let bucket = this.pool.get(buffer.size);
      if (!bucket) this.pool.set(buffer.size, bucket = []);
      bucket.push(buffer); this.bytes += buffer.size; this.count++;
    } else buffer.destroy();
    this.stats.readbacksInUse = this.leased.size; this.stats.pooledReadbackBytes = this.bytes;
  }

  dispose() {
    this.disposed = true;
    for (const bucket of this.pool.values()) for (const buffer of bucket) buffer.destroy();
    this.pool.clear(); this.bytes = 0; this.count = 0; this.stats.pooledReadbackBytes = 0;
    // Leased buffers may still have mapAsync outstanding. Their owner's finally
    // block destroys them on release; disposing never races a pending map.
  }
}
