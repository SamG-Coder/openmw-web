// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: prepare_fixed_matrices.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read_write> b_descriptors: array<u32>;
@group(0) @binding(1) var<storage, read> b_positioned: array<u32>;
struct KernelParams {
  p_draw_count: u32,
  gpu_pad_4: u32,
  gpu_pad_8: u32,
  gpu_pad_12: u32,
}
@group(0) @binding(2) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn f_gpu_buffer_helper_0(gpu_buffer_arg_0: i32, gpu_arg_matrix: u32, gpu_buffer_arg_2: i32, gpu_arg_post: u32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) {
  var gpu_buffer_offset_0: i32 = gpu_buffer_arg_0;
  var gpu_buffer_offset_2: i32 = gpu_buffer_arg_2;
  var v_matrix: u32 = gpu_arg_matrix;
  var v_post: u32 = gpu_arg_post;
  var v_result: array<f32, 16>;
  {
    var v_col: u32 = u32(0i);
    loop {
      if (!(v_col < u32(4i))) { break; }
      {
        var v_row: u32 = u32(0i);
        loop {
          if (!(v_row < u32(4i))) { break; }
          var v_value: f32 = 0.0f;
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(4i))) { break; }
              let gpu_argument_index_0 = (gpu_buffer_offset_2 + i32(((v_post + (v_k * u32(4i))) + v_row)));
              let gpu_argument_index_1 = (gpu_buffer_offset_0 + i32(((v_matrix + (v_col * u32(4i))) + v_k)));
              v_value = (v_value + (bitcast<f32>(b_positioned[gpu_argument_index_0]) * bitcast<f32>(b_descriptors[gpu_argument_index_1])));
              continuing {
                v_k += u32(1);
              }
            }
          }
          v_result[((v_col * u32(4i)) + v_row)] = v_value;
          continuing {
            v_row += u32(1);
          }
        }
      }
      continuing {
        v_col += u32(1);
      }
    }
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(16i))) { break; }
      let gpu_argument_index_2 = v_k;
      b_descriptors[(gpu_buffer_offset_0 + i32((v_matrix + v_k)))] = bitcast<u32>(v_result[gpu_argument_index_2]);
      continuing {
        v_k += u32(1);
      }
    }
  }
}

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_i: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_i >= (gpu_params.p_draw_count * 8u))) {
    return;
  }
  var v_draw: u32 = (v_i / 8u);
  var v_light: u32 = (v_i % 8u);
  var v_d: u32 = (v_draw * 368u);
  var v_table: u32 = b_descriptors[(v_d + 3u)];
  if (((v_table == 0u) || ((b_descriptors[v_d] & (1u << v_light)) == 0u))) {
    return;
  }
  var v_post: u32 = b_positioned[((v_table - 1u) + v_light)];
  if ((v_post != 0u)) {
    f_gpu_buffer_helper_0(0i, (((v_d + 48u) + (v_light * 40u)) + 24u), 0i, (v_post - 1u), gpu_thread, gpu_block, gpu_grid);
  }
}
