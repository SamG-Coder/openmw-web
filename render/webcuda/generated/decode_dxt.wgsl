// CUDA WebShader 0.1.1. Generated from kernel decode_dxt.
@group(0) @binding(0) var<storage, read> b_blocks: array<u32>;
@group(0) @binding(1) var<storage, read_write> b_pixels: array<u32>;
struct CWParams {
  p_width: u32,
  p_height: u32,
  p_format: u32,
  p_block_offset: u32,
  p_pixel_offset: u32,
  cw_pad_20: u32,
  cw_pad_24: u32,
  cw_pad_28: u32,
}
@group(0) @binding(2) var<uniform> cw_params: CWParams;
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




@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_linear_output: u32 = (cw_params.p_format & 65536u);
  var v_channels: u32 = ((cw_params.p_format >> 8u) & 7u);
  var v_encoding: u32 = (cw_params.p_format & 255u);
  var v_block: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  var v_columns: u32 = ((cw_params.p_width + u32(3i)) / u32(4i));
  if ((v_block >= (v_columns * ((cw_params.p_height + u32(3i)) / u32(4i))))) {
    return;
  }
  var cw_tmp_8: i32;
  if (((v_encoding == u32(1i)) || (v_encoding == u32(2i)))) {
    cw_tmp_8 = 2i;
  } else {
    cw_tmp_8 = 4i;
  }
  var v_base: u32 = (cw_params.p_block_offset + (v_block * u32(cw_tmp_8)));
  var cw_tmp_9: i32;
  if (((v_encoding == u32(1i)) || (v_encoding == u32(2i)))) {
    cw_tmp_9 = 0i;
  } else {
    cw_tmp_9 = 2i;
  }
  var v_colorbase: u32 = (v_base + u32(cw_tmp_9));
  var v_endpoints: u32 = b_blocks[v_colorbase];
  var v_c0: u32 = (v_endpoints & u32(65535i));
  var v_c1: u32 = (v_endpoints >> u32(16i));
  var v_r0: u32 = ((v_c0 >> u32(11i)) & u32(31i));
  v_r0 = ((v_r0 << u32(3i)) | (v_r0 >> u32(2i)));
  var v_g0: u32 = ((v_c0 >> u32(5i)) & u32(63i));
  v_g0 = ((v_g0 << u32(2i)) | (v_g0 >> u32(4i)));
  var v_b0: u32 = (v_c0 & u32(31i));
  v_b0 = ((v_b0 << u32(3i)) | (v_b0 >> u32(2i)));
  var v_r1: u32 = ((v_c1 >> u32(11i)) & u32(31i));
  v_r1 = ((v_r1 << u32(3i)) | (v_r1 >> u32(2i)));
  var v_g1: u32 = ((v_c1 >> u32(5i)) & u32(63i));
  v_g1 = ((v_g1 << u32(2i)) | (v_g1 >> u32(4i)));
  var v_b1: u32 = (v_c1 & u32(31i));
  v_b1 = ((v_b1 << u32(3i)) | (v_b1 >> u32(2i)));
  {
    var v_p: u32 = u32(0i);
    loop {
      if (!(v_p < u32(16i))) { break; }
      var v_x: u32 = (((v_block % v_columns) * u32(4i)) + (v_p % u32(4i)));
      var v_y: u32 = (((v_block / v_columns) * u32(4i)) + (v_p / u32(4i)));
      if (((v_x >= cw_params.p_width) || (v_y >= cw_params.p_height))) {
        continue;
      }
      var v_index: u32 = ((b_blocks[(v_colorbase + u32(1i))] >> (v_p * u32(2i))) & u32(3i));
      var v_r: u32 = v_r0;
      var v_g: u32 = v_g0;
      var v_b: u32 = v_b0;
      var v_a: u32 = u32(255i);
      if ((v_index == u32(1i))) {
        v_r = v_r1;
        v_g = v_g1;
        v_b = v_b1;
      }
      if ((v_index >= u32(2i))) {
        if ((((v_c0 > v_c1) || (v_encoding == u32(3i))) || (v_encoding == u32(5i)))) {
          var cw_tmp_10: i32;
          if ((v_index == u32(2i))) {
            cw_tmp_10 = 2i;
          } else {
            cw_tmp_10 = 1i;
          }
          var v_weight: u32 = u32(cw_tmp_10);
          v_r = (((v_weight * v_r0) + ((u32(3i) - v_weight) * v_r1)) / u32(3i));
          v_g = (((v_weight * v_g0) + ((u32(3i) - v_weight) * v_g1)) / u32(3i));
          v_b = (((v_weight * v_b0) + ((u32(3i) - v_weight) * v_b1)) / u32(3i));
        } else {
          if ((v_index == u32(2i))) {
            v_r = ((v_r0 + v_r1) / u32(2i));
            v_g = ((v_g0 + v_g1) / u32(2i));
            v_b = ((v_b0 + v_b1) / u32(2i));
          } else {
            v_r = u32(0i);
            v_g = u32(0i);
            v_b = u32(0i);
            if ((v_encoding == u32(1i))) {
              v_a = u32(0i);
            }
          }
        }
      }
      if ((v_encoding == u32(3i))) {
        v_a = (((b_blocks[(v_base + (v_p / u32(8i)))] >> ((v_p % u32(8i)) * u32(4i))) & u32(15i)) * u32(17i));
      }
      if ((v_encoding == u32(5i))) {
        var v_a0: u32 = (b_blocks[v_base] & u32(255i));
        var v_a1: u32 = ((b_blocks[v_base] >> u32(8i)) & u32(255i));
        var v_lo: u32 = ((b_blocks[v_base] >> u32(16i)) | (b_blocks[(v_base + u32(1i))] << u32(16i)));
        var v_hi: u32 = (b_blocks[(v_base + u32(1i))] >> u32(16i));
        var v_bit: u32 = (v_p * u32(3i));
        var v_ai: u32 = u32(0i);
        if ((v_bit < u32(32i))) {
          v_ai = (v_lo >> v_bit);
          if ((v_bit > u32(29i))) {
            v_ai = (v_ai | (v_hi << (u32(32i) - v_bit)));
          }
        } else {
          v_ai = (v_hi >> (v_bit - u32(32i)));
        }
        v_ai = (v_ai & u32(7i));
        if ((v_ai == u32(0i))) {
          v_a = v_a0;
        } else {
          if ((v_ai == u32(1i))) {
            v_a = v_a1;
          } else {
            if ((v_a0 > v_a1)) {
              v_a = ((((u32(8i) - v_ai) * v_a0) + ((v_ai - u32(1i)) * v_a1)) / u32(7i));
            } else {
              if ((v_ai < u32(6i))) {
                v_a = ((((u32(6i) - v_ai) * v_a0) + ((v_ai - u32(1i)) * v_a1)) / u32(5i));
              } else {
                var cw_tmp_11: i32;
                if ((v_ai == u32(6i))) {
                  cw_tmp_11 = 0i;
                } else {
                  cw_tmp_11 = 255i;
                }
                v_a = u32(cw_tmp_11);
              }
            }
          }
        }
      }
      if ((v_linear_output != 0u)) {
        var v_out: u32 = (cw_params.p_pixel_offset + (((v_y * cw_params.p_width) + v_x) * 4u));
        b_pixels[v_out] = bitcast<u32>(f_srgb_to_linear(cw_divide_f32(f32(v_r), 255.0f), cw_thread, cw_block, cw_grid));
        b_pixels[(v_out + 1u)] = bitcast<u32>(f_srgb_to_linear(cw_divide_f32(f32(v_g), 255.0f), cw_thread, cw_block, cw_grid));
        b_pixels[(v_out + 2u)] = bitcast<u32>(f_srgb_to_linear(cw_divide_f32(f32(v_b), 255.0f), cw_thread, cw_block, cw_grid));
        var cw_tmp_12: f32;
        if ((v_channels == 3u)) {
          cw_tmp_12 = 1.0f;
        } else {
          cw_tmp_12 = cw_divide_f32(f32(v_a), 255.0f);
        }
        b_pixels[(v_out + 3u)] = bitcast<u32>(cw_tmp_12);
      } else {
        b_pixels[((cw_params.p_pixel_offset + (v_y * cw_params.p_width)) + v_x)] = (((v_r | (v_g << u32(8i))) | (v_b << u32(16i))) | (v_a << u32(24i)));
      }
      continuing {
        v_p += u32(1);
      }
    }
  }
}
