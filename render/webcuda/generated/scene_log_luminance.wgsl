// CUDA WebShader 0.1.1. Generated from kernel scene_log_luminance.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_output: array<f32>;
struct CWParams {
  p_width: u32,
  p_height: u32,
  p_source_width: u32,
  p_source_height: u32,
  p_sx: f32,
  p_sy: f32,
  p_viewport_width: u32,
  p_viewport_height: u32,
}
@group(0) @binding(2) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn cw_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }

fn f_expand_half(cw_arg_value: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var v_value: u32 = cw_arg_value;
  var v_sign: u32 = ((v_value & 32768u) << u32(16i));
  var v_exponent: u32 = ((v_value >> u32(10i)) & 31u);
  var v_mantissa: u32 = (v_value & 1023u);
  if ((v_exponent == 31u)) {
    return ((v_sign | 2139095040u) | (v_mantissa << u32(13i)));
  }
  if ((v_exponent == 0u)) {
    if ((v_mantissa == 0u)) {
      return v_sign;
    }
    var v_shift: u32 = 0u;
    {
      loop {
        if (!((v_mantissa & 1024u) == 0u)) { break; }
        v_mantissa = (v_mantissa << u32(1i));
        v_shift += u32(1);
      }
    }
    return ((v_sign | ((113u - v_shift) << u32(23i))) | ((v_mantissa & 1023u) << u32(13i)));
  }
  return ((v_sign | ((v_exponent + 112u) << u32(23i))) | (v_mantissa << u32(13i)));
}
fn f_contract_half(cw_arg_value: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var v_value: f32 = cw_arg_value;
  var v_bits: u32 = bitcast<u32>(v_value);
  var v_sign: u32 = ((v_bits >> u32(16i)) & 32768u);
  var v_exponent: u32 = ((v_bits >> u32(23i)) & 255u);
  var v_mantissa: u32 = (v_bits & 8388607u);
  if ((v_exponent == 255u)) {
    var cw_tmp_0: u32;
    if ((v_mantissa != 0u)) {
      cw_tmp_0 = (512u | (v_mantissa >> u32(13i)));
    } else {
      cw_tmp_0 = 0u;
    }
    return ((v_sign | 31744u) | cw_tmp_0);
  }
  var v_adjusted: i32 = (i32(v_exponent) - 112i);
  if ((v_adjusted >= 31i)) {
    return (v_sign | 31744u);
  }
  if ((v_adjusted <= 0i)) {
    if ((v_adjusted < (-10i))) {
      return v_sign;
    }
    v_mantissa = (v_mantissa | 8388608u);
    var v_shift: u32 = u32((14i - v_adjusted));
    var v_rounded: u32 = (v_mantissa >> v_shift);
    var v_remainder: u32 = (v_mantissa & ((1u << v_shift) - 1u));
    var v_halfway: u32 = (1u << (v_shift - 1u));
    if (((v_remainder > v_halfway) || ((v_remainder == v_halfway) && ((v_rounded & 1u) != 0u)))) {
      v_rounded += u32(1);
    }
    return (v_sign | v_rounded);
  }
  var v_rounded: u32 = ((v_mantissa + 4095u) + ((v_mantissa >> u32(13i)) & 1u));
  if (((v_rounded & 8388608u) != 0u)) {
    v_rounded = 0u;
    v_adjusted += i32(1);
  }
  if ((v_adjusted >= 31i)) {
    return (v_sign | 31744u);
  }
  return ((v_sign | (u32(v_adjusted) << u32(10i))) | (v_rounded >> u32(13i)));
}
fn f_round_half(cw_arg_value: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_value: f32 = cw_arg_value;
  return bitcast<f32>(f_expand_half(f_contract_half(v_value, cw_thread, cw_block, cw_grid), cw_thread, cw_block, cw_grid));
}





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
  var v_u: f32 = (cw_divide_f32((f32((v_i % cw_params.p_width)) + 0.5f), f32(cw_params.p_viewport_width)) * cw_params.p_sx);
  var v_v: f32 = (cw_divide_f32((f32(((cw_params.p_height - 1u) - (v_i / cw_params.p_width))) + 0.5f), f32(cw_params.p_viewport_height)) * cw_params.p_sy);
  var v_lum: f32 = (((f_cw_buffer_helper_0(0i, cw_params.p_source_width, cw_params.p_source_height, v_u, v_v, u32(0i), cw_thread, cw_block, cw_grid) * 0.2126f) + (f_cw_buffer_helper_0(0i, cw_params.p_source_width, cw_params.p_source_height, v_u, v_v, u32(1i), cw_thread, cw_block, cw_grid) * 0.7152f)) + (f_cw_buffer_helper_0(0i, cw_params.p_source_width, cw_params.p_source_height, v_u, v_v, u32(2i), cw_thread, cw_block, cw_grid) * 0.0722f));
  b_output[v_i] = f_round_half(min(1.0f, max(0.0f, cw_divide_f32((log2(max(0.004f, v_lum)) + 9.0f), 13.0f))), cw_thread, cw_block, cw_grid);
}
