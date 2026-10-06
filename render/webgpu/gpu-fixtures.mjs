// SPDX-License-Identifier: GPL-3.0-or-later
// Deterministic packets for GPU integration checks. Expected pixels are
// analytical values; these fixtures do not implement a second rasterizer.
export const GUARD = 12345;

export function rasterParameters(materialCount = 1) {
  const values = new Float32Array(materialCount * 50);
  for (let offset = 0; offset < values.length; offset += 50) {
    values[offset + 3] = 1;
    values[offset + 24] = 1;
    values[offset + 26] = 65535;
    values[offset + 27] = 1;
    values[offset + 37] = values[offset + 38] = 1;
    values.set([0, 64, 1, 1, 0, 0], offset + 43);
    for (const face of [8, 15]) values.set([7, 0, 255, 255, 0, 0, 0], offset + face);
  }
  return values;
}

export function quadVertices(color = [1, 0, 0, 1], z = 0) {
  return new Float32Array([
    -1, 1, z, 1, ...color, 0, 0,
    1, 1, z, 1, ...color, 1, 0,
    1, -1, z, 1, ...color, 1, 1,
    -1, -1, z, 1, ...color, 0, 1,
  ]);
}

export function targetPixels(width, height, {
  samples = 1, compactDepth = false, color = [0, 0, 0, 1],
  depth = 1, normal = [0, 0, 0, 0], stencil = 0,
} = {}) {
  const pixels = width * height;
  const words = pixels * (compactDepth ? 1 : 10) * samples;
  const output = new Float32Array(words + 4);
  if (compactDepth) output.fill(depth, 0, words);
  else for (let sample = 0; sample < samples; sample++) {
    const base = sample * pixels * 10;
    for (let pixel = 0; pixel < pixels; pixel++) {
      output.set([...color, depth, ...normal], base + pixel * 9);
      output[base + pixels * 9 + pixel] = stencil;
    }
  }
  output.fill(GUARD, words);
  return output;
}

export function rasterFixture({width = 8, height = 6, samples = 1,
  compactDepth = false, color = [1, 0, 0, 1], z = 0,
  background = [0, 0, 0, 1], depth = 1, normal = [0, 0, 0, 0], stencil = 0,
  vertices = quadVertices(color, z), triangles = new Uint32Array([0, 1, 2, 0, 0, 2, 3, 0]),
  materials = new Uint32Array([0, 1, 1, 4 | 8, 0, 0, 0, width, height, 0, 0, 0]),
  texels = new Uint32Array([0xffffffff]), rasterParams = rasterParameters(materials.length / 12),
} = {}) {
  const vertexCount = vertices.length / 10;
  const boundary_offset = vertexCount * 34;
  const point_fade_offset = boundary_offset + vertexCount;
  const raster_offset = point_fade_offset + vertexCount * 12;
  const attributes = new Float32Array(raster_offset + rasterParams.length);
  for (let vertex = 0; vertex < vertexCount; vertex++) {
    attributes[vertex * 34 + 5] = 1;
    attributes[boundary_offset + vertex] = 1;
    attributes[point_fade_offset + vertex * 12] = 1;
  }
  attributes.set(rasterParams, raster_offset);
  const initial = targetPixels(width, height, {
    samples, compactDepth, color: background, depth, normal, stencil,
  });
  return {
    width, height, samples, compactDepth, initial,
    scene: {vertices, triangles, materials, texels, rasterParams},
    inputs: {vertices, triangles, materials, texels, attributes,
      counts: new Uint32Array(Math.ceil(width / 16) * Math.ceil(height / 16) + 1 + materials.length / 12),
      target: initial},
    params: {width, height, raster_offset, boundary_offset, point_fade_offset,
      lighting_offset: 0, cluster_offset: 0, fixed_offset: 0, falloff_offset: 0,
      fixed_enabled: 0, normal_enabled: 0, normal_channels: 4, normal_storage: 2,
      color_channels: compactDepth ? 0 : 4, color_storage: 2, depth_bits: 0,
      stencil_enabled: compactDepth ? 0 : 1, sample_count: samples},
  };
}

export function pipelineFixture({width = 8, height = 6, color = [1, 0, 0, 1], z = 0} = {}) {
  const matrices = new Float32Array(32);
  for (const base of [0, 16]) for (let diagonal = 0; diagonal < 4; diagonal++) matrices[base + diagonal * 5] = 1;
  return {
    vertices: quadVertices(color, z), matrices, matrixIds: new Uint32Array(4),
    triangles: new Uint32Array([0, 1, 2, 0, 0, 2, 3, 0]),
    materials: new Uint32Array([0, 1, 1, 4 | 8, 0, 0, 0, width, height, 0, 0, 0]),
    texels: new Uint32Array([0xffffffff]),
  };
}
