// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: float_target_to_texture.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_target: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_texels: array<u32>;
struct KernelParams {
  p_width: u32,
  p_height: u32,
  p_offset: u32,
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
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(4i))) { break; }
      let gpu_argument_index_32 = ((v_i * u32(9i)) + v_c);
      b_texels[((gpu_params.p_offset + (((((gpu_params.p_height - u32(1i)) - (v_i / gpu_params.p_width)) * gpu_params.p_width) + (v_i % gpu_params.p_width)) * u32(4i))) + v_c)] = bitcast<u32>(b_target[gpu_argument_index_32]);
      continuing {
        v_c += u32(1);
      }
    }
  }
}
