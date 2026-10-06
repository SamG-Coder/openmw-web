// CUDA WebShader 0.1.1. Generated from kernel debug_scene.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read> b_depth: array<f32>;
@group(0) @binding(2) var<storage, read> b_normals: array<f32>;
@group(0) @binding(3) var<storage, read> b_settings: array<f32>;
@group(0) @binding(4) var<storage, read_write> b_target: array<f32>;
struct CWParams {
  p_width: u32,
  p_height: u32,
  p_source_width: u32,
  p_source_height: u32,
  p_depth_width: u32,
  p_depth_height: u32,
  p_normal_width: u32,
  p_normal_height: u32,
  p_flags: u32,
  cw_pad_36: u32,
  cw_pad_40: u32,
  cw_pad_44: u32,
}
@group(0) @binding(5) var<uniform> cw_params: CWParams;
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
          v_value = (v_value + ((b_source[(cw_buffer_offset_0 + i32(((((u32(v_sy) * v_width) + u32(v_sx)) * u32(9i)) + v_channel)))] * cw_tmp_12) * cw_tmp_13));
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
          v_value = (v_value + ((b_depth[(cw_buffer_offset_0 + i32(((((u32(v_sy) * v_width) + u32(v_sx)) * u32(9i)) + v_channel)))] * cw_tmp_18) * cw_tmp_19));
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
fn f_cw_buffer_helper_2(cw_buffer_arg_0: i32, cw_arg_width: u32, cw_arg_height: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_channel: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
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
          var cw_tmp_21: i32;
          if ((v_sx < 0i)) {
            cw_tmp_21 = 0i;
          } else {
            var cw_tmp_20: i32;
            if ((v_sx >= i32(v_width))) {
              cw_tmp_20 = (i32(v_width) - 1i);
            } else {
              cw_tmp_20 = v_sx;
            }
            cw_tmp_21 = cw_tmp_20;
          }
          v_sx = cw_tmp_21;
          var cw_tmp_23: i32;
          if ((v_sy < 0i)) {
            cw_tmp_23 = 0i;
          } else {
            var cw_tmp_22: i32;
            if ((v_sy >= i32(v_height))) {
              cw_tmp_22 = (i32(v_height) - 1i);
            } else {
              cw_tmp_22 = v_sy;
            }
            cw_tmp_23 = cw_tmp_22;
          }
          v_sy = cw_tmp_23;
          var cw_tmp_24: f32;
          if ((v_dx == 0i)) {
            cw_tmp_24 = (1.0f - v_fx);
          } else {
            cw_tmp_24 = v_fx;
          }
          var cw_tmp_25: f32;
          if ((v_dy == 0i)) {
            cw_tmp_25 = (1.0f - v_fy);
          } else {
            cw_tmp_25 = v_fy;
          }
          v_value = (v_value + ((b_normals[(cw_buffer_offset_0 + i32(((((u32(v_sy) * v_width) + u32(v_sx)) * u32(9i)) + v_channel)))] * cw_tmp_24) * cw_tmp_25));
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
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(4i))) { break; }
      b_target[((v_i * 9u) + v_c)] = f_cw_buffer_helper_0(0i, cw_params.p_source_width, cw_params.p_source_height, v_u, v_v, v_c, cw_thread, cw_block, cw_grid);
      continuing {
        v_c += u32(1);
      }
    }
  }
  if (((cw_params.p_flags & 1u) != 0u)) {
    var v_z: f32 = f_cw_buffer_helper_1(0i, cw_params.p_depth_width, cw_params.p_depth_height, v_u, v_v, 4u, cw_thread, cw_block, cw_grid);
    var v_near_plane: f32 = b_settings[0i];
    var v_far_plane: f32 = b_settings[1i];
    var v_distance: f32;
    if (((cw_params.p_flags & 8u) != 0u)) {
      v_distance = cw_divide_f32((v_near_plane * v_far_plane), (v_far_plane + (v_z * (v_near_plane - v_far_plane))));
    } else {
      v_distance = cw_divide_f32(((2.0f * v_near_plane) * v_far_plane), ((v_far_plane + v_near_plane) - (((v_z * 2.0f) - 1.0f) * (v_far_plane - v_near_plane))));
    }
    {
      var v_c: u32 = u32(0i);
      loop {
        if (!(v_c < u32(3i))) { break; }
        b_target[((v_i * 9u) + v_c)] = (cw_divide_f32(v_distance, v_far_plane) * b_settings[2i]);
        continuing {
          v_c += u32(1);
        }
      }
    }
    b_target[((v_i * 9u) + 3u)] = 1.0f;
  }
  if ((((cw_params.p_flags & 2u) != 0u) && (((cw_params.p_flags & 1u) == 0u) || (v_u < 0.5f)))) {
    var v_n: array<f32, 3>;
    {
      var v_c: u32 = u32(0i);
      loop {
        if (!(v_c < u32(3i))) { break; }
        v_n[v_c] = ((f_cw_buffer_helper_2(0i, cw_params.p_normal_width, cw_params.p_normal_height, v_u, v_v, (5u + v_c), cw_thread, cw_block, cw_grid) * 2.0f) - 1.0f);
        continuing {
          v_c += u32(1);
        }
      }
    }
    {
      var v_c: u32 = u32(0i);
      loop {
        if (!(v_c < u32(3i))) { break; }
        var v_value: f32 = v_n[v_c];
        if (((cw_params.p_flags & 4u) != 0u)) {
          v_value = (((v_n[0i] * b_settings[(3u + (v_c * 4u))]) + (v_n[1i] * b_settings[(4u + (v_c * 4u))])) + (v_n[2i] * b_settings[(5u + (v_c * 4u))]));
        }
        b_target[((v_i * 9u) + v_c)] = ((v_value * 0.5f) + 0.5f);
        continuing {
          v_c += u32(1);
        }
      }
    }
  }
}
