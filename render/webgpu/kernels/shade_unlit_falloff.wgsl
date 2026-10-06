// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: shade_unlit_falloff.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_endpoints: array<f32>;
@group(0) @binding(1) var<storage, read> b_origins: array<u32>;
@group(0) @binding(2) var<storage, read> b_triangles: array<u32>;
@group(0) @binding(3) var<storage, read> b_materials: array<u32>;
@group(0) @binding(4) var<storage, read> b_texels: array<u32>;
@group(0) @binding(5) var<storage, read_write> b_output: array<f32>;
struct KernelParams {
  p_triangle_count: u32,
  p_track_origins: u32,
  gpu_pad_8: u32,
  gpu_pad_12: u32,
}
@group(0) @binding(6) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn gpu_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }
fn f_gpu_buffer_helper_0(gpu_buffer_arg_0: i32, gpu_arg_data: u32, gpu_arg_angle: f32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var gpu_buffer_offset_0: i32 = gpu_buffer_arg_0;
  var v_data: u32 = gpu_arg_data;
  var v_angle: f32 = gpu_arg_angle;
  if ((((b_texels[(gpu_buffer_offset_0 + i32((v_data + 4u)))] & 268435456u) == 0u) || (b_texels[(gpu_buffer_offset_0 + i32((v_data + 80u)))] == 0u))) {
    return 1.0f;
  }
  let gpu_argument_index_5 = (gpu_buffer_offset_0 + i32((v_data + 81u)));
  var v_start: f32 = bitcast<f32>(b_texels[gpu_argument_index_5]);
  let gpu_argument_index_6 = (gpu_buffer_offset_0 + i32((v_data + 82u)));
  var v_end: f32 = bitcast<f32>(b_texels[gpu_argument_index_6]);
  var gpu_tmp_8: f32;
  if ((v_end != v_start)) {
    gpu_tmp_8 = min(1.0f, max(0.0f, gpu_divide_f32((v_angle - v_start), (v_end - v_start))));
  } else {
    var gpu_tmp_7: f32;
    if ((v_angle >= v_end)) {
      gpu_tmp_7 = 1.0f;
    } else {
      gpu_tmp_7 = 0.0f;
    }
    gpu_tmp_8 = gpu_tmp_7;
  }
  var v_t: f32 = gpu_tmp_8;
  v_t = ((v_t * v_t) * (3.0f - (2.0f * v_t)));
  let gpu_argument_index_9 = (gpu_buffer_offset_0 + i32((v_data + 83u)));
  var v_opacityStart: f32 = min(bitcast<f32>(b_texels[gpu_argument_index_9]), 1.0f);
  let gpu_argument_index_10 = (gpu_buffer_offset_0 + i32((v_data + 84u)));
  var v_opacityEnd: f32 = max(bitcast<f32>(b_texels[gpu_argument_index_10]), 0.0f);
  return (v_opacityStart + ((v_opacityEnd - v_opacityStart) * v_t));
}

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_i: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_i >= (gpu_params.p_triangle_count * 3u))) {
    return;
  }
  var v_vertex: u32 = b_triangles[(((v_i / 3u) * 4u) + (v_i % 3u))];
  var v_mat: u32 = (b_triangles[(((v_i / 3u) * 4u) + 3u)] * 12u);
  var v_data: u32 = b_materials[v_mat];
  b_output[(v_i * 4u)] = 1.0f;
  {
    var v_k: u32 = u32(1i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      b_output[((v_i * 4u) + v_k)] = 0.0f;
      continuing {
        v_k += u32(1);
      }
    }
  }
  if ((((b_materials[(v_mat + 3u)] & 2048u) == 0u) || ((b_texels[(v_data + 4u)] & (268435456u | 536870912u)) == 0u))) {
    return;
  }
  var v_a: u32 = v_vertex;
  var v_b: u32 = v_vertex;
  var v_t: f32 = 0.0f;
  if ((gpu_params.p_track_origins != 0u)) {
    v_a = b_origins[(v_vertex * 3u)];
    v_b = b_origins[((v_vertex * 3u) + 1u)];
    let gpu_argument_index_0 = ((v_vertex * 3u) + 2u);
    v_t = bitcast<f32>(b_origins[gpu_argument_index_0]);
  }
  let gpu_argument_index_1 = (v_a * 6u);
  var v_first: f32 = f_gpu_buffer_helper_0(0i, v_data, b_endpoints[gpu_argument_index_1], gpu_thread, gpu_block, gpu_grid);
  let gpu_argument_index_2 = ((v_a * 6u) + 4u);
  var v_firstEnd: f32 = f_gpu_buffer_helper_0(0i, v_data, b_endpoints[gpu_argument_index_2], gpu_thread, gpu_block, gpu_grid);
  v_first = (v_first + (b_endpoints[((v_a * 6u) + 5u)] * (v_firstEnd - v_first)));
  let gpu_argument_index_3 = (v_b * 6u);
  var v_last: f32 = f_gpu_buffer_helper_0(0i, v_data, b_endpoints[gpu_argument_index_3], gpu_thread, gpu_block, gpu_grid);
  let gpu_argument_index_4 = ((v_b * 6u) + 4u);
  var v_lastEnd: f32 = f_gpu_buffer_helper_0(0i, v_data, b_endpoints[gpu_argument_index_4], gpu_thread, gpu_block, gpu_grid);
  v_last = (v_last + (b_endpoints[((v_b * 6u) + 5u)] * (v_lastEnd - v_last)));
  b_output[(v_i * 4u)] = (v_first + (v_t * (v_last - v_first)));
  {
    var v_k: u32 = u32(1i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      b_output[((v_i * 4u) + v_k)] = (b_endpoints[((v_a * 6u) + v_k)] + (v_t * (b_endpoints[((v_b * 6u) + v_k)] - b_endpoints[((v_a * 6u) + v_k)])));
      continuing {
        v_k += u32(1);
      }
    }
  }
}
