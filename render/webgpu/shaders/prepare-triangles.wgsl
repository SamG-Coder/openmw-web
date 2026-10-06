// SPDX-License-Identifier: GPL-3.0-or-later
// Assemble one slot per submitted triangle. Positions remain homogeneous;
// clipping, coverage and interpolation are performed by the render pipeline.
@group(0) @binding(0) var<storage, read> clip: array<f32>;
@group(0) @binding(1) var<storage, read> indices: array<u32>;
@group(0) @binding(2) var<storage, read> polygon_edges: array<u32>;
@group(0) @binding(3) var<storage, read_write> positions: array<f32>;
@group(0) @binding(4) var<storage, read_write> weights: array<f32>;
@group(0) @binding(5) var<storage, read_write> valid: array<u32>;

struct Params {
  triangle_count: u32,
  padding: u32,
  padding2: u32,
  padding3: u32,
}
@group(0) @binding(6) var<uniform> params: Params;

@compute @workgroup_size(64)
fn main(@builtin(local_invocation_id) local: vec3<u32>,
        @builtin(workgroup_id) group: vec3<u32>,
        @builtin(num_workgroups) grid: vec3<u32>) {
  let triangle = (group.x + group.y * grid.x) * 64u + local.x;
  if (triangle >= params.triangle_count) { return; }
  valid[triangle] = 1u;
  for (var corner = 0u; corner < 3u; corner++) {
    let source = indices[triangle * 4u + corner] * 10u;
    let destination = triangle * 12u + corner * 4u;
    for (var component = 0u; component < 4u; component++) {
      positions[destination + component] = clip[source + component];
      weights[destination + component] = select(0.0, 1.0, component == corner);
    }
    weights[destination + 3u] = f32((polygon_edges[triangle] >> corner) & 1u);
  }
}
