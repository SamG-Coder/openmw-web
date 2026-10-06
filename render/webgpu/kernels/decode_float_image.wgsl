// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: decode_float_image.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_blocks: array<u32>;
@group(0) @binding(1) var<storage, read_write> b_pixels: array<u32>;
struct KernelParams {
  p_width: u32,
  p_height: u32,
  p_format: u32,
  p_block_offset: u32,
  p_pixel_offset: u32,
  gpu_pad_20: u32,
  gpu_pad_24: u32,
  gpu_pad_28: u32,
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
  var v_i: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_i >= (gpu_params.p_width * gpu_params.p_height))) {
    return;
  }
  var v_destination_kind: u32 = ((gpu_params.p_format >> 8u) & 15u);
  var v_storage: u32 = ((gpu_params.p_format >> 12u) & 7u);
  var v_convert: u32 = (gpu_params.p_format & 65536u);
  var v_encoding: u32 = (gpu_params.p_format & 255u);
  var v_family: u32 = (v_encoding / 16u);
  var v_kind: u32 = (v_encoding % 16u);
  var gpu_tmp_10: u32;
  if (((v_kind == 6u) || (v_kind == 13u))) {
    gpu_tmp_10 = 4u;
  } else {
    var gpu_tmp_9: u32;
    if (((v_kind == 7u) || (v_kind == 14u))) {
      gpu_tmp_9 = 3u;
    } else {
      var gpu_tmp_8: u32;
      if (((v_kind == 8u) || (v_kind == 11u))) {
        gpu_tmp_8 = 2u;
      } else {
        gpu_tmp_8 = 1u;
      }
      gpu_tmp_9 = gpu_tmp_8;
    }
    gpu_tmp_10 = gpu_tmp_9;
  }
  var v_channels: u32 = gpu_tmp_10;
  var v_input: array<u32, 4>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      var gpu_tmp_11: u32;
      if ((v_k == u32(3i))) {
        gpu_tmp_11 = 1065353216u;
      } else {
        gpu_tmp_11 = 0u;
      }
      v_input[v_k] = gpu_tmp_11;
      continuing {
        v_k += u32(1);
      }
    }
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < v_channels)) { break; }
      var v_index: u32 = ((v_i * v_channels) + v_k);
      if ((v_family >= 8u)) {
        var gpu_tmp_12: u32;
        if ((v_family < 14u)) {
          gpu_tmp_12 = ((b_blocks[(gpu_params.p_block_offset + (v_i / 2u))] >> ((v_i % 2u) * 16u)) & 65535u);
        } else {
          gpu_tmp_12 = b_blocks[(gpu_params.p_block_offset + v_i)];
        }
        var v_packed: u32 = gpu_tmp_12;
        var v_shift: u32 = 0u;
        var v_bits: u32 = 8u;
        if (((v_family == 8u) || (v_family == 9u))) {
          var gpu_tmp_13: u32;
          if ((v_k == 1u)) {
            gpu_tmp_13 = 6u;
          } else {
            gpu_tmp_13 = 5u;
          }
          v_bits = gpu_tmp_13;
          var gpu_tmp_18: u32;
          if ((v_family == 8u)) {
            var gpu_tmp_15: u32;
            if ((v_k == 0u)) {
              gpu_tmp_15 = 11u;
            } else {
              var gpu_tmp_14: u32;
              if ((v_k == 1u)) {
                gpu_tmp_14 = 5u;
              } else {
                gpu_tmp_14 = 0u;
              }
              gpu_tmp_15 = gpu_tmp_14;
            }
            gpu_tmp_18 = gpu_tmp_15;
          } else {
            var gpu_tmp_17: u32;
            if ((v_k == 0u)) {
              gpu_tmp_17 = 0u;
            } else {
              var gpu_tmp_16: u32;
              if ((v_k == 1u)) {
                gpu_tmp_16 = 5u;
              } else {
                gpu_tmp_16 = 11u;
              }
              gpu_tmp_17 = gpu_tmp_16;
            }
            gpu_tmp_18 = gpu_tmp_17;
          }
          v_shift = gpu_tmp_18;
        } else {
          if (((v_family == 10u) || (v_family == 11u))) {
            v_bits = 4u;
            var gpu_tmp_19: u32;
            if ((v_family == 10u)) {
              gpu_tmp_19 = ((3u - v_k) * 4u);
            } else {
              gpu_tmp_19 = (v_k * 4u);
            }
            v_shift = gpu_tmp_19;
          } else {
            if (((v_family == 12u) || (v_family == 13u))) {
              var gpu_tmp_20: u32;
              if ((v_k == 3u)) {
                gpu_tmp_20 = 1u;
              } else {
                gpu_tmp_20 = 5u;
              }
              v_bits = gpu_tmp_20;
              var gpu_tmp_23: u32;
              if ((v_family == 12u)) {
                var gpu_tmp_21: u32;
                if ((v_k == 3u)) {
                  gpu_tmp_21 = 0u;
                } else {
                  gpu_tmp_21 = (11u - (v_k * 5u));
                }
                gpu_tmp_23 = gpu_tmp_21;
              } else {
                var gpu_tmp_22: u32;
                if ((v_k == 3u)) {
                  gpu_tmp_22 = 15u;
                } else {
                  gpu_tmp_22 = (v_k * 5u);
                }
                gpu_tmp_23 = gpu_tmp_22;
              }
              v_shift = gpu_tmp_23;
            } else {
              var gpu_tmp_24: u32;
              if ((v_family == 14u)) {
                gpu_tmp_24 = ((3u - v_k) * 8u);
              } else {
                gpu_tmp_24 = (v_k * 8u);
              }
              v_shift = gpu_tmp_24;
            }
          }
        }
        var v_mask: u32 = ((1u << v_bits) - 1u);
        v_input[v_k] = bitcast<u32>(gpu_divide_f32(f32(((v_packed >> v_shift) & v_mask)), f32(v_mask)));
      } else {
        if ((v_family == 0u)) {
          v_input[v_k] = b_blocks[(gpu_params.p_block_offset + v_index)];
        } else {
          if ((v_family == 1u)) {
            v_input[v_k] = f_expand_half(((b_blocks[(gpu_params.p_block_offset + (v_index / 2u))] >> ((v_index % 2u) * 16u)) & 65535u), gpu_thread, gpu_block, gpu_grid);
          } else {
            var v_value: u32;
            var v_decoded: f32;
            if (((v_family == 2u) || (v_family == 4u))) {
              v_value = ((b_blocks[(gpu_params.p_block_offset + (v_index / 4u))] >> ((v_index % 4u) * 8u)) & 255u);
              var gpu_tmp_26: f32;
              if ((v_family == 2u)) {
                gpu_tmp_26 = gpu_divide_f32(f32(v_value), 255.0f);
              } else {
                var gpu_tmp_25: i32;
                if ((v_value >= 128u)) {
                  gpu_tmp_25 = 256i;
                } else {
                  gpu_tmp_25 = 0i;
                }
                gpu_tmp_26 = max((-1.0f), gpu_divide_f32(f32((i32(v_value) - gpu_tmp_25)), 127.0f));
              }
              v_decoded = gpu_tmp_26;
            } else {
              if (((v_family == 3u) || (v_family == 5u))) {
                v_value = ((b_blocks[(gpu_params.p_block_offset + (v_index / 2u))] >> ((v_index % 2u) * 16u)) & 65535u);
                var gpu_tmp_28: f32;
                if ((v_family == 3u)) {
                  gpu_tmp_28 = gpu_divide_f32(f32(v_value), 65535.0f);
                } else {
                  var gpu_tmp_27: i32;
                  if ((v_value >= 32768u)) {
                    gpu_tmp_27 = 65536i;
                  } else {
                    gpu_tmp_27 = 0i;
                  }
                  gpu_tmp_28 = max((-1.0f), gpu_divide_f32(f32((i32(v_value) - gpu_tmp_27)), 32767.0f));
                }
                v_decoded = gpu_tmp_28;
              } else {
                v_value = b_blocks[(gpu_params.p_block_offset + v_index)];
                var gpu_tmp_29: f32;
                if ((v_family == 6u)) {
                  gpu_tmp_29 = gpu_divide_f32(f32(v_value), 4294967295.0f);
                } else {
                  gpu_tmp_29 = max((-1.0f), gpu_divide_f32(f32(i32(v_value)), 2147483647.0f));
                }
                v_decoded = gpu_tmp_29;
              }
            }
            v_input[v_k] = bitcast<u32>(v_decoded);
          }
        }
      }
      continuing {
        v_k += u32(1);
      }
    }
  }
  if (((v_convert != 0u) && (v_destination_kind == 9u))) {
    var gpu_tmp_32: u32;
    if ((v_storage == 0u)) {
      gpu_tmp_32 = v_input[0i];
    } else {
      let gpu_argument_index_30 = 0i;
      var gpu_tmp_31: u32;
      if ((v_storage == 1u)) {
        gpu_tmp_31 = 16u;
      } else {
        gpu_tmp_31 = 24u;
      }
      gpu_tmp_32 = bitcast<u32>(f_store_depth_value(bitcast<f32>(v_input[gpu_argument_index_30]), gpu_tmp_31, gpu_thread, gpu_block, gpu_grid));
    }
    b_pixels[(gpu_params.p_pixel_offset + v_i)] = gpu_tmp_32;
    return;
  }
  var v_color: array<f32, 4>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      var v_value: u32 = v_input[v_k];
      if (((v_kind == 10u) || (v_kind == 11u))) {
        var gpu_tmp_34: u32;
        if ((v_k == 3u)) {
          var gpu_tmp_33: u32;
          if ((v_kind == 11u)) {
            gpu_tmp_33 = v_input[1i];
          } else {
            gpu_tmp_33 = 1065353216u;
          }
          gpu_tmp_34 = gpu_tmp_33;
        } else {
          gpu_tmp_34 = v_input[0i];
        }
        v_value = gpu_tmp_34;
      }
      if ((v_kind == 12u)) {
        var gpu_tmp_35: u32;
        if ((v_k == 3u)) {
          gpu_tmp_35 = v_input[0i];
        } else {
          gpu_tmp_35 = 0u;
        }
        v_value = gpu_tmp_35;
      }
      if ((((v_kind == 13u) || (v_kind == 14u)) && (v_k < 3u))) {
        v_value = v_input[(2u - v_k)];
      }
      v_color[v_k] = bitcast<f32>(v_value);
      continuing {
        v_k += u32(1);
      }
    }
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      var v_value: f32 = v_color[v_k];
      if ((v_convert != 0u)) {
        if (((v_destination_kind == 5u) || (v_destination_kind == 6u))) {
          var gpu_tmp_37: f32;
          if ((v_k == 3u)) {
            var gpu_tmp_36: f32;
            if ((v_destination_kind == 6u)) {
              gpu_tmp_36 = v_color[3i];
            } else {
              gpu_tmp_36 = 1.0f;
            }
            gpu_tmp_37 = gpu_tmp_36;
          } else {
            gpu_tmp_37 = v_color[0i];
          }
          v_value = gpu_tmp_37;
        }
        if ((v_destination_kind == 7u)) {
          var gpu_tmp_38: f32;
          if ((v_k == 3u)) {
            gpu_tmp_38 = v_color[3i];
          } else {
            gpu_tmp_38 = 0.0f;
          }
          v_value = gpu_tmp_38;
        }
        if ((v_destination_kind == 8u)) {
          v_value = v_color[0i];
        }
        if ((v_storage == 3u)) {
          v_value = f_store_color_value(v_value, v_k, v_destination_kind, 0u, gpu_thread, gpu_block, gpu_grid);
          if ((v_k < 3u)) {
            v_value = f_srgb_to_linear(v_value, gpu_thread, gpu_block, gpu_grid);
          }
        } else {
          var gpu_tmp_39: u32;
          if ((v_destination_kind > 4u)) {
            gpu_tmp_39 = 4u;
          } else {
            gpu_tmp_39 = v_destination_kind;
          }
          v_value = f_store_color_value(v_value, v_k, gpu_tmp_39, v_storage, gpu_thread, gpu_block, gpu_grid);
        }
      }
      b_pixels[((gpu_params.p_pixel_offset + (v_i * 4u)) + v_k)] = bitcast<u32>(v_value);
      continuing {
        v_k += u32(1);
      }
    }
  }
}
