// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: generate_depth_mip.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read_write> b_texels: array<u32>;
struct KernelParams {
  p_source: u32,
  p_destination: u32,
  p_width: u32,
  p_height: u32,
  p_depth_bits: u32,
  gpu_pad_20: u32,
  gpu_pad_24: u32,
  gpu_pad_28: u32,
}
@group(0) @binding(1) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn gpu_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }







fn f_store_depth_value(gpu_arg_value: f32, gpu_arg_bits: u32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var v_value: f32 = gpu_arg_value;
  var v_bits: u32 = gpu_arg_bits;
  v_value = min(1.0f, max(0.0f, v_value));
  if ((v_bits == 0u)) {
    return v_value;
  }
  var gpu_tmp_7: f32;
  if ((v_bits == 16u)) {
    gpu_tmp_7 = 65535.0f;
  } else {
    gpu_tmp_7 = 16777215.0f;
  }
  var v_maximum: f32 = gpu_tmp_7;
  return min(1.0f, gpu_divide_f32(floor(((v_value * v_maximum) + 0.5f)), v_maximum));
}


























@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_i: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  var gpu_tmp_32: u32;
  if ((gpu_params.p_width > 1u)) {
    gpu_tmp_32 = (gpu_params.p_width / 2u);
  } else {
    gpu_tmp_32 = 1u;
  }
  var v_dw: u32 = gpu_tmp_32;
  var gpu_tmp_33: u32;
  if ((gpu_params.p_height > 1u)) {
    gpu_tmp_33 = (gpu_params.p_height / 2u);
  } else {
    gpu_tmp_33 = 1u;
  }
  var v_dh: u32 = gpu_tmp_33;
  if ((v_i >= (v_dw * v_dh))) {
    return;
  }
  var v_x0: u32 = (((v_i % v_dw) * gpu_params.p_width) / v_dw);
  var v_x1: u32 = ((((v_i % v_dw) + 1u) * gpu_params.p_width) / v_dw);
  var v_y0: u32 = (((v_i / v_dw) * gpu_params.p_height) / v_dh);
  var v_y1: u32 = ((((v_i / v_dw) + 1u) * gpu_params.p_height) / v_dh);
  var v_sum: f32 = 0.0f;
  {
    var v_y: u32 = v_y0;
    loop {
      if (!(v_y < v_y1)) { break; }
      {
        var v_x: u32 = v_x0;
        loop {
          if (!(v_x < v_x1)) { break; }
          let gpu_argument_index_34 = ((gpu_params.p_source + (v_y * gpu_params.p_width)) + v_x);
          v_sum = (v_sum + bitcast<f32>(b_texels[gpu_argument_index_34]));
          continuing {
            v_x += u32(1);
          }
        }
      }
      continuing {
        v_y += u32(1);
      }
    }
  }
  b_texels[(gpu_params.p_destination + v_i)] = bitcast<u32>(f_store_depth_value(gpu_divide_f32(v_sum, f32(((v_x1 - v_x0) * (v_y1 - v_y0)))), gpu_params.p_depth_bits, gpu_thread, gpu_block, gpu_grid));
}
