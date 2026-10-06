// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: broadcast_multisample_color.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_target: array<f32>;
struct KernelParams {
  p_width: u32,
  p_height: u32,
  p_sample_count: u32,
  p_viewport_x: i32,
  p_viewport_y: i32,
  p_viewport_width: u32,
  p_viewport_height: u32,
  gpu_pad_28: u32,
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
  var v_pixels: u32 = (gpu_params.p_width * gpu_params.p_height);
  if ((v_i >= (v_pixels * gpu_params.p_sample_count))) {
    return;
  }
  var v_pixel: u32 = (v_i % v_pixels);
  var v_base: u32 = (((v_i / v_pixels) * v_pixels) * u32(10i));
  var v_x: f32 = (f32((v_pixel % gpu_params.p_width)) + 0.5f);
  var v_y: f32 = ((f32(gpu_params.p_height) - f32((v_pixel / gpu_params.p_width))) - 0.5f);
  if (((((v_x < f32(gpu_params.p_viewport_x)) || (v_y < f32(gpu_params.p_viewport_y))) || (v_x >= (f32(gpu_params.p_viewport_x) + f32(gpu_params.p_viewport_width)))) || (v_y >= (f32(gpu_params.p_viewport_y) + f32(gpu_params.p_viewport_height))))) {
    return;
  }
  {
    var v_channel: u32 = u32(0i);
    loop {
      if (!(v_channel < u32(4i))) { break; }
      b_target[((v_base + (v_pixel * u32(9i))) + v_channel)] = b_source[((v_pixel * u32(9i)) + v_channel)];
      continuing {
        v_channel += u32(1);
      }
    }
  }
}
