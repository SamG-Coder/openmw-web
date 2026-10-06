// CUDA WebShader 0.1.1. Generated from kernel raster_material.
@group(0) @binding(0) var<storage, read> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read> b_triangles: array<u32>;
@group(0) @binding(2) var<storage, read_write> b_counts: array<atomic<u32>>;
@group(0) @binding(3) var<storage, read> b_candidates: array<u32>;
@group(0) @binding(4) var<storage, read> b_materials: array<u32>;
@group(0) @binding(5) var<storage, read> b_texels: array<u32>;
@group(0) @binding(6) var<storage, read_write> b_target: array<f32>;
@group(0) @binding(7) var<storage, read> b_attributes: array<f32>;
struct CWParams {
  p_width: u32,
  p_height: u32,
  p_capacity: u32,
  p_raster_offset: u32,
  p_boundary_offset: u32,
  p_point_fade_offset: u32,
  p_lighting_offset: u32,
  p_cluster_offset: u32,
  p_fixed_offset: u32,
  p_falloff_offset: u32,
  p_fixed_enabled: u32,
  p_normal_enabled: u32,
  p_normal_channels: u32,
  p_normal_storage: u32,
  p_color_channels: u32,
  p_color_storage: u32,
  p_depth_bits: u32,
  p_stencil_enabled: u32,
  p_sample_count: u32,
  cw_pad_76: u32,
}
@group(0) @binding(8) var<uniform> cw_params: CWParams;
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
fn f_store_depth_value(cw_arg_value: f32, cw_arg_bits: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_value: f32 = cw_arg_value;
  var v_bits: u32 = cw_arg_bits;
  v_value = min(1.0f, max(0.0f, v_value));
  if ((v_bits == 0u)) {
    return v_value;
  }
  var cw_tmp_7: f32;
  if ((v_bits == 16u)) {
    cw_tmp_7 = 65535.0f;
  } else {
    cw_tmp_7 = 16777215.0f;
  }
  var v_maximum: f32 = cw_tmp_7;
  return min(1.0f, cw_divide_f32(floor(((v_value * v_maximum) + 0.5f)), v_maximum));
}
fn f_point_disk_integral(cw_arg_x: f32, cw_arg_y: f32, cw_arg_radius: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_x: f32 = cw_arg_x;
  var v_y: f32 = cw_arg_y;
  var v_radius: f32 = cw_arg_radius;
  var cw_tmp_8: f32;
  if ((v_x < 0.0f)) {
    cw_tmp_8 = (-1.0f);
  } else {
    cw_tmp_8 = 1.0f;
  }
  var v_sx: f32 = cw_tmp_8;
  var cw_tmp_9: f32;
  if ((v_y < 0.0f)) {
    cw_tmp_9 = (-1.0f);
  } else {
    cw_tmp_9 = 1.0f;
  }
  var v_sy: f32 = cw_tmp_9;
  v_x = min(abs(v_x), v_radius);
  v_y = min(abs(v_y), v_radius);
  var v_cut: f32 = sqrt(max(0.0f, ((v_radius * v_radius) - (v_y * v_y))));
  var v_flat: f32 = min(v_x, v_cut);
  var v_area: f32 = (v_flat * v_y);
  if ((v_x > v_cut)) {
    var v_height: f32 = sqrt(max(0.0f, ((v_radius * v_radius) - (v_x * v_x))));
    var v_end: f32 = (0.5f * ((v_x * v_height) + ((v_radius * v_radius) * atan2(v_x, v_height))));
    var v_begin: f32 = (0.5f * ((v_cut * v_y) + ((v_radius * v_radius) * atan2(v_cut, v_y))));
    v_area = (v_area + (v_end - v_begin));
  }
  return ((v_sx * v_sy) * v_area);
}
fn f_point_disk_coverage(cw_arg_x: f32, cw_arg_y: f32, cw_arg_radius: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_x: f32 = cw_arg_x;
  var v_y: f32 = cw_arg_y;
  var v_radius: f32 = cw_arg_radius;
  if ((v_radius <= 0.0f)) {
    return 0.0f;
  }
  var v_farX: f32 = (abs(v_x) + 0.5f);
  var v_farY: f32 = (abs(v_y) + 0.5f);
  if ((((v_farX * v_farX) + (v_farY * v_farY)) <= (v_radius * v_radius))) {
    return 1.0f;
  }
  var v_nearX: f32 = max(0.0f, (abs(v_x) - 0.5f));
  var v_nearY: f32 = max(0.0f, (abs(v_y) - 0.5f));
  if ((((v_nearX * v_nearX) + (v_nearY * v_nearY)) >= (v_radius * v_radius))) {
    return 0.0f;
  }
  var v_area: f32 = (((f_point_disk_integral((v_x + 0.5f), (v_y + 0.5f), v_radius, cw_thread, cw_block, cw_grid) - f_point_disk_integral((v_x - 0.5f), (v_y + 0.5f), v_radius, cw_thread, cw_block, cw_grid)) - f_point_disk_integral((v_x + 0.5f), (v_y - 0.5f), v_radius, cw_thread, cw_block, cw_grid)) + f_point_disk_integral((v_x - 0.5f), (v_y - 0.5f), v_radius, cw_thread, cw_block, cw_grid));
  return min(1.0f, max(0.0f, v_area));
}
fn f_line_parameter_less(cw_arg_a: f32, cw_arg_a1: f32, cw_arg_a2: f32, cw_arg_b: f32, cw_arg_b1: f32, cw_arg_b2: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var v_a: f32 = cw_arg_a;
  var v_a1: f32 = cw_arg_a1;
  var v_a2: f32 = cw_arg_a2;
  var v_b: f32 = cw_arg_b;
  var v_b1: f32 = cw_arg_b1;
  var v_b2: f32 = cw_arg_b2;
  if ((v_a != v_b)) {
    return select(u32(0), u32(1), (v_a < v_b));
  }
  if ((v_a1 != v_b1)) {
    return select(u32(0), u32(1), (v_a1 < v_b1));
  }
  return select(u32(0), u32(1), (v_a2 < v_b2));
}
fn f_line_diamond_exit(cw_arg_ax: f32, cw_arg_ay: f32, cw_arg_dx: f32, cw_arg_dy: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var v_ax: f32 = cw_arg_ax;
  var v_ay: f32 = cw_arg_ay;
  var v_dx: f32 = cw_arg_dx;
  var v_dy: f32 = cw_arg_dy;
  var v_enter: f32 = 0.0f;
  var v_enter1: f32 = 0.0f;
  var v_enter2: f32 = 0.0f;
  var v_leave: f32 = 1.0f;
  var v_leave1: f32 = 0.0f;
  var v_leave2: f32 = 0.0f;
  {
    var v_axis: u32 = 0u;
    loop {
      if (!(v_axis < 2u)) { break; }
      var cw_tmp_10: f32;
      if ((v_axis == 0u)) {
        cw_tmp_10 = (v_ax + v_ay);
      } else {
        cw_tmp_10 = (v_ax - v_ay);
      }
      var v_origin: f32 = cw_tmp_10;
      var cw_tmp_11: f32;
      if ((v_axis == 0u)) {
        cw_tmp_11 = (v_dx + v_dy);
      } else {
        cw_tmp_11 = (v_dx - v_dy);
      }
      var v_delta: f32 = cw_tmp_11;
      var cw_tmp_12: f32;
      if ((v_axis == 0u)) {
        cw_tmp_12 = (-1.0f);
      } else {
        cw_tmp_12 = 1.0f;
      }
      var v_second: f32 = cw_tmp_12;
      if ((v_delta == 0.0f)) {
        if (((v_origin <= (-0.5f)) || (v_origin > 0.5f))) {
          return 0u;
        }
      } else {
        var v_low: f32 = cw_divide_f32(((-0.5f) - v_origin), v_delta);
        var v_high: f32 = cw_divide_f32((0.5f - v_origin), v_delta);
        var v_first: f32 = cw_divide_f32(1.0f, v_delta);
        var v_last: f32 = cw_divide_f32(v_second, v_delta);
        if ((v_delta < 0.0f)) {
          var v_swap: f32 = v_low;
          v_low = v_high;
          v_high = v_swap;
        }
        if ((f_line_parameter_less(v_enter, v_enter1, v_enter2, v_low, v_first, v_last, cw_thread, cw_block, cw_grid) != 0u)) {
          v_enter = v_low;
          v_enter1 = v_first;
          v_enter2 = v_last;
        }
        if ((f_line_parameter_less(v_high, v_first, v_last, v_leave, v_leave1, v_leave2, cw_thread, cw_block, cw_grid) != 0u)) {
          v_leave = v_high;
          v_leave1 = v_first;
          v_leave2 = v_last;
        }
      }
      continuing {
        v_axis += u32(1);
      }
    }
  }
  return select(u32(0), u32(1), ((f_line_parameter_less(v_enter, v_enter1, v_enter2, v_leave, v_leave1, v_leave2, cw_thread, cw_block, cw_grid) != 0u) && (f_line_parameter_less(v_leave, v_leave1, v_leave2, 1.0f, 0.0f, 0.0f, cw_thread, cw_block, cw_grid) != 0u)));
}
fn f_line_wide_diamond(cw_arg_ax: f32, cw_arg_ay: f32, cw_arg_dx: f32, cw_arg_dy: f32, cw_arg_width: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var v_ax: f32 = cw_arg_ax;
  var v_ay: f32 = cw_arg_ay;
  var v_dx: f32 = cw_arg_dx;
  var v_dy: f32 = cw_arg_dy;
  var v_width: f32 = cw_arg_width;
  if ((v_width == 1.0f)) {
    return f_line_diamond_exit(v_ax, v_ay, v_dx, v_dy, cw_thread, cw_block, cw_grid);
  }
  var cw_tmp_13: u32;
  if ((abs(v_dx) >= abs(v_dy))) {
    cw_tmp_13 = 1u;
  } else {
    cw_tmp_13 = 0u;
  }
  var v_xMajor: u32 = cw_tmp_13;
  var v_shift: f32 = ((v_width - 1.0f) * 0.5f);
  var cw_tmp_14: f32;
  if ((v_xMajor == 0u)) {
    cw_tmp_14 = v_shift;
  } else {
    cw_tmp_14 = 0.0f;
  }
  var v_baseX: f32 = (v_ax - cw_tmp_14);
  var cw_tmp_15: f32;
  if ((v_xMajor != 0u)) {
    cw_tmp_15 = v_shift;
  } else {
    cw_tmp_15 = 0.0f;
  }
  var v_baseY: f32 = (v_ay + cw_tmp_15);
  var cw_tmp_16: f32;
  if ((v_xMajor != 0u)) {
    cw_tmp_16 = (v_baseY - cw_divide_f32((v_baseX * v_dy), v_dx));
  } else {
    cw_tmp_16 = (-(v_baseX - cw_divide_f32((v_baseY * v_dx), v_dy)));
  }
  var v_expected: f32 = cw_tmp_16;
  var v_nearest: f32 = floor(v_expected);
  {
    var v_candidate: u32 = 0u;
    loop {
      if (!(v_candidate < 3u)) { break; }
      var v_replica: f32 = ((v_nearest + f32(v_candidate)) - 1.0f);
      if (((v_replica < 0.0f) || (v_replica >= v_width))) {
        continue;
      }
      var cw_tmp_17: f32;
      if ((v_xMajor == 0u)) {
        cw_tmp_17 = v_replica;
      } else {
        cw_tmp_17 = 0.0f;
      }
      var v_x: f32 = (v_baseX + cw_tmp_17);
      var cw_tmp_18: f32;
      if ((v_xMajor != 0u)) {
        cw_tmp_18 = v_replica;
      } else {
        cw_tmp_18 = 0.0f;
      }
      var v_y: f32 = (v_baseY - cw_tmp_18);
      if ((f_line_diamond_exit(v_x, v_y, v_dx, v_dy, cw_thread, cw_block, cw_grid) != 0u)) {
        return 1u;
      }
      continuing {
        v_candidate += u32(1);
      }
    }
  }
  return 0u;
}
fn f_line_rectangle_coverage(cw_arg_ax: f32, cw_arg_ay: f32, cw_arg_dx: f32, cw_arg_dy: f32, cw_arg_width: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_ax: f32 = cw_arg_ax;
  var v_ay: f32 = cw_arg_ay;
  var v_dx: f32 = cw_arg_dx;
  var v_dy: f32 = cw_arg_dy;
  var v_width: f32 = cw_arg_width;
  var v_length: f32 = sqrt(((v_dx * v_dx) + (v_dy * v_dy)));
  if (((v_length <= 0.0f) || (v_width <= 0.0f))) {
    return 0.0f;
  }
  var v_nx: f32 = ((cw_divide_f32((-v_dy), v_length) * v_width) * 0.5f);
  var v_ny: f32 = ((cw_divide_f32(v_dx, v_length) * v_width) * 0.5f);
  var v_polygon: array<f32, 40>;
  var v_next: array<f32, 40>;
  v_polygon[0i] = (v_ax + v_nx);
  v_polygon[1i] = (v_ay + v_ny);
  v_polygon[2i] = ((v_ax + v_dx) + v_nx);
  v_polygon[3i] = ((v_ay + v_dy) + v_ny);
  v_polygon[4i] = ((v_ax + v_dx) - v_nx);
  v_polygon[5i] = ((v_ay + v_dy) - v_ny);
  v_polygon[6i] = (v_ax - v_nx);
  v_polygon[7i] = (v_ay - v_ny);
  var v_count: u32 = 4u;
  {
    var v_plane: u32 = 0u;
    loop {
      if (!(v_plane < 4u)) { break; }
      if ((v_count < 3u)) {
        return 0.0f;
      }
      var v_axis: u32 = (v_plane / 2u);
      var v_out: u32 = 0u;
      var cw_tmp_19: f32;
      if (((v_plane % 2u) == 0u)) {
        cw_tmp_19 = 1.0f;
      } else {
        cw_tmp_19 = (-1.0f);
      }
      var v_sign: f32 = cw_tmp_19;
      {
        var v_i: u32 = 0u;
        loop {
          if (!(v_i < v_count)) { break; }
          var cw_tmp_20: u32;
          if ((v_i == 0u)) {
            cw_tmp_20 = (v_count - 1u);
          } else {
            cw_tmp_20 = (v_i - 1u);
          }
          var v_previous: u32 = cw_tmp_20;
          var v_d0: f32 = (0.5f + (v_sign * v_polygon[((v_previous * 2u) + v_axis)]));
          var v_d1: f32 = (0.5f + (v_sign * v_polygon[((v_i * 2u) + v_axis)]));
          if (((((v_d0 >= 0.0f) != (v_d1 >= 0.0f)) && (v_d0 != 0.0f)) && (v_d1 != 0.0f))) {
            var v_t: f32 = cw_divide_f32(v_d0, (v_d0 - v_d1));
            {
              var v_k: u32 = 0u;
              loop {
                if (!(v_k < 2u)) { break; }
                v_next[((v_out * 2u) + v_k)] = (v_polygon[((v_previous * 2u) + v_k)] + (v_t * (v_polygon[((v_i * 2u) + v_k)] - v_polygon[((v_previous * 2u) + v_k)])));
                continuing {
                  v_k += u32(1);
                }
              }
            }
            v_out += u32(1);
          }
          if ((v_d1 >= 0.0f)) {
            v_next[(v_out * 2u)] = v_polygon[(v_i * 2u)];
            v_next[((v_out * 2u) + 1u)] = v_polygon[((v_i * 2u) + 1u)];
            v_out += u32(1);
          }
          continuing {
            v_i += u32(1);
          }
        }
      }
      v_count = v_out;
      {
        var v_i: u32 = 0u;
        loop {
          if (!(v_i < (v_count * 2u))) { break; }
          v_polygon[v_i] = v_next[v_i];
          continuing {
            v_i += u32(1);
          }
        }
      }
      continuing {
        v_plane += u32(1);
      }
    }
  }
  var v_area: f32 = 0.0f;
  {
    var v_i: u32 = 0u;
    loop {
      if (!(v_i < v_count)) { break; }
      var cw_tmp_21: u32;
      if (((v_i + 1u) == v_count)) {
        cw_tmp_21 = 0u;
      } else {
        cw_tmp_21 = (v_i + 1u);
      }
      var v_nextIndex: u32 = cw_tmp_21;
      v_area = (v_area + ((v_polygon[(v_i * 2u)] * v_polygon[((v_nextIndex * 2u) + 1u)]) - (v_polygon[((v_i * 2u) + 1u)] * v_polygon[(v_nextIndex * 2u)])));
      continuing {
        v_i += u32(1);
      }
    }
  }
  return min(1.0f, (abs(v_area) * 0.5f));
}
fn f_compare_value(cw_arg_a: f32, cw_arg_b: f32, cw_arg_function: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var v_a: f32 = cw_arg_a;
  var v_b: f32 = cw_arg_b;
  var v_function: u32 = cw_arg_function;
  if ((v_function == u32(0i))) {
    return u32(0i);
  }
  if ((v_function == u32(1i))) {
    return select(u32(0), u32(1), (v_a < v_b));
  }
  if ((v_function == u32(2i))) {
    return select(u32(0), u32(1), (v_a == v_b));
  }
  if ((v_function == u32(3i))) {
    return select(u32(0), u32(1), (v_a <= v_b));
  }
  if ((v_function == u32(4i))) {
    return select(u32(0), u32(1), (v_a > v_b));
  }
  if ((v_function == u32(5i))) {
    return select(u32(0), u32(1), (v_a != v_b));
  }
  if ((v_function == u32(6i))) {
    return select(u32(0), u32(1), (v_a >= v_b));
  }
  return u32(1i);
}
fn f_blend_factor(cw_arg_factor: u32, cw_arg_source: f32, cw_arg_dest: f32, cw_arg_sa: f32, cw_arg_da: f32, cw_arg_channel: u32, cw_arg_constant: f32, cw_arg_constantAlpha: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_factor: u32 = cw_arg_factor;
  var v_source: f32 = cw_arg_source;
  var v_dest: f32 = cw_arg_dest;
  var v_sa: f32 = cw_arg_sa;
  var v_da: f32 = cw_arg_da;
  var v_channel: u32 = cw_arg_channel;
  var v_constant: f32 = cw_arg_constant;
  var v_constantAlpha: f32 = cw_arg_constantAlpha;
  if ((v_factor == u32(0i))) {
    return 0.0f;
  }
  if ((v_factor == u32(1i))) {
    return 1.0f;
  }
  if ((v_factor == u32(2i))) {
    return v_source;
  }
  if ((v_factor == u32(3i))) {
    return (1.0f - v_source);
  }
  if ((v_factor == u32(4i))) {
    return v_sa;
  }
  if ((v_factor == u32(5i))) {
    return (1.0f - v_sa);
  }
  if ((v_factor == u32(6i))) {
    return v_da;
  }
  if ((v_factor == u32(7i))) {
    return (1.0f - v_da);
  }
  if ((v_factor == u32(8i))) {
    return v_dest;
  }
  if ((v_factor == u32(9i))) {
    return (1.0f - v_dest);
  }
  if ((v_factor == u32(11i))) {
    return v_constant;
  }
  if ((v_factor == u32(12i))) {
    return (1.0f - v_constant);
  }
  if ((v_factor == u32(13i))) {
    return v_constantAlpha;
  }
  if ((v_factor == u32(14i))) {
    return (1.0f - v_constantAlpha);
  }
  var cw_tmp_22: f32;
  if ((v_channel == u32(3i))) {
    cw_tmp_22 = 1.0f;
  } else {
    cw_tmp_22 = min(v_sa, (1.0f - v_da));
  }
  return cw_tmp_22;
}
fn f_blend_value(cw_arg_source: f32, cw_arg_dest: f32, cw_arg_sf: f32, cw_arg_df: f32, cw_arg_equation: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_source: f32 = cw_arg_source;
  var v_dest: f32 = cw_arg_dest;
  var v_sf: f32 = cw_arg_sf;
  var v_df: f32 = cw_arg_df;
  var v_equation: u32 = cw_arg_equation;
  if ((v_equation == u32(3i))) {
    return min(v_source, v_dest);
  }
  if ((v_equation == u32(4i))) {
    return max(v_source, v_dest);
  }
  if ((v_equation == u32(1i))) {
    return ((v_source * v_sf) - (v_dest * v_df));
  }
  if ((v_equation == u32(2i))) {
    return ((v_dest * v_df) - (v_source * v_sf));
  }
  return ((v_source * v_sf) + (v_dest * v_df));
}
fn f_clamp_blend_component(cw_arg_value: f32, cw_arg_storage: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_value: f32 = cw_arg_value;
  var v_storage: u32 = cw_arg_storage;
  if (((v_storage == 1u) || (v_storage == 2u))) {
    return v_value;
  }
  var cw_tmp_23: f32;
  if (((v_storage == 5u) || (v_storage == 6u))) {
    cw_tmp_23 = (-1.0f);
  } else {
    cw_tmp_23 = 0.0f;
  }
  return min(1.0f, max(cw_tmp_23, v_value));
}
fn f_texture_environment(cw_arg_primary: f32, cw_arg_texture: f32, cw_arg_texture_alpha: f32, cw_arg_constant: f32, cw_arg_mode: u32, cw_arg_format: u32, cw_arg_channel: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_primary: f32 = cw_arg_primary;
  var v_texture: f32 = cw_arg_texture;
  var v_texture_alpha: f32 = cw_arg_texture_alpha;
  var v_constant: f32 = cw_arg_constant;
  var v_mode: u32 = cw_arg_mode;
  var v_format: u32 = cw_arg_format;
  var v_channel: u32 = cw_arg_channel;
  if ((((v_channel == 3u) && (v_format == 1u)) || ((v_channel < 3u) && (v_format == 2u)))) {
    return v_primary;
  }
  if ((v_mode == 1u)) {
    return v_texture;
  }
  if ((v_mode == 2u)) {
    if ((v_channel == 3u)) {
      return v_primary;
    }
    var cw_tmp_24: f32;
    if ((v_format == 1u)) {
      cw_tmp_24 = v_texture;
    } else {
      cw_tmp_24 = ((v_primary * (1.0f - v_texture_alpha)) + (v_texture * v_texture_alpha));
    }
    return cw_tmp_24;
  }
  if (((v_mode == 3u) && ((v_channel < 3u) || (v_format == 3u)))) {
    return ((v_primary * (1.0f - v_texture)) + (v_constant * v_texture));
  }
  if (((v_mode == 4u) && ((v_channel < 3u) || (v_format == 3u)))) {
    return (v_primary + v_texture);
  }
  return (v_primary * v_texture);
}
fn f_combine_texture_arguments(cw_arg_a: f32, cw_arg_b: f32, cw_arg_c: f32, cw_arg_operation: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_a: f32 = cw_arg_a;
  var v_b: f32 = cw_arg_b;
  var v_c: f32 = cw_arg_c;
  var v_operation: u32 = cw_arg_operation;
  if ((v_operation == 0u)) {
    return v_a;
  }
  if ((v_operation == 1u)) {
    return (v_a * v_b);
  }
  if ((v_operation == 2u)) {
    return (v_a + v_b);
  }
  if ((v_operation == 3u)) {
    return ((v_a + v_b) - 0.5f);
  }
  if ((v_operation == 4u)) {
    return ((v_a * v_c) + (v_b * (1.0f - v_c)));
  }
  return (v_a - v_b);
}
fn f_color_logic(cw_arg_source: u32, cw_arg_dest: u32, cw_arg_operation: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var v_source: u32 = cw_arg_source;
  var v_dest: u32 = cw_arg_dest;
  var v_operation: u32 = cw_arg_operation;
  if ((v_operation == 0u)) {
    return 0u;
  }
  if ((v_operation == 1u)) {
    return (v_source & v_dest);
  }
  if ((v_operation == 2u)) {
    return (v_source & (~v_dest));
  }
  if ((v_operation == 3u)) {
    return v_source;
  }
  if ((v_operation == 4u)) {
    return ((~v_source) & v_dest);
  }
  if ((v_operation == 5u)) {
    return v_dest;
  }
  if ((v_operation == 6u)) {
    return (v_source ^ v_dest);
  }
  if ((v_operation == 7u)) {
    return (v_source | v_dest);
  }
  if ((v_operation == 8u)) {
    return (~(v_source | v_dest));
  }
  if ((v_operation == 9u)) {
    return (~(v_source ^ v_dest));
  }
  if ((v_operation == 10u)) {
    return (~v_dest);
  }
  if ((v_operation == 11u)) {
    return (v_source | (~v_dest));
  }
  if ((v_operation == 12u)) {
    return (~v_source);
  }
  if ((v_operation == 13u)) {
    return ((~v_source) | v_dest);
  }
  if ((v_operation == 14u)) {
    return (~(v_source & v_dest));
  }
  return 4294967295u;
}
fn f_logic_unorm(cw_arg_source: f32, cw_arg_dest: f32, cw_arg_operation: u32, cw_arg_mask: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_source: f32 = cw_arg_source;
  var v_dest: f32 = cw_arg_dest;
  var v_operation: u32 = cw_arg_operation;
  var v_mask: u32 = cw_arg_mask;
  var v_s: u32 = u32(floor(((min(1.0f, max(0.0f, v_source)) * f32(v_mask)) + 0.5f)));
  var v_d: u32 = u32(floor(((min(1.0f, max(0.0f, v_dest)) * f32(v_mask)) + 0.5f)));
  return cw_divide_f32(f32((f_color_logic(v_s, v_d, v_operation, cw_thread, cw_block, cw_grid) & v_mask)), f32(v_mask));
}
fn f_texture_coord(cw_arg_x: i32, cw_arg_size: i32, cw_arg_repeat: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> i32 {
  var v_x: i32 = cw_arg_x;
  var v_size: i32 = cw_arg_size;
  var v_repeat: u32 = cw_arg_repeat;
  if ((v_repeat != u32(0i))) {
    return (((v_x % v_size) + v_size) % v_size);
  }
  var cw_tmp_26: i32;
  if ((v_x < 0i)) {
    cw_tmp_26 = 0i;
  } else {
    var cw_tmp_25: i32;
    if ((v_x >= v_size)) {
      cw_tmp_25 = (v_size - 1i);
    } else {
      cw_tmp_25 = v_x;
    }
    cw_tmp_26 = cw_tmp_25;
  }
  return cw_tmp_26;
}
fn f_sampler_index(cw_arg_i: i32, cw_arg_size: i32, cw_arg_wrap: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> i32 {
  var v_i: i32 = cw_arg_i;
  var v_size: i32 = cw_arg_size;
  var v_wrap: u32 = cw_arg_wrap;
  if ((v_wrap == u32(1i))) {
    return (((v_i % v_size) + v_size) % v_size);
  }
  if ((v_wrap == u32(2i))) {
    var v_p: i32 = (((v_i % (v_size * 2i)) + (v_size * 2i)) % (v_size * 2i));
    var cw_tmp_27: i32;
    if ((v_p < v_size)) {
      cw_tmp_27 = v_p;
    } else {
      cw_tmp_27 = (((v_size * 2i) - 1i) - v_p);
    }
    return cw_tmp_27;
  }
  var cw_tmp_29: i32;
  if ((v_i < 0i)) {
    cw_tmp_29 = 0i;
  } else {
    var cw_tmp_28: i32;
    if ((v_i >= v_size)) {
      cw_tmp_28 = (v_size - 1i);
    } else {
      cw_tmp_28 = v_i;
    }
    cw_tmp_29 = cw_tmp_28;
  }
  return cw_tmp_29;
}
fn f_water_unit(cw_arg_x: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_x: f32 = cw_arg_x;
  return min(1.0f, max(0.0f, v_x));
}
fn f_water_smooth(cw_arg_a: f32, cw_arg_b: f32, cw_arg_x: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_a: f32 = cw_arg_a;
  var v_b: f32 = cw_arg_b;
  var v_x: f32 = cw_arg_x;
  var v_t: f32 = f_water_unit(cw_divide_f32((v_x - v_a), (v_b - v_a)), cw_thread, cw_block, cw_grid);
  return ((v_t * v_t) * (3.0f - (2.0f * v_t)));
}
fn f_water_depth(cw_arg_depth: f32, cw_arg_near: f32, cw_arg_far: f32, cw_arg_reverse: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_depth: f32 = cw_arg_depth;
  var v_near: f32 = cw_arg_near;
  var v_far: f32 = cw_arg_far;
  var v_reverse: u32 = cw_arg_reverse;
  if ((v_reverse != u32(0i))) {
    v_depth = (1.0f - v_depth);
  }
  return cw_divide_f32((v_near * v_far), max(0.000001f, (v_far - (v_depth * (v_far - v_near)))));
}
fn f_water_fract(cw_arg_x: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_x: f32 = cw_arg_x;
  return (v_x - floor(v_x));
}
fn f_water_scramble(cw_arg_x: f32, cw_arg_power: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_x: f32 = cw_arg_x;
  var v_power: f32 = cw_arg_power;
  return f_water_fract(f_render_power(((f_water_fract(v_x, cw_thread, cw_block, cw_grid) * 3.0f) + 1.0f), v_power, cw_thread, cw_block, cw_grid), cw_thread, cw_block, cw_grid);
}
fn f_water_blip(cw_arg_x: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_x: f32 = cw_arg_x;
  var v_n: f32 = max(0.0f, (1.0f - (v_x * v_x)));
  return ((v_n * v_n) * v_n);
}
fn f_raster_pixel_index(cw_arg_invocation: u32, cw_arg_width: u32, cw_arg_height: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var v_invocation: u32 = cw_arg_invocation;
  var v_width: u32 = cw_arg_width;
  var v_height: u32 = cw_arg_height;
  var v_yBase: u32 = ((v_invocation / (v_width * 16u)) * 16u);
  var cw_tmp_30: u32;
  if (((v_height - v_yBase) < 16u)) {
    cw_tmp_30 = (v_height - v_yBase);
  } else {
    cw_tmp_30 = 16u;
  }
  var v_tileHeight: u32 = cw_tmp_30;
  var v_inRow: u32 = (v_invocation - (v_yBase * v_width));
  var v_column: u32 = (v_inRow / (v_tileHeight * 16u));
  var v_xBase: u32 = (v_column * 16u);
  var cw_tmp_31: u32;
  if (((v_width - v_xBase) < 16u)) {
    cw_tmp_31 = (v_width - v_xBase);
  } else {
    cw_tmp_31 = 16u;
  }
  var v_tileWidth: u32 = cw_tmp_31;
  var v_within: u32 = (v_inRow - ((v_column * v_tileHeight) * 16u));
  var v_x: u32 = (v_xBase + (v_within % v_tileWidth));
  var v_y: u32 = (v_yBase + (v_within / v_tileWidth));
  return ((v_y * v_width) + v_x);
}
fn f_cw_buffer_helper_0(cw_buffer_arg_0: i32, cw_arg_base: u32, cw_arg_width: u32, cw_arg_height: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_ux: f32, cw_arg_vx: f32, cw_arg_uy: f32, cw_arg_vy: f32, cw_arg_sampler: u32, cw_arg_channel: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_base: u32 = cw_arg_base;
  var v_width: u32 = cw_arg_width;
  var v_height: u32 = cw_arg_height;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_ux: f32 = cw_arg_ux;
  var v_vx: f32 = cw_arg_vx;
  var v_uy: f32 = cw_arg_uy;
  var v_vy: f32 = cw_arg_vy;
  var v_sampler: u32 = cw_arg_sampler;
  var v_channel: u32 = cw_arg_channel;
  var v_isotropic: f32 = (0.5f * log2(max(1e-8f, max(((v_ux * v_ux) + (v_vx * v_vx)), ((v_uy * v_uy) + (v_vy * v_vy))))));
  var v_maximum: f32 = 1.0f;
  if (((v_sampler & 536870912u) != 0u)) {
    let cw_argument_index_389 = (cw_buffer_offset_0 + i32((v_base + 9u)));
    v_maximum = min(16.0f, bitcast<f32>(b_texels[cw_argument_index_389]));
  }
  if ((v_maximum <= 1.0f)) {
    return f_cw_buffer_helper_2((cw_buffer_offset_0 + 0i), v_base, v_width, v_height, v_u, v_v, v_isotropic, v_sampler, v_channel, cw_thread, cw_block, cw_grid);
  }
  var v_xx: f32 = ((v_ux * v_ux) + (v_uy * v_uy));
  var v_yy: f32 = ((v_vx * v_vx) + (v_vy * v_vy));
  var v_xy: f32 = ((v_ux * v_vx) + (v_uy * v_vy));
  var v_difference: f32 = (v_xx - v_yy);
  var v_discriminant: f32 = sqrt(max(0.0f, ((v_difference * v_difference) + ((4.0f * v_xy) * v_xy))));
  var v_majorSquared: f32 = max(1e-8f, (((v_xx + v_yy) + v_discriminant) * 0.5f));
  var v_major: f32 = sqrt(v_majorSquared);
  var v_minor: f32 = sqrt(max(1e-8f, (((v_xx + v_yy) - v_discriminant) * 0.5f)));
  if ((v_major <= 1.0f)) {
    return f_cw_buffer_helper_2((cw_buffer_offset_0 + 0i), v_base, v_width, v_height, v_u, v_v, v_isotropic, v_sampler, v_channel, cw_thread, cw_block, cw_grid);
  }
  var v_ratio: f32 = min(v_maximum, cw_divide_f32(v_major, max(1.0f, v_minor)));
  var v_taps: u32 = u32(ceil(max(1.0f, v_ratio)));
  if ((v_taps <= 1u)) {
    return f_cw_buffer_helper_2((cw_buffer_offset_0 + 0i), v_base, v_width, v_height, v_u, v_v, v_isotropic, v_sampler, v_channel, cw_thread, cw_block, cw_grid);
  }
  var cw_tmp_390: f32;
  if ((v_xx >= v_yy)) {
    cw_tmp_390 = 1.0f;
  } else {
    cw_tmp_390 = 0.0f;
  }
  var v_axisU: f32 = cw_tmp_390;
  var cw_tmp_391: f32;
  if ((v_xx >= v_yy)) {
    cw_tmp_391 = 0.0f;
  } else {
    cw_tmp_391 = 1.0f;
  }
  var v_axisV: f32 = cw_tmp_391;
  if ((abs(v_xy) > 1e-8f)) {
    var cw_tmp_392: f32;
    if ((v_xx >= v_yy)) {
      cw_tmp_392 = (v_majorSquared - v_yy);
    } else {
      cw_tmp_392 = v_xy;
    }
    v_axisU = cw_tmp_392;
    var cw_tmp_393: f32;
    if ((v_xx >= v_yy)) {
      cw_tmp_393 = v_xy;
    } else {
      cw_tmp_393 = (v_majorSquared - v_xx);
    }
    v_axisV = cw_tmp_393;
    var v_length: f32 = sqrt(max(1e-12f, ((v_axisU * v_axisU) + (v_axisV * v_axisV))));
    v_axisU = cw_divide_f32(v_axisU, v_length);
    v_axisV = cw_divide_f32(v_axisV, v_length);
  }
  var v_lod: f32 = log2(max(v_minor, cw_divide_f32(v_major, v_maximum)));
  var v_result: f32 = 0.0f;
  {
    var v_tap: u32 = u32(0i);
    loop {
      if (!(v_tap < v_taps)) { break; }
      var v_offset: f32 = (cw_divide_f32((f32(v_tap) + 0.5f), f32(v_taps)) - 0.5f);
      v_result = (v_result + f_cw_buffer_helper_2((cw_buffer_offset_0 + 0i), v_base, v_width, v_height, (v_u + cw_divide_f32(((v_axisU * v_major) * v_offset), f32(v_width))), (v_v + cw_divide_f32(((v_axisV * v_major) * v_offset), f32(v_height))), v_lod, v_sampler, v_channel, cw_thread, cw_block, cw_grid));
      continuing {
        v_tap += u32(1);
      }
    }
  }
  return cw_divide_f32(v_result, f32(v_taps));
}
fn f_cw_buffer_helper_1(cw_buffer_arg_0: i32, cw_arg_base: u32, cw_arg_width: u32, cw_arg_height: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_flags: u32, cw_arg_channel: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_base: u32 = cw_arg_base;
  var v_width: u32 = cw_arg_width;
  var v_height: u32 = cw_arg_height;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_flags: u32 = cw_arg_flags;
  var v_channel: u32 = cw_arg_channel;
  if (((v_width == u32(0i)) || (v_height == u32(0i)))) {
    return 1.0f;
  }
  var cw_tmp_394: f32;
  if (((v_flags & u32(16i)) != u32(0i))) {
    cw_tmp_394 = (v_u - floor(v_u));
  } else {
    cw_tmp_394 = min(1.0f, max(0.0f, v_u));
  }
  v_u = cw_tmp_394;
  var cw_tmp_395: f32;
  if (((v_flags & u32(16i)) != u32(0i))) {
    cw_tmp_395 = (v_v - floor(v_v));
  } else {
    cw_tmp_395 = min(1.0f, max(0.0f, v_v));
  }
  v_v = cw_tmp_395;
  var v_x: f32 = (v_u * f32(v_width));
  var v_y: f32 = (v_v * f32(v_height));
  if (((v_flags & u32(32i)) == u32(0i))) {
    var v_ix: u32 = u32(f_texture_coord(i32(floor(v_x)), i32(v_width), (v_flags & u32(16i)), cw_thread, cw_block, cw_grid));
    var v_iy: u32 = u32(f_texture_coord(i32(floor(v_y)), i32(v_height), (v_flags & u32(16i)), cw_thread, cw_block, cw_grid));
    return cw_divide_f32(f32(((b_texels[(cw_buffer_offset_0 + i32(((v_base + (v_iy * v_width)) + v_ix)))] >> (v_channel * u32(8i))) & u32(255i))), 255.0f);
  }
  v_x = (v_x - 0.5f);
  v_y = (v_y - 0.5f);
  var v_x0: i32 = i32(floor(v_x));
  var v_y0: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - floor(v_x));
  var v_fy: f32 = (v_y - floor(v_y));
  var v_result: f32 = 0.0f;
  {
    var v_row: i32 = 0i;
    loop {
      if (!(v_row < 2i)) { break; }
      {
        var v_col: i32 = 0i;
        loop {
          if (!(v_col < 2i)) { break; }
          var v_ix: u32 = u32(f_texture_coord((v_x0 + v_col), i32(v_width), (v_flags & u32(16i)), cw_thread, cw_block, cw_grid));
          var v_iy: u32 = u32(f_texture_coord((v_y0 + v_row), i32(v_height), (v_flags & u32(16i)), cw_thread, cw_block, cw_grid));
          var cw_tmp_396: f32;
          if ((v_col == 0i)) {
            cw_tmp_396 = (1.0f - v_fx);
          } else {
            cw_tmp_396 = v_fx;
          }
          var cw_tmp_397: f32;
          if ((v_row == 0i)) {
            cw_tmp_397 = (1.0f - v_fy);
          } else {
            cw_tmp_397 = v_fy;
          }
          var v_weight: f32 = (cw_tmp_396 * cw_tmp_397);
          v_result = (v_result + cw_divide_f32((v_weight * f32(((b_texels[(cw_buffer_offset_0 + i32(((v_base + (v_iy * v_width)) + v_ix)))] >> (v_channel * u32(8i))) & u32(255i)))), 255.0f));
          continuing {
            v_col += i32(1);
          }
        }
      }
      continuing {
        v_row += i32(1);
      }
    }
  }
  return v_result;
}
fn f_cw_buffer_helper_2(cw_buffer_arg_0: i32, cw_arg_base: u32, cw_arg_width: u32, cw_arg_height: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_lod: f32, cw_arg_sampler: u32, cw_arg_channel: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_base: u32 = cw_arg_base;
  var v_width: u32 = cw_arg_width;
  var v_height: u32 = cw_arg_height;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_lod: f32 = cw_arg_lod;
  var v_sampler: u32 = cw_arg_sampler;
  var v_channel: u32 = cw_arg_channel;
  if (((v_sampler & 268435456u) != 0u)) {
    var v_selected: u32 = ((v_sampler >> (16u + (v_channel * 3u))) & 7u);
    if ((v_selected >= 4u)) {
      var cw_tmp_398: f32;
      if ((v_selected == 5u)) {
        cw_tmp_398 = 1.0f;
      } else {
        cw_tmp_398 = 0.0f;
      }
      return cw_tmp_398;
    }
    v_channel = v_selected;
  }
  if (((v_sampler & 536870912u) != 0u)) {
    let cw_argument_index_399 = (cw_buffer_offset_0 + i32((v_base + 6u)));
    var v_minimum: f32 = bitcast<f32>(b_texels[cw_argument_index_399]);
    let cw_argument_index_400 = (cw_buffer_offset_0 + i32((v_base + 7u)));
    var v_maximum: f32 = bitcast<f32>(b_texels[cw_argument_index_400]);
    let cw_argument_index_401 = (cw_buffer_offset_0 + i32((v_base + 8u)));
    var v_bias: f32 = min(16.0f, max((-16.0f), bitcast<f32>(b_texels[cw_argument_index_401])));
    v_lod = min(v_maximum, max(v_minimum, (v_lod + v_bias)));
  }
  var v_filter: u32 = ((v_sampler >> u32(5i)) & u32(7i));
  var v_last: u32 = (v_sampler & u32(31i));
  var v_magnification: u32 = ((v_sampler >> u32(8i)) & u32(1i));
  var cw_tmp_402: f32;
  if (((v_magnification != 0u) && ((v_filter == 2u) || (v_filter == 4u)))) {
    cw_tmp_402 = 0.5f;
  } else {
    cw_tmp_402 = 0.0f;
  }
  var v_crossover: f32 = cw_tmp_402;
  var v_linear: u32 = v_magnification;
  var v_low: u32 = 0u;
  var v_high: u32 = 0u;
  var v_samples: u32 = 1u;
  var v_fraction: f32 = 0.0f;
  if ((v_lod > v_crossover)) {
    v_linear = v_filter;
    if ((v_filter >= 2u)) {
      v_lod = min(f32(v_last), max(0.0f, v_lod));
      v_linear = (v_filter & 1u);
      v_low = u32(floor((v_lod + 0.5f)));
      if ((v_filter >= 4u)) {
        v_low = u32(floor(v_lod));
        var cw_tmp_403: u32;
        if ((v_low < v_last)) {
          cw_tmp_403 = (v_low + 1u);
        } else {
          cw_tmp_403 = v_low;
        }
        v_high = cw_tmp_403;
        v_fraction = (v_lod - f32(v_low));
        v_samples = 2u;
      }
    }
  }
  var v_result: f32 = 0.0f;
  {
    var v_sample: u32 = 0u;
    loop {
      if (!(v_sample < v_samples)) { break; }
      var cw_tmp_404: u32;
      if ((v_sample == 0u)) {
        cw_tmp_404 = v_low;
      } else {
        cw_tmp_404 = v_high;
      }
      var v_value: f32 = f_cw_buffer_helper_16((cw_buffer_offset_0 + 0i), v_base, v_width, v_height, v_u, v_v, v_sampler, v_channel, cw_tmp_404, v_linear, cw_thread, cw_block, cw_grid);
      if ((v_sample == 0u)) {
        v_result = v_value;
      } else {
        v_result = ((v_result * (1.0f - v_fraction)) + (v_value * v_fraction));
      }
      continuing {
        v_sample += u32(1);
      }
    }
  }
  return v_result;
}
fn f_cw_buffer_helper_3(cw_buffer_arg_0: i32, cw_buffer_arg_1: i32, cw_arg_descriptor: u32, cw_arg_va: u32, cw_arg_vb: u32, cw_arg_vc: u32, cw_arg_a: f32, cw_arg_b: f32, cw_arg_c: f32, cw_arg_dax: f32, cw_arg_dbx: f32, cw_arg_dcx: f32, cw_arg_day: f32, cw_arg_dby: f32, cw_arg_dcy: f32, cw_arg_inv: f32, cw_arg_channel: u32, cw_arg_spriteMask: u32, cw_arg_spriteU: f32, cw_arg_spriteV: f32, cw_arg_spriteDx: f32, cw_arg_spriteDy: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var cw_buffer_offset_1: i32 = cw_buffer_arg_1;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_va: u32 = cw_arg_va;
  var v_vb: u32 = cw_arg_vb;
  var v_vc: u32 = cw_arg_vc;
  var v_a: f32 = cw_arg_a;
  var v_b: f32 = cw_arg_b;
  var v_c: f32 = cw_arg_c;
  var v_dax: f32 = cw_arg_dax;
  var v_dbx: f32 = cw_arg_dbx;
  var v_dcx: f32 = cw_arg_dcx;
  var v_day: f32 = cw_arg_day;
  var v_dby: f32 = cw_arg_dby;
  var v_dcy: f32 = cw_arg_dcy;
  var v_inv: f32 = cw_arg_inv;
  var v_channel: u32 = cw_arg_channel;
  var v_spriteMask: u32 = cw_arg_spriteMask;
  var v_spriteU: f32 = cw_arg_spriteU;
  var v_spriteV: f32 = cw_arg_spriteV;
  var v_spriteDx: f32 = cw_arg_spriteDx;
  var v_spriteDy: f32 = cw_arg_spriteDy;
  var v_unit: u32 = b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 27u)))];
  var cw_tmp_405: u32;
  if ((v_unit == 0u)) {
    cw_tmp_405 = 16u;
  } else {
    cw_tmp_405 = (10u + ((v_unit - 1u) * 2u));
  }
  var v_coord: u32 = cw_tmp_405;
  if (((v_spriteMask & (1u << v_unit)) != 0u)) {
    let cw_argument_index_406 = (cw_buffer_offset_0 + i32(v_descriptor));
    let cw_argument_index_407 = (cw_buffer_offset_0 + i32((v_descriptor + 24u)));
    let cw_argument_index_408 = (cw_buffer_offset_0 + i32((v_descriptor + 25u)));
    let cw_argument_index_409 = (cw_buffer_offset_0 + i32((v_descriptor + 26u)));
    return f_cw_buffer_helper_0((cw_buffer_offset_0 + 0i), b_texels[cw_argument_index_406], b_texels[cw_argument_index_407], b_texels[cw_argument_index_408], v_spriteU, v_spriteV, (v_spriteDx * f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 24u)))])), 0.0f, 0.0f, (v_spriteDy * f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 25u)))])), b_texels[cw_argument_index_409], v_channel, cw_thread, cw_block, cw_grid);
  }
  var v_indices: array<u32, 3>;
  v_indices[0i] = v_va;
  v_indices[1i] = v_vb;
  v_indices[2i] = v_vc;
  var v_ss: array<f32, 3>;
  var v_ts: array<f32, 3>;
  var v_qs: array<f32, 3>;
  {
    var v_corner: u32 = u32(0i);
    loop {
      if (!(v_corner < u32(3i))) { break; }
      var v_u: f32 = b_attributes[(cw_buffer_offset_1 + i32(((v_indices[v_corner] * 34u) + v_coord)))];
      var v_v: f32 = b_attributes[(cw_buffer_offset_1 + i32((((v_indices[v_corner] * 34u) + v_coord) + 1u)))];
      var v_r: f32 = b_attributes[(cw_buffer_offset_1 + i32((((v_indices[v_corner] * 34u) + 26u) + (v_unit * 2u))))];
      var v_q: f32 = b_attributes[(cw_buffer_offset_1 + i32((((v_indices[v_corner] * 34u) + 27u) + (v_unit * 2u))))];
      let cw_argument_index_410 = (cw_buffer_offset_0 + i32((v_descriptor + 28u)));
      let cw_argument_index_411 = (cw_buffer_offset_0 + i32((v_descriptor + 32u)));
      let cw_argument_index_412 = (cw_buffer_offset_0 + i32((v_descriptor + 36u)));
      let cw_argument_index_413 = (cw_buffer_offset_0 + i32((v_descriptor + 40u)));
      v_ss[v_corner] = ((((bitcast<f32>(b_texels[cw_argument_index_410]) * v_u) + (bitcast<f32>(b_texels[cw_argument_index_411]) * v_v)) + (bitcast<f32>(b_texels[cw_argument_index_412]) * v_r)) + (bitcast<f32>(b_texels[cw_argument_index_413]) * v_q));
      let cw_argument_index_414 = (cw_buffer_offset_0 + i32((v_descriptor + 29u)));
      let cw_argument_index_415 = (cw_buffer_offset_0 + i32((v_descriptor + 33u)));
      let cw_argument_index_416 = (cw_buffer_offset_0 + i32((v_descriptor + 37u)));
      let cw_argument_index_417 = (cw_buffer_offset_0 + i32((v_descriptor + 41u)));
      v_ts[v_corner] = ((((bitcast<f32>(b_texels[cw_argument_index_414]) * v_u) + (bitcast<f32>(b_texels[cw_argument_index_415]) * v_v)) + (bitcast<f32>(b_texels[cw_argument_index_416]) * v_r)) + (bitcast<f32>(b_texels[cw_argument_index_417]) * v_q));
      let cw_argument_index_418 = (cw_buffer_offset_0 + i32((v_descriptor + 31u)));
      let cw_argument_index_419 = (cw_buffer_offset_0 + i32((v_descriptor + 35u)));
      let cw_argument_index_420 = (cw_buffer_offset_0 + i32((v_descriptor + 39u)));
      let cw_argument_index_421 = (cw_buffer_offset_0 + i32((v_descriptor + 43u)));
      v_qs[v_corner] = ((((bitcast<f32>(b_texels[cw_argument_index_418]) * v_u) + (bitcast<f32>(b_texels[cw_argument_index_419]) * v_v)) + (bitcast<f32>(b_texels[cw_argument_index_420]) * v_r)) + (bitcast<f32>(b_texels[cw_argument_index_421]) * v_q));
      continuing {
        v_corner += u32(1);
      }
    }
  }
  var v_ns: f32 = (((v_a * v_ss[0i]) + (v_b * v_ss[1i])) + (v_c * v_ss[2i]));
  var v_nt: f32 = (((v_a * v_ts[0i]) + (v_b * v_ts[1i])) + (v_c * v_ts[2i]));
  var v_q: f32 = (((v_a * v_qs[0i]) + (v_b * v_qs[1i])) + (v_c * v_qs[2i]));
  if ((abs(v_q) < 1e-12f)) {
    return 0.0f;
  }
  var v_u: f32 = cw_divide_f32(v_ns, v_q);
  var v_v: f32 = cw_divide_f32(v_nt, v_q);
  var v_qx: f32 = cw_divide_f32((((v_dax * (v_qs[0i] - v_q)) + (v_dbx * (v_qs[1i] - v_q))) + (v_dcx * (v_qs[2i] - v_q))), v_inv);
  var v_qy: f32 = cw_divide_f32((((v_day * (v_qs[0i] - v_q)) + (v_dby * (v_qs[1i] - v_q))) + (v_dcy * (v_qs[2i] - v_q))), v_inv);
  var v_sx: f32 = cw_divide_f32((((v_dax * (v_ss[0i] - v_ns)) + (v_dbx * (v_ss[1i] - v_ns))) + (v_dcx * (v_ss[2i] - v_ns))), v_inv);
  var v_sy: f32 = cw_divide_f32((((v_day * (v_ss[0i] - v_ns)) + (v_dby * (v_ss[1i] - v_ns))) + (v_dcy * (v_ss[2i] - v_ns))), v_inv);
  var v_tx: f32 = cw_divide_f32((((v_dax * (v_ts[0i] - v_nt)) + (v_dbx * (v_ts[1i] - v_nt))) + (v_dcx * (v_ts[2i] - v_nt))), v_inv);
  var v_ty: f32 = cw_divide_f32((((v_day * (v_ts[0i] - v_nt)) + (v_dby * (v_ts[1i] - v_nt))) + (v_dcy * (v_ts[2i] - v_nt))), v_inv);
  var v_width: f32 = f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 24u)))]);
  var v_height: f32 = f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 25u)))]);
  var v_ux: f32 = (cw_divide_f32((v_sx - (v_u * v_qx)), v_q) * v_width);
  var v_uy: f32 = (cw_divide_f32((v_sy - (v_u * v_qy)), v_q) * v_width);
  var v_vx: f32 = (cw_divide_f32((v_tx - (v_v * v_qx)), v_q) * v_height);
  var v_vy: f32 = (cw_divide_f32((v_ty - (v_v * v_qy)), v_q) * v_height);
  var v_lod: f32 = (0.5f * log2(max(1e-8f, max(((v_ux * v_ux) + (v_vx * v_vx)), ((v_uy * v_uy) + (v_vy * v_vy))))));
  let cw_argument_index_422 = (cw_buffer_offset_0 + i32(v_descriptor));
  let cw_argument_index_423 = (cw_buffer_offset_0 + i32((v_descriptor + 24u)));
  let cw_argument_index_424 = (cw_buffer_offset_0 + i32((v_descriptor + 25u)));
  let cw_argument_index_425 = (cw_buffer_offset_0 + i32((v_descriptor + 26u)));
  return f_cw_buffer_helper_0((cw_buffer_offset_0 + 0i), b_texels[cw_argument_index_422], b_texels[cw_argument_index_423], b_texels[cw_argument_index_424], v_u, v_v, v_ux, v_vx, v_uy, v_vy, b_texels[cw_argument_index_425], v_channel, cw_thread, cw_block, cw_grid);
}
fn f_cw_buffer_helper_4(cw_buffer_arg_0: i32, cw_buffer_arg_1: i32, cw_arg_descriptor: u32, cw_arg_va: u32, cw_arg_vb: u32, cw_arg_vc: u32, cw_arg_a: f32, cw_arg_b: f32, cw_arg_c: f32, cw_arg_dax: f32, cw_arg_dbx: f32, cw_arg_dcx: f32, cw_arg_day: f32, cw_arg_dby: f32, cw_arg_dcy: f32, cw_arg_inv: f32, cw_arg_axis: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var cw_buffer_offset_1: i32 = cw_buffer_arg_1;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_va: u32 = cw_arg_va;
  var v_vb: u32 = cw_arg_vb;
  var v_vc: u32 = cw_arg_vc;
  var v_a: f32 = cw_arg_a;
  var v_b: f32 = cw_arg_b;
  var v_c: f32 = cw_arg_c;
  var v_dax: f32 = cw_arg_dax;
  var v_dbx: f32 = cw_arg_dbx;
  var v_dcx: f32 = cw_arg_dcx;
  var v_day: f32 = cw_arg_day;
  var v_dby: f32 = cw_arg_dby;
  var v_dcy: f32 = cw_arg_dcy;
  var v_inv: f32 = cw_arg_inv;
  var v_axis: u32 = cw_arg_axis;
  var v_position: array<f32, 3>;
  var v_length: f32 = 0.0f;
  var v_projection: f32 = 0.0f;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_position[v_k] = (((v_a * b_attributes[(cw_buffer_offset_1 + i32(((v_va * u32(34i)) + v_k)))]) + (v_b * b_attributes[(cw_buffer_offset_1 + i32(((v_vb * u32(34i)) + v_k)))])) + (v_c * b_attributes[(cw_buffer_offset_1 + i32(((v_vc * u32(34i)) + v_k)))]));
      v_length = (v_length + (v_position[v_k] * v_position[v_k]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  v_length = sqrt(max(v_length, 1e-12f));
  var cw_tmp_426: i32;
  if ((v_axis == u32(0i))) {
    cw_tmp_426 = 6i;
  } else {
    cw_tmp_426 = 18i;
  }
  var v_column: u32 = u32(cw_tmp_426);
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_projection = (v_projection - (cw_divide_f32(v_position[v_k], v_length) * (((v_a * b_attributes[(cw_buffer_offset_1 + i32((((v_va * u32(34i)) + v_column) + v_k)))]) + (v_b * b_attributes[(cw_buffer_offset_1 + i32((((v_vb * u32(34i)) + v_column) + v_k)))])) + (v_c * b_attributes[(cw_buffer_offset_1 + i32((((v_vc * u32(34i)) + v_column) + v_k)))]))));
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_height: f32 = f_cw_buffer_helper_7((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_descriptor, v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i), cw_thread, cw_block, cw_grid);
  return (v_projection * ((v_height * 0.04f) - 0.02f));
}
fn f_cw_buffer_helper_5(cw_buffer_arg_0: i32, cw_buffer_arg_1: i32, cw_arg_descriptor: u32, cw_arg_va: u32, cw_arg_vb: u32, cw_arg_vc: u32, cw_arg_a: f32, cw_arg_b: f32, cw_arg_c: f32, cw_arg_dax: f32, cw_arg_dbx: f32, cw_arg_dcx: f32, cw_arg_day: f32, cw_arg_dby: f32, cw_arg_dcy: f32, cw_arg_inv: f32, cw_arg_channel: u32, cw_arg_offsetU: f32, cw_arg_offsetV: f32, cw_arg_offsetUx: f32, cw_arg_offsetVx: f32, cw_arg_offsetUy: f32, cw_arg_offsetVy: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var cw_buffer_offset_1: i32 = cw_buffer_arg_1;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_va: u32 = cw_arg_va;
  var v_vb: u32 = cw_arg_vb;
  var v_vc: u32 = cw_arg_vc;
  var v_a: f32 = cw_arg_a;
  var v_b: f32 = cw_arg_b;
  var v_c: f32 = cw_arg_c;
  var v_dax: f32 = cw_arg_dax;
  var v_dbx: f32 = cw_arg_dbx;
  var v_dcx: f32 = cw_arg_dcx;
  var v_day: f32 = cw_arg_day;
  var v_dby: f32 = cw_arg_dby;
  var v_dcy: f32 = cw_arg_dcy;
  var v_inv: f32 = cw_arg_inv;
  var v_channel: u32 = cw_arg_channel;
  var v_offsetU: f32 = cw_arg_offsetU;
  var v_offsetV: f32 = cw_arg_offsetV;
  var v_offsetUx: f32 = cw_arg_offsetUx;
  var v_offsetVx: f32 = cw_arg_offsetVx;
  var v_offsetUy: f32 = cw_arg_offsetUy;
  var v_offsetVy: f32 = cw_arg_offsetVy;
  var v_unit: u32 = b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(4i))))];
  var cw_tmp_427: u32;
  if ((v_unit == u32(0i))) {
    cw_tmp_427 = u32(16i);
  } else {
    cw_tmp_427 = (u32(10i) + ((v_unit - u32(1i)) * u32(2i)));
  }
  var v_coord: u32 = cw_tmp_427;
  var v_indices: array<u32, 3>;
  v_indices[0i] = v_va;
  v_indices[1i] = v_vb;
  v_indices[2i] = v_vc;
  var v_us: array<f32, 3>;
  var v_vs: array<f32, 3>;
  {
    var v_corner: u32 = u32(0i);
    loop {
      if (!(v_corner < u32(3i))) { break; }
      var v_u: f32 = b_attributes[(cw_buffer_offset_1 + i32(((v_indices[v_corner] * u32(34i)) + v_coord)))];
      var v_v: f32 = b_attributes[(cw_buffer_offset_1 + i32((((v_indices[v_corner] * u32(34i)) + v_coord) + u32(1i))))];
      let cw_argument_index_428 = (cw_buffer_offset_0 + i32((v_descriptor + u32(8i))));
      let cw_argument_index_429 = (cw_buffer_offset_0 + i32((v_descriptor + u32(12i))));
      let cw_argument_index_430 = (cw_buffer_offset_0 + i32((v_descriptor + u32(20i))));
      v_us[v_corner] = (((bitcast<f32>(b_texels[cw_argument_index_428]) * v_u) + (bitcast<f32>(b_texels[cw_argument_index_429]) * v_v)) + bitcast<f32>(b_texels[cw_argument_index_430]));
      let cw_argument_index_431 = (cw_buffer_offset_0 + i32((v_descriptor + u32(9i))));
      let cw_argument_index_432 = (cw_buffer_offset_0 + i32((v_descriptor + u32(13i))));
      let cw_argument_index_433 = (cw_buffer_offset_0 + i32((v_descriptor + u32(21i))));
      v_vs[v_corner] = (((bitcast<f32>(b_texels[cw_argument_index_431]) * v_u) + (bitcast<f32>(b_texels[cw_argument_index_432]) * v_v)) + bitcast<f32>(b_texels[cw_argument_index_433]));
      continuing {
        v_corner += u32(1);
      }
    }
  }
  var v_u: f32 = (((v_a * v_us[0i]) + (v_b * v_us[1i])) + (v_c * v_us[2i]));
  var v_v: f32 = (((v_a * v_vs[0i]) + (v_b * v_vs[1i])) + (v_c * v_vs[2i]));
  var cw_tmp_434: f32;
  if ((v_channel == u32(4i))) {
    cw_tmp_434 = 256.0f;
  } else {
    cw_tmp_434 = f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(1i))))]);
  }
  var v_w: f32 = cw_tmp_434;
  var cw_tmp_435: f32;
  if ((v_channel == u32(4i))) {
    cw_tmp_435 = 256.0f;
  } else {
    cw_tmp_435 = f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(2i))))]);
  }
  var v_h: f32 = cw_tmp_435;
  var v_ux: f32 = (cw_divide_f32((((v_dax * (v_us[0i] - v_u)) + (v_dbx * (v_us[1i] - v_u))) + (v_dcx * (v_us[2i] - v_u))), v_inv) * v_w);
  var v_vx: f32 = (cw_divide_f32((((v_dax * (v_vs[0i] - v_v)) + (v_dbx * (v_vs[1i] - v_v))) + (v_dcx * (v_vs[2i] - v_v))), v_inv) * v_h);
  var v_uy: f32 = (cw_divide_f32((((v_day * (v_us[0i] - v_u)) + (v_dby * (v_us[1i] - v_u))) + (v_dcy * (v_us[2i] - v_u))), v_inv) * v_w);
  var v_vy: f32 = (cw_divide_f32((((v_day * (v_vs[0i] - v_v)) + (v_dby * (v_vs[1i] - v_v))) + (v_dcy * (v_vs[2i] - v_v))), v_inv) * v_h);
  v_ux = (v_ux + (v_offsetUx * v_w));
  v_vx = (v_vx + (v_offsetVx * v_h));
  v_uy = (v_uy + (v_offsetUy * v_w));
  v_vy = (v_vy + (v_offsetVy * v_h));
  var v_lod: f32 = (0.5f * log2(max(1e-8f, max(((v_ux * v_ux) + (v_vx * v_vx)), ((v_uy * v_uy) + (v_vy * v_vy))))));
  if ((v_channel >= u32(4i))) {
    return max(v_lod, 0.0f);
  }
  let cw_argument_index_436 = (cw_buffer_offset_0 + i32(v_descriptor));
  let cw_argument_index_437 = (cw_buffer_offset_0 + i32((v_descriptor + u32(1i))));
  let cw_argument_index_438 = (cw_buffer_offset_0 + i32((v_descriptor + u32(2i))));
  let cw_argument_index_439 = (cw_buffer_offset_0 + i32((v_descriptor + u32(3i))));
  return f_cw_buffer_helper_0((cw_buffer_offset_0 + 0i), b_texels[cw_argument_index_436], b_texels[cw_argument_index_437], b_texels[cw_argument_index_438], (v_u + v_offsetU), (v_v + v_offsetV), v_ux, v_vx, v_uy, v_vy, b_texels[cw_argument_index_439], v_channel, cw_thread, cw_block, cw_grid);
}
fn f_cw_buffer_helper_6(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_reference: f32, cw_arg_ux: f32, cw_arg_vx: f32, cw_arg_uy: f32, cw_arg_vy: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_reference: f32 = cw_arg_reference;
  var v_ux: f32 = cw_arg_ux;
  var v_vx: f32 = cw_arg_vx;
  var v_uy: f32 = cw_arg_uy;
  var v_vy: f32 = cw_arg_vy;
  var v_base: u32 = b_texels[(cw_buffer_offset_0 + i32(v_descriptor))];
  var v_width: u32 = b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 1u)))];
  var v_height: u32 = b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 2u)))];
  var v_sampler: u32 = b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 3u)))];
  var v_isotropic: f32 = (0.5f * log2(max(1e-8f, max(((v_ux * v_ux) + (v_vx * v_vx)), ((v_uy * v_uy) + (v_vy * v_vy))))));
  var v_maximum: f32 = 1.0f;
  if (((v_sampler & 536870912u) != 0u)) {
    let cw_argument_index_440 = (cw_buffer_offset_0 + i32((v_base + 9u)));
    v_maximum = min(16.0f, bitcast<f32>(b_texels[cw_argument_index_440]));
  }
  if ((v_maximum <= 1.0f)) {
    return f_cw_buffer_helper_17((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, v_isotropic, cw_thread, cw_block, cw_grid);
  }
  var v_xx: f32 = ((v_ux * v_ux) + (v_uy * v_uy));
  var v_yy: f32 = ((v_vx * v_vx) + (v_vy * v_vy));
  var v_xy: f32 = ((v_ux * v_vx) + (v_uy * v_vy));
  var v_difference: f32 = (v_xx - v_yy);
  var v_discriminant: f32 = sqrt(max(0.0f, ((v_difference * v_difference) + ((4.0f * v_xy) * v_xy))));
  var v_majorSquared: f32 = max(1e-8f, (((v_xx + v_yy) + v_discriminant) * 0.5f));
  var v_major: f32 = sqrt(v_majorSquared);
  var v_minor: f32 = sqrt(max(1e-8f, (((v_xx + v_yy) - v_discriminant) * 0.5f)));
  if ((v_major <= 1.0f)) {
    return f_cw_buffer_helper_17((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, v_isotropic, cw_thread, cw_block, cw_grid);
  }
  var v_ratio: f32 = min(v_maximum, cw_divide_f32(v_major, max(1.0f, v_minor)));
  var v_taps: u32 = u32(ceil(max(1.0f, v_ratio)));
  if ((v_taps <= 1u)) {
    return f_cw_buffer_helper_17((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, v_isotropic, cw_thread, cw_block, cw_grid);
  }
  var cw_tmp_441: f32;
  if ((v_xx >= v_yy)) {
    cw_tmp_441 = 1.0f;
  } else {
    cw_tmp_441 = 0.0f;
  }
  var v_axisU: f32 = cw_tmp_441;
  var cw_tmp_442: f32;
  if ((v_xx >= v_yy)) {
    cw_tmp_442 = 0.0f;
  } else {
    cw_tmp_442 = 1.0f;
  }
  var v_axisV: f32 = cw_tmp_442;
  if ((abs(v_xy) > 1e-8f)) {
    var cw_tmp_443: f32;
    if ((v_xx >= v_yy)) {
      cw_tmp_443 = (v_majorSquared - v_yy);
    } else {
      cw_tmp_443 = v_xy;
    }
    v_axisU = cw_tmp_443;
    var cw_tmp_444: f32;
    if ((v_xx >= v_yy)) {
      cw_tmp_444 = v_xy;
    } else {
      cw_tmp_444 = (v_majorSquared - v_xx);
    }
    v_axisV = cw_tmp_444;
    var v_length: f32 = sqrt(max(1e-12f, ((v_axisU * v_axisU) + (v_axisV * v_axisV))));
    v_axisU = cw_divide_f32(v_axisU, v_length);
    v_axisV = cw_divide_f32(v_axisV, v_length);
  }
  var v_lod: f32 = log2(max(v_minor, cw_divide_f32(v_major, v_maximum)));
  var v_result: f32 = 0.0f;
  {
    var v_tap: u32 = u32(0i);
    loop {
      if (!(v_tap < v_taps)) { break; }
      var v_offset: f32 = (cw_divide_f32((f32(v_tap) + 0.5f), f32(v_taps)) - 0.5f);
      v_result = (v_result + f_cw_buffer_helper_17((cw_buffer_offset_0 + 0i), v_descriptor, (v_u + cw_divide_f32(((v_axisU * v_major) * v_offset), f32(v_width))), (v_v + cw_divide_f32(((v_axisV * v_major) * v_offset), f32(v_height))), v_reference, v_lod, cw_thread, cw_block, cw_grid));
      continuing {
        v_tap += u32(1);
      }
    }
  }
  return cw_divide_f32(v_result, f32(v_taps));
}
fn f_cw_buffer_helper_7(cw_buffer_arg_0: i32, cw_buffer_arg_1: i32, cw_arg_descriptor: u32, cw_arg_va: u32, cw_arg_vb: u32, cw_arg_vc: u32, cw_arg_a: f32, cw_arg_b: f32, cw_arg_c: f32, cw_arg_dax: f32, cw_arg_dbx: f32, cw_arg_dcx: f32, cw_arg_day: f32, cw_arg_dby: f32, cw_arg_dcy: f32, cw_arg_inv: f32, cw_arg_channel: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var cw_buffer_offset_1: i32 = cw_buffer_arg_1;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_va: u32 = cw_arg_va;
  var v_vb: u32 = cw_arg_vb;
  var v_vc: u32 = cw_arg_vc;
  var v_a: f32 = cw_arg_a;
  var v_b: f32 = cw_arg_b;
  var v_c: f32 = cw_arg_c;
  var v_dax: f32 = cw_arg_dax;
  var v_dbx: f32 = cw_arg_dbx;
  var v_dcx: f32 = cw_arg_dcx;
  var v_day: f32 = cw_arg_day;
  var v_dby: f32 = cw_arg_dby;
  var v_dcy: f32 = cw_arg_dcy;
  var v_inv: f32 = cw_arg_inv;
  var v_channel: u32 = cw_arg_channel;
  return f_cw_buffer_helper_5((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_descriptor, v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_channel, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, cw_thread, cw_block, cw_grid);
}
fn f_cw_buffer_helper_8(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_screen_x: f32, cw_arg_screen_y: f32, cw_arg_view_z: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_screen_x: f32 = cw_arg_screen_x;
  var v_screen_y: f32 = cw_arg_screen_y;
  var v_view_z: f32 = cw_arg_view_z;
  if ((v_descriptor == u32(0i))) {
    return 4294967295u;
  }
  let cw_argument_index_445 = (cw_buffer_offset_0 + i32((v_descriptor + u32(3i))));
  var v_near: f32 = bitcast<f32>(b_texels[cw_argument_index_445]);
  let cw_argument_index_446 = (cw_buffer_offset_0 + i32((v_descriptor + u32(4i))));
  var v_far: f32 = bitcast<f32>(b_texels[cw_argument_index_446]);
  var v_z: f32 = max(abs(v_view_z), 1e-12f);
  let cw_argument_index_447 = (cw_buffer_offset_0 + i32((v_descriptor + u32(5i))));
  var v_tx: f32 = (cw_divide_f32(v_screen_x, bitcast<f32>(b_texels[cw_argument_index_447])) * f32(b_texels[(cw_buffer_offset_0 + i32(v_descriptor))]));
  let cw_argument_index_448 = (cw_buffer_offset_0 + i32((v_descriptor + u32(6i))));
  var v_ty: f32 = (cw_divide_f32(v_screen_y, bitcast<f32>(b_texels[cw_argument_index_448])) * f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(1i))))]));
  var v_tz: f32 = (cw_divide_f32(log2(cw_divide_f32(v_z, v_near)), log2(cw_divide_f32(v_far, v_near))) * f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(2i))))]));
  if (((((((v_tx < 0.0f) || (v_ty < 0.0f)) || (v_tz < 0.0f)) || (v_tx >= f32(b_texels[(cw_buffer_offset_0 + i32(v_descriptor))]))) || (v_ty >= f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(1i))))]))) || (v_tz >= f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(2i))))])))) {
    return 4294967295u;
  }
  return ((u32(v_tx) + (u32(v_ty) * b_texels[(cw_buffer_offset_0 + i32(v_descriptor))])) + ((u32(v_tz) * b_texels[(cw_buffer_offset_0 + i32(v_descriptor))]) * b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(1i))))]));
}
fn f_cw_buffer_helper_9(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_cell: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_cell: u32 = cw_arg_cell;
  var cw_tmp_449: u32;
  if ((v_cell == 4294967295u)) {
    cw_tmp_449 = 0u;
  } else {
    cw_tmp_449 = b_texels[(cw_buffer_offset_0 + i32(((b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(8i))))] + (v_cell * u32(2i))) + u32(1i))))];
  }
  return cw_tmp_449;
}
fn f_cw_buffer_helper_10(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_cell: u32, cw_arg_ordinal: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_cell: u32 = cw_arg_cell;
  var v_ordinal: u32 = cw_arg_ordinal;
  var v_first: u32 = b_texels[(cw_buffer_offset_0 + i32((b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(8i))))] + (v_cell * u32(2i)))))];
  var v_index: u32 = b_texels[(cw_buffer_offset_0 + i32(((b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(9i))))] + v_first) + v_ordinal)))];
  return (b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(10i))))] + (v_index * u32(16i)));
}
fn f_cw_buffer_helper_11(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_view_z: f32, cw_arg_radius: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_view_z: f32 = cw_arg_view_z;
  var v_radius: f32 = cw_arg_radius;
  let cw_argument_index_450 = (cw_buffer_offset_0 + i32((v_descriptor + u32(4i))));
  var v_far: f32 = bitcast<f32>(b_texels[cw_argument_index_450]);
  var v_t: f32 = min(1.0f, max(0.0f, cw_divide_f32(((-v_view_z) - (v_far - v_radius)), max(v_radius, 1e-12f))));
  var v_fade: f32 = (1.0f - (v_t * v_t));
  return (v_fade * v_fade);
}
fn f_cw_buffer_helper_12(cw_buffer_arg_0: i32, cw_buffer_arg_1: i32, cw_arg_data: u32, cw_arg_va: u32, cw_arg_vb: u32, cw_arg_vc: u32, cw_arg_a: f32, cw_arg_b: f32, cw_arg_c: f32, cw_arg_dax: f32, cw_arg_dbx: f32, cw_arg_dcx: f32, cw_arg_day: f32, cw_arg_dby: f32, cw_arg_dcy: f32, cw_arg_inv: f32, cw_arg_axis: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var cw_buffer_offset_1: i32 = cw_buffer_arg_1;
  var v_data: u32 = cw_arg_data;
  var v_va: u32 = cw_arg_va;
  var v_vb: u32 = cw_arg_vb;
  var v_vc: u32 = cw_arg_vc;
  var v_a: f32 = cw_arg_a;
  var v_b: f32 = cw_arg_b;
  var v_c: f32 = cw_arg_c;
  var v_dax: f32 = cw_arg_dax;
  var v_dbx: f32 = cw_arg_dbx;
  var v_dcx: f32 = cw_arg_dcx;
  var v_day: f32 = cw_arg_day;
  var v_dby: f32 = cw_arg_dby;
  var v_dcy: f32 = cw_arg_dcy;
  var v_inv: f32 = cw_arg_inv;
  var v_axis: u32 = cw_arg_axis;
  var v_layers: u32 = b_texels[(cw_buffer_offset_0 + i32((v_data + u32(72i))))];
  var v_features: u32 = b_texels[(cw_buffer_offset_0 + i32((v_data + u32(4i))))];
  var v_mapped: u32 = select(u32(0), u32(1), ((v_layers & u32(16i)) != u32(0i)));
  var cw_tmp_451: f32;
  if ((v_mapped != u32(0i))) {
    cw_tmp_451 = 0.0f;
  } else {
    cw_tmp_451 = (((v_a * b_attributes[(cw_buffer_offset_1 + i32((((v_va * u32(34i)) + u32(21i)) + v_axis)))]) + (v_b * b_attributes[(cw_buffer_offset_1 + i32((((v_vb * u32(34i)) + u32(21i)) + v_axis)))])) + (v_c * b_attributes[(cw_buffer_offset_1 + i32((((v_vc * u32(34i)) + u32(21i)) + v_axis)))]));
  }
  var v_result: f32 = cw_tmp_451;
  {
    var v_corner: u32 = u32(0i);
    loop {
      var cw_tmp_452: i32;
      if ((v_mapped != u32(0i))) {
        cw_tmp_452 = 1i;
      } else {
        cw_tmp_452 = 0i;
      }
      if (!(v_corner < u32(cw_tmp_452))) { break; }
      var cw_tmp_454: f32;
      if ((v_mapped != u32(0i))) {
        cw_tmp_454 = v_a;
      } else {
        var cw_tmp_453: f32;
        if ((v_corner == u32(0i))) {
          cw_tmp_453 = 1.0f;
        } else {
          cw_tmp_453 = 0.0f;
        }
        cw_tmp_454 = cw_tmp_453;
      }
      var v_aa: f32 = cw_tmp_454;
      var cw_tmp_456: f32;
      if ((v_mapped != u32(0i))) {
        cw_tmp_456 = v_b;
      } else {
        var cw_tmp_455: f32;
        if ((v_corner == u32(1i))) {
          cw_tmp_455 = 1.0f;
        } else {
          cw_tmp_455 = 0.0f;
        }
        cw_tmp_456 = cw_tmp_455;
      }
      var v_bb: f32 = cw_tmp_456;
      var cw_tmp_458: f32;
      if ((v_mapped != u32(0i))) {
        cw_tmp_458 = v_c;
      } else {
        var cw_tmp_457: f32;
        if ((v_corner == u32(2i))) {
          cw_tmp_457 = 1.0f;
        } else {
          cw_tmp_457 = 0.0f;
        }
        cw_tmp_458 = cw_tmp_457;
      }
      var v_cc: f32 = cw_tmp_458;
      var v_p: array<f32, 3>;
      var v_n: array<f32, 3>;
      var v_pl: f32 = 0.0f;
      var v_nl: f32 = 0.0f;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          v_p[v_k] = (((v_aa * b_attributes[(cw_buffer_offset_1 + i32(((v_va * u32(34i)) + v_k)))]) + (v_bb * b_attributes[(cw_buffer_offset_1 + i32(((v_vb * u32(34i)) + v_k)))])) + (v_cc * b_attributes[(cw_buffer_offset_1 + i32(((v_vc * u32(34i)) + v_k)))]));
          v_n[v_k] = (((v_aa * b_attributes[(cw_buffer_offset_1 + i32((((v_va * u32(34i)) + u32(3i)) + v_k)))]) + (v_bb * b_attributes[(cw_buffer_offset_1 + i32((((v_vb * u32(34i)) + u32(3i)) + v_k)))])) + (v_cc * b_attributes[(cw_buffer_offset_1 + i32((((v_vc * u32(34i)) + u32(3i)) + v_k)))]));
          v_pl = (v_pl + (v_p[v_k] * v_p[v_k]));
          continuing {
            v_k += u32(1);
          }
        }
      }
      if ((v_mapped != u32(0i))) {
        var v_offsets: array<f32, 6>;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(6i))) { break; }
            v_offsets[v_k] = 0.0f;
            continuing {
              v_k += u32(1);
            }
          }
        }
        if (((v_features & u32(1536i)) != u32(0i))) {
          var cw_tmp_459: i32;
          if (((v_features & u32(512i)) != u32(0i))) {
            cw_tmp_459 = 176i;
          } else {
            cw_tmp_459 = 224i;
          }
          var v_heightMap: u32 = (v_data + u32(cw_tmp_459));
          var v_ix: f32 = max(1e-12f, (((v_inv + v_dax) + v_dbx) + v_dcx));
          var v_iy: f32 = max(1e-12f, (((v_inv + v_day) + v_dby) + v_dcy));
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(2i))) { break; }
              v_offsets[v_k] = f_cw_buffer_helper_4((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_heightMap, v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, cw_thread, cw_block, cw_grid);
              v_offsets[(v_k + u32(2i))] = (f_cw_buffer_helper_4((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_heightMap, v_va, v_vb, v_vc, cw_divide_f32(((v_a * v_inv) + v_dax), v_ix), cw_divide_f32(((v_b * v_inv) + v_dbx), v_ix), cw_divide_f32(((v_c * v_inv) + v_dcx), v_ix), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_ix, v_k, cw_thread, cw_block, cw_grid) - v_offsets[v_k]);
              v_offsets[(v_k + u32(4i))] = (f_cw_buffer_helper_4((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_heightMap, v_va, v_vb, v_vc, cw_divide_f32(((v_a * v_inv) + v_day), v_iy), cw_divide_f32(((v_b * v_inv) + v_dby), v_iy), cw_divide_f32(((v_c * v_inv) + v_dcy), v_iy), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_iy, v_k, cw_thread, cw_block, cw_grid) - v_offsets[v_k]);
              continuing {
                v_k += u32(1);
              }
            }
          }
        }
        var v_sample: array<f32, 3>;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            let cw_argument_index_460 = 0i;
            let cw_argument_index_461 = 1i;
            let cw_argument_index_462 = 2i;
            let cw_argument_index_463 = 3i;
            let cw_argument_index_464 = 4i;
            let cw_argument_index_465 = 5i;
            v_sample[v_k] = ((f_cw_buffer_helper_5((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(176i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, v_offsets[cw_argument_index_460], v_offsets[cw_argument_index_461], v_offsets[cw_argument_index_462], v_offsets[cw_argument_index_463], v_offsets[cw_argument_index_464], v_offsets[cw_argument_index_465], cw_thread, cw_block, cw_grid) * 2.0f) - 1.0f);
            continuing {
              v_k += u32(1);
            }
          }
        }
        if (((v_features & u32(256i)) != u32(0i))) {
          v_sample[2i] = sqrt(max(0.0f, ((1.0f - (v_sample[0i] * v_sample[0i])) - (v_sample[1i] * v_sample[1i]))));
        }
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            var v_tangent: f32 = (((v_a * b_attributes[(cw_buffer_offset_1 + i32((((v_va * u32(34i)) + u32(6i)) + v_k)))]) + (v_b * b_attributes[(cw_buffer_offset_1 + i32((((v_vb * u32(34i)) + u32(6i)) + v_k)))])) + (v_c * b_attributes[(cw_buffer_offset_1 + i32((((v_vc * u32(34i)) + u32(6i)) + v_k)))]));
            var v_bitangent: f32 = (((v_a * b_attributes[(cw_buffer_offset_1 + i32((((v_va * u32(34i)) + u32(18i)) + v_k)))]) + (v_b * b_attributes[(cw_buffer_offset_1 + i32((((v_vb * u32(34i)) + u32(18i)) + v_k)))])) + (v_c * b_attributes[(cw_buffer_offset_1 + i32((((v_vc * u32(34i)) + u32(18i)) + v_k)))]));
            v_n[v_k] = (((v_tangent * v_sample[0i]) + (v_bitangent * v_sample[1i])) + (v_n[v_k] * v_sample[2i]));
            continuing {
              v_k += u32(1);
            }
          }
        }
      }
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          v_nl = (v_nl + (v_n[v_k] * v_n[v_k]));
          continuing {
            v_k += u32(1);
          }
        }
      }
      v_pl = sqrt(max(v_pl, 1e-12f));
      v_nl = sqrt(max(v_nl, 1e-12f));
      var v_dot: f32 = 0.0f;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          v_p[v_k] = cw_divide_f32(v_p[v_k], v_pl);
          v_n[v_k] = cw_divide_f32(v_n[v_k], v_nl);
          v_dot = (v_dot + (v_p[v_k] * v_n[v_k]));
          continuing {
            v_k += u32(1);
          }
        }
      }
      var v_reflected: array<f32, 3>;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          v_reflected[v_k] = (v_p[v_k] - ((2.0f * v_dot) * v_n[v_k]));
          continuing {
            v_k += u32(1);
          }
        }
      }
      var v_denominator: f32 = (2.0f * sqrt(max(1e-12f, (((v_reflected[0i] * v_reflected[0i]) + (v_reflected[1i] * v_reflected[1i])) + ((v_reflected[2i] + 1.0f) * (v_reflected[2i] + 1.0f))))));
      var cw_tmp_468: f32;
      if ((v_mapped != u32(0i))) {
        cw_tmp_468 = 1.0f;
      } else {
        var cw_tmp_467: f32;
        if ((v_corner == u32(0i))) {
          cw_tmp_467 = v_a;
        } else {
          var cw_tmp_466: f32;
          if ((v_corner == u32(1i))) {
            cw_tmp_466 = v_b;
          } else {
            cw_tmp_466 = v_c;
          }
          cw_tmp_467 = cw_tmp_466;
        }
        cw_tmp_468 = cw_tmp_467;
      }
      v_result = (v_result + ((cw_divide_f32(v_reflected[v_axis], v_denominator) + 0.5f) * cw_tmp_468));
      continuing {
        v_corner += u32(1);
      }
    }
  }
  if (((v_layers & u32(256i)) != u32(0i))) {
    var v_bx: f32 = f_cw_buffer_helper_7((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(272i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(0i), cw_thread, cw_block, cw_grid);
    var v_by: f32 = f_cw_buffer_helper_7((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(272i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(1i), cw_thread, cw_block, cw_grid);
    let cw_argument_index_469 = (cw_buffer_offset_0 + i32(((v_data + u32(320i)) + (v_axis * u32(2i)))));
    let cw_argument_index_470 = (cw_buffer_offset_0 + i32(((v_data + u32(321i)) + (v_axis * u32(2i)))));
    v_result = (v_result + ((v_bx * bitcast<f32>(b_texels[cw_argument_index_469])) + (v_by * bitcast<f32>(b_texels[cw_argument_index_470]))));
  }
  return v_result;
}
fn f_cw_buffer_helper_13(cw_buffer_arg_0: i32, cw_buffer_arg_1: i32, cw_buffer_arg_2: i32, cw_arg_data: u32, cw_arg_flags: u32, cw_arg_falloff_offset: u32, cw_arg_va: u32, cw_arg_vb: u32, cw_arg_vc: u32, cw_arg_a: f32, cw_arg_b: f32, cw_arg_c: f32, cw_arg_dax: f32, cw_arg_dbx: f32, cw_arg_dcx: f32, cw_arg_day: f32, cw_arg_dby: f32, cw_arg_dcy: f32, cw_arg_inv: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var cw_buffer_offset_1: i32 = cw_buffer_arg_1;
  var cw_buffer_offset_2: i32 = cw_buffer_arg_2;
  var v_data: u32 = cw_arg_data;
  var v_flags: u32 = cw_arg_flags;
  var v_falloff_offset: u32 = cw_arg_falloff_offset;
  var v_va: u32 = cw_arg_va;
  var v_vb: u32 = cw_arg_vb;
  var v_vc: u32 = cw_arg_vc;
  var v_a: f32 = cw_arg_a;
  var v_b: f32 = cw_arg_b;
  var v_c: f32 = cw_arg_c;
  var v_dax: f32 = cw_arg_dax;
  var v_dbx: f32 = cw_arg_dbx;
  var v_dcx: f32 = cw_arg_dcx;
  var v_day: f32 = cw_arg_day;
  var v_dby: f32 = cw_arg_dby;
  var v_dcy: f32 = cw_arg_dcy;
  var v_inv: f32 = cw_arg_inv;
  var v_features: u32 = b_texels[(cw_buffer_offset_0 + i32((v_data + u32(4i))))];
  var v_layers: u32 = b_texels[(cw_buffer_offset_0 + i32((v_data + u32(72i))))];
  var v_mode: u32 = b_texels[(cw_buffer_offset_0 + i32((v_data + u32(5i))))];
  var v_offsets: array<f32, 6>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(6i))) { break; }
      v_offsets[v_k] = 0.0f;
      continuing {
        v_k += u32(1);
      }
    }
  }
  if (((v_features & u32(1536i)) != u32(0i))) {
    var cw_tmp_471: i32;
    if (((v_features & u32(512i)) != u32(0i))) {
      cw_tmp_471 = 176i;
    } else {
      cw_tmp_471 = 224i;
    }
    var v_heightMap: u32 = (v_data + u32(cw_tmp_471));
    var v_ix: f32 = max(1e-12f, (((v_inv + v_dax) + v_dbx) + v_dcx));
    var v_iy: f32 = max(1e-12f, (((v_inv + v_day) + v_dby) + v_dcy));
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(2i))) { break; }
        v_offsets[v_k] = f_cw_buffer_helper_4((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_heightMap, v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, cw_thread, cw_block, cw_grid);
        v_offsets[(v_k + u32(2i))] = (f_cw_buffer_helper_4((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_heightMap, v_va, v_vb, v_vc, cw_divide_f32(((v_a * v_inv) + v_dax), v_ix), cw_divide_f32(((v_b * v_inv) + v_dbx), v_ix), cw_divide_f32(((v_c * v_inv) + v_dcx), v_ix), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_ix, v_k, cw_thread, cw_block, cw_grid) - v_offsets[v_k]);
        v_offsets[(v_k + u32(4i))] = (f_cw_buffer_helper_4((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_heightMap, v_va, v_vb, v_vc, cw_divide_f32(((v_a * v_inv) + v_day), v_iy), cw_divide_f32(((v_b * v_inv) + v_dby), v_iy), cw_divide_f32(((v_c * v_inv) + v_dcy), v_iy), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_iy, v_k, cw_thread, cw_block, cw_grid) - v_offsets[v_k]);
        continuing {
          v_k += u32(1);
        }
      }
    }
  }
  var cw_tmp_473: f32;
  if (((v_mode == u32(2i)) || (v_mode == u32(4i)))) {
    cw_tmp_473 = (((v_a * b_vertices[(cw_buffer_offset_2 + i32(((v_va * u32(10i)) + u32(7i))))]) + (v_b * b_vertices[(cw_buffer_offset_2 + i32(((v_vb * u32(10i)) + u32(7i))))])) + (v_c * b_vertices[(cw_buffer_offset_2 + i32(((v_vc * u32(10i)) + u32(7i))))]));
  } else {
    let cw_argument_index_472 = (cw_buffer_offset_0 + i32((v_data + u32(15i))));
    cw_tmp_473 = bitcast<f32>(b_texels[cw_argument_index_472]);
  }
  var v_alpha: f32 = cw_tmp_473;
  if (((v_features & (16384u | 1073741824u)) != 0u)) {
    v_alpha = 1.0f;
  }
  if ((((v_flags & u32(1i)) != u32(0i)) && ((v_features & u32(5120i)) == u32(0i)))) {
    let cw_argument_index_474 = 0i;
    let cw_argument_index_475 = 1i;
    let cw_argument_index_476 = 2i;
    let cw_argument_index_477 = 3i;
    let cw_argument_index_478 = 4i;
    let cw_argument_index_479 = 5i;
    v_alpha = (v_alpha * f_cw_buffer_helper_5((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(224i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i), v_offsets[cw_argument_index_474], v_offsets[cw_argument_index_475], v_offsets[cw_argument_index_476], v_offsets[cw_argument_index_477], v_offsets[cw_argument_index_478], v_offsets[cw_argument_index_479], cw_thread, cw_block, cw_grid));
  }
  if (((v_layers & u32(1i)) != u32(0i))) {
    v_alpha = (v_alpha * f_cw_buffer_helper_7((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(80i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i), cw_thread, cw_block, cw_grid));
  }
  if (((v_layers & u32(1024i)) != u32(0i))) {
    v_alpha = (v_alpha * f_cw_buffer_helper_7((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(328i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i), cw_thread, cw_block, cw_grid));
  }
  if (((v_features & u32(67108864i)) != u32(0i))) {
    var v_depth: f32 = (((v_a * b_attributes[(cw_buffer_offset_1 + i32(((v_va * u32(34i)) + u32(9i))))]) + (v_b * b_attributes[(cw_buffer_offset_1 + i32(((v_vb * u32(34i)) + u32(9i))))])) + (v_c * b_attributes[(cw_buffer_offset_1 + i32(((v_vc * u32(34i)) + u32(9i))))]));
    let cw_argument_index_480 = (cw_buffer_offset_0 + i32((v_data + u32(320i))));
    var v_start: f32 = bitcast<f32>(b_texels[cw_argument_index_480]);
    let cw_argument_index_481 = (cw_buffer_offset_0 + i32((v_data + u32(321i))));
    var v_end: f32 = bitcast<f32>(b_texels[cw_argument_index_481]);
    var v_fade: f32 = min(1.0f, max(0.0f, cw_divide_f32((v_depth - v_start), max(0.000001f, (v_end - v_start)))));
    v_alpha = (v_alpha * (1.0f - ((v_fade * v_fade) * (3.0f - (2.0f * v_fade)))));
  }
  if ((((v_features & u32(64i)) != u32(0i)) && ((v_layers & u32(1i)) != u32(0i)))) {
    var cw_tmp_482: i32;
    if (((v_features & u32(128i)) != u32(0i))) {
      cw_tmp_482 = 5i;
    } else {
      cw_tmp_482 = 4i;
    }
    v_alpha = (v_alpha * (1.0f + (0.25f * f_cw_buffer_helper_7((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(80i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(cw_tmp_482), cw_thread, cw_block, cw_grid))));
  }
  if (((((v_features & u32(64i)) != u32(0i)) && ((v_flags & u32(1i)) != u32(0i))) && ((v_features & u32(5120i)) == u32(0i)))) {
    var cw_tmp_483: i32;
    if (((v_features & u32(128i)) != u32(0i))) {
      cw_tmp_483 = 5i;
    } else {
      cw_tmp_483 = 4i;
    }
    let cw_argument_index_484 = 0i;
    let cw_argument_index_485 = 1i;
    let cw_argument_index_486 = 2i;
    let cw_argument_index_487 = 3i;
    let cw_argument_index_488 = 4i;
    let cw_argument_index_489 = 5i;
    var v_lod: f32 = f_cw_buffer_helper_5((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(224i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(cw_tmp_483), v_offsets[cw_argument_index_484], v_offsets[cw_argument_index_485], v_offsets[cw_argument_index_486], v_offsets[cw_argument_index_487], v_offsets[cw_argument_index_488], v_offsets[cw_argument_index_489], cw_thread, cw_block, cw_grid);
    v_alpha = (v_alpha * (1.0f + (0.25f * max(0.0f, v_lod))));
  }
  if (((v_features & 268435456u) != 0u)) {
    v_alpha = (v_alpha * (((v_a * b_attributes[(cw_buffer_offset_1 + i32((v_falloff_offset + (v_va * 4u))))]) + (v_b * b_attributes[(cw_buffer_offset_1 + i32((v_falloff_offset + (v_vb * 4u))))])) + (v_c * b_attributes[(cw_buffer_offset_1 + i32((v_falloff_offset + (v_vc * 4u))))])));
  }
  return v_alpha;
}
fn f_cw_buffer_helper_14(cw_buffer_arg_0: i32, cw_arg_object: u32, v_viewPosition: ptr<function, array<f32, 3>>, v_viewFootprint: ptr<function, array<f32, 6>>, cw_arg_shadow: f32, cw_arg_sx: f32, cw_arg_sy: f32, cw_arg_depth: f32, cw_arg_linearDepth: f32, v_color: ptr<function, array<f32, 4>>, v_viewNormal: ptr<function, array<f32, 3>>, cw_arg_cluster: u32, cw_arg_clusterScreenX: f32, cw_arg_clusterScreenY: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_object: u32 = cw_arg_object;
  var v_shadow: f32 = cw_arg_shadow;
  var v_sx: f32 = cw_arg_sx;
  var v_sy: f32 = cw_arg_sy;
  var v_depth: f32 = cw_arg_depth;
  var v_linearDepth: f32 = cw_arg_linearDepth;
  var v_cluster: u32 = cw_arg_cluster;
  var v_clusterScreenX: f32 = cw_arg_clusterScreenX;
  var v_clusterScreenY: f32 = cw_arg_clusterScreenY;
  var v_p: u32 = (v_object + b_texels[(cw_buffer_offset_0 + i32((v_object + u32(321i))))]);
  var v_flags: u32 = b_texels[(cw_buffer_offset_0 + i32((v_p + u32(24i))))];
  var v_reverse: u32 = (b_texels[(cw_buffer_offset_0 + i32((v_object + u32(4i))))] & u32(65536i));
  var v_position: array<f32, 3>;
  var v_camera: array<f32, 3>;
  var v_sun: array<f32, 3>;
  var v_eye: array<f32, 3>;
  {
    var v_row: u32 = u32(0i);
    loop {
      if (!(v_row < u32(3i))) { break; }
      let cw_argument_index_490 = (cw_buffer_offset_0 + i32(((v_p + u32(52i)) + v_row)));
      v_camera[v_row] = bitcast<f32>(b_texels[cw_argument_index_490]);
      v_position[v_row] = v_camera[v_row];
      v_sun[v_row] = 0.0f;
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(3i))) { break; }
          let cw_argument_index_491 = (cw_buffer_offset_0 + i32((((v_p + u32(40i)) + (v_col * u32(4i))) + v_row)));
          v_position[v_row] = (v_position[v_row] + (bitcast<f32>(b_texels[cw_argument_index_491]) * (*v_viewPosition)[v_col]));
          let cw_argument_index_492 = (cw_buffer_offset_0 + i32((((v_p + u32(40i)) + (v_col * u32(4i))) + v_row)));
          let cw_argument_index_493 = (cw_buffer_offset_0 + i32(((v_object + u32(24i)) + v_col)));
          v_sun[v_row] = (v_sun[v_row] + (bitcast<f32>(b_texels[cw_argument_index_492]) * bitcast<f32>(b_texels[cw_argument_index_493])));
          continuing {
            v_col += u32(1);
          }
        }
      }
      v_eye[v_row] = (v_position[v_row] - v_camera[v_row]);
      continuing {
        v_row += u32(1);
      }
    }
  }
  f_cw_buffer_helper_18(&v_eye, cw_thread, cw_block, cw_grid);
  f_cw_buffer_helper_18(&v_sun, cw_thread, cw_block, cw_grid);
  let cw_argument_index_494 = (cw_buffer_offset_0 + i32((v_p + u32(20i))));
  var v_time: f32 = bitcast<f32>(b_texels[cw_argument_index_494]);
  let cw_argument_index_495 = (cw_buffer_offset_0 + i32((v_p + u32(23i))));
  var v_rain: f32 = bitcast<f32>(b_texels[cw_argument_index_495]);
  let cw_argument_index_496 = (cw_buffer_offset_0 + i32((v_p + u32(32i))));
  var v_u: f32 = cw_divide_f32(((v_position[0i] + bitcast<f32>(b_texels[cw_argument_index_496])) * 3.0f), 40960.0f);
  let cw_argument_index_497 = (cw_buffer_offset_0 + i32((v_p + u32(33i))));
  var v_v: f32 = cw_divide_f32(((v_position[1i] + bitcast<f32>(b_texels[cw_argument_index_497])) * 3.0f), 40960.0f);
  var v_waves: array<f32, 18>;
  var v_footprint: array<f32, 4>;
  {
    var v_axis: u32 = u32(0i);
    loop {
      if (!(v_axis < u32(2i))) { break; }
      {
        var v_row: u32 = u32(0i);
        loop {
          if (!(v_row < u32(2i))) { break; }
          v_footprint[((v_axis * u32(2i)) + v_row)] = 0.0f;
          {
            var v_col: u32 = u32(0i);
            loop {
              if (!(v_col < u32(3i))) { break; }
              let cw_argument_index_498 = (cw_buffer_offset_0 + i32((((v_p + u32(40i)) + (v_col * u32(4i))) + v_row)));
              v_footprint[((v_axis * u32(2i)) + v_row)] = (v_footprint[((v_axis * u32(2i)) + v_row)] + cw_divide_f32(((bitcast<f32>(b_texels[cw_argument_index_498]) * (*v_viewFootprint)[((v_axis * u32(3i)) + v_col)]) * 3.0f), 40960.0f));
              continuing {
                v_col += u32(1);
              }
            }
          }
          continuing {
            v_row += u32(1);
          }
        }
      }
      continuing {
        v_axis += u32(1);
      }
    }
  }
  let cw_argument_index_499 = 0i;
  let cw_argument_index_500 = 1i;
  let cw_argument_index_501 = 2i;
  let cw_argument_index_502 = 3i;
  f_cw_buffer_helper_19((cw_buffer_offset_0 + 0i), v_p, v_u, v_v, v_time, v_footprint[cw_argument_index_499], v_footprint[cw_argument_index_500], v_footprint[cw_argument_index_501], v_footprint[cw_argument_index_502], &v_waves, cw_thread, cw_block, cw_grid);
  let cw_argument_index_503 = (cw_buffer_offset_0 + i32((v_p + u32(26i))));
  let cw_argument_index_504 = (cw_buffer_offset_0 + i32((v_p + u32(27i))));
  var v_extent: f32 = (bitcast<f32>(b_texels[cw_argument_index_503]) * bitcast<f32>(b_texels[cw_argument_index_504]));
  let cw_argument_index_505 = (cw_buffer_offset_0 + i32((v_p + u32(32i))));
  let cw_argument_index_506 = (cw_buffer_offset_0 + i32((v_p + u32(36i))));
  var v_ru: f32 = (cw_divide_f32(((v_position[0i] + bitcast<f32>(b_texels[cw_argument_index_505])) - bitcast<f32>(b_texels[cw_argument_index_506])), v_extent) + 0.5f);
  let cw_argument_index_507 = (cw_buffer_offset_0 + i32((v_p + u32(33i))));
  let cw_argument_index_508 = (cw_buffer_offset_0 + i32((v_p + u32(37i))));
  var v_rv: f32 = (cw_divide_f32(((v_position[1i] + bitcast<f32>(b_texels[cw_argument_index_507])) - bitcast<f32>(b_texels[cw_argument_index_508])), v_extent) + 0.5f);
  var v_distance: f32 = sqrt((((v_ru - 0.5f) * (v_ru - 0.5f)) + ((v_rv - 0.5f) * (v_rv - 0.5f))));
  var v_blend: f32 = (f_water_smooth(0.001f, 0.02f, v_distance, cw_thread, cw_block, cw_grid) * (1.0f - f_water_smooth(0.3f, 0.4f, v_distance, cw_thread, cw_block, cw_grid)));
  var v_ripple: array<f32, 3>;
  var v_normal: array<f32, 3>;
  var v_specNormal: array<f32, 3>;
  v_ripple[0i] = ((2.0f * f_cw_buffer_helper_20((cw_buffer_offset_0 + 0i), (v_p + u32(16i)), v_ru, v_rv, u32(2i), cw_thread, cw_block, cw_grid)) * v_blend);
  v_ripple[1i] = ((2.0f * f_cw_buffer_helper_20((cw_buffer_offset_0 + 0i), (v_p + u32(16i)), v_ru, v_rv, u32(3i), cw_thread, cw_block, cw_grid)) * v_blend);
  v_ripple[2i] = 0.0f;
  var v_rainRipple: array<f32, 4>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      v_rainRipple[v_k] = 0.0f;
      continuing {
        v_k += u32(1);
      }
    }
  }
  if ((v_rain > 0.01f)) {
    let cw_argument_index_509 = (cw_buffer_offset_0 + i32((v_p + u32(28i))));
    f_cw_buffer_helper_21(cw_divide_f32(v_position[0i], 1000.0f), cw_divide_f32(v_position[1i], 1000.0f), v_time, b_texels[cw_argument_index_509], &v_rainRipple, cw_thread, cw_block, cw_grid);
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      v_rainRipple[v_k] = (v_rainRipple[v_k] * f_water_unit(v_rain, cw_thread, cw_block, cw_grid));
      continuing {
        v_k += u32(1);
      }
    }
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_ripple[v_k] = (v_ripple[v_k] + (v_rainRipple[v_k] * 10.0f));
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_bump: f32 = (0.5f + (2.0f * v_rain));
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_normal[v_k] = (((((v_waves[v_k] + v_waves[(u32(3i) + v_k)]) * 0.1f) + ((v_waves[(u32(6i) + v_k)] + v_waves[(u32(9i) + v_k)]) * (0.1f + (v_rain * 0.1f)))) + ((v_waves[(u32(12i) + v_k)] + v_waves[(u32(15i) + v_k)]) * (0.1f + (v_rain * 0.2f)))) + v_ripple[v_k]);
      if ((v_k < u32(2i))) {
        v_normal[v_k] = (v_normal[v_k] * (-v_bump));
      }
      continuing {
        v_k += u32(1);
      }
    }
  }
  f_cw_buffer_helper_18(&v_normal, cw_thread, cw_block, cw_grid);
  var v_dot: f32 = 0.0f;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_dot = (v_dot + (v_eye[v_k] * v_normal[v_k]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  v_dot = abs(v_dot);
  var cw_tmp_510: f32;
  if ((v_camera[2i] > 0.0f)) {
    cw_tmp_510 = 1.333f;
  } else {
    cw_tmp_510 = cw_divide_f32(1.0f, 1.333f);
  }
  var v_eta: f32 = cw_tmp_510;
  var v_g: f32 = (((v_eta * v_eta) - 1.0f) + (v_dot * v_dot));
  var v_fresnel: f32 = 1.0f;
  if ((v_g > 0.0f)) {
    v_g = sqrt(v_g);
    var v_a: f32 = cw_divide_f32((v_g - v_dot), (v_g + v_dot));
    var v_b: f32 = cw_divide_f32(((v_dot * (v_g + v_dot)) - 1.0f), ((v_dot * (v_g - v_dot)) + 1.0f));
    v_fresnel = f_water_unit((((0.5f * v_a) * v_a) * (1.0f + (v_b * v_b))), cw_thread, cw_block, cw_grid);
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      var cw_tmp_511: f32;
      if ((v_k < u32(2i))) {
        cw_tmp_511 = 5.0f;
      } else {
        cw_tmp_511 = 1.0f;
      }
      v_specNormal[v_k] = (v_normal[v_k] * cw_tmp_511);
      continuing {
        v_k += u32(1);
      }
    }
  }
  f_cw_buffer_helper_18(&v_specNormal, cw_thread, cw_block, cw_grid);
  v_dot = 0.0f;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_dot = (v_dot + (v_eye[v_k] * v_specNormal[v_k]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_phong: f32 = 0.0f;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_phong = (v_phong + ((v_eye[v_k] - ((2.0f * v_dot) * v_specNormal[v_k])) * v_sun[v_k]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  let cw_argument_index_512 = (cw_buffer_offset_0 + i32((v_object + u32(39i))));
  var v_sunAlpha: f32 = min(1.0f, cw_divide_f32(bitcast<f32>(b_texels[cw_argument_index_512]), 0.15f));
  var v_specular: f32 = ((f_water_unit((f_render_power(atan2((max(v_phong, 0.0f) * 1.55f), 1.0f), 256.0f, cw_thread, cw_block, cw_grid) * 1.5f), cw_thread, cw_block, cw_grid) * v_shadow) * v_sunAlpha);
  var v_sunFade: f32 = 0.0f;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      let cw_argument_index_513 = (cw_buffer_offset_0 + i32(((v_object + u32(28i)) + v_k)));
      var v_a: f32 = bitcast<f32>(b_texels[cw_argument_index_513]);
      v_sunFade = (v_sunFade + (v_a * v_a));
      continuing {
        v_k += u32(1);
      }
    }
  }
  v_sunFade = sqrt(v_sunFade);
  var v_ox: f32 = (v_normal[0i] * 0.1f);
  var v_oy: f32 = (v_normal[1i] * 0.1f);
  let cw_argument_index_514 = (cw_buffer_offset_0 + i32((v_p + u32(21i))));
  var v_near: f32 = bitcast<f32>(b_texels[cw_argument_index_514]);
  let cw_argument_index_515 = (cw_buffer_offset_0 + i32((v_p + u32(22i))));
  var v_far: f32 = bitcast<f32>(b_texels[cw_argument_index_515]);
  var v_surface: f32 = f_water_depth(v_depth, v_near, v_far, v_reverse, cw_thread, cw_block, cw_grid);
  var v_realDepth: f32 = 0.0f;
  var v_distorted: f32 = 0.0f;
  if (((v_flags & u32(1i)) != u32(0i))) {
    v_realDepth = (f_water_depth(f_cw_buffer_helper_20((cw_buffer_offset_0 + 0i), (v_p + u32(12i)), v_sx, v_sy, u32(0i), cw_thread, cw_block, cw_grid), v_near, v_far, v_reverse, cw_thread, cw_block, cw_grid) - v_surface);
    v_distorted = max(0.0f, (f_water_depth(f_cw_buffer_helper_20((cw_buffer_offset_0 + 0i), (v_p + u32(12i)), (v_sx - v_ox), (v_sy - v_oy), u32(0i), cw_thread, cw_block, cw_grid), v_near, v_far, v_reverse, cw_thread, cw_block, cw_grid) - v_surface));
    var v_fade: f32 = f_water_unit(cw_divide_f32(v_realDepth, 300.0f), cw_thread, cw_block, cw_grid);
    v_ox = (v_ox * v_fade);
    v_oy = (v_oy * v_fade);
  }
  var v_reflection: array<f32, 3>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_reflection[v_k] = f_cw_buffer_helper_20((cw_buffer_offset_0 + 0i), (v_p + u32(4i)), (v_sx + v_ox), (v_sy + v_oy), v_k, cw_thread, cw_block, cw_grid);
      if (((v_flags & u32(8i)) != u32(0i))) {
        v_reflection[v_k] = (v_reflection[v_k] * 0.4f);
        let cw_argument_index_516 = (cw_buffer_offset_0 + i32((v_p + u32(25i))));
        var v_radius: f32 = bitcast<f32>(b_texels[cw_argument_index_516]);
        {
          var v_tap: u32 = u32(0i);
          loop {
            if (!(v_tap < u32(4i))) { break; }
            var cw_tmp_517: f32;
            if (((v_tap % u32(2i)) == u32(0i))) {
              cw_tmp_517 = (-v_radius);
            } else {
              cw_tmp_517 = v_radius;
            }
            var cw_tmp_518: f32;
            if ((v_tap < u32(2i))) {
              cw_tmp_518 = (-v_radius);
            } else {
              cw_tmp_518 = v_radius;
            }
            v_reflection[v_k] = (v_reflection[v_k] + (0.15f * f_cw_buffer_helper_20((cw_buffer_offset_0 + 0i), (v_p + u32(4i)), ((v_sx + v_ox) + cw_tmp_517), ((v_sy + v_oy) + cw_tmp_518), v_k, cw_thread, cw_block, cw_grid)));
            continuing {
              v_tap += u32(1);
            }
          }
        }
      }
      continuing {
        v_k += u32(1);
      }
    }
  }
  if ((((v_camera[2i] > 0.0f) && (v_realDepth <= 3750.0f)) && (v_distorted > 3750.0f))) {
    v_ox = 0.0f;
    v_oy = 0.0f;
  }
  var v_transparency: f32 = f_water_unit(((v_fresnel * 6.0f) + v_specular), cw_thread, cw_block, cw_grid);
  if (((v_flags & u32(1i)) != u32(0i))) {
    v_distorted = max(0.0f, (f_water_depth(f_cw_buffer_helper_20((cw_buffer_offset_0 + 0i), (v_p + u32(12i)), (v_sx - v_ox), (v_sy - v_oy), u32(0i), cw_thread, cw_block, cw_grid), v_near, v_far, v_reverse, cw_thread, cw_block, cw_grid) - v_surface));
    v_distorted = (v_distorted + ((v_realDepth - v_distorted) * min(cw_divide_f32(v_surface, 3000.0f), 1.0f)));
  }
  var v_scatterNormal: array<f32, 3>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_scatterNormal[v_k] = (((((v_waves[v_k] + v_waves[(u32(3i) + v_k)]) * 0.05f) + (((v_waves[(u32(6i) + v_k)] + v_waves[(u32(9i) + v_k)]) * (0.1f + (v_rain * 0.1f))) * 0.2f)) + (((v_waves[(u32(12i) + v_k)] + v_waves[(u32(15i) + v_k)]) * (0.1f + (v_rain * 0.2f))) * 0.1f)) + v_ripple[v_k]);
      if ((v_k < u32(2i))) {
        v_scatterNormal[v_k] = (v_scatterNormal[v_k] * (-v_bump));
      }
      continuing {
        v_k += u32(1);
      }
    }
  }
  f_cw_buffer_helper_18(&v_scatterNormal, cw_thread, cw_block, cw_grid);
  var v_scatterDot: f32 = 0.0f;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_scatterDot = (v_scatterDot + (v_sun[v_k] * v_scatterNormal[v_k]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_scatterAngle: f32 = 0.0f;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_scatterAngle = (v_scatterAngle + ((v_sun[v_k] - ((2.0f * v_scatterDot) * v_scatterNormal[v_k])) * v_eye[v_k]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_scatter: f32 = (((((max(((v_scatterDot * 0.7f) + 0.3f), 0.0f) * max(((v_scatterAngle * 2.0f) - 1.2f), 0.0f)) * 0.3f) * v_sunFade) * v_sunAlpha) * max((1.0f - exp((-v_sun[2i]))), 0.0f));
  var v_shore: f32 = 1.0f;
  if (((v_flags & u32(5i)) == u32(5i))) {
    var v_waveA: array<f32, 3>;
    var v_waveB: array<f32, 3>;
    var v_previousA: array<f32, 3>;
    var v_previousB: array<f32, 3>;
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(3i))) { break; }
        v_previousA[v_k] = v_waves[(u32(9i) + v_k)];
        v_previousB[v_k] = v_waves[(u32(12i) + v_k)];
        continuing {
          v_k += u32(1);
        }
      }
    }
    f_cw_buffer_helper_22((cw_buffer_offset_0 + 0i), v_p, v_u, v_v, 2.0f, 2.7f, (-v_time), 0.05f, 0.1f, &v_previousA, &v_waveA, cw_thread, cw_block, cw_grid);
    f_cw_buffer_helper_22((cw_buffer_offset_0 + 0i), v_p, v_u, v_v, 2.0f, 2.7f, v_time, 0.04f, (-0.13f), &v_previousB, &v_waveB, cw_thread, cw_block, cw_grid);
    let cw_argument_index_519 = 2i;
    var v_viewFactor: f32 = ((abs(v_eye[cw_argument_index_519]) * 0.8f) + 0.2f);
    v_shore = ((((v_realDepth * v_viewFactor) - (((v_waves[6i] + ((v_rain * (v_waveA[0i] + v_waveB[0i])) * 0.5f)) + 0.15f) * 8.0f)) * min(1.0f, cw_divide_f32(1000.0f, max(v_surface, 0.000001f)))) * v_viewFactor);
    v_shore = f_water_unit((v_shore + ((1.0f - v_shore) * f_water_unit(cw_divide_f32(v_linearDepth, 6200.0f), cw_thread, cw_block, cw_grid))), cw_thread, cw_block, cw_grid);
  }
  var v_pointSpecular: array<f32, 3>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_pointSpecular[v_k] = 0.0f;
      continuing {
        v_k += u32(1);
      }
    }
  }
  if ((v_cluster != u32(0i))) {
    var v_viewSpecNormal: array<f32, 3>;
    var v_viewEye: array<f32, 3>;
    {
      var v_row: u32 = u32(0i);
      loop {
        if (!(v_row < u32(3i))) { break; }
        v_viewSpecNormal[v_row] = 0.0f;
        v_viewEye[v_row] = (*v_viewPosition)[v_row];
        {
          var v_col: u32 = u32(0i);
          loop {
            if (!(v_col < u32(3i))) { break; }
            let cw_argument_index_520 = (cw_buffer_offset_0 + i32((((v_p + u32(40i)) + (v_row * u32(4i))) + v_col)));
            v_viewSpecNormal[v_row] = (v_viewSpecNormal[v_row] + (bitcast<f32>(b_texels[cw_argument_index_520]) * v_specNormal[v_col]));
            continuing {
              v_col += u32(1);
            }
          }
        }
        continuing {
          v_row += u32(1);
        }
      }
    }
    f_cw_buffer_helper_18(&v_viewSpecNormal, cw_thread, cw_block, cw_grid);
    f_cw_buffer_helper_18(&v_viewEye, cw_thread, cw_block, cw_grid);
    var v_cell: u32 = f_cw_buffer_helper_8((cw_buffer_offset_0 + 0i), v_cluster, v_clusterScreenX, v_clusterScreenY, (*v_viewPosition)[2i], cw_thread, cw_block, cw_grid);
    var v_count: u32 = f_cw_buffer_helper_9((cw_buffer_offset_0 + 0i), v_cluster, v_cell, cw_thread, cw_block, cw_grid);
    {
      var v_light: u32 = u32(0i);
      loop {
        if (!(v_light < v_count)) { break; }
        var v_record: u32 = f_cw_buffer_helper_10((cw_buffer_offset_0 + 0i), v_cluster, v_cell, v_light, cw_thread, cw_block, cw_grid);
        var v_direction: array<f32, 3>;
        var v_distance: f32 = 0.0f;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            let cw_argument_index_521 = (cw_buffer_offset_0 + i32((v_record + v_k)));
            v_direction[v_k] = (bitcast<f32>(b_texels[cw_argument_index_521]) - (*v_viewPosition)[v_k]);
            v_distance = (v_distance + (v_direction[v_k] * v_direction[v_k]));
            continuing {
              v_k += u32(1);
            }
          }
        }
        v_distance = sqrt(max(v_distance, 1e-12f));
        let cw_argument_index_522 = (cw_buffer_offset_0 + i32((v_record + u32(15i))));
        var v_radius: f32 = bitcast<f32>(b_texels[cw_argument_index_522]);
        var v_fade: f32 = f_water_unit(cw_divide_f32((cw_divide_f32(v_distance, max(v_radius, 1e-12f)) - 0.75f), 0.25f), cw_thread, cw_block, cw_grid);
        v_fade = (1.0f - (v_fade * v_fade));
        let cw_argument_index_523 = (cw_buffer_offset_0 + i32((v_record + u32(3i))));
        let cw_argument_index_524 = (cw_buffer_offset_0 + i32((v_record + u32(7i))));
        let cw_argument_index_525 = (cw_buffer_offset_0 + i32((v_record + u32(11i))));
        var v_denominator: f32 = ((bitcast<f32>(b_texels[cw_argument_index_523]) + (bitcast<f32>(b_texels[cw_argument_index_524]) * v_distance)) + ((bitcast<f32>(b_texels[cw_argument_index_525]) * v_distance) * v_distance));
        var v_attenuation: f32 = cw_divide_f32(((v_fade * v_fade) * f_cw_buffer_helper_11((cw_buffer_offset_0 + 0i), v_cluster, (*v_viewPosition)[2i], v_radius, cw_thread, cw_block, cw_grid)), max(v_denominator, 1e-12f));
        var v_lambert: f32 = 0.0f;
        var v_halfVector: array<f32, 3>;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            v_direction[v_k] = cw_divide_f32(v_direction[v_k], v_distance);
            v_lambert = (v_lambert + (v_viewSpecNormal[v_k] * v_direction[v_k]));
            v_halfVector[v_k] = (v_direction[v_k] - v_viewEye[v_k]);
            continuing {
              v_k += u32(1);
            }
          }
        }
        f_cw_buffer_helper_18(&v_halfVector, cw_thread, cw_block, cw_grid);
        var v_spec: f32 = 0.0f;
        if ((v_lambert > 0.0f)) {
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              v_spec = (v_spec + (v_viewSpecNormal[v_k] * v_halfVector[v_k]));
              continuing {
                v_k += u32(1);
              }
            }
          }
          v_spec = f_render_power(max(v_spec, 0.0f), 50.0f, cw_thread, cw_block, cw_grid);
        }
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            let cw_argument_index_526 = (cw_buffer_offset_0 + i32(((v_record + u32(12i)) + v_k)));
            v_pointSpecular[v_k] = (v_pointSpecular[v_k] + (((1.5f * bitcast<f32>(b_texels[cw_argument_index_526])) * v_spec) * v_attenuation));
            continuing {
              v_k += u32(1);
            }
          }
        }
        continuing {
          v_light += u32(1);
        }
      }
    }
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      var cw_tmp_528: f32;
      if ((v_k == u32(0i))) {
        cw_tmp_528 = 0.090195f;
      } else {
        var cw_tmp_527: f32;
        if ((v_k == u32(1i))) {
          cw_tmp_527 = 0.115685f;
        } else {
          cw_tmp_527 = 0.12745f;
        }
        cw_tmp_528 = cw_tmp_527;
      }
      var v_waterColor: f32 = (cw_tmp_528 * v_sunFade);
      var v_rawRefraction: f32 = 0.0f;
      if (((v_flags & u32(1i)) != u32(0i))) {
        var v_refraction: f32 = f_cw_buffer_helper_20((cw_buffer_offset_0 + 0i), (v_p + u32(8i)), (v_sx - v_ox), (v_sy - v_oy), v_k, cw_thread, cw_block, cw_grid);
        v_rawRefraction = v_refraction;
        if ((v_camera[2i] < 0.0f)) {
          v_refraction = f_water_unit((v_refraction * 1.5f), cw_thread, cw_block, cw_grid);
        } else {
          var v_correction: f32 = sqrt(1.09f);
          var v_factor: f32 = f_water_unit(((cw_divide_f32(0.0225f, ((((-0.5f) * v_correction) + 0.5f) - cw_divide_f32(v_distorted, 2500.0f))) + (0.5f * v_correction)) + 0.5f), cw_thread, cw_block, cw_grid);
          v_refraction = (v_refraction + ((v_waterColor - v_refraction) * v_factor));
        }
        if (((v_flags & u32(2i)) != u32(0i))) {
          var cw_tmp_530: f32;
          if ((v_k == u32(0i))) {
            cw_tmp_530 = 0.0f;
          } else {
            var cw_tmp_529: f32;
            if ((v_k == u32(1i))) {
              cw_tmp_529 = 1.0f;
            } else {
              cw_tmp_529 = 0.95f;
            }
            cw_tmp_530 = cw_tmp_529;
          }
          var v_tint: f32 = cw_tmp_530;
          var cw_tmp_532: f32;
          if ((v_k == u32(0i))) {
            cw_tmp_532 = 1.0f;
          } else {
            var cw_tmp_531: f32;
            if ((v_k == u32(1i))) {
              cw_tmp_531 = 0.4f;
            } else {
              cw_tmp_531 = 0.0f;
            }
            cw_tmp_532 = cw_tmp_531;
          }
          var v_warm: f32 = cw_tmp_532;
          var cw_tmp_534: f32;
          if ((v_k == u32(0i))) {
            cw_tmp_534 = 0.45f;
          } else {
            var cw_tmp_533: f32;
            if ((v_k == u32(1i))) {
              cw_tmp_533 = 0.55f;
            } else {
              cw_tmp_533 = 0.68f;
            }
            cw_tmp_534 = cw_tmp_533;
          }
          var v_extinction: f32 = cw_tmp_534;
          var v_scatterColor: f32 = (v_tint * (v_warm + ((1.0f - v_warm) * max((1.0f - exp(((-v_sun[2i]) * v_extinction))), 0.0f))));
          v_refraction = (v_refraction + ((v_scatterColor - v_refraction) * v_scatter));
        }
        (*v_color)[v_k] = ((v_refraction * (1.0f - v_fresnel)) + (v_reflection[v_k] * v_fresnel));
      } else {
        (*v_color)[v_k] = (((v_waterColor * (1.0f - v_fresnel)) * 0.5f) + ((v_reflection[v_k] * (1.0f + v_fresnel)) * 0.5f));
      }
      let cw_argument_index_535 = (cw_buffer_offset_0 + i32(((v_object + u32(36i)) + v_k)));
      (*v_color)[v_k] = ((*v_color)[v_k] + ((v_specular * bitcast<f32>(b_texels[cw_argument_index_535])) + v_pointSpecular[v_k]));
      var v_skyEstimate: f32 = max(0.0f, ((-0.3f) + (1.3f * v_sunFade)));
      let cw_argument_index_536 = 3i;
      var cw_tmp_537: f32;
      if (((v_flags & u32(1i)) != u32(0i))) {
        cw_tmp_537 = v_transparency;
      } else {
        cw_tmp_537 = 1.0f;
      }
      (*v_color)[v_k] = ((*v_color)[v_k] + (((abs(v_rainRipple[cw_argument_index_536]) * ((v_skyEstimate * 0.95f) + 0.05f)) * 0.5f) * cw_tmp_537));
      if (((v_flags & u32(5i)) == u32(5i))) {
        (*v_color)[v_k] = (v_rawRefraction + (((*v_color)[v_k] - v_rawRefraction) * v_shore));
      }
      (*v_viewNormal)[v_k] = 0.0f;
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(3i))) { break; }
          let cw_argument_index_538 = (cw_buffer_offset_0 + i32((((v_p + u32(40i)) + (v_k * u32(4i))) + v_col)));
          (*v_viewNormal)[v_k] = ((*v_viewNormal)[v_k] + (bitcast<f32>(b_texels[cw_argument_index_538]) * v_normal[v_col]));
          continuing {
            v_col += u32(1);
          }
        }
      }
      continuing {
        v_k += u32(1);
      }
    }
  }
  f_cw_buffer_helper_18(v_viewNormal, cw_thread, cw_block, cw_grid);
  var cw_tmp_539: f32;
  if (((v_flags & u32(1i)) != u32(0i))) {
    cw_tmp_539 = 1.0f;
  } else {
    cw_tmp_539 = v_transparency;
  }
  (*v_color)[3i] = cw_tmp_539;
}
fn f_cw_buffer_helper_15(cw_buffer_arg_0: i32, cw_buffer_arg_1: i32, cw_arg_raster: u32, cw_arg_pixel: u32, cw_arg_pixel_count: u32, cw_arg_front: u32, cw_arg_depth_pass: u32, cw_arg_target_offset: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var cw_buffer_offset_1: i32 = cw_buffer_arg_1;
  var v_raster: u32 = cw_arg_raster;
  var v_pixel: u32 = cw_arg_pixel;
  var v_pixel_count: u32 = cw_arg_pixel_count;
  var v_front: u32 = cw_arg_front;
  var v_depth_pass: u32 = cw_arg_depth_pass;
  var v_target_offset: u32 = cw_arg_target_offset;
  var cw_tmp_540: u32;
  if ((v_front != 0u)) {
    cw_tmp_540 = 8u;
  } else {
    cw_tmp_540 = 15u;
  }
  var v_base: u32 = (v_raster + cw_tmp_540);
  var v_previous: u32 = (u32(b_target[(cw_buffer_offset_0 + i32(((v_target_offset + (v_pixel_count * 9u)) + v_pixel)))]) & 255u);
  var v_reference: u32 = u32(b_attributes[(cw_buffer_offset_1 + i32((v_base + 1u)))]);
  var v_mask: u32 = u32(b_attributes[(cw_buffer_offset_1 + i32((v_base + 2u)))]);
  var v_passed: u32 = f_compare_value(f32((v_reference & v_mask)), f32((v_previous & v_mask)), u32(b_attributes[(cw_buffer_offset_1 + i32(v_base))]), cw_thread, cw_block, cw_grid);
  var cw_tmp_542: u32;
  if ((v_passed == 0u)) {
    cw_tmp_542 = 4u;
  } else {
    var cw_tmp_541: u32;
    if ((v_depth_pass == 0u)) {
      cw_tmp_541 = 5u;
    } else {
      cw_tmp_541 = 6u;
    }
    cw_tmp_542 = cw_tmp_541;
  }
  var v_operation: u32 = u32(b_attributes[(cw_buffer_offset_1 + i32((v_base + cw_tmp_542)))]);
  var v_value: u32 = v_previous;
  if ((v_operation == 1u)) {
    v_value = 0u;
  }
  if ((v_operation == 2u)) {
    v_value = v_reference;
  }
  if ((v_operation == 3u)) {
    var cw_tmp_543: u32;
    if ((v_previous < 255u)) {
      cw_tmp_543 = (v_previous + 1u);
    } else {
      cw_tmp_543 = 255u;
    }
    v_value = cw_tmp_543;
  }
  if ((v_operation == 4u)) {
    var cw_tmp_544: u32;
    if ((v_previous > 0u)) {
      cw_tmp_544 = (v_previous - 1u);
    } else {
      cw_tmp_544 = 0u;
    }
    v_value = cw_tmp_544;
  }
  if ((v_operation == 5u)) {
    v_value = (v_previous ^ 255u);
  }
  if ((v_operation == 6u)) {
    v_value = ((v_previous + 1u) & 255u);
  }
  if ((v_operation == 7u)) {
    v_value = ((v_previous + 255u) & 255u);
  }
  var v_write: u32 = u32(b_attributes[(cw_buffer_offset_1 + i32((v_base + 3u)))]);
  b_target[(cw_buffer_offset_0 + i32(((v_target_offset + (v_pixel_count * 9u)) + v_pixel)))] = f32(((v_previous & ((~v_write) & 255u)) | (v_value & v_write)));
  return (v_passed & v_depth_pass);
}
fn f_cw_buffer_helper_16(cw_buffer_arg_0: i32, cw_arg_base: u32, cw_arg_width: u32, cw_arg_height: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_sampler: u32, cw_arg_channel: u32, cw_arg_level: u32, cw_arg_linear: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_base: u32 = cw_arg_base;
  var v_width: u32 = cw_arg_width;
  var v_height: u32 = cw_arg_height;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_sampler: u32 = cw_arg_sampler;
  var v_channel: u32 = cw_arg_channel;
  var v_level: u32 = cw_arg_level;
  var v_linear: u32 = cw_arg_linear;
  var cw_tmp_547: f32;
  if (((v_sampler & u32(8192i)) != u32(0i))) {
    var cw_tmp_546: f32;
    if ((v_channel == u32(3i))) {
      cw_tmp_546 = 1.0f;
    } else {
      var cw_tmp_545: f32;
      if (((v_sampler & u32(16384i)) != u32(0i))) {
        cw_tmp_545 = 1.0f;
      } else {
        cw_tmp_545 = 0.0f;
      }
      cw_tmp_546 = cw_tmp_545;
    }
    cw_tmp_547 = cw_tmp_546;
  } else {
    cw_tmp_547 = 0.0f;
  }
  var v_borderValue: f32 = cw_tmp_547;
  if (((v_sampler & 536870912u) != 0u)) {
    var v_description: u32 = b_texels[(cw_buffer_offset_0 + i32((v_base + 5u)))];
    var v_kind: u32 = (v_description & 15u);
    var v_range: u32 = (v_description >> 4u);
    var v_component: u32 = v_channel;
    if (((v_kind == 4u) || (v_kind == 5u))) {
      var cw_tmp_548: u32;
      if ((v_channel == 3u)) {
        cw_tmp_548 = 3u;
      } else {
        cw_tmp_548 = 0u;
      }
      v_component = cw_tmp_548;
    }
    if ((v_kind == 7u)) {
      v_component = 0u;
    }
    if (((v_sampler & u32(8192i)) != 0u)) {
      v_component = 0u;
    }
    let cw_argument_index_549 = (cw_buffer_offset_0 + i32(((v_base + 1u) + v_component)));
    v_borderValue = bitcast<f32>(b_texels[cw_argument_index_549]);
    if ((v_range == 0u)) {
      v_borderValue = min(1.0f, max(0.0f, v_borderValue));
    }
    if ((v_range == 1u)) {
      v_borderValue = min(1.0f, max((-1.0f), v_borderValue));
    }
    if ((v_range == 2u)) {
      v_borderValue = min(65504.0f, max((-65504.0f), v_borderValue));
    }
    if ((((((v_kind >= 1u) && (v_kind <= 3u)) && (v_channel >= v_kind)) || ((v_kind == 4u) && (v_channel == 3u))) || ((v_kind == 6u) && (v_channel < 3u)))) {
      var cw_tmp_550: f32;
      if ((v_channel == 3u)) {
        cw_tmp_550 = 1.0f;
      } else {
        cw_tmp_550 = 0.0f;
      }
      v_borderValue = cw_tmp_550;
    }
    if ((((v_sampler & u32(8192i)) != 0u) && (v_channel == 3u))) {
      v_borderValue = 1.0f;
    }
    v_base = b_texels[(cw_buffer_offset_0 + i32(v_base))];
  }
  var cw_tmp_551: i32;
  if (((v_sampler & u32(32768i)) != u32(0i))) {
    cw_tmp_551 = 4i;
  } else {
    cw_tmp_551 = 1i;
  }
  var v_stride: u32 = u32(cw_tmp_551);
  {
    var v_l: u32 = u32(0i);
    loop {
      if (!(v_l < v_level)) { break; }
      v_base = (v_base + ((v_width * v_height) * v_stride));
      var cw_tmp_552: u32;
      if ((v_width > u32(1i))) {
        cw_tmp_552 = (v_width / u32(2i));
      } else {
        cw_tmp_552 = u32(1i);
      }
      v_width = cw_tmp_552;
      var cw_tmp_553: u32;
      if ((v_height > u32(1i))) {
        cw_tmp_553 = (v_height / u32(2i));
      } else {
        cw_tmp_553 = u32(1i);
      }
      v_height = cw_tmp_553;
      continuing {
        v_l += u32(1);
      }
    }
  }
  var v_ws: u32 = ((v_sampler >> u32(9i)) & u32(3i));
  var v_wt: u32 = ((v_sampler >> u32(11i)) & u32(3i));
  if (((v_sampler & 1073741824u) != 0u)) {
    v_u = min(1.0f, max(0.0f, v_u));
    var cw_tmp_554: u32;
    if ((v_linear != 0u)) {
      cw_tmp_554 = 3u;
    } else {
      cw_tmp_554 = 0u;
    }
    v_ws = cw_tmp_554;
  }
  if (((v_sampler & 2147483648u) != 0u)) {
    v_v = min(1.0f, max(0.0f, v_v));
    var cw_tmp_555: u32;
    if ((v_linear != 0u)) {
      cw_tmp_555 = 3u;
    } else {
      cw_tmp_555 = 0u;
    }
    v_wt = cw_tmp_555;
  }
  var cw_tmp_559: f32;
  if ((v_ws == u32(3i))) {
    cw_tmp_559 = min(2.0f, max((-1.0f), v_u));
  } else {
    var cw_tmp_558: f32;
    if ((v_ws == u32(0i))) {
      cw_tmp_558 = min(1.0f, max(0.0f, v_u));
    } else {
      var cw_tmp_556: f32;
      if ((v_ws == u32(2i))) {
        cw_tmp_556 = 2.0f;
      } else {
        cw_tmp_556 = 1.0f;
      }
      var cw_tmp_557: f32;
      if ((v_ws == u32(2i))) {
        cw_tmp_557 = 2.0f;
      } else {
        cw_tmp_557 = 1.0f;
      }
      cw_tmp_558 = (v_u - (floor(cw_divide_f32(v_u, cw_tmp_556)) * cw_tmp_557));
    }
    cw_tmp_559 = cw_tmp_558;
  }
  v_u = cw_tmp_559;
  var cw_tmp_563: f32;
  if ((v_wt == u32(3i))) {
    cw_tmp_563 = min(2.0f, max((-1.0f), v_v));
  } else {
    var cw_tmp_562: f32;
    if ((v_wt == u32(0i))) {
      cw_tmp_562 = min(1.0f, max(0.0f, v_v));
    } else {
      var cw_tmp_560: f32;
      if ((v_wt == u32(2i))) {
        cw_tmp_560 = 2.0f;
      } else {
        cw_tmp_560 = 1.0f;
      }
      var cw_tmp_561: f32;
      if ((v_wt == u32(2i))) {
        cw_tmp_561 = 2.0f;
      } else {
        cw_tmp_561 = 1.0f;
      }
      cw_tmp_562 = (v_v - (floor(cw_divide_f32(v_v, cw_tmp_560)) * cw_tmp_561));
    }
    cw_tmp_563 = cw_tmp_562;
  }
  v_v = cw_tmp_563;
  var cw_tmp_564: f32;
  if ((v_linear != u32(0i))) {
    cw_tmp_564 = 0.5f;
  } else {
    cw_tmp_564 = 0.0f;
  }
  var v_x: f32 = ((v_u * f32(v_width)) - cw_tmp_564);
  var cw_tmp_565: f32;
  if ((v_linear != u32(0i))) {
    cw_tmp_565 = 0.5f;
  } else {
    cw_tmp_565 = 0.0f;
  }
  var v_y: f32 = ((v_v * f32(v_height)) - cw_tmp_565);
  var v_ix: i32 = i32(floor(v_x));
  var v_iy: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - floor(v_x));
  var v_fy: f32 = (v_y - floor(v_y));
  var v_result: f32 = 0.0f;
  var cw_tmp_566: i32;
  if ((v_linear != u32(0i))) {
    cw_tmp_566 = 2i;
  } else {
    cw_tmp_566 = 1i;
  }
  var v_taps: u32 = u32(cw_tmp_566);
  {
    var v_dy: u32 = u32(0i);
    loop {
      if (!(v_dy < v_taps)) { break; }
      {
        var v_dx: u32 = u32(0i);
        loop {
          if (!(v_dx < v_taps)) { break; }
          var v_address: u32 = (v_base + (((u32(f_sampler_index((v_iy + i32(v_dy)), i32(v_height), v_wt, cw_thread, cw_block, cw_grid)) * v_width) + u32(f_sampler_index((v_ix + i32(v_dx)), i32(v_width), v_ws, cw_thread, cw_block, cw_grid))) * v_stride));
          var cw_tmp_569: f32;
          if ((v_linear != u32(0i))) {
            var cw_tmp_567: f32;
            if ((v_dx == u32(0i))) {
              cw_tmp_567 = (1.0f - v_fx);
            } else {
              cw_tmp_567 = v_fx;
            }
            var cw_tmp_568: f32;
            if ((v_dy == u32(0i))) {
              cw_tmp_568 = (1.0f - v_fy);
            } else {
              cw_tmp_568 = v_fy;
            }
            cw_tmp_569 = (cw_tmp_567 * cw_tmp_568);
          } else {
            cw_tmp_569 = 1.0f;
          }
          var v_weight: f32 = cw_tmp_569;
          var v_border: u32 = select(u32(0), u32(1), (((v_ws == u32(3i)) && (((v_ix + i32(v_dx)) < 0i) || ((v_ix + i32(v_dx)) >= i32(v_width)))) || ((v_wt == u32(3i)) && (((v_iy + i32(v_dy)) < 0i) || ((v_iy + i32(v_dy)) >= i32(v_height))))));
          var cw_tmp_574: f32;
          if (((v_sampler & u32(32768i)) != u32(0i))) {
            let cw_argument_index_570 = (cw_buffer_offset_0 + i32((v_address + v_channel)));
            cw_tmp_574 = bitcast<f32>(b_texels[cw_argument_index_570]);
          } else {
            var cw_tmp_573: f32;
            if (((v_sampler & u32(8192i)) != u32(0i))) {
              var cw_tmp_572: f32;
              if ((v_channel == u32(3i))) {
                cw_tmp_572 = 1.0f;
              } else {
                let cw_argument_index_571 = (cw_buffer_offset_0 + i32(v_address));
                cw_tmp_572 = bitcast<f32>(b_texels[cw_argument_index_571]);
              }
              cw_tmp_573 = cw_tmp_572;
            } else {
              cw_tmp_573 = cw_divide_f32(f32(((b_texels[(cw_buffer_offset_0 + i32(v_address))] >> (v_channel * u32(8i))) & u32(255i))), 255.0f);
            }
            cw_tmp_574 = cw_tmp_573;
          }
          var v_value: f32 = cw_tmp_574;
          if ((v_border != u32(0i))) {
            v_value = v_borderValue;
          }
          v_result = (v_result + (v_weight * v_value));
          continuing {
            v_dx += u32(1);
          }
        }
      }
      continuing {
        v_dy += u32(1);
      }
    }
  }
  return v_result;
}
fn f_cw_buffer_helper_17(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_reference: f32, cw_arg_lod: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_reference: f32 = cw_arg_reference;
  var v_lod: f32 = cw_arg_lod;
  var v_sampler: u32 = b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 3u)))];
  var v_base: u32 = b_texels[(cw_buffer_offset_0 + i32(v_descriptor))];
  if (((v_sampler & 536870912u) != 0u)) {
    let cw_argument_index_575 = (cw_buffer_offset_0 + i32((v_base + 8u)));
    var v_bias: f32 = min(16.0f, max((-16.0f), bitcast<f32>(b_texels[cw_argument_index_575])));
    let cw_argument_index_576 = (cw_buffer_offset_0 + i32((v_base + 7u)));
    let cw_argument_index_577 = (cw_buffer_offset_0 + i32((v_base + 6u)));
    v_lod = min(bitcast<f32>(b_texels[cw_argument_index_576]), max(bitcast<f32>(b_texels[cw_argument_index_577]), (v_lod + v_bias)));
  }
  var v_filter: u32 = ((v_sampler >> 5u) & 7u);
  var v_magnification: u32 = ((v_sampler >> 8u) & 1u);
  var v_last: u32 = (v_sampler & 31u);
  var cw_tmp_578: f32;
  if (((v_magnification != 0u) && ((v_filter == 2u) || (v_filter == 4u)))) {
    cw_tmp_578 = 0.5f;
  } else {
    cw_tmp_578 = 0.0f;
  }
  var v_crossover: f32 = cw_tmp_578;
  if ((v_lod <= v_crossover)) {
    return f_cw_buffer_helper_23((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, 0u, v_magnification, cw_thread, cw_block, cw_grid);
  }
  if ((v_filter < 2u)) {
    return f_cw_buffer_helper_23((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, 0u, v_filter, cw_thread, cw_block, cw_grid);
  }
  v_lod = min(f32(v_last), max(0.0f, v_lod));
  var v_linear: u32 = (v_filter & 1u);
  if ((v_filter < 4u)) {
    return f_cw_buffer_helper_23((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, u32(floor((v_lod + 0.5f))), v_linear, cw_thread, cw_block, cw_grid);
  }
  var v_low: u32 = u32(floor(v_lod));
  var cw_tmp_579: u32;
  if ((v_low < v_last)) {
    cw_tmp_579 = (v_low + 1u);
  } else {
    cw_tmp_579 = v_low;
  }
  var v_high: u32 = cw_tmp_579;
  var v_fraction: f32 = (v_lod - f32(v_low));
  return ((f_cw_buffer_helper_23((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, v_low, v_linear, cw_thread, cw_block, cw_grid) * (1.0f - v_fraction)) + (f_cw_buffer_helper_23((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, v_high, v_linear, cw_thread, cw_block, cw_grid) * v_fraction));
}
fn f_cw_buffer_helper_18(v_v: ptr<function, array<f32, 3>>, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) {
  var v_length: f32 = sqrt(max(1e-12f, ((((*v_v)[0i] * (*v_v)[0i]) + ((*v_v)[1i] * (*v_v)[1i])) + ((*v_v)[2i] * (*v_v)[2i]))));
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      (*v_v)[v_k] = cw_divide_f32((*v_v)[v_k], v_length);
      continuing {
        v_k += u32(1);
      }
    }
  }
}
fn f_cw_buffer_helper_19(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_time: f32, cw_arg_dudx: f32, cw_arg_dvdx: f32, cw_arg_dudy: f32, cw_arg_dvdy: f32, v_waves: ptr<function, array<f32, 18>>, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_time: f32 = cw_arg_time;
  var v_dudx: f32 = cw_arg_dudx;
  var v_dvdx: f32 = cw_arg_dvdx;
  var v_dudy: f32 = cw_arg_dudy;
  var v_dvdy: f32 = cw_arg_dvdy;
  var v_previous: array<f32, 9>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(9i))) { break; }
      v_previous[v_k] = 0.0f;
      continuing {
        v_k += u32(1);
      }
    }
  }
  {
    var v_layer: u32 = u32(0i);
    loop {
      if (!(v_layer < u32(6i))) { break; }
      var cw_tmp_584: f32;
      if ((v_layer == u32(0i))) {
        cw_tmp_584 = 0.05f;
      } else {
        var cw_tmp_583: f32;
        if ((v_layer == u32(1i))) {
          cw_tmp_583 = 0.1f;
        } else {
          var cw_tmp_582: f32;
          if ((v_layer == u32(2i))) {
            cw_tmp_582 = 0.25f;
          } else {
            var cw_tmp_581: f32;
            if ((v_layer == u32(3i))) {
              cw_tmp_581 = 0.5f;
            } else {
              var cw_tmp_580: f32;
              if ((v_layer == u32(4i))) {
                cw_tmp_580 = 1.0f;
              } else {
                cw_tmp_580 = 2.0f;
              }
              cw_tmp_581 = cw_tmp_580;
            }
            cw_tmp_582 = cw_tmp_581;
          }
          cw_tmp_583 = cw_tmp_582;
        }
        cw_tmp_584 = cw_tmp_583;
      }
      var v_scale: f32 = cw_tmp_584;
      var cw_tmp_589: f32;
      if ((v_layer == u32(0i))) {
        cw_tmp_589 = 0.04f;
      } else {
        var cw_tmp_588: f32;
        if ((v_layer == u32(1i))) {
          cw_tmp_588 = 0.08f;
        } else {
          var cw_tmp_587: f32;
          if ((v_layer == u32(2i))) {
            cw_tmp_587 = 0.07f;
          } else {
            var cw_tmp_586: f32;
            if ((v_layer == u32(3i))) {
              cw_tmp_586 = 0.09f;
            } else {
              var cw_tmp_585: f32;
              if ((v_layer == u32(4i))) {
                cw_tmp_585 = 0.4f;
              } else {
                cw_tmp_585 = 0.7f;
              }
              cw_tmp_586 = cw_tmp_585;
            }
            cw_tmp_587 = cw_tmp_586;
          }
          cw_tmp_588 = cw_tmp_587;
        }
        cw_tmp_589 = cw_tmp_588;
      }
      var v_speed: f32 = cw_tmp_589;
      var cw_tmp_594: f32;
      if ((v_layer == u32(0i))) {
        cw_tmp_594 = (-0.015f);
      } else {
        var cw_tmp_593: f32;
        if ((v_layer == u32(1i))) {
          cw_tmp_593 = 0.02f;
        } else {
          var cw_tmp_592: f32;
          if ((v_layer == u32(2i))) {
            cw_tmp_592 = (-0.04f);
          } else {
            var cw_tmp_591: f32;
            if ((v_layer == u32(3i))) {
              cw_tmp_591 = 0.03f;
            } else {
              var cw_tmp_590: f32;
              if ((v_layer == u32(4i))) {
                cw_tmp_590 = (-0.02f);
              } else {
                cw_tmp_590 = 0.1f;
              }
              cw_tmp_591 = cw_tmp_590;
            }
            cw_tmp_592 = cw_tmp_591;
          }
          cw_tmp_593 = cw_tmp_592;
        }
        cw_tmp_594 = cw_tmp_593;
      }
      var v_tx: f32 = cw_tmp_594;
      var cw_tmp_599: f32;
      if ((v_layer == u32(0i))) {
        cw_tmp_599 = (-0.005f);
      } else {
        var cw_tmp_598: f32;
        if ((v_layer == u32(1i))) {
          cw_tmp_598 = 0.015f;
        } else {
          var cw_tmp_597: f32;
          if ((v_layer == u32(2i))) {
            cw_tmp_597 = (-0.03f);
          } else {
            var cw_tmp_596: f32;
            if ((v_layer == u32(3i))) {
              cw_tmp_596 = 0.04f;
            } else {
              var cw_tmp_595: f32;
              if ((v_layer == u32(4i))) {
                cw_tmp_595 = 0.1f;
              } else {
                cw_tmp_595 = (-0.06f);
              }
              cw_tmp_596 = cw_tmp_595;
            }
            cw_tmp_597 = cw_tmp_596;
          }
          cw_tmp_598 = cw_tmp_597;
        }
        cw_tmp_599 = cw_tmp_598;
      }
      var v_ty: f32 = cw_tmp_599;
      var v_coords: array<f32, 6>;
      {
        var v_sample: u32 = u32(0i);
        loop {
          if (!(v_sample < u32(3i))) { break; }
          let cw_argument_index_600 = ((v_sample * u32(3i)) + u32(2i));
          var cw_tmp_601: f32;
          if ((abs(v_previous[cw_argument_index_600]) > 0.000001f)) {
            cw_tmp_601 = v_previous[((v_sample * u32(3i)) + u32(2i))];
          } else {
            cw_tmp_601 = 1.0f;
          }
          var v_denominator: f32 = cw_tmp_601;
          var cw_tmp_603: f32;
          if ((v_sample == u32(1i))) {
            cw_tmp_603 = v_dudx;
          } else {
            var cw_tmp_602: f32;
            if ((v_sample == u32(2i))) {
              cw_tmp_602 = v_dudy;
            } else {
              cw_tmp_602 = 0.0f;
            }
            cw_tmp_603 = cw_tmp_602;
          }
          v_coords[(v_sample * u32(2i))] = (((((v_u + cw_tmp_603) * 75.0f) * v_scale) + (v_time * ((0.1f * v_speed) + v_tx))) - (cw_divide_f32(v_previous[(v_sample * u32(3i))], v_denominator) * 0.05f));
          var cw_tmp_605: f32;
          if ((v_sample == u32(1i))) {
            cw_tmp_605 = v_dvdx;
          } else {
            var cw_tmp_604: f32;
            if ((v_sample == u32(2i))) {
              cw_tmp_604 = v_dvdy;
            } else {
              cw_tmp_604 = 0.0f;
            }
            cw_tmp_605 = cw_tmp_604;
          }
          v_coords[((v_sample * u32(2i)) + u32(1i))] = (((((v_v + cw_tmp_605) * 75.0f) * v_scale) + (v_time * (((-0.16f) * v_speed) + v_ty))) - (cw_divide_f32(v_previous[((v_sample * u32(3i)) + u32(1i))], v_denominator) * 0.05f));
          continuing {
            v_sample += u32(1);
          }
        }
      }
      var v_dx: f32 = ((v_coords[2i] - v_coords[0i]) * f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(1i))))]));
      var v_dy: f32 = ((v_coords[3i] - v_coords[1i]) * f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(2i))))]));
      var v_ex: f32 = ((v_coords[4i] - v_coords[0i]) * f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(1i))))]));
      var v_ey: f32 = ((v_coords[5i] - v_coords[1i]) * f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(2i))))]));
      var v_lod: f32 = (0.5f * log2(max(1e-8f, max(((v_dx * v_dx) + (v_dy * v_dy)), ((v_ex * v_ex) + (v_ey * v_ey))))));
      {
        var v_sample: u32 = u32(0i);
        loop {
          if (!(v_sample < u32(3i))) { break; }
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              let cw_argument_index_606 = (cw_buffer_offset_0 + i32(v_descriptor));
              let cw_argument_index_607 = (cw_buffer_offset_0 + i32((v_descriptor + u32(1i))));
              let cw_argument_index_608 = (cw_buffer_offset_0 + i32((v_descriptor + u32(2i))));
              let cw_argument_index_609 = (v_sample * u32(2i));
              let cw_argument_index_610 = ((v_sample * u32(2i)) + u32(1i));
              let cw_argument_index_611 = (cw_buffer_offset_0 + i32((v_descriptor + u32(3i))));
              v_previous[((v_sample * u32(3i)) + v_k)] = ((2.0f * f_cw_buffer_helper_2((cw_buffer_offset_0 + 0i), b_texels[cw_argument_index_606], b_texels[cw_argument_index_607], b_texels[cw_argument_index_608], v_coords[cw_argument_index_609], v_coords[cw_argument_index_610], v_lod, b_texels[cw_argument_index_611], v_k, cw_thread, cw_block, cw_grid)) - 1.0f);
              continuing {
                v_k += u32(1);
              }
            }
          }
          continuing {
            v_sample += u32(1);
          }
        }
      }
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          (*v_waves)[((v_layer * u32(3i)) + v_k)] = v_previous[v_k];
          continuing {
            v_k += u32(1);
          }
        }
      }
      continuing {
        v_layer += u32(1);
      }
    }
  }
}
fn f_cw_buffer_helper_20(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_channel: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_channel: u32 = cw_arg_channel;
  let cw_argument_index_612 = (cw_buffer_offset_0 + i32(v_descriptor));
  let cw_argument_index_613 = (cw_buffer_offset_0 + i32((v_descriptor + u32(1i))));
  let cw_argument_index_614 = (cw_buffer_offset_0 + i32((v_descriptor + u32(2i))));
  let cw_argument_index_615 = (cw_buffer_offset_0 + i32((v_descriptor + u32(3i))));
  return f_cw_buffer_helper_2((cw_buffer_offset_0 + 0i), b_texels[cw_argument_index_612], b_texels[cw_argument_index_613], b_texels[cw_argument_index_614], v_u, v_v, 0.0f, b_texels[cw_argument_index_615], v_channel, cw_thread, cw_block, cw_grid);
}
fn f_cw_buffer_helper_21(cw_arg_u: f32, cw_arg_v: f32, cw_arg_time: f32, cw_arg_detail: u32, v_output: ptr<function, array<f32, 4>>, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) {
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_time: f32 = cw_arg_time;
  var v_detail: u32 = cw_arg_detail;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      (*v_output)[v_k] = 0.0f;
      continuing {
        v_k += u32(1);
      }
    }
  }
  var cw_tmp_616: i32;
  if ((v_detail == u32(2i))) {
    cw_tmp_616 = 5i;
  } else {
    cw_tmp_616 = 2i;
  }
  var v_layers: u32 = u32(cw_tmp_616);
  {
    var v_layer: u32 = u32(0i);
    loop {
      if (!(v_layer < v_layers)) { break; }
      var v_x: f32 = v_u;
      var v_y: f32 = v_v;
      var v_value: array<f32, 4>;
      if ((v_layer == u32(1i))) {
        v_x = (((v_u * 0.4f) - (v_v * 0.7f)) + 1.2f);
        v_y = (((v_u * 0.7f) + (v_v * 0.4f)) + 3.0f);
      }
      if ((v_layer == u32(2i))) {
        v_x = ((v_u * 0.75f) + 3.7f);
        v_y = ((v_v * 0.75f) + 18.9f);
      }
      if ((v_layer == u32(3i))) {
        v_x = ((v_u * 0.9f) + 5.7f);
        v_y = ((v_v * 0.9f) + 30.1f);
      }
      if ((v_layer == u32(4i))) {
        v_x = (v_u + 10.5f);
        v_y = (v_v + 5.7f);
      }
      f_cw_buffer_helper_24(v_x, v_y, v_time, v_detail, &v_value, cw_thread, cw_block, cw_grid);
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(4i))) { break; }
          (*v_output)[v_k] = ((*v_output)[v_k] + v_value[v_k]);
          continuing {
            v_k += u32(1);
          }
        }
      }
      continuing {
        v_layer += u32(1);
      }
    }
  }
}
fn f_cw_buffer_helper_22(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_scale: f32, cw_arg_speed: f32, cw_arg_time: f32, cw_arg_tx: f32, cw_arg_ty: f32, v_previous: ptr<function, array<f32, 3>>, v_output: ptr<function, array<f32, 3>>, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_scale: f32 = cw_arg_scale;
  var v_speed: f32 = cw_arg_speed;
  var v_time: f32 = cw_arg_time;
  var v_tx: f32 = cw_arg_tx;
  var v_ty: f32 = cw_arg_ty;
  var cw_tmp_617: f32;
  if ((abs((*v_previous)[2i]) > 0.000001f)) {
    cw_tmp_617 = (*v_previous)[2i];
  } else {
    cw_tmp_617 = 1.0f;
  }
  var v_denominator: f32 = cw_tmp_617;
  v_u = (((((v_u * 75.0f) * v_scale) + (((0.5f * v_time) * 0.2f) * v_speed)) - (cw_divide_f32((*v_previous)[0i], v_denominator) * 0.05f)) + (v_time * v_tx));
  v_v = (((((v_v * 75.0f) * v_scale) - (((0.8f * v_time) * 0.2f) * v_speed)) - (cw_divide_f32((*v_previous)[1i], v_denominator) * 0.05f)) + (v_time * v_ty));
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      (*v_output)[v_k] = ((2.0f * f_cw_buffer_helper_20((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_k, cw_thread, cw_block, cw_grid)) - 1.0f);
      continuing {
        v_k += u32(1);
      }
    }
  }
}
fn f_cw_buffer_helper_23(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_reference: f32, cw_arg_level: u32, cw_arg_linear: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_reference: f32 = cw_arg_reference;
  var v_level: u32 = cw_arg_level;
  var v_linear: u32 = cw_arg_linear;
  var v_width: u32 = b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(1i))))];
  var v_height: u32 = b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(2i))))];
  var v_sampler: u32 = b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(3i))))];
  var v_base: u32 = b_texels[(cw_buffer_offset_0 + i32(v_descriptor))];
  var cw_tmp_618: f32;
  if (((v_sampler & u32(16384i)) != u32(0i))) {
    cw_tmp_618 = 1.0f;
  } else {
    cw_tmp_618 = 0.0f;
  }
  var v_borderValue: f32 = cw_tmp_618;
  if (((v_sampler & 536870912u) != 0u)) {
    let cw_argument_index_619 = (cw_buffer_offset_0 + i32((v_base + 1u)));
    v_borderValue = bitcast<f32>(b_texels[cw_argument_index_619]);
    if (((b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 5u)))] & 8u) == 0u)) {
      v_borderValue = min(1.0f, max(0.0f, v_borderValue));
    }
    v_base = b_texels[(cw_buffer_offset_0 + i32(v_base))];
  }
  {
    var v_l: u32 = u32(0i);
    loop {
      if (!(v_l < v_level)) { break; }
      v_base = (v_base + (v_width * v_height));
      var cw_tmp_620: u32;
      if ((v_width > 1u)) {
        cw_tmp_620 = (v_width / 2u);
      } else {
        cw_tmp_620 = 1u;
      }
      v_width = cw_tmp_620;
      var cw_tmp_621: u32;
      if ((v_height > 1u)) {
        cw_tmp_621 = (v_height / 2u);
      } else {
        cw_tmp_621 = 1u;
      }
      v_height = cw_tmp_621;
      continuing {
        v_l += u32(1);
      }
    }
  }
  var v_ws: u32 = ((v_sampler >> u32(9i)) & u32(3i));
  var v_wt: u32 = ((v_sampler >> u32(11i)) & u32(3i));
  if (((v_sampler & 1073741824u) != 0u)) {
    v_u = min(1.0f, max(0.0f, v_u));
    var cw_tmp_622: u32;
    if ((v_linear != 0u)) {
      cw_tmp_622 = 3u;
    } else {
      cw_tmp_622 = 0u;
    }
    v_ws = cw_tmp_622;
  }
  if (((v_sampler & 2147483648u) != 0u)) {
    v_v = min(1.0f, max(0.0f, v_v));
    var cw_tmp_623: u32;
    if ((v_linear != 0u)) {
      cw_tmp_623 = 3u;
    } else {
      cw_tmp_623 = 0u;
    }
    v_wt = cw_tmp_623;
  }
  var cw_tmp_627: f32;
  if ((v_ws == u32(3i))) {
    cw_tmp_627 = min(2.0f, max((-1.0f), v_u));
  } else {
    var cw_tmp_626: f32;
    if ((v_ws == u32(0i))) {
      cw_tmp_626 = min(1.0f, max(0.0f, v_u));
    } else {
      var cw_tmp_624: f32;
      if ((v_ws == u32(2i))) {
        cw_tmp_624 = 2.0f;
      } else {
        cw_tmp_624 = 1.0f;
      }
      var cw_tmp_625: f32;
      if ((v_ws == u32(2i))) {
        cw_tmp_625 = 2.0f;
      } else {
        cw_tmp_625 = 1.0f;
      }
      cw_tmp_626 = (v_u - (floor(cw_divide_f32(v_u, cw_tmp_624)) * cw_tmp_625));
    }
    cw_tmp_627 = cw_tmp_626;
  }
  v_u = cw_tmp_627;
  var cw_tmp_631: f32;
  if ((v_wt == u32(3i))) {
    cw_tmp_631 = min(2.0f, max((-1.0f), v_v));
  } else {
    var cw_tmp_630: f32;
    if ((v_wt == u32(0i))) {
      cw_tmp_630 = min(1.0f, max(0.0f, v_v));
    } else {
      var cw_tmp_628: f32;
      if ((v_wt == u32(2i))) {
        cw_tmp_628 = 2.0f;
      } else {
        cw_tmp_628 = 1.0f;
      }
      var cw_tmp_629: f32;
      if ((v_wt == u32(2i))) {
        cw_tmp_629 = 2.0f;
      } else {
        cw_tmp_629 = 1.0f;
      }
      cw_tmp_630 = (v_v - (floor(cw_divide_f32(v_v, cw_tmp_628)) * cw_tmp_629));
    }
    cw_tmp_631 = cw_tmp_630;
  }
  v_v = cw_tmp_631;
  var cw_tmp_632: f32;
  if ((v_linear != u32(0i))) {
    cw_tmp_632 = 0.5f;
  } else {
    cw_tmp_632 = 0.0f;
  }
  var v_x: f32 = ((v_u * f32(v_width)) - cw_tmp_632);
  var cw_tmp_633: f32;
  if ((v_linear != u32(0i))) {
    cw_tmp_633 = 0.5f;
  } else {
    cw_tmp_633 = 0.0f;
  }
  var v_y: f32 = ((v_v * f32(v_height)) - cw_tmp_633);
  var v_ix: i32 = i32(floor(v_x));
  var v_iy: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - floor(v_x));
  var v_fy: f32 = (v_y - floor(v_y));
  var v_result: f32 = 0.0f;
  var cw_tmp_634: i32;
  if ((v_linear != u32(0i))) {
    cw_tmp_634 = 2i;
  } else {
    cw_tmp_634 = 1i;
  }
  var v_taps: u32 = u32(cw_tmp_634);
  {
    var v_dy: u32 = u32(0i);
    loop {
      if (!(v_dy < v_taps)) { break; }
      {
        var v_dx: u32 = u32(0i);
        loop {
          if (!(v_dx < v_taps)) { break; }
          var v_xx: i32 = (v_ix + i32(v_dx));
          var v_yy: i32 = (v_iy + i32(v_dy));
          var v_border: u32 = select(u32(0), u32(1), (((v_ws == u32(3i)) && ((v_xx < 0i) || (v_xx >= i32(v_width)))) || ((v_wt == u32(3i)) && ((v_yy < 0i) || (v_yy >= i32(v_height))))));
          var v_address: u32 = ((v_base + (u32(f_sampler_index(v_yy, i32(v_height), v_wt, cw_thread, cw_block, cw_grid)) * v_width)) + u32(f_sampler_index(v_xx, i32(v_width), v_ws, cw_thread, cw_block, cw_grid)));
          var cw_tmp_636: f32;
          if ((v_border != u32(0i))) {
            cw_tmp_636 = v_borderValue;
          } else {
            let cw_argument_index_635 = (cw_buffer_offset_0 + i32(v_address));
            cw_tmp_636 = bitcast<f32>(b_texels[cw_argument_index_635]);
          }
          var v_depth: f32 = cw_tmp_636;
          var cw_tmp_639: f32;
          if ((v_linear != u32(0i))) {
            var cw_tmp_637: f32;
            if ((v_dx == u32(0i))) {
              cw_tmp_637 = (1.0f - v_fx);
            } else {
              cw_tmp_637 = v_fx;
            }
            var cw_tmp_638: f32;
            if ((v_dy == u32(0i))) {
              cw_tmp_638 = (1.0f - v_fy);
            } else {
              cw_tmp_638 = v_fy;
            }
            cw_tmp_639 = (cw_tmp_637 * cw_tmp_638);
          } else {
            cw_tmp_639 = 1.0f;
          }
          var v_weight: f32 = cw_tmp_639;
          var v_comparedReference: f32 = v_reference;
          if (((b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 5u)))] & 8u) == 0u)) {
            v_comparedReference = min(1.0f, max(0.0f, v_comparedReference));
            v_depth = min(1.0f, max(0.0f, v_depth));
          }
          let cw_argument_index_640 = (cw_buffer_offset_0 + i32((v_descriptor + u32(4i))));
          v_result = (v_result + (v_weight * f32(f_compare_value(v_comparedReference, v_depth, b_texels[cw_argument_index_640], cw_thread, cw_block, cw_grid))));
          continuing {
            v_dx += u32(1);
          }
        }
      }
      continuing {
        v_dy += u32(1);
      }
    }
  }
  return v_result;
}
fn f_cw_buffer_helper_24(cw_arg_u: f32, cw_arg_v: f32, cw_arg_time: f32, cw_arg_detail: u32, v_output: ptr<function, array<f32, 4>>, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) {
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_time: f32 = cw_arg_time;
  var v_detail: u32 = cw_arg_detail;
  var v_x: f32 = (v_u * 10.0f);
  var v_y: f32 = (v_v * 10.0f);
  var v_cx: f32 = floor(v_x);
  var v_cy: f32 = floor(v_y);
  var v_adjusted: f32 = ((v_time * 1.2f) + f_water_fract(cw_divide_f32((v_cx * v_cy), ((v_cx + v_cy) + 0.1f)), cw_thread, cw_block, cw_grid));
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      (*v_output)[v_k] = 0.0f;
      continuing {
        v_k += u32(1);
      }
    }
  }
  var cw_tmp_641: i32;
  if ((v_detail != u32(0i))) {
    cw_tmp_641 = 4i;
  } else {
    cw_tmp_641 = 1i;
  }
  var v_rings: u32 = u32(cw_tmp_641);
  {
    var v_ring: u32 = u32(0i);
    loop {
      if (!(v_ring < v_rings)) { break; }
      var v_value: array<f32, 4>;
      f_cw_buffer_helper_25(f_water_fract(v_x, cw_thread, cw_block, cw_grid), f_water_fract(v_y, cw_thread, cw_block, cw_grid), v_cx, v_cy, (v_adjusted - cw_divide_f32(f32(v_ring), 6.0f)), v_detail, &v_value, cw_thread, cw_block, cw_grid);
      var cw_tmp_644: f32;
      if ((v_ring == u32(0i))) {
        cw_tmp_644 = 1.0f;
      } else {
        var cw_tmp_643: f32;
        if ((v_ring == u32(1i))) {
          cw_tmp_643 = 0.5f;
        } else {
          var cw_tmp_642: f32;
          if ((v_ring == u32(2i))) {
            cw_tmp_642 = 0.25f;
          } else {
            cw_tmp_642 = 0.125f;
          }
          cw_tmp_643 = cw_tmp_642;
        }
        cw_tmp_644 = cw_tmp_643;
      }
      var v_weight: f32 = cw_tmp_644;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          var cw_tmp_645: f32;
          if (((v_k < u32(2i)) && ((v_ring % u32(2i)) != u32(0i)))) {
            cw_tmp_645 = (-1.0f);
          } else {
            cw_tmp_645 = 1.0f;
          }
          (*v_output)[v_k] = ((*v_output)[v_k] + ((v_value[v_k] * v_weight) * cw_tmp_645));
          continuing {
            v_k += u32(1);
          }
        }
      }
      if ((v_ring == u32(0i))) {
        (*v_output)[3i] = ((*v_output)[3i] + (v_value[3i] * 1.5f));
      }
      if ((v_ring == u32(2i))) {
        (*v_output)[3i] = ((*v_output)[3i] + (v_value[3i] * 0.1875f));
      }
      continuing {
        v_ring += u32(1);
      }
    }
  }
}
fn f_cw_buffer_helper_25(cw_arg_x: f32, cw_arg_y: f32, cw_arg_cellX: f32, cw_arg_cellY: f32, cw_arg_time: f32, cw_arg_detail: u32, v_output: ptr<function, array<f32, 4>>, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) {
  var v_x: f32 = cw_arg_x;
  var v_y: f32 = cw_arg_y;
  var v_cellX: f32 = cw_arg_cellX;
  var v_cellY: f32 = cw_arg_cellY;
  var v_time: f32 = cw_arg_time;
  var v_detail: u32 = cw_arg_detail;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      (*v_output)[v_k] = 0.0f;
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_seed: f32 = f_water_fract(cw_divide_f32(floor(v_time), 1000.0f), cw_thread, cw_block, cw_grid);
  var v_cx: f32 = ((cw_divide_f32((v_cellX * v_cellY), 8.0f) + (v_cellY * 0.3f)) + (v_cellX * 0.2f));
  var v_cy: f32 = ((cw_divide_f32((v_cellX * v_cellY), 14.0f) + (v_cellY * 0.5f)) + (v_cellX * 0.7f));
  v_cx = f_water_fract((v_cx * (f_water_scramble(f_water_scramble((v_seed + cw_divide_f32(v_cx, 1000.0f)), 4.0f, cw_thread, cw_block, cw_grid), 3.0f, cw_thread, cw_block, cw_grid) + 1.0f)), cw_thread, cw_block, cw_grid);
  v_cy = f_water_fract((v_cy * (f_water_scramble(f_water_scramble((v_seed + cw_divide_f32(v_cy, 1000.0f)), 3.5f, cw_thread, cw_block, cw_grid), 3.0f, cw_thread, cw_block, cw_grid) + 1.0f)), cw_thread, cw_block, cw_grid);
  var v_dx: f32 = (v_x - (0.5f + (0.3f * ((2.0f * v_cx) - 1.0f))));
  var v_dy: f32 = (v_y - (0.5f + (0.3f * ((2.0f * v_cy) - 1.0f))));
  var v_distance: f32 = sqrt(((v_dx * v_dx) + (v_dy * v_dy)));
  var v_phase: f32 = f_water_fract(v_time, cw_thread, cw_block, cw_grid);
  var v_ring: f32 = (((v_phase - cw_divide_f32(v_distance, 0.2f)) * 6.0f) - 1.0f);
  var cw_tmp_647: bool = (v_ring < (-1.0f));
  if (!cw_tmp_647) {
    var cw_tmp_646: f32;
    if ((v_detail != u32(0i))) {
      cw_tmp_646 = 1.0f;
    } else {
      cw_tmp_646 = 0.5f;
    }
    cw_tmp_647 = (v_ring > cw_tmp_646);
  }
  if (cw_tmp_647) {
    return;
  }
  var v_energy: f32 = (1.0f - v_phase);
  var v_height: f32 = f_water_blip(((v_ring * 2.0f) + 0.5f), cw_thread, cw_block, cw_grid);
  (*v_output)[3i] = ((v_height * v_energy) * v_energy);
  if ((v_detail == u32(0i))) {
    return;
  }
  if ((v_distance > 1.0f)) {
    v_dx = cw_divide_f32(v_dx, v_distance);
    v_dy = cw_divide_f32(v_dy, v_distance);
  }
  var v_t: f32 = min(1.0f, max((-1.0f), v_ring));
  var v_n: f32 = ((v_t * v_t) - 1.0f);
  var v_derivative: f32 = ((((-6.0f) * v_t) * v_n) * v_n);
  (*v_output)[0i] = (((((-v_dx) * v_derivative) * 5.0f) * v_energy) * v_energy);
  (*v_output)[1i] = (((((-v_dy) * v_derivative) * 5.0f) * v_energy) * v_energy);
  (*v_output)[2i] = 0.5f;
  f_cw_buffer_helper_26(v_output, cw_thread, cw_block, cw_grid);
  var v_limit: f32 = f_water_blip(min(0.0f, v_ring), cw_thread, cw_block, cw_grid);
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      (*v_output)[v_k] = ((*v_output)[v_k] * (v_energy * v_limit));
      continuing {
        v_k += u32(1);
      }
    }
  }
  (*v_output)[2i] = ((*v_output)[2i] * v_limit);
}
fn f_cw_buffer_helper_26(v_v: ptr<function, array<f32, 4>>, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) {
  var v_length: f32 = sqrt(max(1e-12f, ((((*v_v)[0i] * (*v_v)[0i]) + ((*v_v)[1i] * (*v_v)[1i])) + ((*v_v)[2i] * (*v_v)[2i]))));
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      (*v_v)[v_k] = cw_divide_f32((*v_v)[v_k], v_length);
      continuing {
        v_k += u32(1);
      }
    }
  }
}

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_pixel: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_pixel >= ((cw_params.p_width * cw_params.p_height) * cw_params.p_sample_count))) {
    return;
  }
  var v_sample: u32 = (v_pixel / (cw_params.p_width * cw_params.p_height));
  var v_target_offset: u32 = (((v_sample * cw_params.p_width) * cw_params.p_height) * u32(10i));
  v_pixel = f_raster_pixel_index((v_pixel % (cw_params.p_width * cw_params.p_height)), cw_params.p_width, cw_params.p_height, cw_thread, cw_block, cw_grid);
  var v_x: u32 = (v_pixel % cw_params.p_width);
  var v_y: u32 = (v_pixel / cw_params.p_width);
  var v_tile: u32 = (((v_y / u32(16i)) * ((cw_params.p_width + u32(15i)) / u32(16i))) + (v_x / u32(16i)));
  var v_count: u32 = atomicLoad(&b_counts[v_tile]);
  if (((cw_params.p_capacity != 0u) && (v_count > cw_params.p_capacity))) {
    return;
  }
  var cw_tmp_32: u32;
  if ((cw_params.p_capacity == 0u)) {
    cw_tmp_32 = b_candidates[v_tile];
  } else {
    cw_tmp_32 = (v_tile * cw_params.p_capacity);
  }
  var v_candidateBase: u32 = cw_tmp_32;
  var v_sampleX: f32 = 0.5f;
  var v_sampleY: f32 = 0.5f;
  if ((cw_params.p_sample_count == 2u)) {
    var cw_tmp_33: f32;
    if ((v_sample == 0u)) {
      cw_tmp_33 = 0.25f;
    } else {
      cw_tmp_33 = 0.75f;
    }
    v_sampleX = cw_tmp_33;
    v_sampleY = v_sampleX;
  }
  if ((cw_params.p_sample_count == 4u)) {
    var cw_tmp_36: f32;
    if ((v_sample == 0u)) {
      cw_tmp_36 = 0.375f;
    } else {
      var cw_tmp_35: f32;
      if ((v_sample == 1u)) {
        cw_tmp_35 = 0.875f;
      } else {
        var cw_tmp_34: f32;
        if ((v_sample == 2u)) {
          cw_tmp_34 = 0.125f;
        } else {
          cw_tmp_34 = 0.625f;
        }
        cw_tmp_35 = cw_tmp_34;
      }
      cw_tmp_36 = cw_tmp_35;
    }
    v_sampleX = cw_tmp_36;
    var cw_tmp_39: f32;
    if ((v_sample == 0u)) {
      cw_tmp_39 = 0.125f;
    } else {
      var cw_tmp_38: f32;
      if ((v_sample == 1u)) {
        cw_tmp_38 = 0.375f;
      } else {
        var cw_tmp_37: f32;
        if ((v_sample == 2u)) {
          cw_tmp_37 = 0.625f;
        } else {
          cw_tmp_37 = 0.875f;
        }
        cw_tmp_38 = cw_tmp_37;
      }
      cw_tmp_39 = cw_tmp_38;
    }
    v_sampleY = cw_tmp_39;
  }
  if ((cw_params.p_sample_count == 8u)) {
    var v_xs: array<u32, 8>;
    var v_ys: array<u32, 8>;
    v_xs[0i] = 9u;
    v_xs[1i] = 7u;
    v_xs[2i] = 13u;
    v_xs[3i] = 5u;
    v_xs[4i] = 3u;
    v_xs[5i] = 1u;
    v_xs[6i] = 11u;
    v_xs[7i] = 15u;
    v_ys[0i] = 5u;
    v_ys[1i] = 11u;
    v_ys[2i] = 9u;
    v_ys[3i] = 3u;
    v_ys[4i] = 13u;
    v_ys[5i] = 7u;
    v_ys[6i] = 15u;
    v_ys[7i] = 1u;
    v_sampleX = cw_divide_f32(f32(v_xs[v_sample]), 16.0f);
    v_sampleY = cw_divide_f32(f32(v_ys[v_sample]), 16.0f);
  }
  if ((cw_params.p_sample_count == 16u)) {
    v_sampleX = cw_divide_f32((f32((v_sample % 4u)) + 0.5f), 4.0f);
    v_sampleY = cw_divide_f32((f32((v_sample / 4u)) + 0.5f), 4.0f);
  }
  var v_draw: u32 = 0u;
  var v_nextPrimitive: u32 = 0u;
  {
    loop {
      if (!(v_draw < v_count)) { break; }
      var v_t: u32 = (b_candidates[(v_candidateBase + v_draw)] * u32(4i));
      var v_m: u32 = (b_triangles[(v_t + u32(3i))] * u32(12i));
      var v_flags: u32 = b_materials[(v_m + u32(3i))];
      var v_modes: u32 = ((b_materials[(v_m + u32(9i))] >> 27u) & 15u);
      var cw_tmp_40: u32;
      if ((v_modes == 0u)) {
        cw_tmp_40 = 1u;
      } else {
        cw_tmp_40 = 3u;
      }
      var v_primitiveCount: u32 = cw_tmp_40;
      var v_primitive: u32 = v_nextPrimitive;
      v_nextPrimitive += u32(1);
      if ((v_nextPrimitive >= v_primitiveCount)) {
        v_nextPrimitive = 0u;
        v_draw += u32(1);
      }
      var v_raster: u32 = (cw_params.p_raster_offset + (b_triangles[(v_t + u32(3i))] * u32(50i)));
      var cw_tmp_41: u32;
      if (((cw_params.p_sample_count > 1u) && (b_attributes[(v_raster + u32(27i))] != 0.0f))) {
        cw_tmp_41 = 1u;
      } else {
        cw_tmp_41 = 0u;
      }
      var v_multisample: u32 = cw_tmp_41;
      var cw_tmp_42: f32;
      if ((v_multisample != 0u)) {
        cw_tmp_42 = v_sampleX;
      } else {
        cw_tmp_42 = 0.5f;
      }
      var v_px: f32 = (f32(v_x) + cw_tmp_42);
      var cw_tmp_43: f32;
      if ((v_multisample != 0u)) {
        cw_tmp_43 = v_sampleY;
      } else {
        cw_tmp_43 = 0.5f;
      }
      var v_py: f32 = (f32(v_y) + cw_tmp_43);
      if ((v_multisample != 0u)) {
        if ((((u32(b_attributes[(v_raster + u32(26i))]) >> v_sample) & 1u) == 0u)) {
          continue;
        }
        var v_rank: u32 = ((v_sample + (((v_x * 3u) + (v_y * 5u)) % cw_params.p_sample_count)) % cw_params.p_sample_count);
        var cw_tmp_44: u32;
        if ((b_attributes[(v_raster + u32(24i))] >= cw_divide_f32((f32(v_rank) + 0.5f), f32(cw_params.p_sample_count)))) {
          cw_tmp_44 = 1u;
        } else {
          cw_tmp_44 = 0u;
        }
        var v_covered: u32 = cw_tmp_44;
        if ((b_attributes[(v_raster + u32(25i))] != 0.0f)) {
          v_covered = (1u - v_covered);
        }
        if ((v_covered == 0u)) {
          continue;
        }
      }
      if (((((v_x < b_materials[(v_m + u32(5i))]) || (v_y < b_materials[(v_m + u32(6i))])) || ((v_x - b_materials[(v_m + u32(5i))]) >= b_materials[(v_m + u32(7i))])) || ((v_y - b_materials[(v_m + u32(6i))]) >= b_materials[(v_m + u32(8i))]))) {
        continue;
      }
      var v_ia: u32 = (b_triangles[v_t] * u32(10i));
      var v_ib: u32 = (b_triangles[(v_t + u32(1i))] * u32(10i));
      var v_ic: u32 = (b_triangles[(v_t + u32(2i))] * u32(10i));
      var v_aw: f32 = b_vertices[(v_ia + u32(3i))];
      var v_bw: f32 = b_vertices[(v_ib + u32(3i))];
      var v_cw: f32 = b_vertices[(v_ic + u32(3i))];
      if ((((v_aw <= 0.0f) || (v_bw <= 0.0f)) || (v_cw <= 0.0f))) {
        continue;
      }
      var v_ax: f32 = (((cw_divide_f32(b_vertices[v_ia], v_aw) * 0.5f) + 0.5f) * f32(cw_params.p_width));
      var v_ay: f32 = ((0.5f - (cw_divide_f32(b_vertices[(v_ia + u32(1i))], v_aw) * 0.5f)) * f32(cw_params.p_height));
      var v_bx: f32 = (((cw_divide_f32(b_vertices[v_ib], v_bw) * 0.5f) + 0.5f) * f32(cw_params.p_width));
      var v_by: f32 = ((0.5f - (cw_divide_f32(b_vertices[(v_ib + u32(1i))], v_bw) * 0.5f)) * f32(cw_params.p_height));
      var v_cx: f32 = (((cw_divide_f32(b_vertices[v_ic], v_cw) * 0.5f) + 0.5f) * f32(cw_params.p_width));
      var v_cy: f32 = ((0.5f - (cw_divide_f32(b_vertices[(v_ic + u32(1i))], v_cw) * 0.5f)) * f32(cw_params.p_height));
      var v_area: f32 = (((v_bx - v_ax) * (v_cy - v_ay)) - ((v_by - v_ay) * (v_cx - v_ax)));
      if ((abs(v_area) < 0.000001f)) {
        continue;
      }
      var v_control: u32 = b_materials[(v_m + u32(9i))];
      var cw_tmp_45: bool;
      if (((v_control & u32(65536i)) != u32(0i))) {
        cw_tmp_45 = (v_area > 0.0f);
      } else {
        cw_tmp_45 = (v_area < 0.0f);
      }
      var v_front: u32 = select(u32(0), u32(1), cw_tmp_45);
      if (((v_flags & u32(128i)) != u32(0i))) {
        var v_cull: u32 = ((v_control >> u32(14i)) & u32(3i));
        if ((((v_cull == u32(3i)) || ((v_cull == u32(1i)) && (v_front != u32(0i)))) || ((v_cull == u32(2i)) && (v_front == u32(0i))))) {
          continue;
        }
      }
      var cw_tmp_46: f32;
      if ((v_area > 0.0f)) {
        cw_tmp_46 = 1.0f;
      } else {
        cw_tmp_46 = (-1.0f);
      }
      var v_sign: f32 = cw_tmp_46;
      var v_ea: f32 = ((((v_bx - v_px) * (v_cy - v_py)) - ((v_by - v_py) * (v_cx - v_px))) * v_sign);
      var v_eb: f32 = ((((v_cx - v_px) * (v_ay - v_py)) - ((v_cy - v_py) * (v_ax - v_px))) * v_sign);
      var v_ec: f32 = ((((v_ax - v_px) * (v_by - v_py)) - ((v_ay - v_py) * (v_bx - v_px))) * v_sign);
      var cw_tmp_47: u32;
      if ((v_front != 0u)) {
        cw_tmp_47 = ((v_control >> 27u) & 3u);
      } else {
        cw_tmp_47 = ((v_control >> 29u) & 3u);
      }
      var v_polygonMode: u32 = cw_tmp_47;
      if ((v_polygonMode == 0u)) {
        if ((v_primitive != 0u)) {
          continue;
        }
        if ((((v_ea < 0.0f) || (v_eb < 0.0f)) || (v_ec < 0.0f))) {
          continue;
        }
        if (((v_ea == 0.0f) && (!((((v_cy - v_by) * v_sign) < 0.0f) || ((v_cy == v_by) && (((v_cx - v_bx) * v_sign) > 0.0f)))))) {
          continue;
        }
        if (((v_eb == 0.0f) && (!((((v_ay - v_cy) * v_sign) < 0.0f) || ((v_ay == v_cy) && (((v_ax - v_cx) * v_sign) > 0.0f)))))) {
          continue;
        }
        if (((v_ec == 0.0f) && (!((((v_by - v_ay) * v_sign) < 0.0f) || ((v_by == v_ay) && (((v_bx - v_ax) * v_sign) > 0.0f)))))) {
          continue;
        }
      }
      var v_pointFade: f32 = 1.0f;
      var v_spriteU: f32 = 0.0f;
      var v_spriteV: f32 = 0.0f;
      var v_spriteDx: f32 = 0.0f;
      var v_spriteDy: f32 = 0.0f;
      var v_spriteMask: u32 = 0u;
      var v_a: f32 = cw_divide_f32(v_ea, abs(v_area));
      var v_b: f32 = cw_divide_f32(v_eb, abs(v_area));
      var v_c: f32 = cw_divide_f32(v_ec, abs(v_area));
      var v_gradAx: f32 = cw_divide_f32((v_by - v_cy), v_area);
      var v_gradBx: f32 = cw_divide_f32((v_cy - v_ay), v_area);
      var v_gradCx: f32 = cw_divide_f32((v_ay - v_by), v_area);
      var v_gradAy: f32 = cw_divide_f32((v_cx - v_bx), v_area);
      var v_gradBy: f32 = cw_divide_f32((v_ax - v_cx), v_area);
      var v_gradCy: f32 = cw_divide_f32((v_bx - v_ax), v_area);
      if ((v_polygonMode != 0u)) {
        var v_xs: array<f32, 3>;
        var v_ys: array<f32, 3>;
        v_xs[0i] = v_ax;
        v_xs[1i] = v_bx;
        v_xs[2i] = v_cx;
        v_ys[0i] = v_ay;
        v_ys[1i] = v_by;
        v_ys[2i] = v_cy;
        var v_selected: u32 = v_primitive;
        if ((b_attributes[((cw_params.p_boundary_offset + ((v_t / 4u) * 3u)) + v_selected)] == 0.0f)) {
          continue;
        }
        var cw_tmp_48: u32;
        if ((v_selected == 2u)) {
          cw_tmp_48 = 0u;
        } else {
          cw_tmp_48 = (v_selected + 1u);
        }
        var v_next: u32 = cw_tmp_48;
        var v_dx: f32 = (v_xs[v_next] - v_xs[v_selected]);
        var v_dy: f32 = (v_ys[v_next] - v_ys[v_selected]);
        var v_qx: f32 = (v_px - v_xs[v_selected]);
        var v_qy: f32 = (v_py - v_ys[v_selected]);
        var v_along: f32 = 0.0f;
        var v_pointSize: f32 = b_attributes[(v_raster + 38u)];
        if ((v_polygonMode == 2u)) {
          var v_pointVertex: u32 = (b_triangles[(v_t + v_selected)] * 34u);
          var v_distance2: f32 = 0.0f;
          {
            var v_axis: u32 = 0u;
            loop {
              if (!(v_axis < 3u)) { break; }
              v_distance2 = (v_distance2 + (b_attributes[(v_pointVertex + v_axis)] * b_attributes[(v_pointVertex + v_axis)]));
              continuing {
                v_axis += u32(1);
              }
            }
          }
          var v_attenuation: f32 = ((b_attributes[(v_raster + 46u)] + (b_attributes[(v_raster + 47u)] * sqrt(v_distance2))) + (b_attributes[(v_raster + 48u)] * v_distance2));
          v_pointSize = cw_divide_f32(v_pointSize, sqrt(max(1e-12f, v_attenuation)));
          let cw_argument_index_49 = (v_raster + 44u);
          let cw_argument_index_50 = (v_raster + 43u);
          v_pointSize = min(b_attributes[cw_argument_index_49], max(b_attributes[cw_argument_index_50], v_pointSize));
          var v_threshold: f32 = b_attributes[(v_raster + 45u)];
          if ((((v_multisample != 0u) && (v_threshold > 0.0f)) && (v_pointSize < v_threshold))) {
            var v_ratio: f32 = cw_divide_f32(v_pointSize, v_threshold);
            v_pointFade = (v_ratio * v_ratio);
            v_pointSize = v_threshold;
          }
        }
        var cw_tmp_51: f32;
        if ((v_polygonMode == 1u)) {
          cw_tmp_51 = b_attributes[(v_raster + 37u)];
        } else {
          cw_tmp_51 = v_pointSize;
        }
        var v_halfSize: f32 = (cw_tmp_51 * 0.5f);
        if ((v_polygonMode == 1u)) {
          var v_length2: f32 = ((v_dx * v_dx) + (v_dy * v_dy));
          if ((v_length2 <= 1e-12f)) {
            continue;
          }
          v_along = cw_divide_f32(((v_qx * v_dx) + (v_qy * v_dy)), v_length2);
          var v_aliasedWidth: f32 = max(1.0f, floor((b_attributes[(v_raster + 37u)] + 0.5f)));
          if (((v_multisample == 0u) && ((u32(b_attributes[(v_raster + 49u)]) & 128u) != 0u))) {
            let cw_argument_index_52 = (v_raster + 37u);
            var v_coverage: f32 = f_line_rectangle_coverage((-v_qx), (-v_qy), v_dx, v_dy, b_attributes[cw_argument_index_52], cw_thread, cw_block, cw_grid);
            if ((v_coverage <= 0.0f)) {
              continue;
            }
            v_pointFade = (v_pointFade * v_coverage);
            v_along = min(1.0f, max(0.0f, v_along));
          } else {
            if ((v_multisample == 0u)) {
              if ((f_line_wide_diamond((-v_qx), (-v_qy), v_dx, v_dy, v_aliasedWidth, cw_thread, cw_block, cw_grid) == 0u)) {
                continue;
              }
              v_along = min(1.0f, max(0.0f, v_along));
            } else {
              if (((v_along < 0.0f) || (v_along >= 1.0f))) {
                continue;
              }
              var v_perpendicular: f32 = ((v_qx * v_dy) - (v_qy * v_dx));
              if (((v_perpendicular * v_perpendicular) > ((v_halfSize * v_halfSize) * v_length2))) {
                continue;
              }
            }
          }
        } else {
          var v_pointFlags: u32 = u32(b_attributes[(v_raster + 49u)]);
          var cw_tmp_53: u32;
          if (((v_multisample == 0u) && ((v_pointFlags & 3u) == 1u))) {
            cw_tmp_53 = 1u;
          } else {
            cw_tmp_53 = 0u;
          }
          var v_smooth: u32 = cw_tmp_53;
          if ((((v_pointFlags & 2u) != 0u) && (v_pointSize > 0.0f))) {
            v_spriteMask = ((v_pointFlags >> 2u) & 15u);
            v_spriteDx = cw_divide_f32(1.0f, v_pointSize);
            var cw_tmp_54: f32;
            if (((v_pointFlags & 64u) != 0u)) {
              cw_tmp_54 = (-v_spriteDx);
            } else {
              cw_tmp_54 = v_spriteDx;
            }
            v_spriteDy = cw_tmp_54;
            v_spriteU = (0.5f + (((f32(v_x) + 0.5f) - v_xs[v_selected]) * v_spriteDx));
            v_spriteV = (0.5f + (((f32(v_y) + 0.5f) - v_ys[v_selected]) * v_spriteDy));
          }
          if (((v_multisample == 0u) && ((v_pointFlags & 3u) == 0u))) {
            var v_size: f32 = max(1.0f, floor((v_pointSize + 0.5f)));
            var v_odd: f32 = (v_size - (2.0f * floor((v_size * 0.5f))));
            var cw_tmp_56: f32;
            if ((v_odd != 0.0f)) {
              let cw_argument_index_55 = v_selected;
              cw_tmp_56 = (floor(v_xs[cw_argument_index_55]) + 0.5f);
            } else {
              cw_tmp_56 = floor((v_xs[v_selected] + 0.5f));
            }
            var v_centerX: f32 = cw_tmp_56;
            var v_bottomY: f32 = (f32(cw_params.p_height) - v_ys[v_selected]);
            var cw_tmp_57: f32;
            if ((v_odd != 0.0f)) {
              cw_tmp_57 = (floor(v_bottomY) + 0.5f);
            } else {
              cw_tmp_57 = floor((v_bottomY + 0.5f));
            }
            var v_centerY: f32 = cw_tmp_57;
            v_qx = (v_px - v_centerX);
            v_qy = (v_py - (f32(cw_params.p_height) - v_centerY));
            v_halfSize = (v_size * 0.5f);
          }
          if ((v_smooth != 0u)) {
            var v_coverage: f32 = f_point_disk_coverage(v_qx, v_qy, v_halfSize, cw_thread, cw_block, cw_grid);
            if ((v_coverage <= 0.0f)) {
              continue;
            }
            v_pointFade = (v_pointFade * v_coverage);
          } else {
            if (((((v_qx < (-v_halfSize)) || (v_qx >= v_halfSize)) || (v_qy < (-v_halfSize))) || (v_qy >= v_halfSize))) {
              continue;
            }
          }
        }
        var cw_tmp_59: f32;
        if ((v_selected == 0u)) {
          cw_tmp_59 = (1.0f - v_along);
        } else {
          var cw_tmp_58: f32;
          if ((v_selected == 2u)) {
            cw_tmp_58 = v_along;
          } else {
            cw_tmp_58 = 0.0f;
          }
          cw_tmp_59 = cw_tmp_58;
        }
        v_a = cw_tmp_59;
        var cw_tmp_61: f32;
        if ((v_selected == 1u)) {
          cw_tmp_61 = (1.0f - v_along);
        } else {
          var cw_tmp_60: f32;
          if ((v_selected == 0u)) {
            cw_tmp_60 = v_along;
          } else {
            cw_tmp_60 = 0.0f;
          }
          cw_tmp_61 = cw_tmp_60;
        }
        v_b = cw_tmp_61;
        var cw_tmp_63: f32;
        if ((v_selected == 2u)) {
          cw_tmp_63 = (1.0f - v_along);
        } else {
          var cw_tmp_62: f32;
          if ((v_selected == 1u)) {
            cw_tmp_62 = v_along;
          } else {
            cw_tmp_62 = 0.0f;
          }
          cw_tmp_63 = cw_tmp_62;
        }
        v_c = cw_tmp_63;
        var v_gx: f32 = 0.0f;
        var v_gy: f32 = 0.0f;
        if ((v_polygonMode == 1u)) {
          var cw_tmp_64: u32;
          if ((v_selected == 2u)) {
            cw_tmp_64 = 0u;
          } else {
            cw_tmp_64 = (v_selected + 1u);
          }
          var v_next: u32 = cw_tmp_64;
          var v_dx: f32 = (v_xs[v_next] - v_xs[v_selected]);
          var v_dy: f32 = (v_ys[v_next] - v_ys[v_selected]);
          var v_length2: f32 = ((v_dx * v_dx) + (v_dy * v_dy));
          v_gx = cw_divide_f32(v_dx, v_length2);
          v_gy = cw_divide_f32(v_dy, v_length2);
        }
        var cw_tmp_66: f32;
        if ((v_selected == 0u)) {
          cw_tmp_66 = (-v_gx);
        } else {
          var cw_tmp_65: f32;
          if ((v_selected == 2u)) {
            cw_tmp_65 = v_gx;
          } else {
            cw_tmp_65 = 0.0f;
          }
          cw_tmp_66 = cw_tmp_65;
        }
        v_gradAx = cw_tmp_66;
        var cw_tmp_68: f32;
        if ((v_selected == 1u)) {
          cw_tmp_68 = (-v_gx);
        } else {
          var cw_tmp_67: f32;
          if ((v_selected == 0u)) {
            cw_tmp_67 = v_gx;
          } else {
            cw_tmp_67 = 0.0f;
          }
          cw_tmp_68 = cw_tmp_67;
        }
        v_gradBx = cw_tmp_68;
        var cw_tmp_70: f32;
        if ((v_selected == 2u)) {
          cw_tmp_70 = (-v_gx);
        } else {
          var cw_tmp_69: f32;
          if ((v_selected == 1u)) {
            cw_tmp_69 = v_gx;
          } else {
            cw_tmp_69 = 0.0f;
          }
          cw_tmp_70 = cw_tmp_69;
        }
        v_gradCx = cw_tmp_70;
        var cw_tmp_72: f32;
        if ((v_selected == 0u)) {
          cw_tmp_72 = (-v_gy);
        } else {
          var cw_tmp_71: f32;
          if ((v_selected == 2u)) {
            cw_tmp_71 = v_gy;
          } else {
            cw_tmp_71 = 0.0f;
          }
          cw_tmp_72 = cw_tmp_71;
        }
        v_gradAy = cw_tmp_72;
        var cw_tmp_74: f32;
        if ((v_selected == 1u)) {
          cw_tmp_74 = (-v_gy);
        } else {
          var cw_tmp_73: f32;
          if ((v_selected == 0u)) {
            cw_tmp_73 = v_gy;
          } else {
            cw_tmp_73 = 0.0f;
          }
          cw_tmp_74 = cw_tmp_73;
        }
        v_gradBy = cw_tmp_74;
        var cw_tmp_76: f32;
        if ((v_selected == 2u)) {
          cw_tmp_76 = (-v_gy);
        } else {
          var cw_tmp_75: f32;
          if ((v_selected == 1u)) {
            cw_tmp_75 = v_gy;
          } else {
            cw_tmp_75 = 0.0f;
          }
          cw_tmp_76 = cw_tmp_75;
        }
        v_gradCy = cw_tmp_76;
      }
      var v_lineBase: u32 = (cw_params.p_point_fade_offset + ((v_ia / 10u) * 12u));
      var cw_tmp_77: u32;
      if (((b_attributes[(v_lineBase + 7u)] > 0.0f) && (b_attributes[(v_lineBase + 11u)] > 0.0f))) {
        cw_tmp_77 = 1u;
      } else {
        cw_tmp_77 = 0u;
      }
      var v_generatedLine: u32 = cw_tmp_77;
      if ((v_generatedLine != 0u)) {
        var v_w0: f32 = b_attributes[(v_lineBase + 7u)];
        var v_w1: f32 = b_attributes[(v_lineBase + 11u)];
        var v_x0: f32 = (((cw_divide_f32(b_attributes[(v_lineBase + 4u)], v_w0) * 0.5f) + 0.5f) * f32(cw_params.p_width));
        var v_y0: f32 = ((0.5f - (cw_divide_f32(b_attributes[(v_lineBase + 5u)], v_w0) * 0.5f)) * f32(cw_params.p_height));
        var v_dx: f32 = ((((cw_divide_f32(b_attributes[(v_lineBase + 8u)], v_w1) * 0.5f) + 0.5f) * f32(cw_params.p_width)) - v_x0);
        var v_dy: f32 = (((0.5f - (cw_divide_f32(b_attributes[(v_lineBase + 9u)], v_w1) * 0.5f)) * f32(cw_params.p_height)) - v_y0);
        var v_length2: f32 = ((v_dx * v_dx) + (v_dy * v_dy));
        if ((v_length2 <= 1e-12f)) {
          continue;
        }
        var v_qx: f32 = (v_px - v_x0);
        var v_qy: f32 = (v_py - v_y0);
        var v_lineWidth: f32 = b_attributes[(v_lineBase + 2u)];
        var v_along: f32 = cw_divide_f32(((v_qx * v_dx) + (v_qy * v_dy)), v_length2);
        if (((v_multisample == 0u) && ((u32(b_attributes[(v_raster + 49u)]) & 128u) != 0u))) {
          var v_coverage: f32 = f_line_rectangle_coverage((-v_qx), (-v_qy), v_dx, v_dy, v_lineWidth, cw_thread, cw_block, cw_grid);
          if ((v_coverage <= 0.0f)) {
            continue;
          }
          v_pointFade = (v_pointFade * v_coverage);
        } else {
          if ((v_multisample == 0u)) {
            if ((f_line_wide_diamond((-v_qx), (-v_qy), v_dx, v_dy, max(1.0f, floor((v_lineWidth + 0.5f))), cw_thread, cw_block, cw_grid) == 0u)) {
              continue;
            }
          } else {
            var v_perpendicular: f32 = ((v_qx * v_dy) - (v_qy * v_dx));
            if ((((v_along < 0.0f) || (v_along >= 1.0f)) || ((v_perpendicular * v_perpendicular) > (((v_lineWidth * v_lineWidth) * 0.25f) * v_length2)))) {
              continue;
            }
          }
        }
        var cw_tmp_78: f32;
        if (((v_along > 0.0f) && (v_along < 1.0f))) {
          cw_tmp_78 = 1.0f;
        } else {
          cw_tmp_78 = 0.0f;
        }
        var v_gradient: f32 = cw_tmp_78;
        v_along = min(1.0f, max(0.0f, v_along));
        var v_reciprocal: f32 = (cw_divide_f32((1.0f - v_along), v_w0) + cw_divide_f32(v_along, v_w1));
        var v_parameter: f32 = cw_divide_f32(cw_divide_f32(v_along, v_w1), v_reciprocal);
        var v_derivative: f32 = cw_divide_f32(v_gradient, (((v_w0 * v_w1) * v_reciprocal) * v_reciprocal));
        var v_parameters: array<f32, 3>;
        var v_ws: array<f32, 3>;
        var v_basis: array<f32, 3>;
        var v_gx: array<f32, 3>;
        var v_gy: array<f32, 3>;
        v_parameters[0i] = b_attributes[(v_lineBase + 1u)];
        v_parameters[1i] = b_attributes[((cw_params.p_point_fade_offset + ((v_ib / 10u) * 12u)) + 1u)];
        v_parameters[2i] = b_attributes[((cw_params.p_point_fade_offset + ((v_ic / 10u) * 12u)) + 1u)];
        v_ws[0i] = v_aw;
        v_ws[1i] = v_bw;
        v_ws[2i] = v_cw;
        var v_low: u32 = 0u;
        var v_high: u32 = 0u;
        {
          var v_k: u32 = 1u;
          loop {
            if (!(v_k < 3u)) { break; }
            if ((v_parameters[v_k] < v_parameters[v_low])) {
              v_low = v_k;
            }
            if ((v_parameters[v_k] > v_parameters[v_high])) {
              v_high = v_k;
            }
            continuing {
              v_k += u32(1);
            }
          }
        }
        var v_span: f32 = (v_parameters[v_high] - v_parameters[v_low]);
        if ((v_span <= 1e-12f)) {
          continue;
        }
        var v_weight: f32 = cw_divide_f32((v_parameter - v_parameters[v_low]), v_span);
        var v_sum: f32 = (((1.0f - v_weight) * v_ws[v_low]) + (v_weight * v_ws[v_high]));
        if ((v_sum <= 0.0f)) {
          continue;
        }
        {
          var v_k: u32 = 0u;
          loop {
            if (!(v_k < 3u)) { break; }
            var cw_tmp_80: f32;
            if ((v_k == v_low)) {
              cw_tmp_80 = (1.0f - v_weight);
            } else {
              var cw_tmp_79: f32;
              if ((v_k == v_high)) {
                cw_tmp_79 = v_weight;
              } else {
                cw_tmp_79 = 0.0f;
              }
              cw_tmp_80 = cw_tmp_79;
            }
            var v_p: f32 = cw_tmp_80;
            var cw_tmp_82: f32;
            if ((v_k == v_low)) {
              cw_tmp_82 = cw_divide_f32((-1.0f), v_span);
            } else {
              var cw_tmp_81: f32;
              if ((v_k == v_high)) {
                cw_tmp_81 = cw_divide_f32(1.0f, v_span);
              } else {
                cw_tmp_81 = 0.0f;
              }
              cw_tmp_82 = cw_tmp_81;
            }
            var v_dp: f32 = cw_tmp_82;
            v_basis[v_k] = cw_divide_f32((v_p * v_ws[v_k]), v_sum);
            var v_d: f32 = (cw_divide_f32(((v_dp * v_ws[v_k]) - cw_divide_f32((v_basis[v_k] * (v_ws[v_high] - v_ws[v_low])), v_span)), v_sum) * v_derivative);
            v_gx[v_k] = cw_divide_f32((v_d * v_dx), v_length2);
            v_gy[v_k] = cw_divide_f32((v_d * v_dy), v_length2);
            continuing {
              v_k += u32(1);
            }
          }
        }
        v_a = v_basis[0i];
        v_b = v_basis[1i];
        v_c = v_basis[2i];
        v_gradAx = v_gx[0i];
        v_gradBx = v_gx[1i];
        v_gradCx = v_gx[2i];
        v_gradAy = v_gy[0i];
        v_gradBy = v_gy[1i];
        v_gradCy = v_gy[2i];
      }
      var cw_tmp_83: f32;
      if (((v_flags & 8388608u) != 0u)) {
        cw_tmp_83 = 1.0f;
      } else {
        cw_tmp_83 = 0.5f;
      }
      var v_depthScale: f32 = cw_tmp_83;
      var cw_tmp_84: f32;
      if (((v_flags & 8388608u) != 0u)) {
        cw_tmp_84 = 0.0f;
      } else {
        cw_tmp_84 = 0.5f;
      }
      var v_depthBias: f32 = cw_tmp_84;
      var v_z: f32 = ((((cw_divide_f32((v_a * b_vertices[(v_ia + u32(2i))]), v_aw) + cw_divide_f32((v_b * b_vertices[(v_ib + u32(2i))]), v_bw)) + cw_divide_f32((v_c * b_vertices[(v_ic + u32(2i))]), v_cw)) * v_depthScale) + v_depthBias);
      if ((((v_flags & 262144u) == 0u) && ((v_z < 0.0f) || (v_z > 1.0f)))) {
        continue;
      }
      var v_nearDepth: f32 = b_attributes[(v_raster + u32(2i))];
      var v_farDepth: f32 = b_attributes[(v_raster + u32(3i))];
      v_z = (v_nearDepth + (v_z * (v_farDepth - v_nearDepth)));
      var v_dzdx: f32 = ((cw_divide_f32(((cw_divide_f32(((v_by - v_cy) * b_vertices[(v_ia + u32(2i))]), v_aw) + cw_divide_f32(((v_cy - v_ay) * b_vertices[(v_ib + u32(2i))]), v_bw)) + cw_divide_f32(((v_ay - v_by) * b_vertices[(v_ic + u32(2i))]), v_cw)), v_area) * v_depthScale) * (v_farDepth - v_nearDepth));
      var v_dzdy: f32 = ((cw_divide_f32(((cw_divide_f32(((v_cx - v_bx) * b_vertices[(v_ia + u32(2i))]), v_aw) + cw_divide_f32(((v_ax - v_cx) * b_vertices[(v_ib + u32(2i))]), v_bw)) + cw_divide_f32(((v_bx - v_ax) * b_vertices[(v_ic + u32(2i))]), v_cw)), v_area) * v_depthScale) * (v_farDepth - v_nearDepth));
      var v_largest: f32 = 0.0f;
      v_largest = max(v_largest, abs((v_nearDepth + (((cw_divide_f32(b_vertices[(v_ia + u32(2i))], v_aw) * v_depthScale) + v_depthBias) * (v_farDepth - v_nearDepth)))));
      v_largest = max(v_largest, abs((v_nearDepth + (((cw_divide_f32(b_vertices[(v_ib + u32(2i))], v_bw) * v_depthScale) + v_depthBias) * (v_farDepth - v_nearDepth)))));
      v_largest = max(v_largest, abs((v_nearDepth + (((cw_divide_f32(b_vertices[(v_ic + u32(2i))], v_cw) * v_depthScale) + v_depthBias) * (v_farDepth - v_nearDepth)))));
      var cw_tmp_85: f32;
      if ((cw_params.p_depth_bits == 16u)) {
        cw_tmp_85 = cw_divide_f32(1.0f, 65536.0f);
      } else {
        cw_tmp_85 = cw_divide_f32(1.0f, 16777216.0f);
      }
      var v_unit: f32 = cw_tmp_85;
      if ((cw_params.p_depth_bits == 0u)) {
        var v_exponent: u32 = ((bitcast<u32>(v_largest) >> u32(23i)) & 255u);
        var cw_tmp_86: f32;
        if ((v_exponent > 23u)) {
          cw_tmp_86 = bitcast<f32>(((v_exponent - 23u) << u32(23i)));
        } else {
          cw_tmp_86 = bitcast<f32>(1u);
        }
        v_unit = cw_tmp_86;
      }
      var cw_tmp_87: u32;
      if ((v_front != 0u)) {
        cw_tmp_87 = 39u;
      } else {
        cw_tmp_87 = 41u;
      }
      var v_offsetState: u32 = (v_raster + cw_tmp_87);
      v_z = (v_z + ((max(abs(v_dzdx), abs(v_dzdy)) * b_attributes[v_offsetState]) + (b_attributes[(v_offsetState + 1u)] * v_unit)));
      if (((v_flags & 262144u) != 0u)) {
        v_z = min(max(v_nearDepth, v_farDepth), max(min(v_nearDepth, v_farDepth), v_z));
      }
      v_z = f_store_depth_value(v_z, cw_params.p_depth_bits, cw_thread, cw_block, cw_grid);
      var v_depth_pass: u32 = 1u;
      if (((v_flags & u32(4i)) != u32(0i))) {
        var cw_tmp_88: u32;
        if ((cw_params.p_color_channels == 0u)) {
          cw_tmp_88 = v_pixel;
        } else {
          cw_tmp_88 = ((v_target_offset + (v_pixel * u32(9i))) + u32(4i));
        }
        var v_old: f32 = b_target[cw_tmp_88];
        if (((v_flags & u32(128i)) != u32(0i))) {
          v_depth_pass = f_compare_value(v_z, v_old, (v_control & u32(15i)), cw_thread, cw_block, cw_grid);
        } else {
          var cw_tmp_89: bool;
          if (((v_flags & u32(64i)) != u32(0i))) {
            cw_tmp_89 = (v_z <= v_old);
          } else {
            cw_tmp_89 = (v_z < v_old);
          }
          v_depth_pass = select(u32(0), u32(1), cw_tmp_89);
        }
      }
      if (((v_depth_pass == 0u) && (((v_flags & 8192u) == 0u) || (cw_params.p_stencil_enabled == 0u)))) {
        continue;
      }
      var v_inv: f32 = ((cw_divide_f32(v_a, v_aw) + cw_divide_f32(v_b, v_bw)) + cw_divide_f32(v_c, v_cw));
      v_a = cw_divide_f32(cw_divide_f32(v_a, v_aw), v_inv);
      v_b = cw_divide_f32(cw_divide_f32(v_b, v_bw), v_inv);
      v_c = cw_divide_f32(cw_divide_f32(v_c, v_cw), v_inv);
      var v_pointMetadata: array<f32, 4>;
      {
        var v_channel: u32 = u32(0i);
        loop {
          if (!(v_channel < u32(4i))) { break; }
          v_pointMetadata[v_channel] = (((v_a * b_attributes[((cw_params.p_point_fade_offset + ((v_ia / 10u) * 12u)) + v_channel)]) + (v_b * b_attributes[((cw_params.p_point_fade_offset + ((v_ib / 10u) * 12u)) + v_channel)])) + (v_c * b_attributes[((cw_params.p_point_fade_offset + ((v_ic / 10u) * 12u)) + v_channel)]));
          continuing {
            v_channel += u32(1);
          }
        }
      }
      v_pointFade = (v_pointFade * v_pointMetadata[0i]);
      if ((v_pointMetadata[3i] > 0.0f)) {
        let cw_argument_index_90 = 1i;
        let cw_argument_index_91 = 2i;
        let cw_argument_index_92 = 3i;
        var v_coverage: f32 = f_point_disk_coverage(v_pointMetadata[cw_argument_index_90], v_pointMetadata[cw_argument_index_91], v_pointMetadata[cw_argument_index_92], cw_thread, cw_block, cw_grid);
        if ((v_coverage <= 0.0f)) {
          continue;
        }
        v_pointFade = (v_pointFade * v_coverage);
      }
      if ((v_pointMetadata[3i] < 0.0f)) {
        var v_pointFlags: u32 = u32(b_attributes[(v_raster + 49u)]);
        v_spriteMask = ((v_pointFlags >> 2u) & 15u);
        v_spriteDx = cw_divide_f32((-0.5f), v_pointMetadata[3i]);
        var cw_tmp_93: f32;
        if (((v_pointFlags & 64u) != 0u)) {
          cw_tmp_93 = (-v_spriteDx);
        } else {
          cw_tmp_93 = v_spriteDx;
        }
        v_spriteDy = cw_tmp_93;
        var cw_tmp_94: f32;
        if ((v_multisample != 0u)) {
          cw_tmp_94 = (0.5f - v_sampleX);
        } else {
          cw_tmp_94 = 0.0f;
        }
        var v_localX: f32 = (v_pointMetadata[1i] + cw_tmp_94);
        var cw_tmp_95: f32;
        if ((v_multisample != 0u)) {
          cw_tmp_95 = (v_sampleY - 0.5f);
        } else {
          cw_tmp_95 = 0.0f;
        }
        var v_localY: f32 = (v_pointMetadata[2i] + cw_tmp_95);
        v_spriteU = (0.5f + (v_localX * v_spriteDx));
        v_spriteV = (0.5f - (v_localY * v_spriteDy));
      }
      var v_u: f32 = (((v_a * b_vertices[(v_ia + u32(8i))]) + (v_b * b_vertices[(v_ib + u32(8i))])) + (v_c * b_vertices[(v_ic + u32(8i))]));
      var v_v: f32 = (((v_a * b_vertices[(v_ia + u32(9i))]) + (v_b * b_vertices[(v_ib + u32(9i))])) + (v_c * b_vertices[(v_ic + u32(9i))]));
      var v_dax: f32 = cw_divide_f32(v_gradAx, v_aw);
      var v_dbx: f32 = cw_divide_f32(v_gradBx, v_bw);
      var v_dcx: f32 = cw_divide_f32(v_gradCx, v_cw);
      var v_day: f32 = cw_divide_f32(v_gradAy, v_aw);
      var v_dby: f32 = cw_divide_f32(v_gradBy, v_bw);
      var v_dcy: f32 = cw_divide_f32(v_gradCy, v_cw);
      var v_dudx: f32 = (cw_divide_f32((((v_dax * (b_vertices[(v_ia + u32(8i))] - v_u)) + (v_dbx * (b_vertices[(v_ib + u32(8i))] - v_u))) + (v_dcx * (b_vertices[(v_ic + u32(8i))] - v_u))), v_inv) * f32(b_materials[(v_m + u32(1i))]));
      var v_dvdx: f32 = (cw_divide_f32((((v_dax * (b_vertices[(v_ia + u32(9i))] - v_v)) + (v_dbx * (b_vertices[(v_ib + u32(9i))] - v_v))) + (v_dcx * (b_vertices[(v_ic + u32(9i))] - v_v))), v_inv) * f32(b_materials[(v_m + u32(2i))]));
      var v_dudy: f32 = (cw_divide_f32((((v_day * (b_vertices[(v_ia + u32(8i))] - v_u)) + (v_dby * (b_vertices[(v_ib + u32(8i))] - v_u))) + (v_dcy * (b_vertices[(v_ic + u32(8i))] - v_u))), v_inv) * f32(b_materials[(v_m + u32(1i))]));
      var v_dvdy: f32 = (cw_divide_f32((((v_day * (b_vertices[(v_ia + u32(9i))] - v_v)) + (v_dby * (b_vertices[(v_ib + u32(9i))] - v_v))) + (v_dcy * (b_vertices[(v_ic + u32(9i))] - v_v))), v_inv) * f32(b_materials[(v_m + u32(2i))]));
      if (((v_spriteMask & 1u) != 0u)) {
        v_u = v_spriteU;
        v_v = v_spriteV;
        v_dudx = (v_spriteDx * f32(b_materials[(v_m + u32(1i))]));
        v_dvdy = (v_spriteDy * f32(b_materials[(v_m + u32(2i))]));
        v_dvdx = 0.0f;
        v_dudy = 0.0f;
      }
      var v_lod: f32 = (0.5f * log2(max(1e-8f, max(((v_dudx * v_dudx) + (v_dvdx * v_dvdx)), ((v_dudy * v_dudy) + (v_dvdy * v_dvdy))))));
      var v_color: array<f32, 4>;
      var v_fixedSpecular: array<f32, 3>;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          v_fixedSpecular[v_k] = 0.0f;
          continuing {
            v_k += u32(1);
          }
        }
      }
      var v_fixedLit: u32 = u32(0i);
      var v_fa: u32 = u32(0i);
      var v_fb: u32 = u32(0i);
      var v_fc: u32 = u32(0i);
      if ((cw_params.p_fixed_enabled != u32(0i))) {
        var cw_tmp_96: u32;
        if ((v_front != u32(0i))) {
          cw_tmp_96 = 0u;
        } else {
          cw_tmp_96 = 8u;
        }
        v_fa = ((cw_params.p_fixed_offset + ((v_ia / u32(10i)) * u32(16i))) + cw_tmp_96);
        var cw_tmp_97: u32;
        if ((v_front != u32(0i))) {
          cw_tmp_97 = 0u;
        } else {
          cw_tmp_97 = 8u;
        }
        v_fb = ((cw_params.p_fixed_offset + ((v_ib / u32(10i)) * u32(16i))) + cw_tmp_97);
        var cw_tmp_98: u32;
        if ((v_front != u32(0i))) {
          cw_tmp_98 = 0u;
        } else {
          cw_tmp_98 = 8u;
        }
        v_fc = ((cw_params.p_fixed_offset + ((v_ic / u32(10i)) * u32(16i))) + cw_tmp_98);
        v_fixedLit = select(u32(0), u32(1), (b_attributes[(v_fa + u32(7i))] > 0.5f));
        if ((v_fixedLit != u32(0i))) {
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              v_fixedSpecular[v_k] = (((v_a * b_attributes[((v_fa + u32(4i)) + v_k)]) + (v_b * b_attributes[((v_fb + u32(4i)) + v_k)])) + (v_c * b_attributes[((v_fc + u32(4i)) + v_k)]));
              continuing {
                v_k += u32(1);
              }
            }
          }
        }
      }
      var v_fragmentNormal: array<f32, 3>;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          v_fragmentNormal[v_k] = 0.0f;
          continuing {
            v_k += u32(1);
          }
        }
      }
      var v_writeNormal: u32 = u32(0i);
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(4i))) { break; }
          var cw_tmp_99: f32;
          if ((v_fixedLit != u32(0i))) {
            cw_tmp_99 = (((v_a * b_attributes[(v_fa + v_k)]) + (v_b * b_attributes[(v_fb + v_k)])) + (v_c * b_attributes[(v_fc + v_k)]));
          } else {
            cw_tmp_99 = (((v_a * b_vertices[((v_ia + u32(4i)) + v_k)]) + (v_b * b_vertices[((v_ib + u32(4i)) + v_k)])) + (v_c * b_vertices[((v_ic + u32(4i)) + v_k)]));
          }
          v_color[v_k] = cw_tmp_99;
          if ((((v_flags & u32(1i)) != u32(0i)) && ((v_flags & u32(547840i)) == u32(0i)))) {
            var cw_tmp_107: f32;
            if (((v_flags & u32(512i)) != u32(0i))) {
              let cw_argument_index_100 = v_m;
              let cw_argument_index_101 = (v_m + u32(1i));
              let cw_argument_index_102 = (v_m + u32(2i));
              let cw_argument_index_103 = (v_m + u32(11i));
              cw_tmp_107 = f_cw_buffer_helper_0(0i, b_materials[cw_argument_index_100], b_materials[cw_argument_index_101], b_materials[cw_argument_index_102], v_u, v_v, v_dudx, v_dvdx, v_dudy, v_dvdy, b_materials[cw_argument_index_103], v_k, cw_thread, cw_block, cw_grid);
            } else {
              let cw_argument_index_104 = v_m;
              let cw_argument_index_105 = (v_m + u32(1i));
              let cw_argument_index_106 = (v_m + u32(2i));
              cw_tmp_107 = f_cw_buffer_helper_1(0i, b_materials[cw_argument_index_104], b_materials[cw_argument_index_105], b_materials[cw_argument_index_106], v_u, v_v, v_flags, v_k, cw_thread, cw_block, cw_grid);
            }
            v_color[v_k] = (v_color[v_k] * cw_tmp_107);
          }
          continuing {
            v_k += u32(1);
          }
        }
      }
      if (((v_flags & 524288u) != 0u)) {
        var v_glyphAlpha: f32 = v_color[3i];
        var v_shadowAlpha: f32 = 0.0f;
        var v_glyphRgb: array<f32, 3>;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < 3u)) { break; }
            v_glyphRgb[v_k] = v_color[v_k];
            continuing {
              v_k += u32(1);
            }
          }
        }
        var cw_tmp_108: u32;
        if ((b_attributes[(v_raster + u32(30i))] == 1.0f)) {
          cw_tmp_108 = 1u;
        } else {
          cw_tmp_108 = 0u;
        }
        var v_shadow: u32 = cw_tmp_108;
        var cw_tmp_109: u32;
        if ((b_attributes[(v_raster + u32(30i))] == 2.0f)) {
          cw_tmp_109 = 1u;
        } else {
          cw_tmp_109 = 0u;
        }
        var v_outline: u32 = cw_tmp_109;
        var cw_tmp_110: f32;
        if ((v_outline != 0u)) {
          cw_tmp_110 = (b_attributes[(v_raster + u32(31i))] * 0.5f);
        } else {
          cw_tmp_110 = 0.0f;
        }
        var v_outlineWidth: f32 = cw_tmp_110;
        {
          var v_layer: u32 = u32(0i);
          loop {
            if (!(v_layer <= v_shadow)) { break; }
            var v_gu: f32 = v_u;
            var v_gv: f32 = v_v;
            v_color[3i] = v_glyphAlpha;
            {
              var v_k: u32 = u32(0i);
              loop {
                if (!(v_k < 3u)) { break; }
                v_color[v_k] = v_glyphRgb[v_k];
                continuing {
                  v_k += u32(1);
                }
              }
            }
            if (((v_layer == 0u) && (v_shadow != 0u))) {
              var v_scale: f32 = cw_divide_f32((-b_attributes[(v_raster + u32(28i))]), b_attributes[(v_raster + u32(29i))]);
              v_gu = (v_gu + (b_attributes[(v_raster + u32(31i))] * v_scale));
              v_gv = (v_gv + (b_attributes[(v_raster + u32(32i))] * v_scale));
            }
            var cw_tmp_111: u32;
            if (((v_flags & 1048576u) != 0u)) {
              cw_tmp_111 = 0u;
            } else {
              cw_tmp_111 = 3u;
            }
            var v_channel: u32 = cw_tmp_111;
            if (((v_flags & 2097152u) == 0u)) {
              let cw_argument_index_112 = v_m;
              let cw_argument_index_113 = (v_m + u32(1i));
              let cw_argument_index_114 = (v_m + u32(2i));
              let cw_argument_index_115 = (v_m + u32(11i));
              var v_coverage: f32 = f_cw_buffer_helper_0(0i, b_materials[cw_argument_index_112], b_materials[cw_argument_index_113], b_materials[cw_argument_index_114], v_gu, v_gv, v_dudx, v_dvdx, v_dudy, v_dvdy, b_materials[cw_argument_index_115], v_channel, cw_thread, cw_block, cw_grid);
              if ((v_outline != 0u)) {
                var v_delta: f32 = cw_divide_f32(((1.6f * b_attributes[(v_raster + u32(31i))]) * b_attributes[(v_raster + u32(28i))]), b_attributes[(v_raster + u32(29i))]);
                var v_outer: f32 = v_coverage;
                {
                  var v_oy: u32 = u32(0i);
                  loop {
                    if (!(v_oy < 3u)) { break; }
                    {
                      var v_ox: u32 = u32(0i);
                      loop {
                        if (!(v_ox < 3u)) { break; }
                        let cw_argument_index_116 = v_m;
                        let cw_argument_index_117 = (v_m + u32(1i));
                        let cw_argument_index_118 = (v_m + u32(2i));
                        let cw_argument_index_119 = (v_m + u32(11i));
                        var v_local: f32 = f_cw_buffer_helper_0(0i, b_materials[cw_argument_index_116], b_materials[cw_argument_index_117], b_materials[cw_argument_index_118], (v_gu + (((f32(v_ox) - 1.0f) * v_delta) * 0.5f)), (v_gv + (((f32(v_oy) - 1.0f) * v_delta) * 0.5f)), v_dudx, v_dvdx, v_dudy, v_dvdy, b_materials[cw_argument_index_119], v_channel, cw_thread, cw_block, cw_grid);
                        v_outer = max(v_outer, v_local);
                        continuing {
                          v_ox += u32(1);
                        }
                      }
                    }
                    continuing {
                      v_oy += u32(1);
                    }
                  }
                }
                v_outer = min(1.0f, v_outer);
                var v_mixValue: f32 = ((v_coverage * v_coverage) * (3.0f - (2.0f * v_coverage)));
                {
                  var v_k: u32 = u32(0i);
                  loop {
                    if (!(v_k < 3u)) { break; }
                    v_color[v_k] = ((b_attributes[((v_raster + u32(33i)) + v_k)] * (1.0f - v_mixValue)) + (v_color[v_k] * v_mixValue));
                    continuing {
                      v_k += u32(1);
                    }
                  }
                }
                v_color[3i] = (((v_glyphAlpha * v_outer) * v_outer) * (3.0f - (2.0f * v_outer)));
              } else {
                v_color[3i] = (v_color[3i] * v_coverage);
              }
            } else {
              var cw_tmp_120: u32;
              if ((v_channel == 0u)) {
                cw_tmp_120 = 1u;
              } else {
                cw_tmp_120 = 0u;
              }
              v_channel = cw_tmp_120;
              var v_dxu: f32 = cw_divide_f32((0.75f * v_dudx), f32(b_materials[(v_m + u32(1i))]));
              var v_dxv: f32 = cw_divide_f32((0.75f * v_dvdx), f32(b_materials[(v_m + u32(2i))]));
              var v_dyu: f32 = cw_divide_f32((0.75f * v_dudy), f32(b_materials[(v_m + u32(1i))]));
              var v_dyv: f32 = cw_divide_f32((0.75f * v_dvdy), f32(b_materials[(v_m + u32(2i))]));
              var v_textureDimension: f32 = b_attributes[(v_raster + u32(29i))];
              var v_glyphDimension: f32 = b_attributes[(v_raster + u32(28i))];
              var v_distance: f32 = cw_divide_f32((sqrt((((v_dxu + v_dyu) * (v_dxu + v_dyu)) + ((v_dxv + v_dyv) * (v_dxv + v_dyv)))) * v_textureDimension), v_glyphDimension);
              var v_nx: u32 = u32(min(4.0f, max(2.0f, floor((v_textureDimension * sqrt(((v_dxu * v_dxu) + (v_dxv * v_dxv))))))));
              var v_ny: u32 = u32(min(4.0f, max(2.0f, floor((v_textureDimension * sqrt(((v_dyu * v_dyu) + (v_dyv * v_dyv))))))));
              var v_blend: f32 = cw_divide_f32((1.5f * v_distance), f32((v_nx * v_ny)));
              var v_halfBlend: f32 = (v_blend * 0.5f);
              let cw_argument_index_121 = v_m;
              let cw_argument_index_122 = (v_m + u32(1i));
              let cw_argument_index_123 = (v_m + u32(2i));
              let cw_argument_index_124 = (v_m + u32(11i));
              var v_center: f32 = f_cw_buffer_helper_2(0i, b_materials[cw_argument_index_121], b_materials[cw_argument_index_122], b_materials[cw_argument_index_123], v_gu, v_gv, 0.0f, b_materials[cw_argument_index_124], v_channel, cw_thread, cw_block, cw_grid);
              var cw_tmp_125: f32;
              if ((v_center == 0.0f)) {
                cw_tmp_125 = (-1.0f);
              } else {
                cw_tmp_125 = ((v_center - 0.5f) * cw_divide_f32(1.41f, 6.0f));
              }
              var v_edge: f32 = cw_tmp_125;
              if (((((-v_edge) - v_outlineWidth) - v_halfBlend) > v_distance)) {
                v_color[3i] = 0.0f;
              } else {
                if (((v_edge - v_halfBlend) <= v_distance)) {
                  var v_sum: f32 = 0.0f;
                  var v_rgbSum: array<f32, 3>;
                  {
                    var v_k: u32 = u32(0i);
                    loop {
                      if (!(v_k < 3u)) { break; }
                      v_rgbSum[v_k] = 0.0f;
                      continuing {
                        v_k += u32(1);
                      }
                    }
                  }
                  {
                    var v_sy: u32 = u32(0i);
                    loop {
                      if (!(v_sy < v_ny)) { break; }
                      {
                        var v_sx: u32 = u32(0i);
                        loop {
                          if (!(v_sx < v_nx)) { break; }
                          var v_su: f32 = ((((v_gu - (v_dxu * 0.5f)) - (v_dyu * 0.5f)) + cw_divide_f32((v_dxu * f32(v_sx)), f32((v_nx - 1u)))) + cw_divide_f32((v_dyu * f32(v_sy)), f32((v_ny - 1u))));
                          var v_sv: f32 = ((((v_gv - (v_dxv * 0.5f)) - (v_dyv * 0.5f)) + cw_divide_f32((v_dxv * f32(v_sx)), f32((v_nx - 1u)))) + cw_divide_f32((v_dyv * f32(v_sy)), f32((v_ny - 1u))));
                          let cw_argument_index_126 = v_m;
                          let cw_argument_index_127 = (v_m + u32(1i));
                          let cw_argument_index_128 = (v_m + u32(2i));
                          let cw_argument_index_129 = (v_m + u32(11i));
                          var v_value: f32 = f_cw_buffer_helper_2(0i, b_materials[cw_argument_index_126], b_materials[cw_argument_index_127], b_materials[cw_argument_index_128], v_su, v_sv, 0.0f, b_materials[cw_argument_index_129], v_channel, cw_thread, cw_block, cw_grid);
                          var cw_tmp_130: f32;
                          if ((v_value == 0.0f)) {
                            cw_tmp_130 = (-1.0f);
                          } else {
                            cw_tmp_130 = ((v_value - 0.5f) * cw_divide_f32(1.41f, 6.0f));
                          }
                          var v_e: f32 = cw_tmp_130;
                          var cw_tmp_131: f32;
                          if ((v_e > v_halfBlend)) {
                            cw_tmp_131 = 1.0f;
                          } else {
                            cw_tmp_131 = 0.0f;
                          }
                          var v_coverage: f32 = cw_tmp_131;
                          if ((((v_e > (-v_halfBlend)) && (v_e <= v_halfBlend)) && (v_blend > 0.0f))) {
                            v_coverage = min(1.0f, max(0.0f, cw_divide_f32((v_e + v_halfBlend), v_blend)));
                            v_coverage = ((v_coverage * v_coverage) * (3.0f - (2.0f * v_coverage)));
                          }
                          var v_sampleColor: array<f32, 3>;
                          {
                            var v_k: u32 = u32(0i);
                            loop {
                              if (!(v_k < 3u)) { break; }
                              v_sampleColor[v_k] = v_color[v_k];
                              continuing {
                                v_k += u32(1);
                              }
                            }
                          }
                          var v_alpha: f32 = (v_glyphAlpha * v_coverage);
                          if (((v_outline != 0u) && (v_e <= v_halfBlend))) {
                            if (((v_e > (-v_halfBlend)) && (v_blend > 0.0f))) {
                              var v_transition: f32 = min(1.0f, max(0.0f, cw_divide_f32((v_halfBlend - v_e), v_blend)));
                              v_transition = ((v_transition * v_transition) * (3.0f - (2.0f * v_transition)));
                              {
                                var v_k: u32 = u32(0i);
                                loop {
                                  if (!(v_k < 3u)) { break; }
                                  v_sampleColor[v_k] = ((v_color[v_k] * (1.0f - v_transition)) + (b_attributes[((v_raster + u32(33i)) + v_k)] * v_transition));
                                  continuing {
                                    v_k += u32(1);
                                  }
                                }
                              }
                              v_alpha = (v_glyphAlpha * ((1.0f - v_transition) + (b_attributes[(v_raster + u32(36i))] * v_transition)));
                            } else {
                              {
                                var v_k: u32 = u32(0i);
                                loop {
                                  if (!(v_k < 3u)) { break; }
                                  v_sampleColor[v_k] = b_attributes[((v_raster + u32(33i)) + v_k)];
                                  continuing {
                                    v_k += u32(1);
                                  }
                                }
                              }
                              if ((v_e > (v_halfBlend - v_outlineWidth))) {
                                v_alpha = (v_glyphAlpha * b_attributes[(v_raster + u32(36i))]);
                              } else {
                                if (((v_e > (-(v_outlineWidth + v_halfBlend))) && (v_blend > 0.0f))) {
                                  v_alpha = cw_divide_f32((v_glyphAlpha * ((v_halfBlend + v_outlineWidth) + v_e)), v_blend);
                                } else {
                                  v_alpha = 0.0f;
                                }
                              }
                            }
                          }
                          v_sum = (v_sum + (v_alpha * v_alpha));
                          {
                            var v_k: u32 = u32(0i);
                            loop {
                              if (!(v_k < 3u)) { break; }
                              v_rgbSum[v_k] = (v_rgbSum[v_k] + (v_sampleColor[v_k] * v_alpha));
                              continuing {
                                v_k += u32(1);
                              }
                            }
                          }
                          continuing {
                            v_sx += u32(1);
                          }
                        }
                      }
                      continuing {
                        v_sy += u32(1);
                      }
                    }
                  }
                  if ((v_sum > 0.0f)) {
                    {
                      var v_k: u32 = u32(0i);
                      loop {
                        if (!(v_k < 3u)) { break; }
                        v_color[v_k] = cw_divide_f32(v_rgbSum[v_k], v_sum);
                        continuing {
                          v_k += u32(1);
                        }
                      }
                    }
                  }
                  v_color[3i] = cw_divide_f32(v_sum, f32((v_nx * v_ny)));
                }
              }
            }
            if ((v_shadow != 0u)) {
              let cw_argument_index_132 = 3i;
              var cw_tmp_133: f32;
              if (((v_flags & 2097152u) != 0u)) {
                cw_tmp_133 = 0.6f;
              } else {
                cw_tmp_133 = 0.5f;
              }
              var v_alpha: f32 = f_render_power(max(0.0f, v_color[cw_argument_index_132]), cw_tmp_133, cw_thread, cw_block, cw_grid);
              if ((v_layer == 0u)) {
                v_shadowAlpha = v_alpha;
              } else {
                {
                  var v_k: u32 = u32(0i);
                  loop {
                    if (!(v_k < u32(3i))) { break; }
                    v_color[v_k] = ((b_attributes[((v_raster + u32(33i)) + v_k)] * (1.0f - v_alpha)) + (v_color[v_k] * v_alpha));
                    continuing {
                      v_k += u32(1);
                    }
                  }
                }
                v_color[3i] = ((v_shadowAlpha * (1.0f - v_alpha)) + (v_alpha * v_alpha));
              }
            }
            continuing {
              v_layer += u32(1);
            }
          }
        }
        if ((v_color[3i] == 0.0f)) {
          continue;
        }
      }
      if (((v_flags & 16384u) != 0u)) {
        var v_primary: array<f32, 4>;
        var v_samples: array<f32, 16>;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(4i))) { break; }
            v_primary[v_k] = v_color[v_k];
            continuing {
              v_k += u32(1);
            }
          }
        }
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(16i))) { break; }
            v_samples[v_k] = 1.0f;
            continuing {
              v_k += u32(1);
            }
          }
        }
        var v_environment: u32 = b_materials[v_m];
        {
          var v_stage: u32 = u32(0i);
          loop {
            if (!((v_stage < 4u) && (v_environment != 0u))) { break; }
            var v_unit: u32 = b_texels[(v_environment + 27u)];
            {
              var v_k: u32 = u32(0i);
              loop {
                if (!(v_k < u32(4i))) { break; }
                let cw_argument_index_134 = v_t;
                let cw_argument_index_135 = (v_t + u32(1i));
                let cw_argument_index_136 = (v_t + u32(2i));
                v_samples[((v_unit * 4u) + v_k)] = f_cw_buffer_helper_3(0i, 0i, v_environment, b_triangles[cw_argument_index_134], b_triangles[cw_argument_index_135], b_triangles[cw_argument_index_136], v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, v_spriteMask, v_spriteU, v_spriteV, v_spriteDx, v_spriteDy, cw_thread, cw_block, cw_grid);
                continuing {
                  v_k += u32(1);
                }
              }
            }
            v_environment = b_texels[(v_environment + 3u)];
            continuing {
              v_stage += u32(1);
            }
          }
        }
        v_environment = b_materials[v_m];
        {
          var v_stage: u32 = u32(0i);
          loop {
            if (!((v_stage < 4u) && (v_environment != 0u))) { break; }
            var v_unit: u32 = b_texels[(v_environment + 27u)];
            if ((b_texels[(v_environment + 1u)] == 5u)) {
              var v_arguments: array<f32, 12>;
              {
                var v_k: u32 = u32(0i);
                loop {
                  if (!(v_k < u32(4i))) { break; }
                  {
                    var v_argument: u32 = u32(0i);
                    loop {
                      if (!(v_argument < u32(3i))) { break; }
                      var cw_tmp_137: u32;
                      if ((v_k == 3u)) {
                        cw_tmp_137 = 18u;
                      } else {
                        cw_tmp_137 = 12u;
                      }
                      var v_descriptor: u32 = ((v_environment + cw_tmp_137) + v_argument);
                      var v_source: u32 = b_texels[v_descriptor];
                      var v_operand: u32 = b_texels[(v_descriptor + 3u)];
                      var cw_tmp_138: u32;
                      if ((v_operand >= 2u)) {
                        cw_tmp_138 = 3u;
                      } else {
                        cw_tmp_138 = v_k;
                      }
                      var v_channel: u32 = cw_tmp_138;
                      var cw_tmp_143: f32;
                      if ((v_source == 0u)) {
                        cw_tmp_143 = v_samples[((v_unit * 4u) + v_channel)];
                      } else {
                        var cw_tmp_142: f32;
                        if ((v_source == 1u)) {
                          cw_tmp_142 = v_primary[v_channel];
                        } else {
                          var cw_tmp_141: f32;
                          if ((v_source == 2u)) {
                            let cw_argument_index_139 = ((v_environment + 4u) + v_channel);
                            cw_tmp_141 = bitcast<f32>(b_texels[cw_argument_index_139]);
                          } else {
                            var cw_tmp_140: f32;
                            if ((v_source == 3u)) {
                              cw_tmp_140 = v_color[v_channel];
                            } else {
                              cw_tmp_140 = v_samples[(((v_source - 4u) * 4u) + v_channel)];
                            }
                            cw_tmp_141 = cw_tmp_140;
                          }
                          cw_tmp_142 = cw_tmp_141;
                        }
                        cw_tmp_143 = cw_tmp_142;
                      }
                      var v_value: f32 = cw_tmp_143;
                      var cw_tmp_144: f32;
                      if (((v_operand & 1u) != 0u)) {
                        cw_tmp_144 = (1.0f - v_value);
                      } else {
                        cw_tmp_144 = v_value;
                      }
                      v_arguments[((v_k * 3u) + v_argument)] = cw_tmp_144;
                      continuing {
                        v_argument += u32(1);
                      }
                    }
                  }
                  continuing {
                    v_k += u32(1);
                  }
                }
              }
              var v_rgbOperation: u32 = b_texels[(v_environment + 8u)];
              var v_dot: f32 = 0.0f;
              {
                var v_k: u32 = u32(0i);
                loop {
                  if (!(v_k < u32(3i))) { break; }
                  v_dot = (v_dot + ((4.0f * (v_arguments[(v_k * 3u)] - 0.5f)) * (v_arguments[((v_k * 3u) + 1u)] - 0.5f)));
                  continuing {
                    v_k += u32(1);
                  }
                }
              }
              {
                var v_k: u32 = u32(0i);
                loop {
                  if (!(v_k < u32(4i))) { break; }
                  var cw_tmp_145: u32;
                  if ((v_k == 3u)) {
                    cw_tmp_145 = 9u;
                  } else {
                    cw_tmp_145 = 8u;
                  }
                  var v_operation: u32 = b_texels[(v_environment + cw_tmp_145)];
                  var cw_tmp_149: f32;
                  if (((v_rgbOperation >= 6u) && ((v_k < 3u) || (v_rgbOperation == 7u)))) {
                    cw_tmp_149 = v_dot;
                  } else {
                    let cw_argument_index_146 = (v_k * 3u);
                    let cw_argument_index_147 = ((v_k * 3u) + 1u);
                    let cw_argument_index_148 = ((v_k * 3u) + 2u);
                    cw_tmp_149 = f_combine_texture_arguments(v_arguments[cw_argument_index_146], v_arguments[cw_argument_index_147], v_arguments[cw_argument_index_148], v_operation, cw_thread, cw_block, cw_grid);
                  }
                  var v_value: f32 = cw_tmp_149;
                  var cw_tmp_150: u32;
                  if (((v_k == 3u) && (v_rgbOperation != 7u))) {
                    cw_tmp_150 = 11u;
                  } else {
                    cw_tmp_150 = 10u;
                  }
                  var v_scale: u32 = b_texels[(v_environment + cw_tmp_150)];
                  v_color[v_k] = min(1.0f, max(0.0f, (v_value * f32(v_scale))));
                  continuing {
                    v_k += u32(1);
                  }
                }
              }
            } else {
              {
                var v_k: u32 = u32(0i);
                loop {
                  if (!(v_k < u32(4i))) { break; }
                  let cw_argument_index_151 = v_k;
                  let cw_argument_index_152 = ((v_unit * 4u) + v_k);
                  let cw_argument_index_153 = ((v_unit * 4u) + 3u);
                  let cw_argument_index_154 = ((v_environment + 4u) + v_k);
                  let cw_argument_index_155 = (v_environment + 1u);
                  let cw_argument_index_156 = (v_environment + 2u);
                  v_color[v_k] = min(1.0f, max(0.0f, f_texture_environment(v_color[cw_argument_index_151], v_samples[cw_argument_index_152], v_samples[cw_argument_index_153], bitcast<f32>(b_texels[cw_argument_index_154]), b_texels[cw_argument_index_155], b_texels[cw_argument_index_156], v_k, cw_thread, cw_block, cw_grid)));
                  continuing {
                    v_k += u32(1);
                  }
                }
              }
            }
            v_environment = b_texels[(v_environment + 3u)];
            continuing {
              v_stage += u32(1);
            }
          }
        }
      }
      if (((v_flags & u32(4096i)) != u32(0i))) {
        var v_data: u32 = b_materials[v_m];
        var cw_tmp_159: f32;
        if ((b_texels[(v_data + u32(5i))] != u32(0i))) {
          var cw_tmp_157: f32;
          if (((b_texels[(v_data + u32(7i))] & u32(1i)) != u32(0i))) {
            cw_tmp_157 = 1.0f;
          } else {
            cw_tmp_157 = v_color[3i];
          }
          cw_tmp_159 = cw_tmp_157;
        } else {
          let cw_argument_index_158 = (v_data + u32(6i));
          cw_tmp_159 = bitcast<f32>(b_texels[cw_argument_index_158]);
        }
        var v_alpha: f32 = cw_tmp_159;
        if (((v_flags & u32(1i)) != u32(0i))) {
          let cw_argument_index_160 = v_data;
          let cw_argument_index_161 = (v_data + u32(1i));
          let cw_argument_index_162 = (v_data + u32(2i));
          let cw_argument_index_163 = (v_data + u32(3i));
          v_alpha = (v_alpha * f_cw_buffer_helper_0(0i, b_texels[cw_argument_index_160], b_texels[cw_argument_index_161], b_texels[cw_argument_index_162], v_u, v_v, v_dudx, v_dvdx, v_dudy, v_dvdy, b_texels[cw_argument_index_163], u32(3i), cw_thread, cw_block, cw_grid));
        }
        var v_function: u32 = b_texels[(v_data + u32(8i))];
        let cw_argument_index_164 = (v_data + u32(4i));
        var v_reference: f32 = bitcast<f32>(b_texels[cw_argument_index_164]);
        if ((((b_texels[(v_data + u32(7i))] & 4u) != 0u) && ((((v_function == 1u) || (v_function == 3u)) || (v_function == 4u)) || (v_function == 6u)))) {
          var v_quadAlpha: array<f32, 4>;
          {
            var v_lane: u32 = u32(0i);
            loop {
              if (!(v_lane < u32(4i))) { break; }
              var v_dx: f32 = ((f32(((v_x - (v_x % 2u)) + (v_lane % 2u))) + 0.5f) - v_px);
              var v_dy: f32 = ((f32(((v_y - (v_y % 2u)) + (v_lane / 2u))) + 0.5f) - v_py);
              var v_qi: f32 = ((v_inv + (v_dx * ((v_dax + v_dbx) + v_dcx))) + (v_dy * ((v_day + v_dby) + v_dcy)));
              var cw_tmp_165: f32;
              if ((abs(v_qi) > 1e-12f)) {
                cw_tmp_165 = v_qi;
              } else {
                cw_tmp_165 = 1e-12f;
              }
              v_qi = cw_tmp_165;
              var v_qa: f32 = cw_divide_f32((((v_a * v_inv) + (v_dx * v_dax)) + (v_dy * v_day)), v_qi);
              var v_qb: f32 = cw_divide_f32((((v_b * v_inv) + (v_dx * v_dbx)) + (v_dy * v_dby)), v_qi);
              var v_qc: f32 = cw_divide_f32((((v_c * v_inv) + (v_dx * v_dcx)) + (v_dy * v_dcy)), v_qi);
              var cw_tmp_168: f32;
              if ((b_texels[(v_data + u32(5i))] != u32(0i))) {
                var cw_tmp_166: f32;
                if (((b_texels[(v_data + u32(7i))] & 1u) != 0u)) {
                  cw_tmp_166 = 1.0f;
                } else {
                  cw_tmp_166 = (((v_qa * b_vertices[(v_ia + u32(7i))]) + (v_qb * b_vertices[(v_ib + u32(7i))])) + (v_qc * b_vertices[(v_ic + u32(7i))]));
                }
                cw_tmp_168 = cw_tmp_166;
              } else {
                let cw_argument_index_167 = (v_data + u32(6i));
                cw_tmp_168 = bitcast<f32>(b_texels[cw_argument_index_167]);
              }
              var v_value: f32 = cw_tmp_168;
              if (((v_flags & 1u) != 0u)) {
                var v_qu: f32 = (((v_qa * b_vertices[(v_ia + u32(8i))]) + (v_qb * b_vertices[(v_ib + u32(8i))])) + (v_qc * b_vertices[(v_ic + u32(8i))]));
                var v_qv: f32 = (((v_qa * b_vertices[(v_ia + u32(9i))]) + (v_qb * b_vertices[(v_ib + u32(9i))])) + (v_qc * b_vertices[(v_ic + u32(9i))]));
                var v_ux: f32 = (cw_divide_f32((((v_dax * (b_vertices[(v_ia + u32(8i))] - v_qu)) + (v_dbx * (b_vertices[(v_ib + u32(8i))] - v_qu))) + (v_dcx * (b_vertices[(v_ic + u32(8i))] - v_qu))), v_qi) * f32(b_texels[(v_data + u32(1i))]));
                var v_vx: f32 = (cw_divide_f32((((v_dax * (b_vertices[(v_ia + u32(9i))] - v_qv)) + (v_dbx * (b_vertices[(v_ib + u32(9i))] - v_qv))) + (v_dcx * (b_vertices[(v_ic + u32(9i))] - v_qv))), v_qi) * f32(b_texels[(v_data + u32(2i))]));
                var v_uy: f32 = (cw_divide_f32((((v_day * (b_vertices[(v_ia + u32(8i))] - v_qu)) + (v_dby * (b_vertices[(v_ib + u32(8i))] - v_qu))) + (v_dcy * (b_vertices[(v_ic + u32(8i))] - v_qu))), v_qi) * f32(b_texels[(v_data + u32(1i))]));
                var v_vy: f32 = (cw_divide_f32((((v_day * (b_vertices[(v_ia + u32(9i))] - v_qv)) + (v_dby * (b_vertices[(v_ib + u32(9i))] - v_qv))) + (v_dcy * (b_vertices[(v_ic + u32(9i))] - v_qv))), v_qi) * f32(b_texels[(v_data + u32(2i))]));
                let cw_argument_index_169 = v_data;
                let cw_argument_index_170 = (v_data + u32(1i));
                let cw_argument_index_171 = (v_data + u32(2i));
                let cw_argument_index_172 = (v_data + u32(3i));
                v_value = (v_value * f_cw_buffer_helper_0(0i, b_texels[cw_argument_index_169], b_texels[cw_argument_index_170], b_texels[cw_argument_index_171], v_qu, v_qv, v_ux, v_vx, v_uy, v_vy, b_texels[cw_argument_index_172], u32(3i), cw_thread, cw_block, cw_grid));
              }
              v_quadAlpha[v_lane] = v_value;
              continuing {
                v_lane += u32(1);
              }
            }
          }
          var v_row: u32 = ((v_y % 2u) * 2u);
          var v_column: u32 = (v_x % 2u);
          var v_alphaWidth: f32 = (abs((v_quadAlpha[(v_row + u32(1i))] - v_quadAlpha[v_row])) + abs((v_quadAlpha[(v_column + u32(2i))] - v_quadAlpha[v_column])));
          var v_coverage: f32 = (cw_divide_f32((v_alpha - min(0.9999f, max(0.0001f, v_reference))), max(v_alphaWidth, 0.0001f)) + 0.5f);
          var cw_tmp_173: f32;
          if (((v_function == 1u) || (v_function == 3u))) {
            cw_tmp_173 = (1.0f - v_coverage);
          } else {
            cw_tmp_173 = v_coverage;
          }
          v_alpha = cw_tmp_173;
        } else {
          if ((f_compare_value(v_alpha, v_reference, v_function, cw_thread, cw_block, cw_grid) == u32(0i))) {
            continue;
          }
        }
        if ((((b_texels[(v_data + u32(7i))] & u32(2i)) != u32(0i)) && (v_alpha <= 0.5f))) {
          continue;
        }
        v_color[0i] = 1.0f;
        v_color[1i] = 1.0f;
        v_color[2i] = 1.0f;
        v_color[3i] = v_alpha;
      }
      if (((v_flags & u32(2048i)) != u32(0i))) {
        var v_data: u32 = b_materials[v_m];
        var v_features: u32 = b_texels[(v_data + u32(4i))];
        var v_mode: u32 = b_texels[(v_data + u32(5i))];
        var cw_tmp_174: u32;
        if (((v_features & u32(16777216i)) != u32(0i))) {
          cw_tmp_174 = b_texels[(cw_params.p_cluster_offset + (v_m / u32(12i)))];
        } else {
          cw_tmp_174 = u32(0i);
        }
        var v_cluster: u32 = cw_tmp_174;
        var v_layers: u32 = b_texels[(v_data + u32(72i))];
        var v_offsets: array<f32, 6>;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(6i))) { break; }
            v_offsets[v_k] = 0.0f;
            continuing {
              v_k += u32(1);
            }
          }
        }
        if (((v_features & u32(1536i)) != u32(0i))) {
          var cw_tmp_175: i32;
          if (((v_features & u32(512i)) != u32(0i))) {
            cw_tmp_175 = 176i;
          } else {
            cw_tmp_175 = 224i;
          }
          var v_heightMap: u32 = (v_data + u32(cw_tmp_175));
          var v_ix: f32 = max(1e-12f, (((v_inv + v_dax) + v_dbx) + v_dcx));
          var v_iy: f32 = max(1e-12f, (((v_inv + v_day) + v_dby) + v_dcy));
          {
            var v_axis: u32 = u32(0i);
            loop {
              if (!(v_axis < u32(2i))) { break; }
              v_offsets[v_axis] = f_cw_buffer_helper_4(0i, 0i, v_heightMap, (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_axis, cw_thread, cw_block, cw_grid);
              v_offsets[(v_axis + u32(2i))] = (f_cw_buffer_helper_4(0i, 0i, v_heightMap, (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), cw_divide_f32(((v_a * v_inv) + v_dax), v_ix), cw_divide_f32(((v_b * v_inv) + v_dbx), v_ix), cw_divide_f32(((v_c * v_inv) + v_dcx), v_ix), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_ix, v_axis, cw_thread, cw_block, cw_grid) - v_offsets[v_axis]);
              v_offsets[(v_axis + u32(4i))] = (f_cw_buffer_helper_4(0i, 0i, v_heightMap, (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), cw_divide_f32(((v_a * v_inv) + v_day), v_iy), cw_divide_f32(((v_b * v_inv) + v_dby), v_iy), cw_divide_f32(((v_c * v_inv) + v_dcy), v_iy), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_iy, v_axis, cw_thread, cw_block, cw_grid) - v_offsets[v_axis]);
              continuing {
                v_axis += u32(1);
              }
            }
          }
        }
        var v_position: array<f32, 3>;
        var v_normal: array<f32, 3>;
        var v_eye: array<f32, 3>;
        var v_normalLength: f32 = 0.0f;
        var v_eyeLength: f32 = 0.0f;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            v_position[v_k] = (((v_a * b_attributes[(((v_ia / u32(10i)) * u32(34i)) + v_k)]) + (v_b * b_attributes[(((v_ib / u32(10i)) * u32(34i)) + v_k)])) + (v_c * b_attributes[(((v_ic / u32(10i)) * u32(34i)) + v_k)]));
            v_normal[v_k] = (((v_a * b_attributes[((((v_ia / u32(10i)) * u32(34i)) + u32(3i)) + v_k)]) + (v_b * b_attributes[((((v_ib / u32(10i)) * u32(34i)) + u32(3i)) + v_k)])) + (v_c * b_attributes[((((v_ic / u32(10i)) * u32(34i)) + u32(3i)) + v_k)]));
            if ((((v_features & (268435456u | 536870912u)) != 0u) && ((v_layers & 16u) == 0u))) {
              v_normal[v_k] = (((v_a * b_attributes[(((cw_params.p_falloff_offset + ((v_ia / 10u) * 4u)) + 1u) + v_k)]) + (v_b * b_attributes[(((cw_params.p_falloff_offset + ((v_ib / 10u) * 4u)) + 1u) + v_k)])) + (v_c * b_attributes[(((cw_params.p_falloff_offset + ((v_ic / 10u) * 4u)) + 1u) + v_k)]));
            }
            v_normalLength = (v_normalLength + (v_normal[v_k] * v_normal[v_k]));
            v_eyeLength = (v_eyeLength + (v_position[v_k] * v_position[v_k]));
            continuing {
              v_k += u32(1);
            }
          }
        }
        if (((v_layers & u32(16i)) != u32(0i))) {
          var v_mapped: array<f32, 3>;
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              let cw_argument_index_176 = 0i;
              let cw_argument_index_177 = 1i;
              let cw_argument_index_178 = 2i;
              let cw_argument_index_179 = 3i;
              let cw_argument_index_180 = 4i;
              let cw_argument_index_181 = 5i;
              v_mapped[v_k] = ((f_cw_buffer_helper_5(0i, 0i, (v_data + u32(176i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, v_offsets[cw_argument_index_176], v_offsets[cw_argument_index_177], v_offsets[cw_argument_index_178], v_offsets[cw_argument_index_179], v_offsets[cw_argument_index_180], v_offsets[cw_argument_index_181], cw_thread, cw_block, cw_grid) * 2.0f) - 1.0f);
              continuing {
                v_k += u32(1);
              }
            }
          }
          if (((v_features & u32(256i)) != u32(0i))) {
            v_mapped[2i] = sqrt(max(0.0f, ((1.0f - (v_mapped[0i] * v_mapped[0i])) - (v_mapped[1i] * v_mapped[1i]))));
          }
          v_normalLength = 0.0f;
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              var v_tangent: f32 = (((v_a * b_attributes[((((v_ia / u32(10i)) * u32(34i)) + u32(6i)) + v_k)]) + (v_b * b_attributes[((((v_ib / u32(10i)) * u32(34i)) + u32(6i)) + v_k)])) + (v_c * b_attributes[((((v_ic / u32(10i)) * u32(34i)) + u32(6i)) + v_k)]));
              var v_bitangent: f32 = (((v_a * b_attributes[((((v_ia / u32(10i)) * u32(34i)) + u32(18i)) + v_k)]) + (v_b * b_attributes[((((v_ib / u32(10i)) * u32(34i)) + u32(18i)) + v_k)])) + (v_c * b_attributes[((((v_ic / u32(10i)) * u32(34i)) + u32(18i)) + v_k)]));
              v_normal[v_k] = (((v_tangent * v_mapped[0i]) + (v_bitangent * v_mapped[1i])) + (v_normal[v_k] * v_mapped[2i]));
              v_normalLength = (v_normalLength + (v_normal[v_k] * v_normal[v_k]));
              continuing {
                v_k += u32(1);
              }
            }
          }
        }
        v_normalLength = sqrt(max(v_normalLength, 1e-12f));
        v_eyeLength = sqrt(max(v_eyeLength, 1e-12f));
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            v_normal[v_k] = cw_divide_f32(v_normal[v_k], v_normalLength);
            v_eye[v_k] = cw_divide_f32(v_position[v_k], v_eyeLength);
            continuing {
              v_k += u32(1);
            }
          }
        }
        if (((v_features & u32(131072i)) != u32(0i))) {
          v_writeNormal = u32(1i);
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              v_fragmentNormal[v_k] = ((v_normal[v_k] * 0.5f) + 0.5f);
              continuing {
                v_k += u32(1);
              }
            }
          }
        }
        let cw_argument_index_182 = (v_data + u32(71i));
        var v_clipDistance: f32 = bitcast<f32>(b_texels[cw_argument_index_182]);
        {
          var v_row: u32 = u32(0i);
          loop {
            if (!(v_row < u32(3i))) { break; }
            let cw_argument_index_183 = (((v_data + u32(52i)) + u32(12i)) + v_row);
            var v_world: f32 = bitcast<f32>(b_texels[cw_argument_index_183]);
            {
              var v_col: u32 = u32(0i);
              loop {
                if (!(v_col < u32(3i))) { break; }
                let cw_argument_index_184 = (((v_data + u32(52i)) + (v_col * u32(4i))) + v_row);
                v_world = (v_world + (bitcast<f32>(b_texels[cw_argument_index_184]) * v_position[v_col]));
                continuing {
                  v_col += u32(1);
                }
              }
            }
            let cw_argument_index_185 = ((v_data + u32(68i)) + v_row);
            v_clipDistance = (v_clipDistance + (v_world * bitcast<f32>(b_texels[cw_argument_index_185])));
            continuing {
              v_row += u32(1);
            }
          }
        }
        if (((v_clipDistance < 0.0f) && ((v_features & u32(16384i)) == u32(0i)))) {
          continue;
        }
        if (((v_features & u32(524288i)) != u32(0i))) {
          var v_particle: u32 = (v_data + b_texels[(v_data + u32(79i))]);
          var v_world: array<f32, 4>;
          {
            var v_row: u32 = u32(0i);
            loop {
              if (!(v_row < u32(4i))) { break; }
              let cw_argument_index_186 = (((v_data + u32(52i)) + u32(12i)) + v_row);
              v_world[v_row] = bitcast<f32>(b_texels[cw_argument_index_186]);
              {
                var v_col: u32 = u32(0i);
                loop {
                  if (!(v_col < u32(3i))) { break; }
                  let cw_argument_index_187 = (((v_data + u32(52i)) + (v_col * u32(4i))) + v_row);
                  v_world[v_row] = (v_world[v_row] + (bitcast<f32>(b_texels[cw_argument_index_187]) * v_position[v_col]));
                  continuing {
                    v_col += u32(1);
                  }
                }
              }
              continuing {
                v_row += u32(1);
              }
            }
          }
          var v_coord: array<f32, 3>;
          {
            var v_row: u32 = u32(0i);
            loop {
              if (!(v_row < u32(3i))) { break; }
              v_coord[v_row] = 0.0f;
              {
                var v_col: u32 = u32(0i);
                loop {
                  if (!(v_col < u32(4i))) { break; }
                  let cw_argument_index_188 = (((v_particle + u32(16i)) + (v_col * u32(4i))) + v_row);
                  v_coord[v_row] = (v_coord[v_row] + (bitcast<f32>(b_texels[cw_argument_index_188]) * v_world[v_col]));
                  continuing {
                    v_col += u32(1);
                  }
                }
              }
              continuing {
                v_row += u32(1);
              }
            }
          }
          let cw_argument_index_189 = (v_particle + u32(12i));
          let cw_argument_index_190 = (v_particle + u32(13i));
          let cw_argument_index_191 = (v_particle + u32(14i));
          let cw_argument_index_192 = (v_particle + u32(15i));
          var v_sceneDepth: f32 = f_cw_buffer_helper_2(0i, b_texels[cw_argument_index_189], b_texels[cw_argument_index_190], b_texels[cw_argument_index_191], ((v_coord[0i] * 0.5f) + 0.5f), ((v_coord[1i] * 0.5f) + 0.5f), 0.0f, b_texels[cw_argument_index_192], u32(0i), cw_thread, cw_block, cw_grid);
          var cw_tmp_193: bool;
          if (((v_features & u32(65536i)) != u32(0i))) {
            cw_tmp_193 = (v_coord[2i] < v_sceneDepth);
          } else {
            cw_tmp_193 = (((v_coord[2i] * 0.5f) + 0.5f) > v_sceneDepth);
          }
          if (cw_tmp_193) {
            continue;
          }
        }
        var v_diffuse: array<f32, 4>;
        var v_ambient: array<f32, 3>;
        var v_specular: array<f32, 3>;
        var v_lighting: array<f32, 3>;
        var v_shine: array<f32, 3>;
        var cw_tmp_194: f32;
        if ((((v_features & ((69210112u | 268435456u) | 536870912u)) != 0u) && ((v_features & u32(65536i)) == u32(0i)))) {
          cw_tmp_194 = (((v_a * b_vertices[(v_ia + u32(2i))]) + (v_b * b_vertices[(v_ib + u32(2i))])) + (v_c * b_vertices[(v_ic + u32(2i))]));
        } else {
          cw_tmp_194 = (-v_position[2i]);
        }
        var v_linearDepth: f32 = cw_tmp_194;
        var v_shadowing: f32 = 1.0f;
        var v_shadowDebug: array<f32, 3>;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            v_shadowDebug[v_k] = 0.0f;
            continuing {
              v_k += u32(1);
            }
          }
        }
        var v_shadowDone: u32 = u32(0i);
        {
          var v_cascade: u32 = u32(0i);
          loop {
            if (!(v_cascade < b_texels[(v_data + u32(324i))])) { break; }
            if ((v_shadowDone != u32(0i))) {
              break;
            }
            var v_descriptor: u32 = ((v_data + b_texels[(v_data + u32(325i))]) + (v_cascade * u32(40i)));
            var v_coords: array<f32, 4>;
            var v_region: array<f32, 4>;
            var v_coordsDx: array<f32, 4>;
            var v_coordsDy: array<f32, 4>;
            {
              var v_row: u32 = u32(0i);
              loop {
                if (!(v_row < u32(4i))) { break; }
                v_coordsDx[v_row] = 0.0f;
                v_coordsDy[v_row] = 0.0f;
                let cw_argument_index_195 = (((v_descriptor + u32(8i)) + u32(12i)) + v_row);
                v_coords[v_row] = bitcast<f32>(b_texels[cw_argument_index_195]);
                let cw_argument_index_196 = (((v_descriptor + u32(24i)) + u32(12i)) + v_row);
                v_region[v_row] = bitcast<f32>(b_texels[cw_argument_index_196]);
                {
                  var v_col: u32 = u32(0i);
                  loop {
                    if (!(v_col < u32(3i))) { break; }
                    var v_unitNormal: f32 = (((v_a * b_attributes[((((v_ia / u32(10i)) * u32(34i)) + u32(23i)) + v_col)]) + (v_b * b_attributes[((((v_ib / u32(10i)) * u32(34i)) + u32(23i)) + v_col)])) + (v_c * b_attributes[((((v_ic / u32(10i)) * u32(34i)) + u32(23i)) + v_col)]));
                    let cw_argument_index_197 = (v_descriptor + u32(6i));
                    var v_offset: f32 = (v_unitNormal * bitcast<f32>(b_texels[cw_argument_index_197]));
                    let cw_argument_index_198 = (((v_descriptor + u32(8i)) + (v_col * u32(4i))) + v_row);
                    v_coords[v_row] = (v_coords[v_row] + (bitcast<f32>(b_texels[cw_argument_index_198]) * (v_position[v_col] + v_offset)));
                    let cw_argument_index_199 = (((v_descriptor + u32(24i)) + (v_col * u32(4i))) + v_row);
                    v_region[v_row] = (v_region[v_row] + (bitcast<f32>(b_texels[cw_argument_index_199]) * v_position[v_col]));
                    let cw_argument_index_200 = (v_descriptor + u32(6i));
                    var v_normalOffset: f32 = bitcast<f32>(b_texels[cw_argument_index_200]);
                    var v_av: f32 = (((b_attributes[(((v_ia / u32(10i)) * u32(34i)) + v_col)] + (b_attributes[((((v_ia / u32(10i)) * u32(34i)) + u32(23i)) + v_col)] * v_normalOffset)) - v_position[v_col]) - v_offset);
                    var v_bv: f32 = (((b_attributes[(((v_ib / u32(10i)) * u32(34i)) + v_col)] + (b_attributes[((((v_ib / u32(10i)) * u32(34i)) + u32(23i)) + v_col)] * v_normalOffset)) - v_position[v_col]) - v_offset);
                    var v_cv: f32 = (((b_attributes[(((v_ic / u32(10i)) * u32(34i)) + v_col)] + (b_attributes[((((v_ic / u32(10i)) * u32(34i)) + u32(23i)) + v_col)] * v_normalOffset)) - v_position[v_col]) - v_offset);
                    let cw_argument_index_201 = (((v_descriptor + u32(8i)) + (v_col * u32(4i))) + v_row);
                    var v_coefficient: f32 = bitcast<f32>(b_texels[cw_argument_index_201]);
                    v_coordsDx[v_row] = (v_coordsDx[v_row] + cw_divide_f32((v_coefficient * (((v_dax * v_av) + (v_dbx * v_bv)) + (v_dcx * v_cv))), v_inv));
                    v_coordsDy[v_row] = (v_coordsDy[v_row] + cw_divide_f32((v_coefficient * (((v_day * v_av) + (v_dby * v_bv)) + (v_dcy * v_cv))), v_inv));
                    continuing {
                      v_col += u32(1);
                    }
                  }
                }
                continuing {
                  v_row += u32(1);
                }
              }
            }
            let cw_argument_index_202 = 3i;
            if ((abs(v_coords[cw_argument_index_202]) < 1e-12f)) {
              continue;
            }
            var v_sx: f32 = cw_divide_f32(v_coords[0i], v_coords[3i]);
            var v_sy: f32 = cw_divide_f32(v_coords[1i], v_coords[3i]);
            var v_sz: f32 = cw_divide_f32(v_coords[2i], v_coords[3i]);
            if (((((v_sx <= 0.0f) || (v_sx >= 1.0f)) || (v_sy <= 0.0f)) || (v_sy >= 1.0f))) {
              continue;
            }
            v_shadowing = min(v_shadowing, f_cw_buffer_helper_6(0i, v_descriptor, v_sx, v_sy, v_sz, (cw_divide_f32((v_coordsDx[0i] - (v_sx * v_coordsDx[3i])), v_coords[3i]) * f32(b_texels[(v_descriptor + u32(1i))])), (cw_divide_f32((v_coordsDx[1i] - (v_sy * v_coordsDx[3i])), v_coords[3i]) * f32(b_texels[(v_descriptor + u32(2i))])), (cw_divide_f32((v_coordsDy[0i] - (v_sx * v_coordsDy[3i])), v_coords[3i]) * f32(b_texels[(v_descriptor + u32(1i))])), (cw_divide_f32((v_coordsDy[1i] - (v_sy * v_coordsDy[3i])), v_coords[3i]) * f32(b_texels[(v_descriptor + u32(2i))])), cw_thread, cw_block, cw_grid));
            if (((b_texels[(v_descriptor + u32(5i))] & u32(2i)) != u32(0i))) {
              v_shadowDebug[b_texels[(v_descriptor + u32(7i))]] = (v_shadowDebug[b_texels[(v_descriptor + u32(7i))]] + 0.1f);
            }
            v_shadowDone = select(u32(0), u32(1), ((((((v_sx > 0.05f) && (v_sx < 0.95f)) && (v_sy > 0.05f)) && (v_sy < 0.95f)) && (v_sz > 0.0f)) && (v_sz < 1.0f)));
            if (((b_texels[(v_descriptor + u32(5i))] & u32(1i)) != u32(0i))) {
              let cw_argument_index_203 = 3i;
              if ((abs(v_region[cw_argument_index_203]) < 1e-12f)) {
                v_shadowDone = u32(0i);
              } else {
                v_shadowDone = select(u32(0), u32(1), ((((((v_shadowDone != u32(0i)) && (cw_divide_f32(v_region[0i], v_region[3i]) > (-1.0f))) && (cw_divide_f32(v_region[0i], v_region[3i]) < 1.0f)) && (cw_divide_f32(v_region[1i], v_region[3i]) > (-1.0f))) && (cw_divide_f32(v_region[1i], v_region[3i]) < 1.0f)) && (cw_divide_f32(v_region[2i], v_region[3i]) < 1.0f)));
              }
            }
            continuing {
              v_cascade += u32(1);
            }
          }
        }
        if ((b_texels[(v_data + u32(324i))] != u32(0i))) {
          var v_first: u32 = (v_data + b_texels[(v_data + u32(325i))]);
          if (((b_texels[(v_first + u32(5i))] & u32(4i)) != u32(0i))) {
            let cw_argument_index_204 = (v_data + u32(326i));
            var v_start: f32 = bitcast<f32>(b_texels[cw_argument_index_204]);
            let cw_argument_index_205 = (v_data + u32(327i));
            var v_end: f32 = bitcast<f32>(b_texels[cw_argument_index_205]);
            var v_fade: f32 = min(1.0f, max(0.0f, cw_divide_f32((v_linearDepth - v_start), max(0.000001f, (v_end - v_start)))));
            v_shadowing = ((v_shadowing * (1.0f - v_fade)) + v_fade);
          }
        }
        let cw_argument_index_206 = (v_data + u32(46i));
        var v_shininess: f32 = max(0.0001f, bitcast<f32>(b_texels[cw_argument_index_206]));
        if (((v_features & u32(8192i)) != u32(0i))) {
          v_shininess = 128.0f;
        }
        if (((v_layers & u32(32i)) != u32(0i))) {
          v_shininess = max(0.0001f, (255.0f * f_cw_buffer_helper_7(0i, 0i, (v_data + u32(200i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i), cw_thread, cw_block, cw_grid)));
        }
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(4i))) { break; }
            var cw_tmp_208: f32;
            if (((v_mode == u32(2i)) || (v_mode == u32(4i)))) {
              cw_tmp_208 = v_color[v_k];
            } else {
              let cw_argument_index_207 = ((v_data + u32(12i)) + v_k);
              cw_tmp_208 = bitcast<f32>(b_texels[cw_argument_index_207]);
            }
            v_diffuse[v_k] = cw_tmp_208;
            continuing {
              v_k += u32(1);
            }
          }
        }
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            var cw_tmp_210: f32;
            if (((v_mode == u32(2i)) || (v_mode == u32(3i)))) {
              cw_tmp_210 = v_color[v_k];
            } else {
              let cw_argument_index_209 = ((v_data + u32(8i)) + v_k);
              cw_tmp_210 = bitcast<f32>(b_texels[cw_argument_index_209]);
            }
            v_ambient[v_k] = cw_tmp_210;
            var cw_tmp_212: f32;
            if ((v_mode == u32(5i))) {
              cw_tmp_212 = v_color[v_k];
            } else {
              let cw_argument_index_211 = ((v_data + u32(16i)) + v_k);
              cw_tmp_212 = bitcast<f32>(b_texels[cw_argument_index_211]);
            }
            v_specular[v_k] = cw_tmp_212;
            if ((((v_features & 536870912u) != 0u) && ((v_layers & 16u) != 0u))) {
              v_specular[v_k] = (v_specular[v_k] * f_cw_buffer_helper_7(0i, 0i, (v_data + u32(176i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i), cw_thread, cw_block, cw_grid));
            }
            if (((v_layers & u32(32i)) != u32(0i))) {
              v_specular[v_k] = f_cw_buffer_helper_7(0i, 0i, (v_data + u32(200i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, cw_thread, cw_block, cw_grid);
            }
            if (((v_features & u32(8192i)) != u32(0i))) {
              let cw_argument_index_213 = 0i;
              let cw_argument_index_214 = 1i;
              let cw_argument_index_215 = 2i;
              let cw_argument_index_216 = 3i;
              let cw_argument_index_217 = 4i;
              let cw_argument_index_218 = 5i;
              v_specular[v_k] = f_cw_buffer_helper_5(0i, 0i, (v_data + u32(224i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i), v_offsets[cw_argument_index_213], v_offsets[cw_argument_index_214], v_offsets[cw_argument_index_215], v_offsets[cw_argument_index_216], v_offsets[cw_argument_index_217], v_offsets[cw_argument_index_218], cw_thread, cw_block, cw_grid);
            }
            var cw_tmp_220: f32;
            if ((v_mode == u32(1i))) {
              cw_tmp_220 = v_color[v_k];
            } else {
              let cw_argument_index_219 = ((v_data + u32(20i)) + v_k);
              cw_tmp_220 = bitcast<f32>(b_texels[cw_argument_index_219]);
            }
            let cw_argument_index_221 = (v_data + u32(47i));
            v_lighting[v_k] = (cw_tmp_220 * bitcast<f32>(b_texels[cw_argument_index_221]));
            if ((((v_features & 536870912u) != 0u) && ((v_layers & 8u) != 0u))) {
              v_lighting[v_k] = (v_lighting[v_k] * f_cw_buffer_helper_7(0i, 0i, (v_data + u32(152i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, cw_thread, cw_block, cw_grid));
            }
            v_shine[v_k] = 0.0f;
            continuing {
              v_k += u32(1);
            }
          }
        }
        let cw_argument_index_222 = 2i;
        var v_cell: u32 = f_cw_buffer_helper_8(0i, v_cluster, v_px, (f32(cw_params.p_height) - v_py), v_position[cw_argument_index_222], cw_thread, cw_block, cw_grid);
        var cw_tmp_223: u32;
        if ((v_cluster != u32(0i))) {
          cw_tmp_223 = f_cw_buffer_helper_9(0i, v_cluster, v_cell, cw_thread, cw_block, cw_grid);
        } else {
          cw_tmp_223 = b_texels[(v_data + u32(6i))];
        }
        var v_pointCount: u32 = cw_tmp_223;
        if (((v_features & (8388608u | 268435456u)) == 0u)) {
          {
            var v_light: u32 = u32(0i);
            loop {
              if (!(v_light <= v_pointCount)) { break; }
              var cw_tmp_225: u32;
              if ((v_light == u32(0i))) {
                cw_tmp_225 = (v_data + u32(24i));
              } else {
                var cw_tmp_224: u32;
                if ((v_cluster != u32(0i))) {
                  cw_tmp_224 = f_cw_buffer_helper_10(0i, v_cluster, v_cell, (v_light - u32(1i)), cw_thread, cw_block, cw_grid);
                } else {
                  cw_tmp_224 = ((v_data + b_texels[(v_data + u32(7i))]) + ((v_light - u32(1i)) * u32(16i)));
                }
                cw_tmp_225 = cw_tmp_224;
              }
              var v_record: u32 = cw_tmp_225;
              var v_direction: array<f32, 3>;
              var v_distance: f32 = 0.0f;
              {
                var v_k: u32 = u32(0i);
                loop {
                  if (!(v_k < u32(3i))) { break; }
                  let cw_argument_index_226 = (v_record + v_k);
                  var cw_tmp_227: f32;
                  if ((v_light == u32(0i))) {
                    cw_tmp_227 = 0.0f;
                  } else {
                    cw_tmp_227 = v_position[v_k];
                  }
                  v_direction[v_k] = (bitcast<f32>(b_texels[cw_argument_index_226]) - cw_tmp_227);
                  v_distance = (v_distance + (v_direction[v_k] * v_direction[v_k]));
                  continuing {
                    v_k += u32(1);
                  }
                }
              }
              v_distance = sqrt(max(v_distance, 1e-12f));
              var v_attenuation: f32 = 1.0f;
              if ((v_light != u32(0i))) {
                let cw_argument_index_228 = (v_record + u32(15i));
                var v_radius: f32 = bitcast<f32>(b_texels[cw_argument_index_228]);
                if (((((v_features & u32(1i)) == u32(0i)) || (v_cluster != u32(0i))) && (v_distance > v_radius))) {
                  continue;
                }
                if ((v_cluster != u32(0i))) {
                  let cw_argument_index_229 = 2i;
                  v_attenuation = (v_attenuation * f_cw_buffer_helper_11(0i, v_cluster, v_position[cw_argument_index_229], v_radius, cw_thread, cw_block, cw_grid));
                }
                let cw_argument_index_230 = (v_record + u32(3i));
                let cw_argument_index_231 = (v_record + u32(7i));
                let cw_argument_index_232 = (v_record + u32(11i));
                var v_denominator: f32 = ((bitcast<f32>(b_texels[cw_argument_index_230]) + (bitcast<f32>(b_texels[cw_argument_index_231]) * v_distance)) + ((bitcast<f32>(b_texels[cw_argument_index_232]) * v_distance) * v_distance));
                v_attenuation = cw_divide_f32(v_attenuation, max(v_denominator, 1e-12f));
                if ((((v_features & u32(1i)) == u32(0i)) || (v_cluster != u32(0i)))) {
                  var v_fade: f32 = min(1.0f, max(0.0f, cw_divide_f32((cw_divide_f32(v_distance, max(v_radius, 0.000001f)) - 0.75f), 0.25f)));
                  v_fade = (1.0f - (v_fade * v_fade));
                  v_attenuation = (v_attenuation * (v_fade * v_fade));
                }
              }
              var v_lambert: f32 = 0.0f;
              var v_halfLength: f32 = 0.0f;
              var v_halfVector: array<f32, 3>;
              {
                var v_k: u32 = u32(0i);
                loop {
                  if (!(v_k < u32(3i))) { break; }
                  v_direction[v_k] = cw_divide_f32(v_direction[v_k], v_distance);
                  v_lambert = (v_lambert + (v_normal[v_k] * v_direction[v_k]));
                  v_halfVector[v_k] = (v_direction[v_k] - v_eye[v_k]);
                  v_halfLength = (v_halfLength + (v_halfVector[v_k] * v_halfVector[v_k]));
                  continuing {
                    v_k += u32(1);
                  }
                }
              }
              if (((v_features & u32(67108864i)) != u32(0i))) {
                var v_eyeCosine: f32 = 0.0f;
                {
                  var v_axis: u32 = u32(0i);
                  loop {
                    if (!(v_axis < u32(3i))) { break; }
                    v_eyeCosine = (v_eyeCosine + (v_normal[v_axis] * v_eye[v_axis]));
                    continuing {
                      v_axis += u32(1);
                    }
                  }
                }
                if ((v_lambert < 0.0f)) {
                  v_lambert = (-v_lambert);
                  v_eyeCosine = (-v_eyeCosine);
                }
                v_lambert = (v_lambert * min(1.0f, max(0.3f, (1.0f - (5.6f * v_eyeCosine)))));
              }
              v_halfLength = sqrt(max(v_halfLength, 1e-12f));
              var v_spec: f32 = 0.0f;
              if ((v_lambert > 0.0f)) {
                {
                  var v_k: u32 = u32(0i);
                  loop {
                    if (!(v_k < u32(3i))) { break; }
                    v_spec = (v_spec + cw_divide_f32((v_normal[v_k] * v_halfVector[v_k]), v_halfLength));
                    continuing {
                      v_k += u32(1);
                    }
                  }
                }
                v_spec = f_render_power(max(v_spec, 0.0f), v_shininess, cw_thread, cw_block, cw_grid);
              }
              {
                var v_k: u32 = u32(0i);
                loop {
                  if (!(v_k < u32(3i))) { break; }
                  let cw_argument_index_233 = ((v_record + u32(8i)) + v_k);
                  var cw_tmp_234: f32;
                  if ((v_light == u32(0i))) {
                    cw_tmp_234 = v_shadowing;
                  } else {
                    cw_tmp_234 = 1.0f;
                  }
                  let cw_argument_index_235 = ((v_record + u32(4i)) + v_k);
                  v_lighting[v_k] = (v_lighting[v_k] + (((((v_diffuse[v_k] * bitcast<f32>(b_texels[cw_argument_index_233])) * max(v_lambert, 0.0f)) * cw_tmp_234) + (v_ambient[v_k] * bitcast<f32>(b_texels[cw_argument_index_235]))) * v_attenuation));
                  let cw_argument_index_236 = ((v_record + u32(12i)) + v_k);
                  let cw_argument_index_237 = (v_data + u32(48i));
                  var cw_tmp_238: f32;
                  if ((v_light == u32(0i))) {
                    cw_tmp_238 = v_shadowing;
                  } else {
                    cw_tmp_238 = 1.0f;
                  }
                  v_shine[v_k] = (v_shine[v_k] + (((((v_specular[v_k] * bitcast<f32>(b_texels[cw_argument_index_236])) * v_spec) * v_attenuation) * bitcast<f32>(b_texels[cw_argument_index_237])) * cw_tmp_238));
                  continuing {
                    v_k += u32(1);
                  }
                }
              }
              continuing {
                v_light += u32(1);
              }
            }
          }
        }
        if (((v_features & u32(8388608i)) != u32(0i))) {
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              var v_la: u32 = (cw_params.p_lighting_offset + ((v_ia / u32(10i)) * u32(12i)));
              var v_lb: u32 = (cw_params.p_lighting_offset + ((v_ib / u32(10i)) * u32(12i)));
              var v_lc: u32 = (cw_params.p_lighting_offset + ((v_ic / u32(10i)) * u32(12i)));
              var v_shaded: f32 = (((v_a * b_attributes[(v_la + v_k)]) + (v_b * b_attributes[(v_lb + v_k)])) + (v_c * b_attributes[(v_lc + v_k)]));
              var v_lit: f32 = (((v_a * b_attributes[((v_la + u32(6i)) + v_k)]) + (v_b * b_attributes[((v_lb + u32(6i)) + v_k)])) + (v_c * b_attributes[((v_lc + u32(6i)) + v_k)]));
              var v_shadeSpec: f32 = (((v_a * b_attributes[((v_la + u32(3i)) + v_k)]) + (v_b * b_attributes[((v_lb + u32(3i)) + v_k)])) + (v_c * b_attributes[((v_lc + u32(3i)) + v_k)]));
              var v_litSpec: f32 = (((v_a * b_attributes[((v_la + u32(9i)) + v_k)]) + (v_b * b_attributes[((v_lb + u32(9i)) + v_k)])) + (v_c * b_attributes[((v_lc + u32(9i)) + v_k)]));
              v_lighting[v_k] = ((v_shaded * (1.0f - v_shadowing)) + (v_lit * v_shadowing));
              v_shine[v_k] = ((v_shadeSpec * (1.0f - v_shadowing)) + (v_litSpec * v_shadowing));
              continuing {
                v_k += u32(1);
              }
            }
          }
        }
        var v_environment: array<f32, 3>;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            v_environment[v_k] = 0.0f;
            continuing {
              v_k += u32(1);
            }
          }
        }
        if (((v_layers & u32(128i)) != u32(0i))) {
          var v_envUV: array<f32, 2>;
          var v_envDx: array<f32, 2>;
          var v_envDy: array<f32, 2>;
          var v_ix: f32 = max(1e-12f, (((v_inv + v_dax) + v_dbx) + v_dcx));
          var v_iy: f32 = max(1e-12f, (((v_inv + v_day) + v_dby) + v_dcy));
          {
            var v_axis: u32 = u32(0i);
            loop {
              if (!(v_axis < u32(2i))) { break; }
              v_envUV[v_axis] = f_cw_buffer_helper_12(0i, 0i, v_data, (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_axis, cw_thread, cw_block, cw_grid);
              v_envDx[v_axis] = (f_cw_buffer_helper_12(0i, 0i, v_data, (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), cw_divide_f32(((v_a * v_inv) + v_dax), v_ix), cw_divide_f32(((v_b * v_inv) + v_dbx), v_ix), cw_divide_f32(((v_c * v_inv) + v_dcx), v_ix), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_ix, v_axis, cw_thread, cw_block, cw_grid) - v_envUV[v_axis]);
              v_envDy[v_axis] = (f_cw_buffer_helper_12(0i, 0i, v_data, (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), cw_divide_f32(((v_a * v_inv) + v_day), v_iy), cw_divide_f32(((v_b * v_inv) + v_dby), v_iy), cw_divide_f32(((v_c * v_inv) + v_dcy), v_iy), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_iy, v_axis, cw_thread, cw_block, cw_grid) - v_envUV[v_axis]);
              continuing {
                v_axis += u32(1);
              }
            }
          }
          var v_width: f32 = f32(b_texels[(v_data + u32(249i))]);
          var v_height: f32 = f32(b_texels[(v_data + u32(250i))]);
          var v_luma: f32 = 1.0f;
          if (((v_layers & u32(256i)) != u32(0i))) {
            let cw_argument_index_239 = (v_data + u32(77i));
            let cw_argument_index_240 = (v_data + u32(78i));
            v_luma = min(1.0f, max(0.0f, ((f_cw_buffer_helper_7(0i, 0i, (v_data + u32(272i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(2i), cw_thread, cw_block, cw_grid) * bitcast<f32>(b_texels[cw_argument_index_239])) + bitcast<f32>(b_texels[cw_argument_index_240]))));
          }
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              let cw_argument_index_241 = (v_data + u32(248i));
              let cw_argument_index_242 = (v_data + u32(249i));
              let cw_argument_index_243 = (v_data + u32(250i));
              let cw_argument_index_244 = 0i;
              let cw_argument_index_245 = 1i;
              let cw_argument_index_246 = (v_data + u32(251i));
              let cw_argument_index_247 = ((v_data + u32(73i)) + v_k);
              v_environment[v_k] = ((f_cw_buffer_helper_0(0i, b_texels[cw_argument_index_241], b_texels[cw_argument_index_242], b_texels[cw_argument_index_243], v_envUV[cw_argument_index_244], v_envUV[cw_argument_index_245], (v_envDx[0i] * v_width), (v_envDx[1i] * v_height), (v_envDy[0i] * v_width), (v_envDy[1i] * v_height), b_texels[cw_argument_index_246], v_k, cw_thread, cw_block, cw_grid) * bitcast<f32>(b_texels[cw_argument_index_247])) * v_luma);
              if (((v_layers & u32(512i)) != u32(0i))) {
                v_environment[v_k] = (v_environment[v_k] * f_cw_buffer_helper_7(0i, 0i, (v_data + u32(296i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, cw_thread, cw_block, cw_grid));
              }
              continuing {
                v_k += u32(1);
              }
            }
          }
        }
        var cw_tmp_248: f32;
        if (((v_layers & u32(4i)) != u32(0i))) {
          cw_tmp_248 = (f_cw_buffer_helper_7(0i, 0i, (v_data + u32(128i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i), cw_thread, cw_block, cw_grid) * v_diffuse[3i]);
        } else {
          cw_tmp_248 = 0.0f;
        }
        var v_decalAlpha: f32 = cw_tmp_248;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(4i))) { break; }
            var cw_tmp_255: f32;
            if (((v_flags & u32(1i)) != u32(0i))) {
              let cw_argument_index_249 = 0i;
              let cw_argument_index_250 = 1i;
              let cw_argument_index_251 = 2i;
              let cw_argument_index_252 = 3i;
              let cw_argument_index_253 = 4i;
              let cw_argument_index_254 = 5i;
              cw_tmp_255 = f_cw_buffer_helper_5(0i, 0i, (v_data + u32(224i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, v_offsets[cw_argument_index_249], v_offsets[cw_argument_index_250], v_offsets[cw_argument_index_251], v_offsets[cw_argument_index_252], v_offsets[cw_argument_index_253], v_offsets[cw_argument_index_254], cw_thread, cw_block, cw_grid);
            } else {
              cw_tmp_255 = 1.0f;
            }
            var v_sample: f32 = cw_tmp_255;
            if (((v_k == u32(3i)) && ((v_features & u32(5120i)) != u32(0i)))) {
              v_sample = 1.0f;
            }
            if (((v_layers & u32(1i)) != u32(0i))) {
              v_sample = (v_sample * f_cw_buffer_helper_7(0i, 0i, (v_data + u32(80i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, cw_thread, cw_block, cw_grid));
            }
            if ((v_k < u32(3i))) {
              if (((v_layers & u32(2i)) != u32(0i))) {
                v_sample = (v_sample * (2.0f * f_cw_buffer_helper_7(0i, 0i, (v_data + u32(104i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, cw_thread, cw_block, cw_grid)));
              }
              if (((v_layers & u32(4i)) != u32(0i))) {
                v_sample = ((v_sample * (1.0f - v_decalAlpha)) + (f_cw_buffer_helper_7(0i, 0i, (v_data + u32(128i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, cw_thread, cw_block, cw_grid) * v_decalAlpha));
              }
              if (((v_features & u32(2048i)) != u32(0i))) {
                v_sample = (v_sample + v_environment[v_k]);
              }
              var cw_tmp_258: f32;
              if (((v_features & u32(2i)) != u32(0i))) {
                let cw_argument_index_256 = v_k;
                cw_tmp_258 = min(1.0f, max(v_lighting[cw_argument_index_256], 0.0f));
              } else {
                let cw_argument_index_257 = v_k;
                cw_tmp_258 = max(v_lighting[cw_argument_index_257], 0.0f);
              }
              v_color[v_k] = ((v_sample * cw_tmp_258) + v_shine[v_k]);
              if (((v_features & u32(2048i)) == u32(0i))) {
                v_color[v_k] = (v_color[v_k] + v_environment[v_k]);
              }
              if (((v_features & u32(16384i)) != u32(0i))) {
                v_color[v_k] = v_sample;
              }
              if (((v_features & 268435456u) != 0u)) {
                v_color[v_k] = (v_sample * v_diffuse[v_k]);
              }
              if ((((v_layers & u32(8i)) != u32(0i)) && ((v_features & 536870912u) == 0u))) {
                v_color[v_k] = (v_color[v_k] + f_cw_buffer_helper_7(0i, 0i, (v_data + u32(152i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, cw_thread, cw_block, cw_grid));
              }
            } else {
              var cw_tmp_259: f32;
              if (((v_features & (16384u | 1073741824u)) != 0u)) {
                cw_tmp_259 = 1.0f;
              } else {
                cw_tmp_259 = v_diffuse[v_k];
              }
              v_color[v_k] = (v_sample * cw_tmp_259);
            }
            continuing {
              v_k += u32(1);
            }
          }
        }
        if (((v_features & u32(67108864i)) != u32(0i))) {
          var v_depth: f32 = (((v_a * b_attributes[(((v_ia / u32(10i)) * u32(34i)) + u32(9i))]) + (v_b * b_attributes[(((v_ib / u32(10i)) * u32(34i)) + u32(9i))])) + (v_c * b_attributes[(((v_ic / u32(10i)) * u32(34i)) + u32(9i))]));
          let cw_argument_index_260 = (v_data + u32(320i));
          var v_start: f32 = bitcast<f32>(b_texels[cw_argument_index_260]);
          let cw_argument_index_261 = (v_data + u32(321i));
          var v_end: f32 = bitcast<f32>(b_texels[cw_argument_index_261]);
          var v_fade: f32 = min(1.0f, max(0.0f, cw_divide_f32((v_depth - v_start), max(0.000001f, (v_end - v_start)))));
          v_color[3i] = (v_color[3i] * (1.0f - ((v_fade * v_fade) * (3.0f - (2.0f * v_fade)))));
        }
        if (((v_layers & u32(1024i)) != u32(0i))) {
          v_color[3i] = (v_color[3i] * f_cw_buffer_helper_7(0i, 0i, (v_data + u32(328i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i), cw_thread, cw_block, cw_grid));
        }
        if ((((v_features & u32(64i)) != u32(0i)) && ((v_layers & u32(1i)) != u32(0i)))) {
          var cw_tmp_262: i32;
          if (((v_features & u32(128i)) != u32(0i))) {
            cw_tmp_262 = 5i;
          } else {
            cw_tmp_262 = 4i;
          }
          v_color[3i] = (v_color[3i] * (1.0f + (0.25f * f_cw_buffer_helper_7(0i, 0i, (v_data + u32(80i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(cw_tmp_262), cw_thread, cw_block, cw_grid))));
        }
        if (((((v_features & u32(64i)) != u32(0i)) && ((v_flags & u32(1i)) != u32(0i))) && ((v_features & u32(5120i)) == u32(0i)))) {
          var cw_tmp_263: i32;
          if (((v_features & u32(128i)) != u32(0i))) {
            cw_tmp_263 = 5i;
          } else {
            cw_tmp_263 = 4i;
          }
          let cw_argument_index_264 = 0i;
          let cw_argument_index_265 = 1i;
          let cw_argument_index_266 = 2i;
          let cw_argument_index_267 = 3i;
          let cw_argument_index_268 = 4i;
          let cw_argument_index_269 = 5i;
          var v_coverageLod: f32 = f_cw_buffer_helper_5(0i, 0i, (v_data + u32(224i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(cw_tmp_263), v_offsets[cw_argument_index_264], v_offsets[cw_argument_index_265], v_offsets[cw_argument_index_266], v_offsets[cw_argument_index_267], v_offsets[cw_argument_index_268], v_offsets[cw_argument_index_269], cw_thread, cw_block, cw_grid);
          v_color[3i] = (v_color[3i] * (1.0f + (max(v_coverageLod, 0.0f) * 0.25f)));
        }
        if (((v_features & 268435456u) != 0u)) {
          v_color[3i] = (v_color[3i] * (((v_a * b_attributes[(cw_params.p_falloff_offset + ((v_ia / 10u) * 4u))]) + (v_b * b_attributes[(cw_params.p_falloff_offset + ((v_ib / 10u) * 4u))])) + (v_c * b_attributes[(cw_params.p_falloff_offset + ((v_ic / 10u) * 4u))])));
        }
        if (((v_features & u32(4194304i)) == u32(0i))) {
          let cw_argument_index_270 = (v_data + u32(49i));
          var v_reference: f32 = bitcast<f32>(b_texels[cw_argument_index_270]);
          var v_function: u32 = b_texels[(v_data + u32(51i))];
          if ((((v_features & u32(134217728i)) != u32(0i)) && ((((v_function == 1u) || (v_function == 3u)) || (v_function == 4u)) || (v_function == 6u)))) {
            var v_quadAlpha: array<f32, 4>;
            {
              var v_lane: u32 = u32(0i);
              loop {
                if (!(v_lane < u32(4i))) { break; }
                var v_dx: f32 = ((f32(((v_x - (v_x % 2u)) + (v_lane % 2u))) + 0.5f) - v_px);
                var v_dy: f32 = ((f32(((v_y - (v_y % 2u)) + (v_lane / 2u))) + 0.5f) - v_py);
                var v_qi: f32 = ((v_inv + (v_dx * ((v_dax + v_dbx) + v_dcx))) + (v_dy * ((v_day + v_dby) + v_dcy)));
                var cw_tmp_271: f32;
                if ((abs(v_qi) > 1e-12f)) {
                  cw_tmp_271 = v_qi;
                } else {
                  cw_tmp_271 = 1e-12f;
                }
                v_qi = cw_tmp_271;
                var v_qa: f32 = cw_divide_f32((((v_a * v_inv) + (v_dx * v_dax)) + (v_dy * v_day)), v_qi);
                var v_qb: f32 = cw_divide_f32((((v_b * v_inv) + (v_dx * v_dbx)) + (v_dy * v_dby)), v_qi);
                var v_qc: f32 = cw_divide_f32((((v_c * v_inv) + (v_dx * v_dcx)) + (v_dy * v_dcy)), v_qi);
                v_quadAlpha[v_lane] = f_cw_buffer_helper_13(0i, 0i, 0i, v_data, v_flags, cw_params.p_falloff_offset, (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_qa, v_qb, v_qc, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_qi, cw_thread, cw_block, cw_grid);
                continuing {
                  v_lane += u32(1);
                }
              }
            }
            var v_row: u32 = ((v_y % 2u) * 2u);
            var v_column: u32 = (v_x % 2u);
            var v_alphaWidth: f32 = (abs((v_quadAlpha[(v_row + u32(1i))] - v_quadAlpha[v_row])) + abs((v_quadAlpha[(v_column + u32(2i))] - v_quadAlpha[v_column])));
            var v_coverage: f32 = (cw_divide_f32((v_color[3i] - min(0.9999f, max(0.0001f, v_reference))), max(v_alphaWidth, 0.0001f)) + 0.5f);
            var cw_tmp_272: f32;
            if (((v_function == 1u) || (v_function == 3u))) {
              cw_tmp_272 = (1.0f - v_coverage);
            } else {
              cw_tmp_272 = v_coverage;
            }
            v_color[3i] = cw_tmp_272;
          } else {
            let cw_argument_index_273 = 3i;
            if ((f_compare_value(v_color[cw_argument_index_273], v_reference, v_function, cw_thread, cw_block, cw_grid) == u32(0i))) {
              continue;
            }
          }
        }
        if (((v_features & u32(2097152i)) != u32(0i))) {
          var v_waterNormal: array<f32, 3>;
          var v_footprint: array<f32, 6>;
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              var v_va: f32 = (b_attributes[(((v_ia / u32(10i)) * u32(34i)) + v_k)] - v_position[v_k]);
              var v_vb: f32 = (b_attributes[(((v_ib / u32(10i)) * u32(34i)) + v_k)] - v_position[v_k]);
              var v_vc: f32 = (b_attributes[(((v_ic / u32(10i)) * u32(34i)) + v_k)] - v_position[v_k]);
              v_footprint[v_k] = cw_divide_f32((((v_dax * v_va) + (v_dbx * v_vb)) + (v_dcx * v_vc)), v_inv);
              v_footprint[(u32(3i) + v_k)] = cw_divide_f32((((v_day * v_va) + (v_dby * v_vb)) + (v_dcy * v_vc)), v_inv);
              continuing {
                v_k += u32(1);
              }
            }
          }
          f_cw_buffer_helper_14(0i, v_data, &v_position, &v_footprint, v_shadowing, cw_divide_f32((f32(v_x) + 0.5f), f32(cw_params.p_width)), (1.0f - cw_divide_f32((f32(v_y) + 0.5f), f32(cw_params.p_height))), v_z, v_linearDepth, &v_color, &v_waterNormal, v_cluster, v_px, (f32(cw_params.p_height) - v_py), cw_thread, cw_block, cw_grid);
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              v_fragmentNormal[v_k] = ((v_waterNormal[v_k] * 0.5f) + 0.5f);
              continuing {
                v_k += u32(1);
              }
            }
          }
        }
        if (((v_features & u32(4194304i)) != u32(0i))) {
          var v_distortion: u32 = ((v_data + b_texels[(v_data + u32(79i))]) + u32(40i));
          let cw_argument_index_274 = (v_distortion + u32(5i));
          var v_ratio: f32 = max(0.000001f, bitcast<f32>(b_texels[cw_argument_index_274]));
          let cw_argument_index_275 = v_distortion;
          let cw_argument_index_276 = (v_distortion + u32(1i));
          let cw_argument_index_277 = (v_distortion + u32(2i));
          let cw_argument_index_278 = (v_distortion + u32(3i));
          var v_sceneDepth: f32 = f_cw_buffer_helper_2(0i, b_texels[cw_argument_index_275], b_texels[cw_argument_index_276], b_texels[cw_argument_index_277], cw_divide_f32(cw_divide_f32((f32(v_x) + 0.5f), f32(cw_params.p_width)), v_ratio), cw_divide_f32((1.0f - cw_divide_f32((f32(v_y) + 0.5f), f32(cw_params.p_height))), v_ratio), 0.0f, b_texels[cw_argument_index_278], u32(0i), cw_thread, cw_block, cw_grid);
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(4i))) { break; }
              let cw_argument_index_279 = 0i;
              let cw_argument_index_280 = 1i;
              let cw_argument_index_281 = 2i;
              let cw_argument_index_282 = 3i;
              let cw_argument_index_283 = 4i;
              let cw_argument_index_284 = 5i;
              v_color[v_k] = f_cw_buffer_helper_5(0i, 0i, (v_data + u32(224i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, v_offsets[cw_argument_index_279], v_offsets[cw_argument_index_280], v_offsets[cw_argument_index_281], v_offsets[cw_argument_index_282], v_offsets[cw_argument_index_283], v_offsets[cw_argument_index_284], cw_thread, cw_block, cw_grid);
              continuing {
                v_k += u32(1);
              }
            }
          }
          v_color[3i] = (v_color[3i] * v_diffuse[3i]);
          if ((v_color[3i] < 0.1f)) {
            continue;
          }
          var cw_tmp_285: bool;
          if (((v_features & u32(65536i)) != u32(0i))) {
            cw_tmp_285 = (v_z < v_sceneDepth);
          } else {
            cw_tmp_285 = (v_z > v_sceneDepth);
          }
          var v_occluded: u32 = select(u32(0), u32(1), cw_tmp_285);
          var cw_tmp_287: f32;
          if ((v_occluded != u32(0i))) {
            cw_tmp_287 = 0.0f;
          } else {
            let cw_argument_index_286 = (v_distortion + u32(4i));
            cw_tmp_287 = (bitcast<f32>(b_texels[cw_argument_index_286]) * v_color[3i]);
          }
          var v_strength: f32 = cw_tmp_287;
          v_color[0i] = (((v_color[0i] * 2.0f) - 1.0f) * v_strength);
          v_color[1i] = (((v_color[1i] * 2.0f) - 1.0f) * v_strength);
          var cw_tmp_288: f32;
          if ((v_occluded != u32(0i))) {
            cw_tmp_288 = 1.0f;
          } else {
            cw_tmp_288 = 0.0f;
          }
          v_color[2i] = cw_tmp_288;
          v_writeNormal = u32(0i);
        }
        if ((((v_features & u32(32i)) != u32(0i)) && ((v_features & u32(4194304i)) == u32(0i)))) {
          var cw_tmp_289: f32;
          if (((v_features & ((67112960u | 268435456u) | 536870912u)) != 0u)) {
            cw_tmp_289 = (((v_a * b_attributes[(((v_ia / u32(10i)) * u32(34i)) + u32(9i))]) + (v_b * b_attributes[(((v_ib / u32(10i)) * u32(34i)) + u32(9i))])) + (v_c * b_attributes[(((v_ic / u32(10i)) * u32(34i)) + u32(9i))]));
          } else {
            cw_tmp_289 = v_eyeLength;
          }
          var v_euclidean: f32 = cw_tmp_289;
          var cw_tmp_290: f32;
          if (((v_features & u32(4i)) != u32(0i))) {
            cw_tmp_290 = v_euclidean;
          } else {
            cw_tmp_290 = abs(v_linearDepth);
          }
          var v_distance: f32 = cw_tmp_290;
          let cw_argument_index_291 = (v_data + u32(44i));
          var v_start: f32 = bitcast<f32>(b_texels[cw_argument_index_291]);
          let cw_argument_index_292 = (v_data + u32(45i));
          var v_end: f32 = bitcast<f32>(b_texels[cw_argument_index_292]);
          var cw_tmp_293: f32;
          if (((v_features & u32(8i)) != u32(0i))) {
            cw_tmp_293 = (1.0f - exp(cw_divide_f32(((-2.0f) * max(0.0f, (v_distance - (v_start * 0.5f)))), max(0.000001f, (v_end - (v_start * 0.5f))))));
          } else {
            cw_tmp_293 = min(1.0f, max(0.0f, cw_divide_f32((v_distance - v_start), max(0.000001f, (v_end - v_start)))));
          }
          var v_fog: f32 = cw_tmp_293;
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              var cw_tmp_295: f32;
              if (((v_features & u32(16i)) != u32(0i))) {
                cw_tmp_295 = 0.0f;
              } else {
                let cw_argument_index_294 = ((v_data + u32(40i)) + v_k);
                cw_tmp_295 = (bitcast<f32>(b_texels[cw_argument_index_294]) * v_fog);
              }
              v_color[v_k] = ((v_color[v_k] * (1.0f - v_fog)) + cw_tmp_295);
              continuing {
                v_k += u32(1);
              }
            }
          }
          if (((v_features & u32(1048576i)) != u32(0i))) {
            var v_sky: u32 = ((v_data + b_texels[(v_data + u32(79i))]) + u32(32i));
            let cw_argument_index_296 = (v_sky + u32(4i));
            var v_far: f32 = bitcast<f32>(b_texels[cw_argument_index_296]);
            let cw_argument_index_297 = (v_sky + u32(5i));
            var v_begin: f32 = bitcast<f32>(b_texels[cw_argument_index_297]);
            var v_fade: f32 = min(1.0f, max(0.0f, cw_divide_f32((v_far - v_distance), max(0.000001f, (v_far - v_begin)))));
            v_fade = (v_fade * v_fade);
            {
              var v_k: u32 = u32(0i);
              loop {
                if (!(v_k < u32(3i))) { break; }
                var cw_tmp_302: f32;
                if (((v_features & u32(16i)) != u32(0i))) {
                  cw_tmp_302 = 0.0f;
                } else {
                  let cw_argument_index_298 = v_sky;
                  let cw_argument_index_299 = (v_sky + u32(1i));
                  let cw_argument_index_300 = (v_sky + u32(2i));
                  let cw_argument_index_301 = (v_sky + u32(3i));
                  cw_tmp_302 = f_cw_buffer_helper_2(0i, b_texels[cw_argument_index_298], b_texels[cw_argument_index_299], b_texels[cw_argument_index_300], cw_divide_f32((f32(v_x) + 0.5f), f32(cw_params.p_width)), (1.0f - cw_divide_f32((f32(v_y) + 0.5f), f32(cw_params.p_height))), 0.0f, b_texels[cw_argument_index_301], v_k, cw_thread, cw_block, cw_grid);
                }
                var v_background: f32 = cw_tmp_302;
                v_color[v_k] = ((v_background * (1.0f - v_fade)) + (v_color[v_k] * v_fade));
                continuing {
                  v_k += u32(1);
                }
              }
            }
          }
        }
        if ((((v_features & u32(262144i)) != u32(0i)) && ((v_features & u32(4194304i)) == u32(0i)))) {
          var v_particle: u32 = (v_data + b_texels[(v_data + u32(79i))]);
          let cw_argument_index_303 = v_particle;
          let cw_argument_index_304 = (v_particle + u32(1i));
          let cw_argument_index_305 = (v_particle + u32(2i));
          let cw_argument_index_306 = (v_particle + u32(3i));
          var v_sceneDepth: f32 = f_cw_buffer_helper_2(0i, b_texels[cw_argument_index_303], b_texels[cw_argument_index_304], b_texels[cw_argument_index_305], cw_divide_f32((f32(v_x) + 0.5f), f32(cw_params.p_width)), (1.0f - cw_divide_f32((f32(v_y) + 0.5f), f32(cw_params.p_height))), 0.0f, b_texels[cw_argument_index_306], u32(0i), cw_thread, cw_block, cw_grid);
          if (((v_features & u32(65536i)) != u32(0i))) {
            v_sceneDepth = (1.0f - v_sceneDepth);
          }
          let cw_argument_index_307 = (v_particle + u32(4i));
          var v_near: f32 = bitcast<f32>(b_texels[cw_argument_index_307]);
          let cw_argument_index_308 = (v_particle + u32(5i));
          var v_far: f32 = bitcast<f32>(b_texels[cw_argument_index_308]);
          v_sceneDepth = cw_divide_f32((v_near * v_far), (((v_far - v_near) * v_sceneDepth) - v_far));
          let cw_argument_index_309 = (v_particle + u32(6i));
          var v_size: f32 = bitcast<f32>(b_texels[cw_argument_index_309]);
          let cw_argument_index_310 = (v_particle + u32(8i));
          var v_falloff: f32 = bitcast<f32>(b_texels[cw_argument_index_310]);
          var v_delta: f32 = min(1.0f, max(0.0f, cw_divide_f32((v_position[2i] - v_sceneDepth), max(0.000001f, (v_size * 0.33f)))));
          var v_bias: f32 = 1.0f;
          if ((b_texels[(v_particle + u32(7i))] != u32(0i))) {
            var v_dot: f32 = 0.0f;
            {
              var v_k: u32 = u32(0i);
              loop {
                if (!(v_k < u32(3i))) { break; }
                v_dot = (v_dot + (v_eye[v_k] * v_normal[v_k]));
                continuing {
                  v_k += u32(1);
                }
              }
            }
            v_dot = min(1.0f, abs(v_dot));
            var v_fade: f32 = min(1.0f, max(0.0f, cw_divide_f32(v_eyeLength, max(v_falloff, 0.000001f))));
            v_fade = (1.0f - (v_fade * v_fade));
            v_fade = (1.0f - (v_fade * v_fade));
            v_bias = ((v_dot * v_fade) * (1.0f - f_render_power((1.0f - v_dot), 1.3f, cw_thread, cw_block, cw_grid)));
          }
          v_color[3i] = (v_color[3i] * ((0.845f * f_render_power(v_delta, 1.3f, cw_thread, cw_block, cw_grid)) * v_bias));
        }
        if (((v_features & u32(4194304i)) == u32(0i))) {
          if ((b_texels[(v_data + u32(50i))] != u32(0i))) {
            v_color[3i] = 1.0f;
          }
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              v_color[v_k] = (v_color[v_k] + v_shadowDebug[v_k]);
              continuing {
                v_k += u32(1);
              }
            }
          }
        }
      }
      if (((v_flags & u32(1024i)) != u32(0i))) {
        var v_data: u32 = b_materials[v_m];
        var v_pass: u32 = b_texels[(v_data + u32(8i))];
        if ((v_pass == u32(5i))) {
          let cw_argument_index_311 = v_data;
          let cw_argument_index_312 = (v_data + u32(1i));
          let cw_argument_index_313 = (v_data + u32(2i));
          let cw_argument_index_314 = (v_data + u32(3i));
          var v_alpha: f32 = f_cw_buffer_helper_0(0i, b_texels[cw_argument_index_311], b_texels[cw_argument_index_312], b_texels[cw_argument_index_313], v_u, v_v, v_dudx, v_dvdx, v_dudy, v_dvdy, b_texels[cw_argument_index_314], u32(3i), cw_thread, cw_block, cw_grid);
          if ((v_alpha <= 0.8f)) {
            continue;
          }
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(4i))) { break; }
              v_color[v_k] = 1.0f;
              continuing {
                v_k += u32(1);
              }
            }
          }
        }
        var v_vertexAlpha: f32 = v_color[3i];
        let cw_argument_index_315 = (v_data + u32(9i));
        var v_opacity: f32 = bitcast<f32>(b_texels[cw_argument_index_315]);
        var v_phaseAlpha: f32 = 1.0f;
        var v_maskAlpha: f32 = 1.0f;
        var v_maskScaleX: f32 = 1.0f;
        var v_maskScaleY: f32 = 1.0f;
        if ((v_pass == u32(3i))) {
          v_maskScaleX = cw_divide_f32(f32(b_texels[(v_data + u32(5i))]), f32(b_materials[(v_m + u32(1i))]));
          v_maskScaleY = cw_divide_f32(f32(b_texels[(v_data + u32(6i))]), f32(b_materials[(v_m + u32(2i))]));
          let cw_argument_index_316 = v_data;
          let cw_argument_index_317 = (v_data + u32(1i));
          let cw_argument_index_318 = (v_data + u32(2i));
          let cw_argument_index_319 = (v_data + u32(3i));
          v_phaseAlpha = f_cw_buffer_helper_0(0i, b_texels[cw_argument_index_316], b_texels[cw_argument_index_317], b_texels[cw_argument_index_318], v_u, v_v, v_dudx, v_dvdx, v_dudy, v_dvdy, b_texels[cw_argument_index_319], u32(3i), cw_thread, cw_block, cw_grid);
          let cw_argument_index_320 = (v_data + u32(4i));
          let cw_argument_index_321 = (v_data + u32(5i));
          let cw_argument_index_322 = (v_data + u32(6i));
          let cw_argument_index_323 = (v_data + u32(7i));
          let cw_argument_index_324 = (v_data + u32(17i));
          v_maskAlpha = (f_cw_buffer_helper_0(0i, b_texels[cw_argument_index_320], b_texels[cw_argument_index_321], b_texels[cw_argument_index_322], v_u, v_v, (v_dudx * v_maskScaleX), (v_dvdx * v_maskScaleY), (v_dudy * v_maskScaleX), (v_dvdy * v_maskScaleY), b_texels[cw_argument_index_323], u32(3i), cw_thread, cw_block, cw_grid) * bitcast<f32>(b_texels[cw_argument_index_324]));
        }
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(4i))) { break; }
            let cw_argument_index_325 = ((v_data + u32(18i)) + v_k);
            var v_emission: f32 = bitcast<f32>(b_texels[cw_argument_index_325]);
            var v_sample: f32 = 1.0f;
            if (((v_pass >= u32(1i)) && (v_pass <= u32(4i)))) {
              let cw_argument_index_326 = v_data;
              let cw_argument_index_327 = (v_data + u32(1i));
              let cw_argument_index_328 = (v_data + u32(2i));
              let cw_argument_index_329 = (v_data + u32(3i));
              v_sample = f_cw_buffer_helper_0(0i, b_texels[cw_argument_index_326], b_texels[cw_argument_index_327], b_texels[cw_argument_index_328], v_u, v_v, v_dudx, v_dvdx, v_dudy, v_dvdy, b_texels[cw_argument_index_329], v_k, cw_thread, cw_block, cw_grid);
            }
            if ((v_pass == u32(0i))) {
              var cw_tmp_330: f32;
              if ((v_k == u32(3i))) {
                cw_tmp_330 = v_vertexAlpha;
              } else {
                cw_tmp_330 = 1.0f;
              }
              v_color[v_k] = (v_emission * cw_tmp_330);
            }
            if ((v_pass == u32(1i))) {
              var cw_tmp_331: f32;
              if ((v_k == u32(3i))) {
                cw_tmp_331 = (v_vertexAlpha * v_opacity);
              } else {
                cw_tmp_331 = 1.0f;
              }
              v_color[v_k] = (v_sample * cw_tmp_331);
            }
            if ((v_pass == u32(2i))) {
              let cw_argument_index_332 = ((v_data + u32(26i)) + v_k);
              var v_fog: f32 = bitcast<f32>(b_texels[cw_argument_index_332]);
              var cw_tmp_333: f32;
              if ((v_k == u32(3i))) {
                cw_tmp_333 = ((v_sample * v_vertexAlpha) * v_opacity);
              } else {
                cw_tmp_333 = ((v_fog * (1.0f - v_vertexAlpha)) + (min(1.0f, max(0.0f, (v_sample * v_emission))) * v_vertexAlpha));
              }
              v_color[v_k] = cw_tmp_333;
            }
            if ((v_pass == u32(3i))) {
              let cw_argument_index_334 = (v_data + u32(4i));
              let cw_argument_index_335 = (v_data + u32(5i));
              let cw_argument_index_336 = (v_data + u32(6i));
              let cw_argument_index_337 = (v_data + u32(7i));
              var v_mask: f32 = f_cw_buffer_helper_0(0i, b_texels[cw_argument_index_334], b_texels[cw_argument_index_335], b_texels[cw_argument_index_336], v_u, v_v, (v_dudx * v_maskScaleX), (v_dvdx * v_maskScaleY), (v_dudy * v_maskScaleX), (v_dvdy * v_maskScaleY), b_texels[cw_argument_index_337], v_k, cw_thread, cw_block, cw_grid);
              var cw_tmp_341: f32;
              if ((v_k == u32(3i))) {
                cw_tmp_341 = v_maskAlpha;
              } else {
                let cw_argument_index_338 = ((v_data + u32(14i)) + v_k);
                let cw_argument_index_339 = ((v_data + u32(10i)) + v_k);
                let cw_argument_index_340 = (v_data + u32(17i));
                cw_tmp_341 = (((v_mask * bitcast<f32>(b_texels[cw_argument_index_338])) * v_maskAlpha) + (((v_sample * bitcast<f32>(b_texels[cw_argument_index_339])) * v_phaseAlpha) * bitcast<f32>(b_texels[cw_argument_index_340])));
              }
              v_color[v_k] = cw_tmp_341;
            }
            if ((v_pass == u32(4i))) {
              var cw_tmp_343: f32;
              if ((v_k == u32(3i))) {
                let cw_argument_index_342 = (v_data + u32(25i));
                cw_tmp_343 = bitcast<f32>(b_texels[cw_argument_index_342]);
              } else {
                cw_tmp_343 = 1.0f;
              }
              v_color[v_k] = (v_sample * cw_tmp_343);
            }
            if ((v_pass == u32(6i))) {
              var cw_tmp_345: f32;
              if ((v_k == u32(3i))) {
                let cw_argument_index_344 = (v_data + u32(25i));
                cw_tmp_345 = bitcast<f32>(b_texels[cw_argument_index_344]);
              } else {
                cw_tmp_345 = v_emission;
              }
              v_color[v_k] = cw_tmp_345;
            }
            continuing {
              v_k += u32(1);
            }
          }
        }
      }
      if ((v_fixedLit != u32(0i))) {
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            v_color[v_k] = min(1.0f, max(0.0f, (v_color[v_k] + v_fixedSpecular[v_k])));
            continuing {
              v_k += u32(1);
            }
          }
        }
      }
      if (((v_flags & 32768u) != 0u)) {
        let cw_argument_index_346 = (v_raster + 23u);
        var v_fog: u32 = bitcast<u32>(b_attributes[cw_argument_index_346]);
        var v_mode: u32 = (b_texels[v_fog] & 3u);
        var v_position: array<f32, 3>;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            v_position[v_k] = (((v_a * b_attributes[(((v_ia / 10u) * 34u) + v_k)]) + (v_b * b_attributes[(((v_ib / 10u) * 34u) + v_k)])) + (v_c * b_attributes[(((v_ic / 10u) * 34u) + v_k)]));
            continuing {
              v_k += u32(1);
            }
          }
        }
        var cw_tmp_348: f32;
        if (((b_texels[v_fog] & 4u) != 0u)) {
          cw_tmp_348 = sqrt((((v_position[0i] * v_position[0i]) + (v_position[1i] * v_position[1i])) + (v_position[2i] * v_position[2i])));
        } else {
          let cw_argument_index_347 = 2i;
          cw_tmp_348 = abs(v_position[cw_argument_index_347]);
        }
        var v_distance: f32 = cw_tmp_348;
        if (((b_texels[v_fog] & 8u) != 0u)) {
          v_distance = (((v_a * b_attributes[(((v_ia / 10u) * 34u) + 9u)]) + (v_b * b_attributes[(((v_ib / 10u) * 34u) + 9u)])) + (v_c * b_attributes[(((v_ic / 10u) * 34u) + 9u)]));
        }
        if (((b_texels[v_fog] & 16u) != 0u)) {
          let cw_argument_index_349 = (v_fog + 8u);
          v_distance = bitcast<f32>(b_texels[cw_argument_index_349]);
        }
        let cw_argument_index_350 = (v_fog + 1u);
        var v_density: f32 = bitcast<f32>(b_texels[cw_argument_index_350]);
        let cw_argument_index_351 = (v_fog + 2u);
        var v_start: f32 = bitcast<f32>(b_texels[cw_argument_index_351]);
        let cw_argument_index_352 = (v_fog + 3u);
        var v_end: f32 = bitcast<f32>(b_texels[cw_argument_index_352]);
        var v_factor: f32 = 0.0f;
        if ((v_mode == 0u)) {
          var cw_tmp_354: f32;
          if ((v_end != v_start)) {
            cw_tmp_354 = cw_divide_f32((v_end - v_distance), (v_end - v_start));
          } else {
            var cw_tmp_353: f32;
            if ((v_distance < v_end)) {
              cw_tmp_353 = 1.0f;
            } else {
              cw_tmp_353 = 0.0f;
            }
            cw_tmp_354 = cw_tmp_353;
          }
          v_factor = cw_tmp_354;
        } else {
          var v_exponent: f32 = (v_density * v_distance);
          if ((v_mode == 2u)) {
            v_exponent = (v_exponent * v_exponent);
          }
          v_factor = exp((-v_exponent));
        }
        v_factor = min(1.0f, max(0.0f, v_factor));
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            let cw_argument_index_355 = ((v_fog + 4u) + v_k);
            v_color[v_k] = ((v_factor * v_color[v_k]) + ((1.0f - v_factor) * bitcast<f32>(b_texels[cw_argument_index_355])));
            continuing {
              v_k += u32(1);
            }
          }
        }
      }
      if (((v_flags & u32(256i)) != u32(0i))) {
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(4i))) { break; }
            let cw_argument_index_356 = v_k;
            v_color[v_k] = min(1.0f, max(0.0f, v_color[cw_argument_index_356]));
            continuing {
              v_k += u32(1);
            }
          }
        }
      }
      v_color[3i] = (v_color[3i] * v_pointFade);
      if (((v_flags & u32(128i)) != u32(0i))) {
        let cw_argument_index_357 = 3i;
        let cw_argument_index_358 = (v_m + u32(4i));
        if ((f_compare_value(v_color[cw_argument_index_357], bitcast<f32>(b_materials[cw_argument_index_358]), ((v_control >> u32(4i)) & u32(15i)), cw_thread, cw_block, cw_grid) == u32(0i))) {
          continue;
        }
      } else {
        if ((v_color[3i] < cw_divide_f32(f32(b_materials[(v_m + u32(4i))]), 255.0f))) {
          continue;
        }
      }
      if (((v_multisample != 0u) && ((v_flags & 65536u) != 0u))) {
        var v_rank: u32 = ((v_sample + (((v_x * 3u) + (v_y * 5u)) % cw_params.p_sample_count)) % cw_params.p_sample_count);
        let cw_argument_index_359 = 3i;
        var v_coverage: f32 = min(1.0f, max(0.0f, v_color[cw_argument_index_359]));
        if ((v_coverage < cw_divide_f32((f32(v_rank) + 0.5f), f32(cw_params.p_sample_count)))) {
          continue;
        }
      }
      if (((v_multisample != 0u) && ((v_flags & 131072u) != 0u))) {
        v_color[3i] = 1.0f;
      }
      var cw_tmp_360: u32;
      if (((v_flags & 4194304u) != 0u)) {
        cw_tmp_360 = 1u;
      } else {
        cw_tmp_360 = v_front;
      }
      var v_stencilFront: u32 = cw_tmp_360;
      if ((((v_flags & 8192u) != 0u) && (cw_params.p_stencil_enabled != 0u))) {
        if ((f_cw_buffer_helper_15(0i, 0i, v_raster, v_pixel, (cw_params.p_width * cw_params.p_height), v_stencilFront, v_depth_pass, v_target_offset, cw_thread, cw_block, cw_grid) == 0u)) {
          continue;
        }
      }
      if ((v_depth_pass == 0u)) {
        continue;
      }
      if ((((v_flags & 1024u) != 0u) && (b_texels[(b_materials[v_m] + 8u)] == 5u))) {
        _ = atomicAdd(&b_counts[(((((cw_params.p_width + 15u) / 16u) * ((cw_params.p_height + 15u) / 16u)) + 1u) + (v_m / 12u))], 1u);
        continue;
      }
      if ((cw_params.p_color_channels == 0u)) {
        if (((v_flags & 8u) != 0u)) {
          b_target[v_pixel] = v_z;
        }
        continue;
      }
      let cw_argument_index_361 = 3i;
      var v_alpha: f32 = f_clamp_blend_component(v_color[cw_argument_index_361], cw_params.p_color_storage, cw_thread, cw_block, cw_grid);
      var cw_tmp_363: f32;
      if ((cw_params.p_color_channels < 4u)) {
        cw_tmp_363 = 1.0f;
      } else {
        let cw_argument_index_362 = ((v_target_offset + (v_pixel * u32(9i))) + u32(3i));
        cw_tmp_363 = f_clamp_blend_component(b_target[cw_argument_index_362], cw_params.p_color_storage, cw_thread, cw_block, cw_grid);
      }
      var v_destAlpha: f32 = cw_tmp_363;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(4i))) { break; }
          if ((((v_k < cw_params.p_color_channels) && ((v_flags & u32(128i)) != u32(0i))) && (((v_control >> (u32(17i) + v_k)) & u32(1i)) != u32(0i)))) {
            continue;
          }
          var v_value: f32 = v_color[v_k];
          var cw_tmp_365: f32;
          if ((v_k >= cw_params.p_color_channels)) {
            var cw_tmp_364: f32;
            if ((v_k == 3u)) {
              cw_tmp_364 = 1.0f;
            } else {
              cw_tmp_364 = 0.0f;
            }
            cw_tmp_365 = cw_tmp_364;
          } else {
            cw_tmp_365 = b_target[((v_target_offset + (v_pixel * u32(9i))) + v_k)];
          }
          var v_dest: f32 = cw_tmp_365;
          var v_logic: u32 = select(u32(0), u32(1), (((v_flags & 128u) != 0u) && ((v_control & 33554432u) != 0u)));
          if (((v_logic != 0u) && ((cw_params.p_color_storage == 0u) || (cw_params.p_color_storage == 4u)))) {
            var cw_tmp_366: u32;
            if ((cw_params.p_color_storage == 4u)) {
              cw_tmp_366 = 65535u;
            } else {
              cw_tmp_366 = 255u;
            }
            v_value = f_logic_unorm(v_value, v_dest, ((v_control >> 21u) & 15u), cw_tmp_366, cw_thread, cw_block, cw_grid);
          }
          if ((((v_flags & u32(2i)) != u32(0i)) && (v_logic == 0u))) {
            let cw_argument_index_367 = v_k;
            var v_sourceBlend: f32 = f_clamp_blend_component(v_color[cw_argument_index_367], cw_params.p_color_storage, cw_thread, cw_block, cw_grid);
            var v_destBlend: f32 = f_clamp_blend_component(v_dest, cw_params.p_color_storage, cw_thread, cw_block, cw_grid);
            if (((v_flags & u32(128i)) != u32(0i))) {
              var cw_tmp_368: i32;
              if ((v_k == u32(3i))) {
                cw_tmp_368 = 8i;
              } else {
                cw_tmp_368 = 0i;
              }
              var v_factors: u32 = (b_materials[(v_m + u32(10i))] >> u32(cw_tmp_368));
              let cw_argument_index_369 = ((v_raster + u32(4i)) + v_k);
              let cw_argument_index_370 = (v_raster + u32(7i));
              var v_sf: f32 = f_clamp_blend_component(f_blend_factor((v_factors & u32(15i)), v_sourceBlend, v_destBlend, v_alpha, v_destAlpha, v_k, b_attributes[cw_argument_index_369], b_attributes[cw_argument_index_370], cw_thread, cw_block, cw_grid), cw_params.p_color_storage, cw_thread, cw_block, cw_grid);
              let cw_argument_index_371 = ((v_raster + u32(4i)) + v_k);
              let cw_argument_index_372 = (v_raster + u32(7i));
              var v_df: f32 = f_clamp_blend_component(f_blend_factor(((v_factors >> u32(4i)) & u32(15i)), v_sourceBlend, v_destBlend, v_alpha, v_destAlpha, v_k, b_attributes[cw_argument_index_371], b_attributes[cw_argument_index_372], cw_thread, cw_block, cw_grid), cw_params.p_color_storage, cw_thread, cw_block, cw_grid);
              var cw_tmp_373: i32;
              if ((v_k == u32(3i))) {
                cw_tmp_373 = 11i;
              } else {
                cw_tmp_373 = 8i;
              }
              v_value = f_blend_value(v_sourceBlend, v_destBlend, v_sf, v_df, ((v_control >> u32(cw_tmp_373)) & u32(7i)), cw_thread, cw_block, cw_grid);
            } else {
              var cw_tmp_374: f32;
              if ((v_k == u32(3i))) {
                cw_tmp_374 = (v_alpha + (v_destBlend * (1.0f - v_alpha)));
              } else {
                cw_tmp_374 = ((v_sourceBlend * v_alpha) + (v_destBlend * (1.0f - v_alpha)));
              }
              v_value = cw_tmp_374;
            }
          }
          if (((v_flags & u32(256i)) != u32(0i))) {
            v_value = min(1.0f, max(0.0f, v_value));
          }
          b_target[((v_target_offset + (v_pixel * u32(9i))) + v_k)] = f_store_color_value(v_value, v_k, cw_params.p_color_channels, cw_params.p_color_storage, cw_thread, cw_block, cw_grid);
          continuing {
            v_k += u32(1);
          }
        }
      }
      if (((v_flags & u32(8i)) != u32(0i))) {
        b_target[((v_target_offset + (v_pixel * u32(9i))) + u32(4i))] = v_z;
      }
      if (((v_writeNormal != u32(0i)) && (cw_params.p_normal_enabled != u32(0i)))) {
        var cw_tmp_375: u32;
        if (((v_flags & u32(128i)) != u32(0i))) {
          cw_tmp_375 = u32(b_attributes[(v_raster + 22u)]);
        } else {
          cw_tmp_375 = 0u;
        }
        var v_normal_mask: u32 = cw_tmp_375;
        var cw_tmp_376: f32;
        if (((v_multisample != 0u) && ((v_flags & 131072u) != 0u))) {
          cw_tmp_376 = 1.0f;
        } else {
          cw_tmp_376 = v_pointFade;
        }
        var v_normalAlpha: f32 = cw_tmp_376;
        var cw_tmp_378: f32;
        if ((cw_params.p_normal_channels < 4u)) {
          cw_tmp_378 = 1.0f;
        } else {
          let cw_argument_index_377 = ((v_target_offset + (v_pixel * u32(9i))) + u32(8i));
          cw_tmp_378 = f_clamp_blend_component(b_target[cw_argument_index_377], cw_params.p_normal_storage, cw_thread, cw_block, cw_grid);
        }
        var v_normalDestAlpha: f32 = cw_tmp_378;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(4i))) { break; }
            if (((v_k >= cw_params.p_normal_channels) || ((v_normal_mask & (1u << v_k)) == 0u))) {
              var cw_tmp_379: f32;
              if ((v_k < 3u)) {
                cw_tmp_379 = v_fragmentNormal[v_k];
              } else {
                cw_tmp_379 = v_normalAlpha;
              }
              var v_value: f32 = cw_tmp_379;
              var cw_tmp_381: f32;
              if ((v_k >= cw_params.p_normal_channels)) {
                var cw_tmp_380: f32;
                if ((v_k == 3u)) {
                  cw_tmp_380 = 1.0f;
                } else {
                  cw_tmp_380 = 0.0f;
                }
                cw_tmp_381 = cw_tmp_380;
              } else {
                cw_tmp_381 = b_target[(((v_target_offset + (v_pixel * u32(9i))) + u32(5i)) + v_k)];
              }
              var v_dest: f32 = cw_tmp_381;
              var v_logic: u32 = select(u32(0), u32(1), (((v_flags & 128u) != 0u) && ((v_control & 33554432u) != 0u)));
              if (((v_logic != 0u) && ((cw_params.p_normal_storage == 0u) || (cw_params.p_normal_storage == 4u)))) {
                var cw_tmp_382: u32;
                if ((cw_params.p_normal_storage == 4u)) {
                  cw_tmp_382 = 65535u;
                } else {
                  cw_tmp_382 = 255u;
                }
                v_value = f_logic_unorm(v_value, v_dest, ((v_control >> 21u) & 15u), cw_tmp_382, cw_thread, cw_block, cw_grid);
              }
              if ((((v_logic == 0u) && ((v_flags & 128u) != 0u)) && ((v_control & 67108864u) != 0u))) {
                var v_sourceBlend: f32 = f_clamp_blend_component(v_value, cw_params.p_normal_storage, cw_thread, cw_block, cw_grid);
                var v_destBlend: f32 = f_clamp_blend_component(v_dest, cw_params.p_normal_storage, cw_thread, cw_block, cw_grid);
                var cw_tmp_383: u32;
                if ((v_k == 3u)) {
                  cw_tmp_383 = 8u;
                } else {
                  cw_tmp_383 = 0u;
                }
                var v_factors: u32 = (b_materials[(v_m + u32(10i))] >> cw_tmp_383);
                let cw_argument_index_384 = ((v_raster + 4u) + v_k);
                let cw_argument_index_385 = (v_raster + 7u);
                var v_sf: f32 = f_clamp_blend_component(f_blend_factor((v_factors & 15u), v_sourceBlend, v_destBlend, v_normalAlpha, v_normalDestAlpha, v_k, b_attributes[cw_argument_index_384], b_attributes[cw_argument_index_385], cw_thread, cw_block, cw_grid), cw_params.p_normal_storage, cw_thread, cw_block, cw_grid);
                let cw_argument_index_386 = ((v_raster + 4u) + v_k);
                let cw_argument_index_387 = (v_raster + 7u);
                var v_df: f32 = f_clamp_blend_component(f_blend_factor(((v_factors >> 4u) & 15u), v_sourceBlend, v_destBlend, v_normalAlpha, v_normalDestAlpha, v_k, b_attributes[cw_argument_index_386], b_attributes[cw_argument_index_387], cw_thread, cw_block, cw_grid), cw_params.p_normal_storage, cw_thread, cw_block, cw_grid);
                var cw_tmp_388: u32;
                if ((v_k == 3u)) {
                  cw_tmp_388 = 11u;
                } else {
                  cw_tmp_388 = 8u;
                }
                v_value = f_blend_value(v_sourceBlend, v_destBlend, v_sf, v_df, ((v_control >> cw_tmp_388) & 7u), cw_thread, cw_block, cw_grid);
              }
              b_target[(((v_target_offset + (v_pixel * u32(9i))) + u32(5i)) + v_k)] = f_store_color_value(v_value, v_k, cw_params.p_normal_channels, cw_params.p_normal_storage, cw_thread, cw_block, cw_grid);
            }
            continuing {
              v_k += u32(1);
            }
          }
        }
      }
    }
  }
}
