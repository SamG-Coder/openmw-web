// CUDA WebShader 0.1.1. Generated from kernel prepare_texgen_matrices.
@group(0) @binding(0) var<storage, read_write> b_descriptors: array<u32>;
@group(0) @binding(1) var<storage, read> b_positioned: array<u32>;
struct CWParams {
  p_draw_count: u32,
  cw_pad_4: u32,
  cw_pad_8: u32,
  cw_pad_12: u32,
}
@group(0) @binding(2) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn f_cw_buffer_helper_0(cw_buffer_arg_0: i32, cw_arg_matrix: u32, cw_buffer_arg_2: i32, cw_arg_post: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var cw_buffer_offset_2: i32 = cw_buffer_arg_2;
  var v_matrix: u32 = cw_arg_matrix;
  var v_post: u32 = cw_arg_post;
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
              let cw_argument_index_0 = (cw_buffer_offset_2 + i32(((v_post + (v_k * u32(4i))) + v_row)));
              let cw_argument_index_1 = (cw_buffer_offset_0 + i32(((v_matrix + (v_col * u32(4i))) + v_k)));
              v_value = (v_value + (bitcast<f32>(b_positioned[cw_argument_index_0]) * bitcast<f32>(b_descriptors[cw_argument_index_1])));
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
      let cw_argument_index_2 = v_k;
      b_descriptors[(cw_buffer_offset_0 + i32((v_matrix + v_k)))] = bitcast<u32>(v_result[cw_argument_index_2]);
      continuing {
        v_k += u32(1);
      }
    }
  }
}

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_i: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_i >= (cw_params.p_draw_count * 4u))) {
    return;
  }
  var v_d: u32 = (v_i * 36u);
  var v_post: u32 = b_descriptors[(v_d + 3u)];
  if ((((v_post == 0u) || (b_descriptors[v_d] == 0u)) || (b_descriptors[(v_d + 1u)] != 5u))) {
    return;
  }
  f_cw_buffer_helper_0(0i, (v_d + 20u), 0i, (v_post - 1u), cw_thread, cw_block, cw_grid);
}
