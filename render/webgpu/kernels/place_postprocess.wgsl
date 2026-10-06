// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: place_postprocess.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_target: array<f32>;
struct KernelParams {
  p_width: u32,
  p_height: u32,
  p_source_width: u32,
  p_source_height: u32,
  p_viewport_x: i32,
  p_viewport_y: i32,
  gpu_pad_24: u32,
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
  if ((v_i >= (gpu_params.p_width * gpu_params.p_height))) {
    return;
  }
  var v_sx: f32 = (f32((v_i % gpu_params.p_width)) - f32(gpu_params.p_viewport_x));
  var v_sy: f32 = (f32(((gpu_params.p_height - 1u) - (v_i / gpu_params.p_width))) - f32(gpu_params.p_viewport_y));
  if (((((v_sx < 0.0f) || (v_sy < 0.0f)) || (v_sx >= f32(gpu_params.p_source_width))) || (v_sy >= f32(gpu_params.p_source_height)))) {
    return;
  }
  var v_source_pixel: u32 = ((((gpu_params.p_source_height - 1u) - u32(v_sy)) * gpu_params.p_source_width) + u32(v_sx));
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(4i))) { break; }
      b_target[((v_i * 9u) + v_c)] = b_source[((v_source_pixel * 9u) + v_c)];
      continuing {
        v_c += u32(1);
      }
    }
  }
}
