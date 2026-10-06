// CUDA WebShader 0.1.1. Generated from kernel resolve_scene.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read> b_distortion: array<f32>;
@group(0) @binding(2) var<storage, read_write> b_target: array<f32>;
struct CWParams {
  p_width: u32,
  p_height: u32,
  p_source_width: u32,
  p_source_height: u32,
  p_distortion_width: u32,
  p_distortion_height: u32,
  p_use_distortion: u32,
  p_scale_x: f32,
  p_scale_y: f32,
  cw_pad_36: u32,
  cw_pad_40: u32,
  cw_pad_44: u32,
}
@group(0) @binding(3) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn cw_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }









fn f_cw_buffer_helper_0(cw_buffer_arg_0: i32, cw_arg_width: u32, cw_arg_height: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_channel: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_width: u32 = cw_arg_width;
  var v_height: u32 = cw_arg_height;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_channel: u32 = cw_arg_channel;
  var v_x: f32 = ((min(1.0f, max(0.0f, v_u)) * f32(v_width)) - 0.5f);
  var v_y: f32 = (((1.0f - min(1.0f, max(0.0f, v_v))) * f32(v_height)) - 0.5f);
  var v_ix: i32 = i32(floor(v_x));
  var v_iy: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - floor(v_x));
  var v_fy: f32 = (v_y - floor(v_y));
  var v_value: f32 = 0.0f;
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
          var cw_tmp_9: i32;
          if ((v_sx < 0i)) {
            cw_tmp_9 = 0i;
          } else {
            var cw_tmp_8: i32;
            if ((v_sx >= i32(v_width))) {
              cw_tmp_8 = (i32(v_width) - 1i);
            } else {
              cw_tmp_8 = v_sx;
            }
            cw_tmp_9 = cw_tmp_8;
          }
          v_sx = cw_tmp_9;
          var cw_tmp_11: i32;
          if ((v_sy < 0i)) {
            cw_tmp_11 = 0i;
          } else {
            var cw_tmp_10: i32;
            if ((v_sy >= i32(v_height))) {
              cw_tmp_10 = (i32(v_height) - 1i);
            } else {
              cw_tmp_10 = v_sy;
            }
            cw_tmp_11 = cw_tmp_10;
          }
          v_sy = cw_tmp_11;
          var cw_tmp_12: f32;
          if ((v_dx == 0i)) {
            cw_tmp_12 = (1.0f - v_fx);
          } else {
            cw_tmp_12 = v_fx;
          }
          var cw_tmp_13: f32;
          if ((v_dy == 0i)) {
            cw_tmp_13 = (1.0f - v_fy);
          } else {
            cw_tmp_13 = v_fy;
          }
          v_value = (v_value + ((b_distortion[(cw_buffer_offset_0 + i32(((((u32(v_sy) * v_width) + u32(v_sx)) * u32(9i)) + v_channel)))] * cw_tmp_12) * cw_tmp_13));
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
  return v_value;
}
fn f_cw_buffer_helper_1(cw_buffer_arg_0: i32, cw_arg_width: u32, cw_arg_height: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_channel: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_width: u32 = cw_arg_width;
  var v_height: u32 = cw_arg_height;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_channel: u32 = cw_arg_channel;
  var v_x: f32 = ((min(1.0f, max(0.0f, v_u)) * f32(v_width)) - 0.5f);
  var v_y: f32 = (((1.0f - min(1.0f, max(0.0f, v_v))) * f32(v_height)) - 0.5f);
  var v_ix: i32 = i32(floor(v_x));
  var v_iy: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - floor(v_x));
  var v_fy: f32 = (v_y - floor(v_y));
  var v_value: f32 = 0.0f;
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
          var cw_tmp_15: i32;
          if ((v_sx < 0i)) {
            cw_tmp_15 = 0i;
          } else {
            var cw_tmp_14: i32;
            if ((v_sx >= i32(v_width))) {
              cw_tmp_14 = (i32(v_width) - 1i);
            } else {
              cw_tmp_14 = v_sx;
            }
            cw_tmp_15 = cw_tmp_14;
          }
          v_sx = cw_tmp_15;
          var cw_tmp_17: i32;
          if ((v_sy < 0i)) {
            cw_tmp_17 = 0i;
          } else {
            var cw_tmp_16: i32;
            if ((v_sy >= i32(v_height))) {
              cw_tmp_16 = (i32(v_height) - 1i);
            } else {
              cw_tmp_16 = v_sy;
            }
            cw_tmp_17 = cw_tmp_16;
          }
          v_sy = cw_tmp_17;
          var cw_tmp_18: f32;
          if ((v_dx == 0i)) {
            cw_tmp_18 = (1.0f - v_fx);
          } else {
            cw_tmp_18 = v_fx;
          }
          var cw_tmp_19: f32;
          if ((v_dy == 0i)) {
            cw_tmp_19 = (1.0f - v_fy);
          } else {
            cw_tmp_19 = v_fy;
          }
          v_value = (v_value + ((b_source[(cw_buffer_offset_0 + i32(((((u32(v_sy) * v_width) + u32(v_sx)) * u32(9i)) + v_channel)))] * cw_tmp_18) * cw_tmp_19));
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
  return v_value;
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
  var v_u: f32 = cw_divide_f32((f32((v_i % cw_params.p_width)) + 0.5f), f32(cw_params.p_width));
  var v_v: f32 = (1.0f - cw_divide_f32((f32((v_i / cw_params.p_width)) + 0.5f), f32(cw_params.p_height)));
  v_u = (v_u * cw_params.p_scale_x);
  v_v = (v_v * cw_params.p_scale_y);
  var v_dx: f32 = 0.0f;
  var v_dy: f32 = 0.0f;
  var v_occlusion: f32 = 1.0f;
  if ((cw_params.p_use_distortion != u32(0i))) {
    v_dx = min(1.0f, max((-1.0f), (f_cw_buffer_helper_0(0i, cw_params.p_distortion_width, cw_params.p_distortion_height, v_u, v_v, u32(0i), cw_thread, cw_block, cw_grid) * 0.14f)));
    v_dy = min(1.0f, max((-1.0f), (f_cw_buffer_helper_0(0i, cw_params.p_distortion_width, cw_params.p_distortion_height, v_u, v_v, u32(1i), cw_thread, cw_block, cw_grid) * 0.14f)));
    v_occlusion = f_cw_buffer_helper_0(0i, cw_params.p_distortion_width, cw_params.p_distortion_height, (v_u + v_dx), (v_v + v_dy), u32(2i), cw_thread, cw_block, cw_grid);
  }
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(4i))) { break; }
      b_target[((v_i * u32(9i)) + v_c)] = ((f_cw_buffer_helper_1(0i, cw_params.p_source_width, cw_params.p_source_height, (v_u + v_dx), (v_v + v_dy), v_c, cw_thread, cw_block, cw_grid) * (1.0f - v_occlusion)) + (f_cw_buffer_helper_1(0i, cw_params.p_source_width, cw_params.p_source_height, v_u, v_v, v_c, cw_thread, cw_block, cw_grid) * v_occlusion));
      continuing {
        v_c += u32(1);
      }
    }
  }
}
