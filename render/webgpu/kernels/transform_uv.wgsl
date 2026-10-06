// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: transform_uv.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read_write> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read> b_uv_matrices: array<f32>;
@group(0) @binding(2) var<storage, read> b_matrix_ids: array<u32>;
struct KernelParams {
  p_vertex_count: u32,
  gpu_pad_4: u32,
  gpu_pad_8: u32,
  gpu_pad_12: u32,
}
@group(0) @binding(3) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);


@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_i: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_i >= gpu_params.p_vertex_count)) {
    return;
  }
  var v_m: u32 = (b_matrix_ids[v_i] * u32(16i));
  var v_u: f32 = b_vertices[((v_i * u32(10i)) + u32(8i))];
  var v_v: f32 = b_vertices[((v_i * u32(10i)) + u32(9i))];
  b_vertices[((v_i * u32(10i)) + u32(8i))] = (((b_uv_matrices[v_m] * v_u) + (b_uv_matrices[(v_m + u32(4i))] * v_v)) + b_uv_matrices[(v_m + u32(12i))]);
  b_vertices[((v_i * u32(10i)) + u32(9i))] = (((b_uv_matrices[(v_m + u32(1i))] * v_u) + (b_uv_matrices[(v_m + u32(5i))] * v_v)) + b_uv_matrices[(v_m + u32(13i))]);
}
