// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: pack_target.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_target: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_pixels: array<u32>;
struct KernelParams {
  p_width: u32,
  p_height: u32,
  p_row_pixels: u32,
  gpu_pad_12: u32,
}
@group(0) @binding(2) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);




































@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_i: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_i >= (gpu_params.p_width * gpu_params.p_height))) {
    return;
  }
  let gpu_argument_index_32 = (v_i * u32(9i));
  var v_r: u32 = u32(((min(1.0f, max(0.0f, b_target[gpu_argument_index_32])) * 255.0f) + 0.5f));
  let gpu_argument_index_33 = ((v_i * u32(9i)) + u32(1i));
  var v_g: u32 = u32(((min(1.0f, max(0.0f, b_target[gpu_argument_index_33])) * 255.0f) + 0.5f));
  let gpu_argument_index_34 = ((v_i * u32(9i)) + u32(2i));
  var v_b: u32 = u32(((min(1.0f, max(0.0f, b_target[gpu_argument_index_34])) * 255.0f) + 0.5f));
  let gpu_argument_index_35 = ((v_i * u32(9i)) + u32(3i));
  var v_a: u32 = u32(((min(1.0f, max(0.0f, b_target[gpu_argument_index_35])) * 255.0f) + 0.5f));
  b_pixels[(((v_i / gpu_params.p_width) * gpu_params.p_row_pixels) + (v_i % gpu_params.p_width))] = (((v_r | (v_g << u32(8i))) | (v_b << u32(16i))) | (v_a << u32(24i)));
}
