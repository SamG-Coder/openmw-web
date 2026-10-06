// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: bloom_blur.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_target: array<f32>;
struct KernelParams {
  p_width: u32,
  p_height: u32,
  p_resolution_width: u32,
  p_resolution_height: u32,
  p_radius_parameter: f32,
  p_vertical: u32,
  gpu_pad_24: u32,
  gpu_pad_28: u32,
}
@group(0) @binding(2) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn gpu_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }

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





fn f_gpu_buffer_helper_0(gpu_buffer_arg_0: i32, gpu_arg_width: u32, gpu_arg_height: u32, gpu_arg_u: f32, gpu_arg_v: f32, gpu_arg_channel: u32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var gpu_buffer_offset_0: i32 = gpu_buffer_arg_0;
  var v_width: u32 = gpu_arg_width;
  var v_height: u32 = gpu_arg_height;
  var v_u: f32 = gpu_arg_u;
  var v_v: f32 = gpu_arg_v;
  var v_channel: u32 = gpu_arg_channel;
  var v_x: i32 = i32(floor((v_u * f32(v_width))));
  var v_y: i32 = i32(floor(((1.0f - v_v) * f32(v_height))));
  var gpu_tmp_11: i32;
  if ((v_x < 0i)) {
    gpu_tmp_11 = 0i;
  } else {
    var gpu_tmp_10: i32;
    if ((v_x >= i32(v_width))) {
      gpu_tmp_10 = (i32(v_width) - 1i);
    } else {
      gpu_tmp_10 = v_x;
    }
    gpu_tmp_11 = gpu_tmp_10;
  }
  v_x = gpu_tmp_11;
  var gpu_tmp_13: i32;
  if ((v_y < 0i)) {
    gpu_tmp_13 = 0i;
  } else {
    var gpu_tmp_12: i32;
    if ((v_y >= i32(v_height))) {
      gpu_tmp_12 = (i32(v_height) - 1i);
    } else {
      gpu_tmp_12 = v_y;
    }
    gpu_tmp_13 = gpu_tmp_12;
  }
  v_y = gpu_tmp_13;
  return b_source[(gpu_buffer_offset_0 + i32(((((u32(v_y) * v_width) + u32(v_x)) * 9u) + v_channel)))];
}

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_i: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_i >= (gpu_params.p_width * gpu_params.p_height))) {
    return;
  }
  var v_u: f32 = gpu_divide_f32((f32((v_i % gpu_params.p_width)) + 0.5f), f32(gpu_params.p_width));
  var v_v: f32 = (1.0f - gpu_divide_f32((f32((v_i / gpu_params.p_width)) + 0.5f), f32(gpu_params.p_height)));
  var v_x: f32 = ((v_u * 2.0f) - 1.0f);
  var v_y: f32 = ((v_v * 2.0f) - 1.0f);
  var v_radius: f32 = ((max(0.1f, ((gpu_params.p_radius_parameter * 0.2f) * f32(gpu_params.p_resolution_height))) * ((v_x * v_x) + 1.0f)) * ((v_y * v_y) + 1.0f));
  var v_extent: i32 = i32(ceil(v_radius));
  var v_sum: array<f32, 3>;
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(3i))) { break; }
      v_sum[v_c] = 0.0f;
      continuing {
        v_c += u32(1);
      }
    }
  }
  var v_normalize: f32 = 0.0f;
  {
    var v_offset: i32 = (-v_extent);
    loop {
      if (!(v_offset <= v_extent)) { break; }
      var v_position: f32 = (gpu_divide_f32(f32(v_offset), v_radius) * 2.0f);
      var v_weight: f32 = exp(((-v_position) * v_position));
      var gpu_tmp_8: f32;
      if ((gpu_params.p_vertical == 0u)) {
        gpu_tmp_8 = gpu_divide_f32(f32(v_offset), f32(gpu_params.p_resolution_width));
      } else {
        gpu_tmp_8 = 0.0f;
      }
      var v_su: f32 = (v_u + gpu_tmp_8);
      var gpu_tmp_9: f32;
      if ((gpu_params.p_vertical != 0u)) {
        gpu_tmp_9 = gpu_divide_f32(f32(v_offset), f32(gpu_params.p_resolution_height));
      } else {
        gpu_tmp_9 = 0.0f;
      }
      var v_sv: f32 = (v_v + gpu_tmp_9);
      v_normalize = (v_normalize + v_weight);
      {
        var v_c: u32 = u32(0i);
        loop {
          if (!(v_c < u32(3i))) { break; }
          v_sum[v_c] = (v_sum[v_c] + (v_weight * f_gpu_buffer_helper_0(0i, gpu_params.p_width, gpu_params.p_height, v_su, v_sv, v_c, gpu_thread, gpu_block, gpu_grid)));
          continuing {
            v_c += u32(1);
          }
        }
      }
      continuing {
        v_offset += i32(1);
      }
    }
  }
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(3i))) { break; }
      b_target[((v_i * 9u) + v_c)] = f_round_half(gpu_divide_f32(v_sum[v_c], v_normalize), gpu_thread, gpu_block, gpu_grid);
      continuing {
        v_c += u32(1);
      }
    }
  }
  b_target[((v_i * 9u) + 3u)] = 1.0f;
}
