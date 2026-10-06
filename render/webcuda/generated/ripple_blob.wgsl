// CUDA WebShader 0.1.1. Generated from kernel ripple_blob.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_target: array<f32>;
@group(0) @binding(2) var<storage, read> b_positions: array<f32>;
struct CWParams {
  p_width: u32,
  p_height: u32,
  p_count: u32,
  p_offset_x: f32,
  p_offset_y: f32,
  p_time: f32,
  cw_pad_24: u32,
  cw_pad_28: u32,
}
@group(0) @binding(3) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn cw_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }
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
          var cw_tmp_1: i32;
          if ((v_sx < 0i)) {
            cw_tmp_1 = 0i;
          } else {
            var cw_tmp_0: i32;
            if ((v_sx >= i32(v_width))) {
              cw_tmp_0 = (i32(v_width) - 1i);
            } else {
              cw_tmp_0 = v_sx;
            }
            cw_tmp_1 = cw_tmp_0;
          }
          v_sx = cw_tmp_1;
          var cw_tmp_3: i32;
          if ((v_sy < 0i)) {
            cw_tmp_3 = 0i;
          } else {
            var cw_tmp_2: i32;
            if ((v_sy >= i32(v_height))) {
              cw_tmp_2 = (i32(v_height) - 1i);
            } else {
              cw_tmp_2 = v_sy;
            }
            cw_tmp_3 = cw_tmp_2;
          }
          v_sy = cw_tmp_3;
          var cw_tmp_4: f32;
          if ((v_dx == 0i)) {
            cw_tmp_4 = (1.0f - v_fx);
          } else {
            cw_tmp_4 = v_fx;
          }
          var cw_tmp_5: f32;
          if ((v_dy == 0i)) {
            cw_tmp_5 = (1.0f - v_fy);
          } else {
            cw_tmp_5 = v_fy;
          }
          v_sum = (v_sum + ((b_source[(cw_buffer_offset_0 + i32(((((((v_height - u32(1i)) - u32(v_sy)) * v_width) + u32(v_sx)) * u32(9i)) + v_channel)))] * cw_tmp_4) * cw_tmp_5));
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
  var v_color: array<f32, 4>;
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(4i))) { break; }
      v_color[v_c] = f_cw_buffer_helper_0(0i, cw_params.p_width, cw_params.p_height, (v_x + cw_params.p_offset_x), (v_y + cw_params.p_offset_y), v_c, cw_thread, cw_block, cw_grid);
      continuing {
        v_c += u32(1);
      }
    }
  }
  var v_multiplier: f32 = ((1.0f + (0.055f * sin((16.0f * cw_params.p_time)))) + (0.065f * sin((12.87645f * cw_params.p_time))));
  {
    var v_p: u32 = u32(0i);
    loop {
      if (!(v_p < cw_params.p_count)) { break; }
      var v_size: f32 = (v_multiplier * b_positions[((v_p * u32(3i)) + u32(2i))]);
      if ((v_size <= 0.0f)) {
        continue;
      }
      var v_dx: f32 = ((b_positions[(v_p * u32(3i))] + cw_params.p_offset_x) - v_x);
      var v_dy: f32 = ((b_positions[((v_p * u32(3i)) + u32(1i))] + cw_params.p_offset_y) - v_y);
      var v_displace: f32 = min(1.0f, max(0.0f, ((0.2f * abs((cw_divide_f32(sqrt(((v_dx * v_dx) + (v_dy * v_dy))), v_size) - 1.0f))) + 0.8f)));
      v_color[0i] = ((-1.0f) + ((v_color[0i] + 1.0f) * v_displace));
      v_color[1i] = ((-1.0f) + ((v_color[1i] + 1.0f) * v_displace));
      continuing {
        v_p += u32(1);
      }
    }
  }
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(4i))) { break; }
      b_target[((v_i * u32(9i)) + v_c)] = v_color[v_c];
      continuing {
        v_c += u32(1);
      }
    }
  }
}
