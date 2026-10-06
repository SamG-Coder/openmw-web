// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: copy_resolved_attachment.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_target: array<f32>;
struct KernelParams {
  p_width: u32,
  p_height: u32,
  p_plane: u32,
  p_color_channels: u32,
  p_color_storage: u32,
  p_depth_bits: u32,
  p_viewport_x: i32,
  p_viewport_y: i32,
  p_viewport_width: u32,
  p_viewport_height: u32,
  p_source_compact: u32,
  p_target_compact: u32,
}
@group(0) @binding(2) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn gpu_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }
fn f_render_power(gpu_arg_base: f32, gpu_arg_exponent: f32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var v_base: f32 = gpu_arg_base;
  var v_exponent: f32 = gpu_arg_exponent;
  if (((v_exponent == 0.0f) || (v_base == 1.0f))) {
    return 1.0f;
  }
  if ((v_base == 0.0f)) {
    return 0.0f;
  }
  return exp2((v_exponent * log2(v_base)));
}
fn f_expand_half(gpu_arg_value: u32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> u32 {
  var v_value: u32 = gpu_arg_value;
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
fn f_contract_half(gpu_arg_value: f32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> u32 {
  var v_value: f32 = gpu_arg_value;
  var v_bits: u32 = bitcast<u32>(v_value);
  var v_sign: u32 = ((v_bits >> u32(16i)) & 32768u);
  var v_exponent: u32 = ((v_bits >> u32(23i)) & 255u);
  var v_mantissa: u32 = (v_bits & 8388607u);
  if ((v_exponent == 255u)) {
    var gpu_tmp_0: u32;
    if ((v_mantissa != 0u)) {
      gpu_tmp_0 = (512u | (v_mantissa >> u32(13i)));
    } else {
      gpu_tmp_0 = 0u;
    }
    return ((v_sign | 31744u) | gpu_tmp_0);
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
fn f_round_half(gpu_arg_value: f32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var v_value: f32 = gpu_arg_value;
  return bitcast<f32>(f_expand_half(f_contract_half(v_value, gpu_thread, gpu_block, gpu_grid), gpu_thread, gpu_block, gpu_grid));
}
fn f_srgb_to_linear(gpu_arg_value: f32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var v_value: f32 = gpu_arg_value;
  v_value = min(1.0f, max(0.0f, v_value));
  var gpu_tmp_1: f32;
  if ((v_value <= 0.04045f)) {
    gpu_tmp_1 = gpu_divide_f32(v_value, 12.92f);
  } else {
    gpu_tmp_1 = f_render_power(gpu_divide_f32((v_value + 0.055f), 1.055f), 2.4f, gpu_thread, gpu_block, gpu_grid);
  }
  return gpu_tmp_1;
}
fn f_linear_to_srgb(gpu_arg_value: f32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var v_value: f32 = gpu_arg_value;
  v_value = min(1.0f, max(0.0f, v_value));
  var gpu_tmp_2: f32;
  if ((v_value <= 0.0031308f)) {
    gpu_tmp_2 = (v_value * 12.92f);
  } else {
    gpu_tmp_2 = ((1.055f * f_render_power(v_value, gpu_divide_f32(1.0f, 2.4f), gpu_thread, gpu_block, gpu_grid)) - 0.055f);
  }
  return gpu_tmp_2;
}
fn f_store_color_value(gpu_arg_value: f32, gpu_arg_channel: u32, gpu_arg_channels: u32, gpu_arg_storage: u32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var v_value: f32 = gpu_arg_value;
  var v_channel: u32 = gpu_arg_channel;
  var v_channels: u32 = gpu_arg_channels;
  var v_storage: u32 = gpu_arg_storage;
  if ((v_channel >= v_channels)) {
    var gpu_tmp_3: f32;
    if ((v_channel == 3u)) {
      gpu_tmp_3 = 1.0f;
    } else {
      gpu_tmp_3 = 0.0f;
    }
    return gpu_tmp_3;
  }
  if ((v_storage == 0u)) {
    return gpu_divide_f32(floor(((min(1.0f, max(0.0f, v_value)) * 255.0f) + 0.5f)), 255.0f);
  }
  if ((v_storage == 1u)) {
    return f_round_half(v_value, gpu_thread, gpu_block, gpu_grid);
  }
  if ((v_storage == 4u)) {
    return gpu_divide_f32(floor(((min(1.0f, max(0.0f, v_value)) * 65535.0f) + 0.5f)), 65535.0f);
  }
  if (((v_storage == 5u) || (v_storage == 6u))) {
    var gpu_tmp_4: f32;
    if ((v_storage == 5u)) {
      gpu_tmp_4 = 127.0f;
    } else {
      gpu_tmp_4 = 32767.0f;
    }
    var v_maximum: f32 = gpu_tmp_4;
    return gpu_divide_f32(floor(((min(1.0f, max((-1.0f), v_value)) * v_maximum) + 0.5f)), v_maximum);
  }
  if ((v_storage == 3u)) {
    var gpu_tmp_5: f32;
    if ((v_channel < 3u)) {
      gpu_tmp_5 = f_linear_to_srgb(v_value, gpu_thread, gpu_block, gpu_grid);
    } else {
      gpu_tmp_5 = min(1.0f, max(0.0f, v_value));
    }
    var v_encoded: f32 = gpu_tmp_5;
    v_encoded = gpu_divide_f32(floor(((v_encoded * 255.0f) + 0.5f)), 255.0f);
    var gpu_tmp_6: f32;
    if ((v_channel < 3u)) {
      gpu_tmp_6 = f_srgb_to_linear(v_encoded, gpu_thread, gpu_block, gpu_grid);
    } else {
      gpu_tmp_6 = v_encoded;
    }
    return gpu_tmp_6;
  }
  return v_value;
}
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
  var v_pixel: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_pixel >= (gpu_params.p_width * gpu_params.p_height))) {
    return;
  }
  var v_x: f32 = (f32((v_pixel % gpu_params.p_width)) + 0.5f);
  var v_y: f32 = ((f32(gpu_params.p_height) - f32((v_pixel / gpu_params.p_width))) - 0.5f);
  if (((((v_x < f32(gpu_params.p_viewport_x)) || (v_y < f32(gpu_params.p_viewport_y))) || (v_x >= (f32(gpu_params.p_viewport_x) + f32(gpu_params.p_viewport_width)))) || (v_y >= (f32(gpu_params.p_viewport_y) + f32(gpu_params.p_viewport_height))))) {
    return;
  }
  if ((gpu_params.p_plane == 0u)) {
    {
      var v_channel: u32 = u32(0i);
      loop {
        if (!(v_channel < u32(4i))) { break; }
        let gpu_argument_index_8 = ((v_pixel * u32(9i)) + v_channel);
        b_target[((v_pixel * u32(9i)) + v_channel)] = f_store_color_value(b_source[gpu_argument_index_8], v_channel, gpu_params.p_color_channels, gpu_params.p_color_storage, gpu_thread, gpu_block, gpu_grid);
        continuing {
          v_channel += u32(1);
        }
      }
    }
  }
  if (((gpu_params.p_plane == 1u) || (gpu_params.p_plane == 4u))) {
    var gpu_tmp_9: u32;
    if ((gpu_params.p_target_compact != 0u)) {
      gpu_tmp_9 = v_pixel;
    } else {
      gpu_tmp_9 = ((v_pixel * u32(9i)) + u32(4i));
    }
    var gpu_tmp_10: u32;
    if ((gpu_params.p_source_compact != 0u)) {
      gpu_tmp_10 = v_pixel;
    } else {
      gpu_tmp_10 = ((v_pixel * u32(9i)) + u32(4i));
    }
    let gpu_argument_index_11 = gpu_tmp_10;
    b_target[gpu_tmp_9] = f_store_depth_value(b_source[gpu_argument_index_11], gpu_params.p_depth_bits, gpu_thread, gpu_block, gpu_grid);
  }
  if ((gpu_params.p_plane == 2u)) {
    {
      var v_channel: u32 = u32(0i);
      loop {
        if (!(v_channel < u32(4i))) { break; }
        let gpu_argument_index_12 = (((v_pixel * u32(9i)) + u32(5i)) + v_channel);
        b_target[(((v_pixel * u32(9i)) + u32(5i)) + v_channel)] = f_store_color_value(b_source[gpu_argument_index_12], v_channel, gpu_params.p_color_channels, gpu_params.p_color_storage, gpu_thread, gpu_block, gpu_grid);
        continuing {
          v_channel += u32(1);
        }
      }
    }
  }
  if (((gpu_params.p_plane == 3u) || (gpu_params.p_plane == 4u))) {
    b_target[(((gpu_params.p_width * gpu_params.p_height) * u32(9i)) + v_pixel)] = b_source[(((gpu_params.p_width * gpu_params.p_height) * u32(9i)) + v_pixel)];
  }
}
