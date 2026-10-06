// CUDA WebShader 0.1.1. Generated from kernel ripple_simulate.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_target: array<f32>;
struct CWParams {
  p_width: u32,
  p_height: u32,
  cw_pad_8: u32,
  cw_pad_12: u32,
}
@group(0) @binding(2) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn f_cw_buffer_helper_0(cw_buffer_arg_0: i32, cw_arg_width: u32, cw_arg_height: u32, cw_arg_x: f32, cw_arg_y: f32, cw_arg_channel: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_width: u32 = cw_arg_width;
  var v_height: u32 = cw_arg_height;
  var v_x: f32 = cw_arg_x;
  var v_y: f32 = cw_arg_y;
  var v_channel: u32 = cw_arg_channel;
  v_x = (v_x - 0.5f);
  v_y = (v_y - 0.5f);
  var v_ix: i32 = i32(floor(v_x));
  var v_iy: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - floor(v_x));
  var v_fy: f32 = (v_y - floor(v_y));
  var v_sum: f32 = 0.0f;
  {
    var v_dy: i32 = 0i;
    loop {
      if (!(v_dy < 2i)) { break; }
      {
        var v_dx: i32 = 0i;
        loop {
          if (!(v_dx < 2i)) { break; }
          var v_sx: i32 = (v_ix + v_dx);
          var v_sy: i32 = (v_iy + v_dy);
          var cw_tmp_5: i32;
          if ((v_sx < 0i)) {
            cw_tmp_5 = 0i;
          } else {
            var cw_tmp_4: i32;
            if ((v_sx >= i32(v_width))) {
              cw_tmp_4 = (i32(v_width) - 1i);
            } else {
              cw_tmp_4 = v_sx;
            }
            cw_tmp_5 = cw_tmp_4;
          }
          v_sx = cw_tmp_5;
          var cw_tmp_7: i32;
          if ((v_sy < 0i)) {
            cw_tmp_7 = 0i;
          } else {
            var cw_tmp_6: i32;
            if ((v_sy >= i32(v_height))) {
              cw_tmp_6 = (i32(v_height) - 1i);
            } else {
              cw_tmp_6 = v_sy;
            }
            cw_tmp_7 = cw_tmp_6;
          }
          v_sy = cw_tmp_7;
          var cw_tmp_8: f32;
          if ((v_dx == 0i)) {
            cw_tmp_8 = (1.0f - v_fx);
          } else {
            cw_tmp_8 = v_fx;
          }
          var cw_tmp_9: f32;
          if ((v_dy == 0i)) {
            cw_tmp_9 = (1.0f - v_fy);
          } else {
            cw_tmp_9 = v_fy;
          }
          v_sum = (v_sum + ((b_source[(cw_buffer_offset_0 + i32(((((((v_height - u32(1i)) - u32(v_sy)) * v_width) + u32(v_sx)) * u32(9i)) + v_channel)))] * cw_tmp_8) * cw_tmp_9));
          continuing {
            v_dx += i32(1);
          }
        }
      }
      continuing {
        v_dy += i32(1);
      }
    }
  }
  return v_sum;
}

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_i: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_i >= (cw_params.p_width * cw_params.p_height))) {
    return;
  }
  var v_x: f32 = (f32((v_i % cw_params.p_width)) + 0.5f);
  var v_y: f32 = (f32(((cw_params.p_height - u32(1i)) - (v_i / cw_params.p_width))) + 0.5f);
  var v_n: array<f32, 4>;
  var v_n2: array<f32, 4>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      var cw_tmp_1: f32;
      if ((v_k == u32(0i))) {
        cw_tmp_1 = 1.0f;
      } else {
        var cw_tmp_0: f32;
        if ((v_k == u32(1i))) {
          cw_tmp_0 = (-1.0f);
        } else {
          cw_tmp_0 = 0.0f;
        }
        cw_tmp_1 = cw_tmp_0;
      }
      var v_dx: f32 = cw_tmp_1;
      var cw_tmp_3: f32;
      if ((v_k == u32(2i))) {
        cw_tmp_3 = 1.0f;
      } else {
        var cw_tmp_2: f32;
        if ((v_k == u32(3i))) {
          cw_tmp_2 = (-1.0f);
        } else {
          cw_tmp_2 = 0.0f;
        }
        cw_tmp_3 = cw_tmp_2;
      }
      var v_dy: f32 = cw_tmp_3;
      v_n[v_k] = f_cw_buffer_helper_0(0i, cw_params.p_width, cw_params.p_height, (v_x + v_dx), (v_y + v_dy), u32(0i), cw_thread, cw_block, cw_grid);
      v_n2[v_k] = f_cw_buffer_helper_0(0i, cw_params.p_width, cw_params.p_height, (v_x + (v_dx * 1.5f)), (v_y + (v_dy * 1.5f)), u32(0i), cw_thread, cw_block, cw_grid);
      continuing {
        v_k += u32(1);
      }
    }
  }
  b_target[(v_i * u32(9i))] = (((0.28f * (((v_n[0i] + v_n[1i]) + v_n[2i]) + v_n[3i])) + (0.8f * b_source[(v_i * u32(9i))])) - (0.96f * b_source[((v_i * u32(9i)) + u32(1i))]));
  b_target[((v_i * u32(9i)) + u32(1i))] = b_source[(v_i * u32(9i))];
  b_target[((v_i * u32(9i)) + u32(2i))] = ((2.0f * (v_n[0i] - v_n[1i])) + (0.5f * (v_n2[0i] - v_n2[1i])));
  b_target[((v_i * u32(9i)) + u32(3i))] = ((2.0f * (v_n[2i] - v_n[3i])) + (0.5f * (v_n2[2i] - v_n2[3i])));
}
