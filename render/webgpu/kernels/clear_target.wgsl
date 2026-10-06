// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: clear_target.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read_write> b_target: array<f32>;
struct KernelParams {
  p_pixel_count: u32,
  p_red: f32,
  p_green: f32,
  p_blue: f32,
  p_alpha: f32,
  p_depth: f32,
  gpu_pad_24: u32,
  gpu_pad_28: u32,
}
@group(0) @binding(1) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);




































@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_p: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_p >= gpu_params.p_pixel_count)) {
    return;
  }
  b_target[(v_p * u32(9i))] = gpu_params.p_red;
  b_target[((v_p * u32(9i)) + u32(1i))] = gpu_params.p_green;
  b_target[((v_p * u32(9i)) + u32(2i))] = gpu_params.p_blue;
  b_target[((v_p * u32(9i)) + u32(3i))] = gpu_params.p_alpha;
  b_target[((v_p * u32(9i)) + u32(4i))] = gpu_params.p_depth;
  b_target[((v_p * u32(9i)) + u32(5i))] = gpu_params.p_red;
  b_target[((v_p * u32(9i)) + u32(6i))] = gpu_params.p_green;
  b_target[((v_p * u32(9i)) + u32(7i))] = gpu_params.p_blue;
  b_target[((v_p * u32(9i)) + u32(8i))] = gpu_params.p_alpha;
  b_target[((gpu_params.p_pixel_count * 9u) + v_p)] = 0.0f;
}
