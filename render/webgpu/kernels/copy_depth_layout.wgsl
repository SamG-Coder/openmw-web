// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: copy_depth_layout.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_target: array<f32>;
struct KernelParams {
  p_pixel_count: u32,
  p_source_compact: u32,
  p_target_compact: u32,
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
  if ((v_i < gpu_params.p_pixel_count)) {
    var gpu_tmp_0: u32;
    if ((gpu_params.p_target_compact != 0u)) {
      gpu_tmp_0 = v_i;
    } else {
      gpu_tmp_0 = ((v_i * 9u) + 4u);
    }
    var gpu_tmp_1: u32;
    if ((gpu_params.p_source_compact != 0u)) {
      gpu_tmp_1 = v_i;
    } else {
      gpu_tmp_1 = ((v_i * 9u) + 4u);
    }
    b_target[gpu_tmp_0] = b_source[gpu_tmp_1];
  }
}
