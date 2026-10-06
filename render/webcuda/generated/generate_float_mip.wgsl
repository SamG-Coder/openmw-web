// CUDA WebShader 0.1.1. Generated from kernel generate_float_mip.
@group(0) @binding(0) var<storage, read_write> b_texels: array<u32>;
struct CWParams {
  p_source: u32,
  p_destination: u32,
  p_width: u32,
  p_height: u32,
  p_color_channels: u32,
  p_color_storage: u32,
  cw_pad_24: u32,
  cw_pad_28: u32,
}
@group(0) @binding(1) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn cw_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }
fn f_render_power(cw_arg_base: f32, cw_arg_exponent: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_base: f32 = cw_arg_base;
  var v_exponent: f32 = cw_arg_exponent;
  if (((v_exponent == 0.0f) || (v_base == 1.0f))) {
    return 1.0f;
  }
  if ((v_base == 0.0f)) {
    return 0.0f;
  }
  return exp2((v_exponent * log2(v_base)));
}
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
fn f_srgb_to_linear(cw_arg_value: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_value: f32 = cw_arg_value;
  v_value = min(1.0f, max(0.0f, v_value));
  var cw_tmp_1: f32;
  if ((v_value <= 0.04045f)) {
    cw_tmp_1 = cw_divide_f32(v_value, 12.92f);
  } else {
    cw_tmp_1 = f_render_power(cw_divide_f32((v_value + 0.055f), 1.055f), 2.4f, cw_thread, cw_block, cw_grid);
  }
  return cw_tmp_1;
}
fn f_linear_to_srgb(cw_arg_value: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_value: f32 = cw_arg_value;
  v_value = min(1.0f, max(0.0f, v_value));
  var cw_tmp_2: f32;
  if ((v_value <= 0.0031308f)) {
    cw_tmp_2 = (v_value * 12.92f);
  } else {
    cw_tmp_2 = ((1.055f * f_render_power(v_value, cw_divide_f32(1.0f, 2.4f), cw_thread, cw_block, cw_grid)) - 0.055f);
  }
  return cw_tmp_2;
}
fn f_store_color_value(cw_arg_value: f32, cw_arg_channel: u32, cw_arg_channels: u32, cw_arg_storage: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_value: f32 = cw_arg_value;
  var v_channel: u32 = cw_arg_channel;
  var v_channels: u32 = cw_arg_channels;
  var v_storage: u32 = cw_arg_storage;
  if ((v_channel >= v_channels)) {
    var cw_tmp_3: f32;
    if ((v_channel == 3u)) {
      cw_tmp_3 = 1.0f;
    } else {
      cw_tmp_3 = 0.0f;
    }
    return cw_tmp_3;
  }
  if ((v_storage == 0u)) {
    return cw_divide_f32(floor(((min(1.0f, max(0.0f, v_value)) * 255.0f) + 0.5f)), 255.0f);
  }
  if ((v_storage == 1u)) {
    return f_round_half(v_value, cw_thread, cw_block, cw_grid);
  }
  if ((v_storage == 4u)) {
    return cw_divide_f32(floor(((min(1.0f, max(0.0f, v_value)) * 65535.0f) + 0.5f)), 65535.0f);
  }
  if (((v_storage == 5u) || (v_storage == 6u))) {
    var cw_tmp_4: f32;
    if ((v_storage == 5u)) {
      cw_tmp_4 = 127.0f;
    } else {
      cw_tmp_4 = 32767.0f;
    }
    var v_maximum: f32 = cw_tmp_4;
    return cw_divide_f32(floor(((min(1.0f, max((-1.0f), v_value)) * v_maximum) + 0.5f)), v_maximum);
  }
  if ((v_storage == 3u)) {
    var cw_tmp_5: f32;
    if ((v_channel < 3u)) {
      cw_tmp_5 = f_linear_to_srgb(v_value, cw_thread, cw_block, cw_grid);
    } else {
      cw_tmp_5 = min(1.0f, max(0.0f, v_value));
    }
    var v_encoded: f32 = cw_tmp_5;
    v_encoded = cw_divide_f32(floor(((v_encoded * 255.0f) + 0.5f)), 255.0f);
    var cw_tmp_6: f32;
    if ((v_channel < 3u)) {
      cw_tmp_6 = f_srgb_to_linear(v_encoded, cw_thread, cw_block, cw_grid);
    } else {
      cw_tmp_6 = v_encoded;
    }
    return cw_tmp_6;
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
  var cw_tmp_30: u32;
  if ((cw_params.p_width > u32(1i))) {
    cw_tmp_30 = (cw_params.p_width / u32(2i));
  } else {
    cw_tmp_30 = u32(1i);
  }
  var v_dw: u32 = cw_tmp_30;
  var cw_tmp_31: u32;
  if ((cw_params.p_height > u32(1i))) {
    cw_tmp_31 = (cw_params.p_height / u32(2i));
  } else {
    cw_tmp_31 = u32(1i);
  }
  var v_dh: u32 = cw_tmp_31;
  if ((v_i >= (v_dw * v_dh))) {
    return;
  }
  var v_x0: u32 = (((v_i % v_dw) * cw_params.p_width) / v_dw);
  var v_x1: u32 = ((((v_i % v_dw) + u32(1i)) * cw_params.p_width) / v_dw);
  var v_y0: u32 = (((v_i / v_dw) * cw_params.p_height) / v_dh);
  var v_y1: u32 = ((((v_i / v_dw) + u32(1i)) * cw_params.p_height) / v_dh);
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(4i))) { break; }
      var v_sum: f32 = 0.0f;
      {
        var v_y: u32 = v_y0;
        loop {
          if (!(v_y < v_y1)) { break; }
          {
            var v_x: u32 = v_x0;
            loop {
              if (!(v_x < v_x1)) { break; }
              let cw_argument_index_32 = ((cw_params.p_source + (((v_y * cw_params.p_width) + v_x) * u32(4i))) + v_c);
              v_sum = (v_sum + bitcast<f32>(b_texels[cw_argument_index_32]));
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
      b_texels[((cw_params.p_destination + (v_i * u32(4i))) + v_c)] = bitcast<u32>(f_store_color_value(cw_divide_f32(v_sum, f32(((v_x1 - v_x0) * (v_y1 - v_y0)))), v_c, cw_params.p_color_channels, cw_params.p_color_storage, cw_thread, cw_block, cw_grid));
      continuing {
        v_c += u32(1);
      }
    }
  }
}
