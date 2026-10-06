// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: copy_multisample_plane.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_target: array<f32>;
struct KernelParams {
  p_pixel_count: u32,
  p_sample_count: u32,
  p_plane: u32,
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
  if ((v_i >= (gpu_params.p_pixel_count * gpu_params.p_sample_count))) {
    return;
  }
  var v_pixel: u32 = (v_i % gpu_params.p_pixel_count);
  var v_base: u32 = (((v_i / gpu_params.p_pixel_count) * gpu_params.p_pixel_count) * u32(10i));
  if ((gpu_params.p_plane == 0u)) {
    b_target[((v_base + (v_pixel * u32(9i))) + u32(4i))] = b_source[((v_base + (v_pixel * u32(9i))) + u32(4i))];
  }
  if ((gpu_params.p_plane == 1u)) {
    {
      var v_channel: u32 = u32(0i);
      loop {
        if (!(v_channel < u32(4i))) { break; }
        b_target[(((v_base + (v_pixel * u32(9i))) + u32(5i)) + v_channel)] = b_source[(((v_base + (v_pixel * u32(9i))) + u32(5i)) + v_channel)];
        continuing {
          v_channel += u32(1);
        }
      }
    }
  }
  if ((gpu_params.p_plane == 2u)) {
    b_target[((v_base + (gpu_params.p_pixel_count * u32(9i))) + v_pixel)] = b_source[((v_base + (gpu_params.p_pixel_count * u32(9i))) + v_pixel)];
  }
}
