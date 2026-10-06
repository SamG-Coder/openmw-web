// SPDX-License-Identifier: GPL-3.0-or-later
// Authored WebGPU vertex/fragment renderer. The material arithmetic was ported
// once from the material stage at 95d9814; this file is the editable source.
// No runtime translation or CUDA compiler participates in this rendering path.
// Coverage, clipping, depth/stencil testing, and blending use GPU render passes.
// Buffer textures retain the engine's atlas/material ABI and explicit gradients.

// Pipeline specialization keeps inactive material families out of driver
// compilation; these descriptors are immutable CPU packet metadata.
override MATERIAL_FLAGS: u32 = 0u;
override MATERIAL_FEATURES: u32 = 0u;
override MATERIAL_LAYERS: u32 = 0u;
override MATERIAL_MODE: u32 = 0u;
override SKY_PASS: u32 = 0u;
override HAS_SHADOWS: u32 = 0u;

@group(0) @binding(0) var<storage, read> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read> b_triangles: array<u32>;
@group(0) @binding(2) var<storage, read> b_materials: array<u32>;
@group(0) @binding(3) var<storage, read> b_texels: array<u32>;
@group(0) @binding(4) var<storage, read> b_attributes: array<f32>;
struct RasterParams {
  width: u32, height: u32, capacity: u32, raster_offset: u32,
  boundary_offset: u32, point_fade_offset: u32, lighting_offset: u32, cluster_offset: u32,
  fixed_offset: u32, falloff_offset: u32, fixed_enabled: u32, normal_enabled: u32,
  normal_channels: u32, normal_storage: u32, color_channels: u32, color_storage: u32,
  depth_bits: u32, stencil_enabled: u32, sample_count: u32, draw_material: u32,
}
@group(0) @binding(5) var<uniform> params: RasterParams;

struct RasterVaryings {
  @builtin(position) position: vec4<f32>,
  @location(0) @interpolate(perspective, sample) weights: vec3<f32>,
  @location(1) @interpolate(flat) triangle: u32,
}

@vertex fn vertex_main(@builtin(vertex_index) index: u32) -> RasterVaryings {
  let triangle = index / 3u;
  let corner = index % 3u;
  let base = b_triangles[triangle * 4u + corner] * 10u;
  let material = b_triangles[triangle * 4u + 3u];
  let flags = MATERIAL_FLAGS;
  var out: RasterVaryings;
  out.position = vec4<f32>(b_vertices[base], b_vertices[base+1u], b_vertices[base+2u], b_vertices[base+3u]);
  // GL clip depths are [-w,w], unless the packet explicitly selects [0,w].
  if ((flags & 8388608u) == 0u) { out.position.z = 0.5 * (out.position.z + out.position.w); }
  if (material != params.draw_material || all(out.position == vec4<f32>(0.0))) {
    out.position = vec4<f32>(2.0, 2.0, 2.0, 1.0);
  }
  out.weights = vec3<f32>(select(0.0, 1.0, corner == 0u), select(0.0, 1.0, corner == 1u), select(0.0, 1.0, corner == 2u));
  out.triangle = triangle;
  return out;
}

// Homogeneous screen coordinates avoid dividing by individual vertex w. This
// remains defined for triangles crossing the eye/near plane, including w == 0.
fn homogeneous_screen(base: u32) -> vec3<f32> {
  let w = b_vertices[base+3u];
  return vec3<f32>((b_vertices[base] + w) * 0.5 * f32(params.width),
    (w - b_vertices[base+1u]) * 0.5 * f32(params.height), w);
}
struct MaterialResult { color: vec4<f32>, normal: vec4<f32>, depth: f32 }
struct ColorOutput { @location(0) color: vec4<f32>, @builtin(frag_depth) depth: f32 }
struct NormalOutput { @location(0) color: vec4<f32>, @location(1) normal: vec4<f32>, @builtin(frag_depth) depth: f32 }
fn precise_divide(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }
fn f_render_power(cw_arg_base: f32, cw_arg_exponent: f32) -> f32 {
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






fn f_store_depth_value(cw_arg_value: f32, cw_arg_bits: u32) -> f32 {
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
  return min(1.0f, precise_divide(floor(((v_value * v_maximum) + 0.5f)), v_maximum));
}
fn f_raster_unit_value(cw_arg_value: f32) -> f32 {
  var v_value: f32 = cw_arg_value;
  return min(1.0f, max(0.0f, v_value));
}

fn f_point_disk_integral(cw_arg_x: f32, cw_arg_y: f32, cw_arg_radius: f32) -> f32 {
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
fn f_point_disk_coverage(cw_arg_x: f32, cw_arg_y: f32, cw_arg_radius: f32) -> f32 {
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
  var v_area: f32 = (((f_point_disk_integral((v_x + 0.5f), (v_y + 0.5f), v_radius) - f_point_disk_integral((v_x - 0.5f), (v_y + 0.5f), v_radius)) - f_point_disk_integral((v_x + 0.5f), (v_y - 0.5f), v_radius)) + f_point_disk_integral((v_x - 0.5f), (v_y - 0.5f), v_radius));
  return min(1.0f, max(0.0f, v_area));
}
fn f_line_parameter_less(cw_arg_a: f32, cw_arg_a1: f32, cw_arg_a2: f32, cw_arg_b: f32, cw_arg_b1: f32, cw_arg_b2: f32) -> u32 {
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
fn f_line_diamond_exit(cw_arg_ax: f32, cw_arg_ay: f32, cw_arg_dx: f32, cw_arg_dy: f32) -> u32 {
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
        var v_low: f32 = precise_divide(((-0.5f) - v_origin), v_delta);
        var v_high: f32 = precise_divide((0.5f - v_origin), v_delta);
        var v_first: f32 = precise_divide(1.0f, v_delta);
        var v_last: f32 = precise_divide(v_second, v_delta);
        if ((v_delta < 0.0f)) {
          var v_swap: f32 = v_low;
          v_low = v_high;
          v_high = v_swap;
        }
        if ((f_line_parameter_less(v_enter, v_enter1, v_enter2, v_low, v_first, v_last) != 0u)) {
          v_enter = v_low;
          v_enter1 = v_first;
          v_enter2 = v_last;
        }
        if ((f_line_parameter_less(v_high, v_first, v_last, v_leave, v_leave1, v_leave2) != 0u)) {
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
  return select(u32(0), u32(1), ((f_line_parameter_less(v_enter, v_enter1, v_enter2, v_leave, v_leave1, v_leave2) != 0u) && (f_line_parameter_less(v_leave, v_leave1, v_leave2, 1.0f, 0.0f, 0.0f) != 0u)));
}
fn f_line_wide_diamond(cw_arg_ax: f32, cw_arg_ay: f32, cw_arg_dx: f32, cw_arg_dy: f32, cw_arg_width: f32) -> u32 {
  var v_ax: f32 = cw_arg_ax;
  var v_ay: f32 = cw_arg_ay;
  var v_dx: f32 = cw_arg_dx;
  var v_dy: f32 = cw_arg_dy;
  var v_width: f32 = cw_arg_width;
  if ((v_width == 1.0f)) {
    return f_line_diamond_exit(v_ax, v_ay, v_dx, v_dy);
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
    cw_tmp_16 = (v_baseY - precise_divide((v_baseX * v_dy), v_dx));
  } else {
    cw_tmp_16 = (-(v_baseX - precise_divide((v_baseY * v_dx), v_dy)));
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
      if ((f_line_diamond_exit(v_x, v_y, v_dx, v_dy) != 0u)) {
        return 1u;
      }
      continuing {
        v_candidate += u32(1);
      }
    }
  }
  return 0u;
}
fn f_line_rectangle_coverage(cw_arg_ax: f32, cw_arg_ay: f32, cw_arg_dx: f32, cw_arg_dy: f32, cw_arg_width: f32) -> f32 {
  var v_ax: f32 = cw_arg_ax;
  var v_ay: f32 = cw_arg_ay;
  var v_dx: f32 = cw_arg_dx;
  var v_dy: f32 = cw_arg_dy;
  var v_width: f32 = cw_arg_width;
  var v_length: f32 = sqrt(((v_dx * v_dx) + (v_dy * v_dy)));
  if (((v_length <= 0.0f) || (v_width <= 0.0f))) {
    return 0.0f;
  }
  var v_nx: f32 = ((precise_divide((-v_dy), v_length) * v_width) * 0.5f);
  var v_ny: f32 = ((precise_divide(v_dx, v_length) * v_width) * 0.5f);
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
            var v_t: f32 = precise_divide(v_d0, (v_d0 - v_d1));
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
fn f_compare_value(cw_arg_a: f32, cw_arg_b: f32, cw_arg_function: u32) -> u32 {
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



fn f_texture_environment(cw_arg_primary: f32, cw_arg_texture: f32, cw_arg_texture_alpha: f32, cw_arg_constant: f32, cw_arg_mode: u32, cw_arg_format: u32, cw_arg_channel: u32) -> f32 {
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
fn f_combine_texture_arguments(cw_arg_a: f32, cw_arg_b: f32, cw_arg_c: f32, cw_arg_operation: u32) -> f32 {
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


fn f_texture_coord(cw_arg_x: i32, cw_arg_size: i32, cw_arg_repeat: u32) -> i32 {
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
fn f_sampler_index(cw_arg_i: i32, cw_arg_size: i32, cw_arg_wrap: u32) -> i32 {
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
fn f_water_unit(cw_arg_x: f32) -> f32 {
  var v_x: f32 = cw_arg_x;
  return min(1.0f, max(0.0f, v_x));
}
fn f_water_smooth(cw_arg_a: f32, cw_arg_b: f32, cw_arg_x: f32) -> f32 {
  var v_a: f32 = cw_arg_a;
  var v_b: f32 = cw_arg_b;
  var v_x: f32 = cw_arg_x;
  var v_t: f32 = f_water_unit(precise_divide((v_x - v_a), (v_b - v_a)));
  return ((v_t * v_t) * (3.0f - (2.0f * v_t)));
}
fn f_water_depth(cw_arg_depth: f32, cw_arg_near: f32, cw_arg_far: f32, cw_arg_reverse: u32) -> f32 {
  var v_depth: f32 = cw_arg_depth;
  var v_near: f32 = cw_arg_near;
  var v_far: f32 = cw_arg_far;
  var v_reverse: u32 = cw_arg_reverse;
  if ((v_reverse != u32(0i))) {
    v_depth = (1.0f - v_depth);
  }
  return precise_divide((v_near * v_far), max(0.000001f, (v_far - (v_depth * (v_far - v_near)))));
}
fn f_water_fract(cw_arg_x: f32) -> f32 {
  var v_x: f32 = cw_arg_x;
  return (v_x - floor(v_x));
}
fn f_water_scramble(cw_arg_x: f32, cw_arg_power: f32) -> f32 {
  var v_x: f32 = cw_arg_x;
  var v_power: f32 = cw_arg_power;
  return f_water_fract(f_render_power(((f_water_fract(v_x) * 3.0f) + 1.0f), v_power));
}
fn f_water_blip(cw_arg_x: f32) -> f32 {
  var v_x: f32 = cw_arg_x;
  var v_n: f32 = max(0.0f, (1.0f - (v_x * v_x)));
  return ((v_n * v_n) * v_n);
}

fn sample_atlas(cw_buffer_arg_0: i32, cw_arg_base: u32, cw_arg_width: u32, cw_arg_height: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_ux: f32, cw_arg_vx: f32, cw_arg_uy: f32, cw_arg_vy: f32, cw_arg_sampler: u32, cw_arg_channel: u32) -> f32 {
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
    let cw_argument_index_397 = (cw_buffer_offset_0 + i32((v_base + 9u)));
    v_maximum = min(16.0f, bitcast<f32>(b_texels[cw_argument_index_397]));
  }
  if ((v_maximum <= 1.0f)) {
    return sample_texture_lod((cw_buffer_offset_0 + 0i), v_base, v_width, v_height, v_u, v_v, v_isotropic, v_sampler, v_channel);
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
    return sample_texture_lod((cw_buffer_offset_0 + 0i), v_base, v_width, v_height, v_u, v_v, v_isotropic, v_sampler, v_channel);
  }
  var v_ratio: f32 = min(v_maximum, precise_divide(v_major, max(1.0f, v_minor)));
  var v_taps: u32 = u32(ceil(max(1.0f, v_ratio)));
  if ((v_taps <= 1u)) {
    return sample_texture_lod((cw_buffer_offset_0 + 0i), v_base, v_width, v_height, v_u, v_v, v_isotropic, v_sampler, v_channel);
  }
  var cw_tmp_398: f32;
  if ((v_xx >= v_yy)) {
    cw_tmp_398 = 1.0f;
  } else {
    cw_tmp_398 = 0.0f;
  }
  var v_axisU: f32 = cw_tmp_398;
  var cw_tmp_399: f32;
  if ((v_xx >= v_yy)) {
    cw_tmp_399 = 0.0f;
  } else {
    cw_tmp_399 = 1.0f;
  }
  var v_axisV: f32 = cw_tmp_399;
  if ((abs(v_xy) > 1e-8f)) {
    var cw_tmp_400: f32;
    if ((v_xx >= v_yy)) {
      cw_tmp_400 = (v_majorSquared - v_yy);
    } else {
      cw_tmp_400 = v_xy;
    }
    v_axisU = cw_tmp_400;
    var cw_tmp_401: f32;
    if ((v_xx >= v_yy)) {
      cw_tmp_401 = v_xy;
    } else {
      cw_tmp_401 = (v_majorSquared - v_xx);
    }
    v_axisV = cw_tmp_401;
    var v_length: f32 = sqrt(max(1e-12f, ((v_axisU * v_axisU) + (v_axisV * v_axisV))));
    v_axisU = precise_divide(v_axisU, v_length);
    v_axisV = precise_divide(v_axisV, v_length);
  }
  var v_lod: f32 = log2(max(v_minor, precise_divide(v_major, v_maximum)));
  var v_result: f32 = 0.0f;
  {
    var v_tap: u32 = u32(0i);
    loop {
      if (!(v_tap < v_taps)) { break; }
      var v_offset: f32 = (precise_divide((f32(v_tap) + 0.5f), f32(v_taps)) - 0.5f);
      v_result = (v_result + sample_texture_lod((cw_buffer_offset_0 + 0i), v_base, v_width, v_height, (v_u + precise_divide(((v_axisU * v_major) * v_offset), f32(v_width))), (v_v + precise_divide(((v_axisV * v_major) * v_offset), f32(v_height))), v_lod, v_sampler, v_channel));
      continuing {
        v_tap += u32(1);
      }
    }
  }
  return precise_divide(v_result, f32(v_taps));
}
fn sample_legacy_texture(cw_buffer_arg_0: i32, cw_arg_base: u32, cw_arg_width: u32, cw_arg_height: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_flags: u32, cw_arg_channel: u32) -> f32 {
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
  var cw_tmp_402: f32;
  if (((v_flags & u32(16i)) != u32(0i))) {
    cw_tmp_402 = (v_u - floor(v_u));
  } else {
    cw_tmp_402 = min(1.0f, max(0.0f, v_u));
  }
  v_u = cw_tmp_402;
  var cw_tmp_403: f32;
  if (((v_flags & u32(16i)) != u32(0i))) {
    cw_tmp_403 = (v_v - floor(v_v));
  } else {
    cw_tmp_403 = min(1.0f, max(0.0f, v_v));
  }
  v_v = cw_tmp_403;
  var v_x: f32 = (v_u * f32(v_width));
  var v_y: f32 = (v_v * f32(v_height));
  if (((v_flags & u32(32i)) == u32(0i))) {
    var v_ix: u32 = u32(f_texture_coord(i32(floor(v_x)), i32(v_width), (v_flags & u32(16i))));
    var v_iy: u32 = u32(f_texture_coord(i32(floor(v_y)), i32(v_height), (v_flags & u32(16i))));
    return precise_divide(f32(((b_texels[(cw_buffer_offset_0 + i32(((v_base + (v_iy * v_width)) + v_ix)))] >> (v_channel * u32(8i))) & u32(255i))), 255.0f);
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
          var v_ix: u32 = u32(f_texture_coord((v_x0 + v_col), i32(v_width), (v_flags & u32(16i))));
          var v_iy: u32 = u32(f_texture_coord((v_y0 + v_row), i32(v_height), (v_flags & u32(16i))));
          var cw_tmp_404: f32;
          if ((v_col == 0i)) {
            cw_tmp_404 = (1.0f - v_fx);
          } else {
            cw_tmp_404 = v_fx;
          }
          var cw_tmp_405: f32;
          if ((v_row == 0i)) {
            cw_tmp_405 = (1.0f - v_fy);
          } else {
            cw_tmp_405 = v_fy;
          }
          var v_weight: f32 = (cw_tmp_404 * cw_tmp_405);
          v_result = (v_result + precise_divide((v_weight * f32(((b_texels[(cw_buffer_offset_0 + i32(((v_base + (v_iy * v_width)) + v_ix)))] >> (v_channel * u32(8i))) & u32(255i)))), 255.0f));
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
fn sample_texture_lod(cw_buffer_arg_0: i32, cw_arg_base: u32, cw_arg_width: u32, cw_arg_height: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_lod: f32, cw_arg_sampler: u32, cw_arg_channel: u32) -> f32 {
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
      var cw_tmp_406: f32;
      if ((v_selected == 5u)) {
        cw_tmp_406 = 1.0f;
      } else {
        cw_tmp_406 = 0.0f;
      }
      return cw_tmp_406;
    }
    v_channel = v_selected;
  }
  if (((v_sampler & 536870912u) != 0u)) {
    let cw_argument_index_407 = (cw_buffer_offset_0 + i32((v_base + 6u)));
    var v_minimum: f32 = bitcast<f32>(b_texels[cw_argument_index_407]);
    let cw_argument_index_408 = (cw_buffer_offset_0 + i32((v_base + 7u)));
    var v_maximum: f32 = bitcast<f32>(b_texels[cw_argument_index_408]);
    let cw_argument_index_409 = (cw_buffer_offset_0 + i32((v_base + 8u)));
    var v_bias: f32 = min(16.0f, max((-16.0f), bitcast<f32>(b_texels[cw_argument_index_409])));
    v_lod = min(v_maximum, max(v_minimum, (v_lod + v_bias)));
  }
  var v_filter: u32 = ((v_sampler >> u32(5i)) & u32(7i));
  var v_last: u32 = (v_sampler & u32(31i));
  var v_magnification: u32 = ((v_sampler >> u32(8i)) & u32(1i));
  var cw_tmp_410: f32;
  if (((v_magnification != 0u) && ((v_filter == 2u) || (v_filter == 4u)))) {
    cw_tmp_410 = 0.5f;
  } else {
    cw_tmp_410 = 0.0f;
  }
  var v_crossover: f32 = cw_tmp_410;
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
        var cw_tmp_411: u32;
        if ((v_low < v_last)) {
          cw_tmp_411 = (v_low + 1u);
        } else {
          cw_tmp_411 = v_low;
        }
        v_high = cw_tmp_411;
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
      var cw_tmp_412: u32;
      if ((v_sample == 0u)) {
        cw_tmp_412 = v_low;
      } else {
        cw_tmp_412 = v_high;
      }
      var v_value: f32 = sample_mip((cw_buffer_offset_0 + 0i), v_base, v_width, v_height, v_u, v_v, v_sampler, v_channel, cw_tmp_412, v_linear);
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
fn sample_texture_environment(cw_buffer_arg_0: i32, cw_buffer_arg_1: i32, cw_arg_descriptor: u32, cw_arg_va: u32, cw_arg_vb: u32, cw_arg_vc: u32, cw_arg_a: f32, cw_arg_b: f32, cw_arg_c: f32, cw_arg_dax: f32, cw_arg_dbx: f32, cw_arg_dcx: f32, cw_arg_day: f32, cw_arg_dby: f32, cw_arg_dcy: f32, cw_arg_inv: f32, cw_arg_channel: u32, cw_arg_spriteMask: u32, cw_arg_spriteU: f32, cw_arg_spriteV: f32, cw_arg_spriteDx: f32, cw_arg_spriteDy: f32) -> f32 {
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
  var cw_tmp_413: u32;
  if ((v_unit == 0u)) {
    cw_tmp_413 = 16u;
  } else {
    cw_tmp_413 = (10u + ((v_unit - 1u) * 2u));
  }
  var v_coord: u32 = cw_tmp_413;
  if (((v_spriteMask & (1u << v_unit)) != 0u)) {
    let cw_argument_index_414 = (cw_buffer_offset_0 + i32(v_descriptor));
    let cw_argument_index_415 = (cw_buffer_offset_0 + i32((v_descriptor + 24u)));
    let cw_argument_index_416 = (cw_buffer_offset_0 + i32((v_descriptor + 25u)));
    let cw_argument_index_417 = (cw_buffer_offset_0 + i32((v_descriptor + 26u)));
    return sample_atlas((cw_buffer_offset_0 + 0i), b_texels[cw_argument_index_414], b_texels[cw_argument_index_415], b_texels[cw_argument_index_416], v_spriteU, v_spriteV, (v_spriteDx * f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 24u)))])), 0.0f, 0.0f, (v_spriteDy * f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 25u)))])), b_texels[cw_argument_index_417], v_channel);
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
      let cw_argument_index_418 = (cw_buffer_offset_0 + i32((v_descriptor + 28u)));
      let cw_argument_index_419 = (cw_buffer_offset_0 + i32((v_descriptor + 32u)));
      let cw_argument_index_420 = (cw_buffer_offset_0 + i32((v_descriptor + 36u)));
      let cw_argument_index_421 = (cw_buffer_offset_0 + i32((v_descriptor + 40u)));
      v_ss[v_corner] = ((((bitcast<f32>(b_texels[cw_argument_index_418]) * v_u) + (bitcast<f32>(b_texels[cw_argument_index_419]) * v_v)) + (bitcast<f32>(b_texels[cw_argument_index_420]) * v_r)) + (bitcast<f32>(b_texels[cw_argument_index_421]) * v_q));
      let cw_argument_index_422 = (cw_buffer_offset_0 + i32((v_descriptor + 29u)));
      let cw_argument_index_423 = (cw_buffer_offset_0 + i32((v_descriptor + 33u)));
      let cw_argument_index_424 = (cw_buffer_offset_0 + i32((v_descriptor + 37u)));
      let cw_argument_index_425 = (cw_buffer_offset_0 + i32((v_descriptor + 41u)));
      v_ts[v_corner] = ((((bitcast<f32>(b_texels[cw_argument_index_422]) * v_u) + (bitcast<f32>(b_texels[cw_argument_index_423]) * v_v)) + (bitcast<f32>(b_texels[cw_argument_index_424]) * v_r)) + (bitcast<f32>(b_texels[cw_argument_index_425]) * v_q));
      let cw_argument_index_426 = (cw_buffer_offset_0 + i32((v_descriptor + 31u)));
      let cw_argument_index_427 = (cw_buffer_offset_0 + i32((v_descriptor + 35u)));
      let cw_argument_index_428 = (cw_buffer_offset_0 + i32((v_descriptor + 39u)));
      let cw_argument_index_429 = (cw_buffer_offset_0 + i32((v_descriptor + 43u)));
      v_qs[v_corner] = ((((bitcast<f32>(b_texels[cw_argument_index_426]) * v_u) + (bitcast<f32>(b_texels[cw_argument_index_427]) * v_v)) + (bitcast<f32>(b_texels[cw_argument_index_428]) * v_r)) + (bitcast<f32>(b_texels[cw_argument_index_429]) * v_q));
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
  var v_u: f32 = precise_divide(v_ns, v_q);
  var v_v: f32 = precise_divide(v_nt, v_q);
  var v_qx: f32 = precise_divide((((v_dax * (v_qs[0i] - v_q)) + (v_dbx * (v_qs[1i] - v_q))) + (v_dcx * (v_qs[2i] - v_q))), v_inv);
  var v_qy: f32 = precise_divide((((v_day * (v_qs[0i] - v_q)) + (v_dby * (v_qs[1i] - v_q))) + (v_dcy * (v_qs[2i] - v_q))), v_inv);
  var v_sx: f32 = precise_divide((((v_dax * (v_ss[0i] - v_ns)) + (v_dbx * (v_ss[1i] - v_ns))) + (v_dcx * (v_ss[2i] - v_ns))), v_inv);
  var v_sy: f32 = precise_divide((((v_day * (v_ss[0i] - v_ns)) + (v_dby * (v_ss[1i] - v_ns))) + (v_dcy * (v_ss[2i] - v_ns))), v_inv);
  var v_tx: f32 = precise_divide((((v_dax * (v_ts[0i] - v_nt)) + (v_dbx * (v_ts[1i] - v_nt))) + (v_dcx * (v_ts[2i] - v_nt))), v_inv);
  var v_ty: f32 = precise_divide((((v_day * (v_ts[0i] - v_nt)) + (v_dby * (v_ts[1i] - v_nt))) + (v_dcy * (v_ts[2i] - v_nt))), v_inv);
  var v_width: f32 = f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 24u)))]);
  var v_height: f32 = f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 25u)))]);
  var v_ux: f32 = (precise_divide((v_sx - (v_u * v_qx)), v_q) * v_width);
  var v_uy: f32 = (precise_divide((v_sy - (v_u * v_qy)), v_q) * v_width);
  var v_vx: f32 = (precise_divide((v_tx - (v_v * v_qx)), v_q) * v_height);
  var v_vy: f32 = (precise_divide((v_ty - (v_v * v_qy)), v_q) * v_height);
  var v_lod: f32 = (0.5f * log2(max(1e-8f, max(((v_ux * v_ux) + (v_vx * v_vx)), ((v_uy * v_uy) + (v_vy * v_vy))))));
  let cw_argument_index_430 = (cw_buffer_offset_0 + i32(v_descriptor));
  let cw_argument_index_431 = (cw_buffer_offset_0 + i32((v_descriptor + 24u)));
  let cw_argument_index_432 = (cw_buffer_offset_0 + i32((v_descriptor + 25u)));
  let cw_argument_index_433 = (cw_buffer_offset_0 + i32((v_descriptor + 26u)));
  return sample_atlas((cw_buffer_offset_0 + 0i), b_texels[cw_argument_index_430], b_texels[cw_argument_index_431], b_texels[cw_argument_index_432], v_u, v_v, v_ux, v_vx, v_uy, v_vy, b_texels[cw_argument_index_433], v_channel);
}
fn material_parallax(cw_buffer_arg_0: i32, cw_buffer_arg_1: i32, cw_arg_descriptor: u32, cw_arg_va: u32, cw_arg_vb: u32, cw_arg_vc: u32, cw_arg_a: f32, cw_arg_b: f32, cw_arg_c: f32, cw_arg_dax: f32, cw_arg_dbx: f32, cw_arg_dcx: f32, cw_arg_day: f32, cw_arg_dby: f32, cw_arg_dcy: f32, cw_arg_inv: f32, cw_arg_axis: u32) -> f32 {
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
  var cw_tmp_434: i32;
  if ((v_axis == u32(0i))) {
    cw_tmp_434 = 6i;
  } else {
    cw_tmp_434 = 18i;
  }
  var v_column: u32 = u32(cw_tmp_434);
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_projection = (v_projection - (precise_divide(v_position[v_k], v_length) * (((v_a * b_attributes[(cw_buffer_offset_1 + i32((((v_va * u32(34i)) + v_column) + v_k)))]) + (v_b * b_attributes[(cw_buffer_offset_1 + i32((((v_vb * u32(34i)) + v_column) + v_k)))])) + (v_c * b_attributes[(cw_buffer_offset_1 + i32((((v_vc * u32(34i)) + v_column) + v_k)))]))));
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_height: f32 = sample_layer((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_descriptor, v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i));
  return (v_projection * ((v_height * 0.04f) - 0.02f));
}
fn sample_material_layer(cw_buffer_arg_0: i32, cw_buffer_arg_1: i32, cw_arg_descriptor: u32, cw_arg_va: u32, cw_arg_vb: u32, cw_arg_vc: u32, cw_arg_a: f32, cw_arg_b: f32, cw_arg_c: f32, cw_arg_dax: f32, cw_arg_dbx: f32, cw_arg_dcx: f32, cw_arg_day: f32, cw_arg_dby: f32, cw_arg_dcy: f32, cw_arg_inv: f32, cw_arg_channel: u32, cw_arg_offsetU: f32, cw_arg_offsetV: f32, cw_arg_offsetUx: f32, cw_arg_offsetVx: f32, cw_arg_offsetUy: f32, cw_arg_offsetVy: f32) -> f32 {
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
  var cw_tmp_435: u32;
  if ((v_unit == u32(0i))) {
    cw_tmp_435 = u32(16i);
  } else {
    cw_tmp_435 = (u32(10i) + ((v_unit - u32(1i)) * u32(2i)));
  }
  var v_coord: u32 = cw_tmp_435;
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
      let cw_argument_index_436 = (cw_buffer_offset_0 + i32((v_descriptor + u32(8i))));
      let cw_argument_index_437 = (cw_buffer_offset_0 + i32((v_descriptor + u32(12i))));
      let cw_argument_index_438 = (cw_buffer_offset_0 + i32((v_descriptor + u32(20i))));
      v_us[v_corner] = (((bitcast<f32>(b_texels[cw_argument_index_436]) * v_u) + (bitcast<f32>(b_texels[cw_argument_index_437]) * v_v)) + bitcast<f32>(b_texels[cw_argument_index_438]));
      let cw_argument_index_439 = (cw_buffer_offset_0 + i32((v_descriptor + u32(9i))));
      let cw_argument_index_440 = (cw_buffer_offset_0 + i32((v_descriptor + u32(13i))));
      let cw_argument_index_441 = (cw_buffer_offset_0 + i32((v_descriptor + u32(21i))));
      v_vs[v_corner] = (((bitcast<f32>(b_texels[cw_argument_index_439]) * v_u) + (bitcast<f32>(b_texels[cw_argument_index_440]) * v_v)) + bitcast<f32>(b_texels[cw_argument_index_441]));
      continuing {
        v_corner += u32(1);
      }
    }
  }
  var v_u: f32 = (((v_a * v_us[0i]) + (v_b * v_us[1i])) + (v_c * v_us[2i]));
  var v_v: f32 = (((v_a * v_vs[0i]) + (v_b * v_vs[1i])) + (v_c * v_vs[2i]));
  var cw_tmp_442: f32;
  if ((v_channel == u32(4i))) {
    cw_tmp_442 = 256.0f;
  } else {
    cw_tmp_442 = f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(1i))))]);
  }
  var v_w: f32 = cw_tmp_442;
  var cw_tmp_443: f32;
  if ((v_channel == u32(4i))) {
    cw_tmp_443 = 256.0f;
  } else {
    cw_tmp_443 = f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(2i))))]);
  }
  var v_h: f32 = cw_tmp_443;
  var v_ux: f32 = (precise_divide((((v_dax * (v_us[0i] - v_u)) + (v_dbx * (v_us[1i] - v_u))) + (v_dcx * (v_us[2i] - v_u))), v_inv) * v_w);
  var v_vx: f32 = (precise_divide((((v_dax * (v_vs[0i] - v_v)) + (v_dbx * (v_vs[1i] - v_v))) + (v_dcx * (v_vs[2i] - v_v))), v_inv) * v_h);
  var v_uy: f32 = (precise_divide((((v_day * (v_us[0i] - v_u)) + (v_dby * (v_us[1i] - v_u))) + (v_dcy * (v_us[2i] - v_u))), v_inv) * v_w);
  var v_vy: f32 = (precise_divide((((v_day * (v_vs[0i] - v_v)) + (v_dby * (v_vs[1i] - v_v))) + (v_dcy * (v_vs[2i] - v_v))), v_inv) * v_h);
  v_ux = (v_ux + (v_offsetUx * v_w));
  v_vx = (v_vx + (v_offsetVx * v_h));
  v_uy = (v_uy + (v_offsetUy * v_w));
  v_vy = (v_vy + (v_offsetVy * v_h));
  var v_lod: f32 = (0.5f * log2(max(1e-8f, max(((v_ux * v_ux) + (v_vx * v_vx)), ((v_uy * v_uy) + (v_vy * v_vy))))));
  if ((v_channel >= u32(4i))) {
    return max(v_lod, 0.0f);
  }
  let cw_argument_index_444 = (cw_buffer_offset_0 + i32(v_descriptor));
  let cw_argument_index_445 = (cw_buffer_offset_0 + i32((v_descriptor + u32(1i))));
  let cw_argument_index_446 = (cw_buffer_offset_0 + i32((v_descriptor + u32(2i))));
  let cw_argument_index_447 = (cw_buffer_offset_0 + i32((v_descriptor + u32(3i))));
  return sample_atlas((cw_buffer_offset_0 + 0i), b_texels[cw_argument_index_444], b_texels[cw_argument_index_445], b_texels[cw_argument_index_446], (v_u + v_offsetU), (v_v + v_offsetV), v_ux, v_vx, v_uy, v_vy, b_texels[cw_argument_index_447], v_channel);
}
fn sample_shadow_compare(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_reference: f32, cw_arg_ux: f32, cw_arg_vx: f32, cw_arg_uy: f32, cw_arg_vy: f32) -> f32 {
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
    let cw_argument_index_448 = (cw_buffer_offset_0 + i32((v_base + 9u)));
    v_maximum = min(16.0f, bitcast<f32>(b_texels[cw_argument_index_448]));
  }
  if ((v_maximum <= 1.0f)) {
    return shadow_mipped((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, v_isotropic);
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
    return shadow_mipped((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, v_isotropic);
  }
  var v_ratio: f32 = min(v_maximum, precise_divide(v_major, max(1.0f, v_minor)));
  var v_taps: u32 = u32(ceil(max(1.0f, v_ratio)));
  if ((v_taps <= 1u)) {
    return shadow_mipped((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, v_isotropic);
  }
  var cw_tmp_449: f32;
  if ((v_xx >= v_yy)) {
    cw_tmp_449 = 1.0f;
  } else {
    cw_tmp_449 = 0.0f;
  }
  var v_axisU: f32 = cw_tmp_449;
  var cw_tmp_450: f32;
  if ((v_xx >= v_yy)) {
    cw_tmp_450 = 0.0f;
  } else {
    cw_tmp_450 = 1.0f;
  }
  var v_axisV: f32 = cw_tmp_450;
  if ((abs(v_xy) > 1e-8f)) {
    var cw_tmp_451: f32;
    if ((v_xx >= v_yy)) {
      cw_tmp_451 = (v_majorSquared - v_yy);
    } else {
      cw_tmp_451 = v_xy;
    }
    v_axisU = cw_tmp_451;
    var cw_tmp_452: f32;
    if ((v_xx >= v_yy)) {
      cw_tmp_452 = v_xy;
    } else {
      cw_tmp_452 = (v_majorSquared - v_xx);
    }
    v_axisV = cw_tmp_452;
    var v_length: f32 = sqrt(max(1e-12f, ((v_axisU * v_axisU) + (v_axisV * v_axisV))));
    v_axisU = precise_divide(v_axisU, v_length);
    v_axisV = precise_divide(v_axisV, v_length);
  }
  var v_lod: f32 = log2(max(v_minor, precise_divide(v_major, v_maximum)));
  var v_result: f32 = 0.0f;
  {
    var v_tap: u32 = u32(0i);
    loop {
      if (!(v_tap < v_taps)) { break; }
      var v_offset: f32 = (precise_divide((f32(v_tap) + 0.5f), f32(v_taps)) - 0.5f);
      v_result = (v_result + shadow_mipped((cw_buffer_offset_0 + 0i), v_descriptor, (v_u + precise_divide(((v_axisU * v_major) * v_offset), f32(v_width))), (v_v + precise_divide(((v_axisV * v_major) * v_offset), f32(v_height))), v_reference, v_lod));
      continuing {
        v_tap += u32(1);
      }
    }
  }
  return precise_divide(v_result, f32(v_taps));
}
fn sample_layer(cw_buffer_arg_0: i32, cw_buffer_arg_1: i32, cw_arg_descriptor: u32, cw_arg_va: u32, cw_arg_vb: u32, cw_arg_vc: u32, cw_arg_a: f32, cw_arg_b: f32, cw_arg_c: f32, cw_arg_dax: f32, cw_arg_dbx: f32, cw_arg_dcx: f32, cw_arg_day: f32, cw_arg_dby: f32, cw_arg_dcy: f32, cw_arg_inv: f32, cw_arg_channel: u32) -> f32 {
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
  return sample_material_layer((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_descriptor, v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_channel, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f);
}
fn cluster_cell(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_screen_x: f32, cw_arg_screen_y: f32, cw_arg_view_z: f32) -> u32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_screen_x: f32 = cw_arg_screen_x;
  var v_screen_y: f32 = cw_arg_screen_y;
  var v_view_z: f32 = cw_arg_view_z;
  if ((v_descriptor == u32(0i))) {
    return 4294967295u;
  }
  let cw_argument_index_453 = (cw_buffer_offset_0 + i32((v_descriptor + u32(3i))));
  var v_near: f32 = bitcast<f32>(b_texels[cw_argument_index_453]);
  let cw_argument_index_454 = (cw_buffer_offset_0 + i32((v_descriptor + u32(4i))));
  var v_far: f32 = bitcast<f32>(b_texels[cw_argument_index_454]);
  var v_z: f32 = max(abs(v_view_z), 1e-12f);
  let cw_argument_index_455 = (cw_buffer_offset_0 + i32((v_descriptor + u32(5i))));
  var v_tx: f32 = (precise_divide(v_screen_x, bitcast<f32>(b_texels[cw_argument_index_455])) * f32(b_texels[(cw_buffer_offset_0 + i32(v_descriptor))]));
  let cw_argument_index_456 = (cw_buffer_offset_0 + i32((v_descriptor + u32(6i))));
  var v_ty: f32 = (precise_divide(v_screen_y, bitcast<f32>(b_texels[cw_argument_index_456])) * f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(1i))))]));
  var v_tz: f32 = (precise_divide(log2(precise_divide(v_z, v_near)), log2(precise_divide(v_far, v_near))) * f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(2i))))]));
  if (((((((v_tx < 0.0f) || (v_ty < 0.0f)) || (v_tz < 0.0f)) || (v_tx >= f32(b_texels[(cw_buffer_offset_0 + i32(v_descriptor))]))) || (v_ty >= f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(1i))))]))) || (v_tz >= f32(b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(2i))))])))) {
    return 4294967295u;
  }
  return ((u32(v_tx) + (u32(v_ty) * b_texels[(cw_buffer_offset_0 + i32(v_descriptor))])) + ((u32(v_tz) * b_texels[(cw_buffer_offset_0 + i32(v_descriptor))]) * b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(1i))))]));
}
fn cluster_count(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_cell: u32) -> u32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_cell: u32 = cw_arg_cell;
  var cw_tmp_457: u32;
  if ((v_cell == 4294967295u)) {
    cw_tmp_457 = 0u;
  } else {
    cw_tmp_457 = b_texels[(cw_buffer_offset_0 + i32(((b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(8i))))] + (v_cell * u32(2i))) + u32(1i))))];
  }
  return cw_tmp_457;
}
fn cluster_light(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_cell: u32, cw_arg_ordinal: u32) -> u32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_cell: u32 = cw_arg_cell;
  var v_ordinal: u32 = cw_arg_ordinal;
  var v_first: u32 = b_texels[(cw_buffer_offset_0 + i32((b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(8i))))] + (v_cell * u32(2i)))))];
  var v_index: u32 = b_texels[(cw_buffer_offset_0 + i32(((b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(9i))))] + v_first) + v_ordinal)))];
  return (b_texels[(cw_buffer_offset_0 + i32((v_descriptor + u32(10i))))] + (v_index * u32(16i)));
}
fn cluster_distance_fade(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_view_z: f32, cw_arg_radius: f32) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_view_z: f32 = cw_arg_view_z;
  var v_radius: f32 = cw_arg_radius;
  let cw_argument_index_458 = (cw_buffer_offset_0 + i32((v_descriptor + u32(4i))));
  var v_far: f32 = bitcast<f32>(b_texels[cw_argument_index_458]);
  var v_t: f32 = min(1.0f, max(0.0f, precise_divide(((-v_view_z) - (v_far - v_radius)), max(v_radius, 1e-12f))));
  var v_fade: f32 = (1.0f - (v_t * v_t));
  return (v_fade * v_fade);
}
fn environment_coordinate(cw_buffer_arg_0: i32, cw_buffer_arg_1: i32, cw_arg_data: u32, cw_arg_va: u32, cw_arg_vb: u32, cw_arg_vc: u32, cw_arg_a: f32, cw_arg_b: f32, cw_arg_c: f32, cw_arg_dax: f32, cw_arg_dbx: f32, cw_arg_dcx: f32, cw_arg_day: f32, cw_arg_dby: f32, cw_arg_dcy: f32, cw_arg_inv: f32, cw_arg_axis: u32) -> f32 {
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
  var v_layers: u32 = MATERIAL_LAYERS;
  var v_features: u32 = MATERIAL_FEATURES;
  var v_mapped: u32 = select(u32(0), u32(1), ((v_layers & u32(16i)) != u32(0i)));
  var cw_tmp_459: f32;
  if ((v_mapped != u32(0i))) {
    cw_tmp_459 = 0.0f;
  } else {
    cw_tmp_459 = (((v_a * b_attributes[(cw_buffer_offset_1 + i32((((v_va * u32(34i)) + u32(21i)) + v_axis)))]) + (v_b * b_attributes[(cw_buffer_offset_1 + i32((((v_vb * u32(34i)) + u32(21i)) + v_axis)))])) + (v_c * b_attributes[(cw_buffer_offset_1 + i32((((v_vc * u32(34i)) + u32(21i)) + v_axis)))]));
  }
  var v_result: f32 = cw_tmp_459;
  {
    var v_corner: u32 = u32(0i);
    loop {
      var cw_tmp_460: i32;
      if ((v_mapped != u32(0i))) {
        cw_tmp_460 = 1i;
      } else {
        cw_tmp_460 = 0i;
      }
      if (!(v_corner < u32(cw_tmp_460))) { break; }
      var cw_tmp_462: f32;
      if ((v_mapped != u32(0i))) {
        cw_tmp_462 = v_a;
      } else {
        var cw_tmp_461: f32;
        if ((v_corner == u32(0i))) {
          cw_tmp_461 = 1.0f;
        } else {
          cw_tmp_461 = 0.0f;
        }
        cw_tmp_462 = cw_tmp_461;
      }
      var v_aa: f32 = cw_tmp_462;
      var cw_tmp_464: f32;
      if ((v_mapped != u32(0i))) {
        cw_tmp_464 = v_b;
      } else {
        var cw_tmp_463: f32;
        if ((v_corner == u32(1i))) {
          cw_tmp_463 = 1.0f;
        } else {
          cw_tmp_463 = 0.0f;
        }
        cw_tmp_464 = cw_tmp_463;
      }
      var v_bb: f32 = cw_tmp_464;
      var cw_tmp_466: f32;
      if ((v_mapped != u32(0i))) {
        cw_tmp_466 = v_c;
      } else {
        var cw_tmp_465: f32;
        if ((v_corner == u32(2i))) {
          cw_tmp_465 = 1.0f;
        } else {
          cw_tmp_465 = 0.0f;
        }
        cw_tmp_466 = cw_tmp_465;
      }
      var v_cc: f32 = cw_tmp_466;
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
          var cw_tmp_467: i32;
          if (((v_features & u32(512i)) != u32(0i))) {
            cw_tmp_467 = 176i;
          } else {
            cw_tmp_467 = 224i;
          }
          var v_heightMap: u32 = (v_data + u32(cw_tmp_467));
          var v_ix: f32 = max(1e-12f, (((v_inv + v_dax) + v_dbx) + v_dcx));
          var v_iy: f32 = max(1e-12f, (((v_inv + v_day) + v_dby) + v_dcy));
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(2i))) { break; }
              v_offsets[v_k] = material_parallax((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_heightMap, v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k);
              v_offsets[(v_k + u32(2i))] = (material_parallax((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_heightMap, v_va, v_vb, v_vc, precise_divide(((v_a * v_inv) + v_dax), v_ix), precise_divide(((v_b * v_inv) + v_dbx), v_ix), precise_divide(((v_c * v_inv) + v_dcx), v_ix), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_ix, v_k) - v_offsets[v_k]);
              v_offsets[(v_k + u32(4i))] = (material_parallax((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_heightMap, v_va, v_vb, v_vc, precise_divide(((v_a * v_inv) + v_day), v_iy), precise_divide(((v_b * v_inv) + v_dby), v_iy), precise_divide(((v_c * v_inv) + v_dcy), v_iy), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_iy, v_k) - v_offsets[v_k]);
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
            let cw_argument_index_468 = 0i;
            let cw_argument_index_469 = 1i;
            let cw_argument_index_470 = 2i;
            let cw_argument_index_471 = 3i;
            let cw_argument_index_472 = 4i;
            let cw_argument_index_473 = 5i;
            v_sample[v_k] = ((sample_material_layer((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(176i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, v_offsets[cw_argument_index_468], v_offsets[cw_argument_index_469], v_offsets[cw_argument_index_470], v_offsets[cw_argument_index_471], v_offsets[cw_argument_index_472], v_offsets[cw_argument_index_473]) * 2.0f) - 1.0f);
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
          v_p[v_k] = precise_divide(v_p[v_k], v_pl);
          v_n[v_k] = precise_divide(v_n[v_k], v_nl);
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
      var cw_tmp_476: f32;
      if ((v_mapped != u32(0i))) {
        cw_tmp_476 = 1.0f;
      } else {
        var cw_tmp_475: f32;
        if ((v_corner == u32(0i))) {
          cw_tmp_475 = v_a;
        } else {
          var cw_tmp_474: f32;
          if ((v_corner == u32(1i))) {
            cw_tmp_474 = v_b;
          } else {
            cw_tmp_474 = v_c;
          }
          cw_tmp_475 = cw_tmp_474;
        }
        cw_tmp_476 = cw_tmp_475;
      }
      v_result = (v_result + ((precise_divide(v_reflected[v_axis], v_denominator) + 0.5f) * cw_tmp_476));
      continuing {
        v_corner += u32(1);
      }
    }
  }
  if (((v_layers & u32(256i)) != u32(0i))) {
    var v_bx: f32 = sample_layer((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(272i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(0i));
    var v_by: f32 = sample_layer((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(272i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(1i));
    let cw_argument_index_477 = (cw_buffer_offset_0 + i32(((v_data + u32(320i)) + (v_axis * u32(2i)))));
    let cw_argument_index_478 = (cw_buffer_offset_0 + i32(((v_data + u32(321i)) + (v_axis * u32(2i)))));
    v_result = (v_result + ((v_bx * bitcast<f32>(b_texels[cw_argument_index_477])) + (v_by * bitcast<f32>(b_texels[cw_argument_index_478]))));
  }
  return v_result;
}
fn material_alpha(cw_buffer_arg_0: i32, cw_buffer_arg_1: i32, cw_buffer_arg_2: i32, cw_arg_data: u32, cw_arg_flags: u32, cw_arg_falloff_offset: u32, cw_arg_va: u32, cw_arg_vb: u32, cw_arg_vc: u32, cw_arg_a: f32, cw_arg_b: f32, cw_arg_c: f32, cw_arg_dax: f32, cw_arg_dbx: f32, cw_arg_dcx: f32, cw_arg_day: f32, cw_arg_dby: f32, cw_arg_dcy: f32, cw_arg_inv: f32) -> f32 {
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
  var v_features: u32 = MATERIAL_FEATURES;
  var v_layers: u32 = MATERIAL_LAYERS;
  var v_mode: u32 = MATERIAL_MODE;
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
    var cw_tmp_479: i32;
    if (((v_features & u32(512i)) != u32(0i))) {
      cw_tmp_479 = 176i;
    } else {
      cw_tmp_479 = 224i;
    }
    var v_heightMap: u32 = (v_data + u32(cw_tmp_479));
    var v_ix: f32 = max(1e-12f, (((v_inv + v_dax) + v_dbx) + v_dcx));
    var v_iy: f32 = max(1e-12f, (((v_inv + v_day) + v_dby) + v_dcy));
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(2i))) { break; }
        v_offsets[v_k] = material_parallax((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_heightMap, v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k);
        v_offsets[(v_k + u32(2i))] = (material_parallax((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_heightMap, v_va, v_vb, v_vc, precise_divide(((v_a * v_inv) + v_dax), v_ix), precise_divide(((v_b * v_inv) + v_dbx), v_ix), precise_divide(((v_c * v_inv) + v_dcx), v_ix), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_ix, v_k) - v_offsets[v_k]);
        v_offsets[(v_k + u32(4i))] = (material_parallax((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), v_heightMap, v_va, v_vb, v_vc, precise_divide(((v_a * v_inv) + v_day), v_iy), precise_divide(((v_b * v_inv) + v_dby), v_iy), precise_divide(((v_c * v_inv) + v_dcy), v_iy), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_iy, v_k) - v_offsets[v_k]);
        continuing {
          v_k += u32(1);
        }
      }
    }
  }
  var cw_tmp_481: f32;
  if (((v_mode == u32(2i)) || (v_mode == u32(4i)))) {
    cw_tmp_481 = (((v_a * b_vertices[(cw_buffer_offset_2 + i32(((v_va * u32(10i)) + u32(7i))))]) + (v_b * b_vertices[(cw_buffer_offset_2 + i32(((v_vb * u32(10i)) + u32(7i))))])) + (v_c * b_vertices[(cw_buffer_offset_2 + i32(((v_vc * u32(10i)) + u32(7i))))]));
  } else {
    let cw_argument_index_480 = (cw_buffer_offset_0 + i32((v_data + u32(15i))));
    cw_tmp_481 = bitcast<f32>(b_texels[cw_argument_index_480]);
  }
  var v_alpha: f32 = cw_tmp_481;
  if (((v_features & (16384u | 1073741824u)) != 0u)) {
    v_alpha = 1.0f;
  }
  if ((((v_flags & u32(1i)) != u32(0i)) && ((v_features & u32(5120i)) == u32(0i)))) {
    let cw_argument_index_482 = 0i;
    let cw_argument_index_483 = 1i;
    let cw_argument_index_484 = 2i;
    let cw_argument_index_485 = 3i;
    let cw_argument_index_486 = 4i;
    let cw_argument_index_487 = 5i;
    v_alpha = (v_alpha * sample_material_layer((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(224i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i), v_offsets[cw_argument_index_482], v_offsets[cw_argument_index_483], v_offsets[cw_argument_index_484], v_offsets[cw_argument_index_485], v_offsets[cw_argument_index_486], v_offsets[cw_argument_index_487]));
  }
  if (((v_layers & u32(1i)) != u32(0i))) {
    v_alpha = (v_alpha * sample_layer((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(80i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i)));
  }
  if (((v_layers & u32(1024i)) != u32(0i))) {
    v_alpha = (v_alpha * sample_layer((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(328i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i)));
  }
  if (((v_features & u32(67108864i)) != u32(0i))) {
    var v_depth: f32 = (((v_a * b_attributes[(cw_buffer_offset_1 + i32(((v_va * u32(34i)) + u32(9i))))]) + (v_b * b_attributes[(cw_buffer_offset_1 + i32(((v_vb * u32(34i)) + u32(9i))))])) + (v_c * b_attributes[(cw_buffer_offset_1 + i32(((v_vc * u32(34i)) + u32(9i))))]));
    let cw_argument_index_488 = (cw_buffer_offset_0 + i32((v_data + u32(320i))));
    var v_start: f32 = bitcast<f32>(b_texels[cw_argument_index_488]);
    let cw_argument_index_489 = (cw_buffer_offset_0 + i32((v_data + u32(321i))));
    var v_end: f32 = bitcast<f32>(b_texels[cw_argument_index_489]);
    var v_fade: f32 = min(1.0f, max(0.0f, precise_divide((v_depth - v_start), max(0.000001f, (v_end - v_start)))));
    v_alpha = (v_alpha * (1.0f - ((v_fade * v_fade) * (3.0f - (2.0f * v_fade)))));
  }
  if ((((v_features & u32(64i)) != u32(0i)) && ((v_layers & u32(1i)) != u32(0i)))) {
    var cw_tmp_490: i32;
    if (((v_features & u32(128i)) != u32(0i))) {
      cw_tmp_490 = 5i;
    } else {
      cw_tmp_490 = 4i;
    }
    v_alpha = (v_alpha * (1.0f + (0.25f * sample_layer((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(80i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(cw_tmp_490)))));
  }
  if (((((v_features & u32(64i)) != u32(0i)) && ((v_flags & u32(1i)) != u32(0i))) && ((v_features & u32(5120i)) == u32(0i)))) {
    var cw_tmp_491: i32;
    if (((v_features & u32(128i)) != u32(0i))) {
      cw_tmp_491 = 5i;
    } else {
      cw_tmp_491 = 4i;
    }
    let cw_argument_index_492 = 0i;
    let cw_argument_index_493 = 1i;
    let cw_argument_index_494 = 2i;
    let cw_argument_index_495 = 3i;
    let cw_argument_index_496 = 4i;
    let cw_argument_index_497 = 5i;
    var v_lod: f32 = sample_material_layer((cw_buffer_offset_0 + 0i), (cw_buffer_offset_1 + 0i), (v_data + u32(224i)), v_va, v_vb, v_vc, v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(cw_tmp_491), v_offsets[cw_argument_index_492], v_offsets[cw_argument_index_493], v_offsets[cw_argument_index_494], v_offsets[cw_argument_index_495], v_offsets[cw_argument_index_496], v_offsets[cw_argument_index_497]);
    v_alpha = (v_alpha * (1.0f + (0.25f * max(0.0f, v_lod))));
  }
  if (((v_features & 268435456u) != 0u)) {
    v_alpha = (v_alpha * (((v_a * b_attributes[(cw_buffer_offset_1 + i32((v_falloff_offset + (v_va * 4u))))]) + (v_b * b_attributes[(cw_buffer_offset_1 + i32((v_falloff_offset + (v_vb * 4u))))])) + (v_c * b_attributes[(cw_buffer_offset_1 + i32((v_falloff_offset + (v_vc * 4u))))])));
  }
  return v_alpha;
}
fn shade_water(cw_buffer_arg_0: i32, cw_arg_object: u32, v_viewPosition: ptr<function, array<f32, 3>>, v_viewFootprint: ptr<function, array<f32, 6>>, cw_arg_shadow: f32, cw_arg_sx: f32, cw_arg_sy: f32, cw_arg_depth: f32, cw_arg_linearDepth: f32, v_color: ptr<function, array<f32, 4>>, v_viewNormal: ptr<function, array<f32, 3>>, cw_arg_cluster: u32, cw_arg_clusterScreenX: f32, cw_arg_clusterScreenY: f32) {
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
      let cw_argument_index_498 = (cw_buffer_offset_0 + i32(((v_p + u32(52i)) + v_row)));
      v_camera[v_row] = bitcast<f32>(b_texels[cw_argument_index_498]);
      v_position[v_row] = v_camera[v_row];
      v_sun[v_row] = 0.0f;
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(3i))) { break; }
          let cw_argument_index_499 = (cw_buffer_offset_0 + i32((((v_p + u32(40i)) + (v_col * u32(4i))) + v_row)));
          v_position[v_row] = (v_position[v_row] + (bitcast<f32>(b_texels[cw_argument_index_499]) * (*v_viewPosition)[v_col]));
          let cw_argument_index_500 = (cw_buffer_offset_0 + i32((((v_p + u32(40i)) + (v_col * u32(4i))) + v_row)));
          let cw_argument_index_501 = (cw_buffer_offset_0 + i32(((v_object + u32(24i)) + v_col)));
          v_sun[v_row] = (v_sun[v_row] + (bitcast<f32>(b_texels[cw_argument_index_500]) * bitcast<f32>(b_texels[cw_argument_index_501])));
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
  water_normalize(&v_eye);
  water_normalize(&v_sun);
  let cw_argument_index_502 = (cw_buffer_offset_0 + i32((v_p + u32(20i))));
  var v_time: f32 = bitcast<f32>(b_texels[cw_argument_index_502]);
  let cw_argument_index_503 = (cw_buffer_offset_0 + i32((v_p + u32(23i))));
  var v_rain: f32 = bitcast<f32>(b_texels[cw_argument_index_503]);
  let cw_argument_index_504 = (cw_buffer_offset_0 + i32((v_p + u32(32i))));
  var v_u: f32 = precise_divide(((v_position[0i] + bitcast<f32>(b_texels[cw_argument_index_504])) * 3.0f), 40960.0f);
  let cw_argument_index_505 = (cw_buffer_offset_0 + i32((v_p + u32(33i))));
  var v_v: f32 = precise_divide(((v_position[1i] + bitcast<f32>(b_texels[cw_argument_index_505])) * 3.0f), 40960.0f);
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
              let cw_argument_index_506 = (cw_buffer_offset_0 + i32((((v_p + u32(40i)) + (v_col * u32(4i))) + v_row)));
              v_footprint[((v_axis * u32(2i)) + v_row)] = (v_footprint[((v_axis * u32(2i)) + v_row)] + precise_divide(((bitcast<f32>(b_texels[cw_argument_index_506]) * (*v_viewFootprint)[((v_axis * u32(3i)) + v_col)]) * 3.0f), 40960.0f));
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
  let cw_argument_index_507 = 0i;
  let cw_argument_index_508 = 1i;
  let cw_argument_index_509 = 2i;
  let cw_argument_index_510 = 3i;
  water_wave_chain((cw_buffer_offset_0 + 0i), v_p, v_u, v_v, v_time, v_footprint[cw_argument_index_507], v_footprint[cw_argument_index_508], v_footprint[cw_argument_index_509], v_footprint[cw_argument_index_510], &v_waves);
  let cw_argument_index_511 = (cw_buffer_offset_0 + i32((v_p + u32(26i))));
  let cw_argument_index_512 = (cw_buffer_offset_0 + i32((v_p + u32(27i))));
  var v_extent: f32 = (bitcast<f32>(b_texels[cw_argument_index_511]) * bitcast<f32>(b_texels[cw_argument_index_512]));
  let cw_argument_index_513 = (cw_buffer_offset_0 + i32((v_p + u32(32i))));
  let cw_argument_index_514 = (cw_buffer_offset_0 + i32((v_p + u32(36i))));
  var v_ru: f32 = (precise_divide(((v_position[0i] + bitcast<f32>(b_texels[cw_argument_index_513])) - bitcast<f32>(b_texels[cw_argument_index_514])), v_extent) + 0.5f);
  let cw_argument_index_515 = (cw_buffer_offset_0 + i32((v_p + u32(33i))));
  let cw_argument_index_516 = (cw_buffer_offset_0 + i32((v_p + u32(37i))));
  var v_rv: f32 = (precise_divide(((v_position[1i] + bitcast<f32>(b_texels[cw_argument_index_515])) - bitcast<f32>(b_texels[cw_argument_index_516])), v_extent) + 0.5f);
  var v_distance: f32 = sqrt((((v_ru - 0.5f) * (v_ru - 0.5f)) + ((v_rv - 0.5f) * (v_rv - 0.5f))));
  var v_blend: f32 = (f_water_smooth(0.001f, 0.02f, v_distance) * (1.0f - f_water_smooth(0.3f, 0.4f, v_distance)));
  var v_ripple: array<f32, 3>;
  var v_normal: array<f32, 3>;
  var v_specNormal: array<f32, 3>;
  v_ripple[0i] = ((2.0f * water_sample((cw_buffer_offset_0 + 0i), (v_p + u32(16i)), v_ru, v_rv, u32(2i))) * v_blend);
  v_ripple[1i] = ((2.0f * water_sample((cw_buffer_offset_0 + 0i), (v_p + u32(16i)), v_ru, v_rv, u32(3i))) * v_blend);
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
    let cw_argument_index_517 = (cw_buffer_offset_0 + i32((v_p + u32(28i))));
    water_rain_combined(precise_divide(v_position[0i], 1000.0f), precise_divide(v_position[1i], 1000.0f), v_time, b_texels[cw_argument_index_517], &v_rainRipple);
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      v_rainRipple[v_k] = (v_rainRipple[v_k] * f_water_unit(v_rain));
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
  water_normalize(&v_normal);
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
  var cw_tmp_518: f32;
  if ((v_camera[2i] > 0.0f)) {
    cw_tmp_518 = 1.333f;
  } else {
    cw_tmp_518 = precise_divide(1.0f, 1.333f);
  }
  var v_eta: f32 = cw_tmp_518;
  var v_g: f32 = (((v_eta * v_eta) - 1.0f) + (v_dot * v_dot));
  var v_fresnel: f32 = 1.0f;
  if ((v_g > 0.0f)) {
    v_g = sqrt(v_g);
    var v_a: f32 = precise_divide((v_g - v_dot), (v_g + v_dot));
    var v_b: f32 = precise_divide(((v_dot * (v_g + v_dot)) - 1.0f), ((v_dot * (v_g - v_dot)) + 1.0f));
    v_fresnel = f_water_unit((((0.5f * v_a) * v_a) * (1.0f + (v_b * v_b))));
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      var cw_tmp_519: f32;
      if ((v_k < u32(2i))) {
        cw_tmp_519 = 5.0f;
      } else {
        cw_tmp_519 = 1.0f;
      }
      v_specNormal[v_k] = (v_normal[v_k] * cw_tmp_519);
      continuing {
        v_k += u32(1);
      }
    }
  }
  water_normalize(&v_specNormal);
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
  let cw_argument_index_520 = (cw_buffer_offset_0 + i32((v_object + u32(39i))));
  var v_sunAlpha: f32 = min(1.0f, precise_divide(bitcast<f32>(b_texels[cw_argument_index_520]), 0.15f));
  var v_specular: f32 = ((f_water_unit((f_render_power(atan2((max(v_phong, 0.0f) * 1.55f), 1.0f), 256.0f) * 1.5f)) * v_shadow) * v_sunAlpha);
  var v_sunFade: f32 = 0.0f;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      let cw_argument_index_521 = (cw_buffer_offset_0 + i32(((v_object + u32(28i)) + v_k)));
      var v_a: f32 = bitcast<f32>(b_texels[cw_argument_index_521]);
      v_sunFade = (v_sunFade + (v_a * v_a));
      continuing {
        v_k += u32(1);
      }
    }
  }
  v_sunFade = sqrt(v_sunFade);
  var v_ox: f32 = (v_normal[0i] * 0.1f);
  var v_oy: f32 = (v_normal[1i] * 0.1f);
  let cw_argument_index_522 = (cw_buffer_offset_0 + i32((v_p + u32(21i))));
  var v_near: f32 = bitcast<f32>(b_texels[cw_argument_index_522]);
  let cw_argument_index_523 = (cw_buffer_offset_0 + i32((v_p + u32(22i))));
  var v_far: f32 = bitcast<f32>(b_texels[cw_argument_index_523]);
  var v_surface: f32 = f_water_depth(v_depth, v_near, v_far, v_reverse);
  var v_realDepth: f32 = 0.0f;
  var v_distorted: f32 = 0.0f;
  if (((v_flags & u32(1i)) != u32(0i))) {
    v_realDepth = (f_water_depth(water_sample((cw_buffer_offset_0 + 0i), (v_p + u32(12i)), v_sx, v_sy, u32(0i)), v_near, v_far, v_reverse) - v_surface);
    v_distorted = max(0.0f, (f_water_depth(water_sample((cw_buffer_offset_0 + 0i), (v_p + u32(12i)), (v_sx - v_ox), (v_sy - v_oy), u32(0i)), v_near, v_far, v_reverse) - v_surface));
    var v_fade: f32 = f_water_unit(precise_divide(v_realDepth, 300.0f));
    v_ox = (v_ox * v_fade);
    v_oy = (v_oy * v_fade);
  }
  var v_reflection: array<f32, 3>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_reflection[v_k] = water_sample((cw_buffer_offset_0 + 0i), (v_p + u32(4i)), (v_sx + v_ox), (v_sy + v_oy), v_k);
      if (((v_flags & u32(8i)) != u32(0i))) {
        v_reflection[v_k] = (v_reflection[v_k] * 0.4f);
        let cw_argument_index_524 = (cw_buffer_offset_0 + i32((v_p + u32(25i))));
        var v_radius: f32 = bitcast<f32>(b_texels[cw_argument_index_524]);
        {
          var v_tap: u32 = u32(0i);
          loop {
            if (!(v_tap < u32(4i))) { break; }
            var cw_tmp_525: f32;
            if (((v_tap % u32(2i)) == u32(0i))) {
              cw_tmp_525 = (-v_radius);
            } else {
              cw_tmp_525 = v_radius;
            }
            var cw_tmp_526: f32;
            if ((v_tap < u32(2i))) {
              cw_tmp_526 = (-v_radius);
            } else {
              cw_tmp_526 = v_radius;
            }
            v_reflection[v_k] = (v_reflection[v_k] + (0.15f * water_sample((cw_buffer_offset_0 + 0i), (v_p + u32(4i)), ((v_sx + v_ox) + cw_tmp_525), ((v_sy + v_oy) + cw_tmp_526), v_k)));
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
  var v_transparency: f32 = f_water_unit(((v_fresnel * 6.0f) + v_specular));
  if (((v_flags & u32(1i)) != u32(0i))) {
    v_distorted = max(0.0f, (f_water_depth(water_sample((cw_buffer_offset_0 + 0i), (v_p + u32(12i)), (v_sx - v_ox), (v_sy - v_oy), u32(0i)), v_near, v_far, v_reverse) - v_surface));
    v_distorted = (v_distorted + ((v_realDepth - v_distorted) * min(precise_divide(v_surface, 3000.0f), 1.0f)));
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
  water_normalize(&v_scatterNormal);
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
    water_wave((cw_buffer_offset_0 + 0i), v_p, v_u, v_v, 2.0f, 2.7f, (-v_time), 0.05f, 0.1f, &v_previousA, &v_waveA);
    water_wave((cw_buffer_offset_0 + 0i), v_p, v_u, v_v, 2.0f, 2.7f, v_time, 0.04f, (-0.13f), &v_previousB, &v_waveB);
    let cw_argument_index_527 = 2i;
    var v_viewFactor: f32 = ((abs(v_eye[cw_argument_index_527]) * 0.8f) + 0.2f);
    v_shore = ((((v_realDepth * v_viewFactor) - (((v_waves[6i] + ((v_rain * (v_waveA[0i] + v_waveB[0i])) * 0.5f)) + 0.15f) * 8.0f)) * min(1.0f, precise_divide(1000.0f, max(v_surface, 0.000001f)))) * v_viewFactor);
    v_shore = f_water_unit((v_shore + ((1.0f - v_shore) * f_water_unit(precise_divide(v_linearDepth, 6200.0f)))));
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
            let cw_argument_index_528 = (cw_buffer_offset_0 + i32((((v_p + u32(40i)) + (v_row * u32(4i))) + v_col)));
            v_viewSpecNormal[v_row] = (v_viewSpecNormal[v_row] + (bitcast<f32>(b_texels[cw_argument_index_528]) * v_specNormal[v_col]));
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
    water_normalize(&v_viewSpecNormal);
    water_normalize(&v_viewEye);
    var v_cell: u32 = cluster_cell((cw_buffer_offset_0 + 0i), v_cluster, v_clusterScreenX, v_clusterScreenY, (*v_viewPosition)[2i]);
    var v_count: u32 = cluster_count((cw_buffer_offset_0 + 0i), v_cluster, v_cell);
    {
      var v_light: u32 = u32(0i);
      loop {
        if (!(v_light < v_count)) { break; }
        var v_record: u32 = cluster_light((cw_buffer_offset_0 + 0i), v_cluster, v_cell, v_light);
        var v_direction: array<f32, 3>;
        var v_distance: f32 = 0.0f;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            let cw_argument_index_529 = (cw_buffer_offset_0 + i32((v_record + v_k)));
            v_direction[v_k] = (bitcast<f32>(b_texels[cw_argument_index_529]) - (*v_viewPosition)[v_k]);
            v_distance = (v_distance + (v_direction[v_k] * v_direction[v_k]));
            continuing {
              v_k += u32(1);
            }
          }
        }
        v_distance = sqrt(max(v_distance, 1e-12f));
        let cw_argument_index_530 = (cw_buffer_offset_0 + i32((v_record + u32(15i))));
        var v_radius: f32 = bitcast<f32>(b_texels[cw_argument_index_530]);
        var v_fade: f32 = f_water_unit(precise_divide((precise_divide(v_distance, max(v_radius, 1e-12f)) - 0.75f), 0.25f));
        v_fade = (1.0f - (v_fade * v_fade));
        let cw_argument_index_531 = (cw_buffer_offset_0 + i32((v_record + u32(3i))));
        let cw_argument_index_532 = (cw_buffer_offset_0 + i32((v_record + u32(7i))));
        let cw_argument_index_533 = (cw_buffer_offset_0 + i32((v_record + u32(11i))));
        var v_denominator: f32 = ((bitcast<f32>(b_texels[cw_argument_index_531]) + (bitcast<f32>(b_texels[cw_argument_index_532]) * v_distance)) + ((bitcast<f32>(b_texels[cw_argument_index_533]) * v_distance) * v_distance));
        var v_attenuation: f32 = precise_divide(((v_fade * v_fade) * cluster_distance_fade((cw_buffer_offset_0 + 0i), v_cluster, (*v_viewPosition)[2i], v_radius)), max(v_denominator, 1e-12f));
        var v_lambert: f32 = 0.0f;
        var v_halfVector: array<f32, 3>;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            v_direction[v_k] = precise_divide(v_direction[v_k], v_distance);
            v_lambert = (v_lambert + (v_viewSpecNormal[v_k] * v_direction[v_k]));
            v_halfVector[v_k] = (v_direction[v_k] - v_viewEye[v_k]);
            continuing {
              v_k += u32(1);
            }
          }
        }
        water_normalize(&v_halfVector);
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
          v_spec = f_render_power(max(v_spec, 0.0f), 50.0f);
        }
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            let cw_argument_index_534 = (cw_buffer_offset_0 + i32(((v_record + u32(12i)) + v_k)));
            v_pointSpecular[v_k] = (v_pointSpecular[v_k] + (((1.5f * bitcast<f32>(b_texels[cw_argument_index_534])) * v_spec) * v_attenuation));
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
      var cw_tmp_536: f32;
      if ((v_k == u32(0i))) {
        cw_tmp_536 = 0.090195f;
      } else {
        var cw_tmp_535: f32;
        if ((v_k == u32(1i))) {
          cw_tmp_535 = 0.115685f;
        } else {
          cw_tmp_535 = 0.12745f;
        }
        cw_tmp_536 = cw_tmp_535;
      }
      var v_waterColor: f32 = (cw_tmp_536 * v_sunFade);
      var v_rawRefraction: f32 = 0.0f;
      if (((v_flags & u32(1i)) != u32(0i))) {
        var v_refraction: f32 = water_sample((cw_buffer_offset_0 + 0i), (v_p + u32(8i)), (v_sx - v_ox), (v_sy - v_oy), v_k);
        v_rawRefraction = v_refraction;
        if ((v_camera[2i] < 0.0f)) {
          v_refraction = f_water_unit((v_refraction * 1.5f));
        } else {
          var v_correction: f32 = sqrt(1.09f);
          var v_factor: f32 = f_water_unit(((precise_divide(0.0225f, ((((-0.5f) * v_correction) + 0.5f) - precise_divide(v_distorted, 2500.0f))) + (0.5f * v_correction)) + 0.5f));
          v_refraction = (v_refraction + ((v_waterColor - v_refraction) * v_factor));
        }
        if (((v_flags & u32(2i)) != u32(0i))) {
          var cw_tmp_538: f32;
          if ((v_k == u32(0i))) {
            cw_tmp_538 = 0.0f;
          } else {
            var cw_tmp_537: f32;
            if ((v_k == u32(1i))) {
              cw_tmp_537 = 1.0f;
            } else {
              cw_tmp_537 = 0.95f;
            }
            cw_tmp_538 = cw_tmp_537;
          }
          var v_tint: f32 = cw_tmp_538;
          var cw_tmp_540: f32;
          if ((v_k == u32(0i))) {
            cw_tmp_540 = 1.0f;
          } else {
            var cw_tmp_539: f32;
            if ((v_k == u32(1i))) {
              cw_tmp_539 = 0.4f;
            } else {
              cw_tmp_539 = 0.0f;
            }
            cw_tmp_540 = cw_tmp_539;
          }
          var v_warm: f32 = cw_tmp_540;
          var cw_tmp_542: f32;
          if ((v_k == u32(0i))) {
            cw_tmp_542 = 0.45f;
          } else {
            var cw_tmp_541: f32;
            if ((v_k == u32(1i))) {
              cw_tmp_541 = 0.55f;
            } else {
              cw_tmp_541 = 0.68f;
            }
            cw_tmp_542 = cw_tmp_541;
          }
          var v_extinction: f32 = cw_tmp_542;
          var v_scatterColor: f32 = (v_tint * (v_warm + ((1.0f - v_warm) * max((1.0f - exp(((-v_sun[2i]) * v_extinction))), 0.0f))));
          v_refraction = (v_refraction + ((v_scatterColor - v_refraction) * v_scatter));
        }
        (*v_color)[v_k] = ((v_refraction * (1.0f - v_fresnel)) + (v_reflection[v_k] * v_fresnel));
      } else {
        (*v_color)[v_k] = (((v_waterColor * (1.0f - v_fresnel)) * 0.5f) + ((v_reflection[v_k] * (1.0f + v_fresnel)) * 0.5f));
      }
      let cw_argument_index_543 = (cw_buffer_offset_0 + i32(((v_object + u32(36i)) + v_k)));
      (*v_color)[v_k] = ((*v_color)[v_k] + ((v_specular * bitcast<f32>(b_texels[cw_argument_index_543])) + v_pointSpecular[v_k]));
      var v_skyEstimate: f32 = max(0.0f, ((-0.3f) + (1.3f * v_sunFade)));
      let cw_argument_index_544 = 3i;
      var cw_tmp_545: f32;
      if (((v_flags & u32(1i)) != u32(0i))) {
        cw_tmp_545 = v_transparency;
      } else {
        cw_tmp_545 = 1.0f;
      }
      (*v_color)[v_k] = ((*v_color)[v_k] + (((abs(v_rainRipple[cw_argument_index_544]) * ((v_skyEstimate * 0.95f) + 0.05f)) * 0.5f) * cw_tmp_545));
      if (((v_flags & u32(5i)) == u32(5i))) {
        (*v_color)[v_k] = (v_rawRefraction + (((*v_color)[v_k] - v_rawRefraction) * v_shore));
      }
      (*v_viewNormal)[v_k] = 0.0f;
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(3i))) { break; }
          let cw_argument_index_546 = (cw_buffer_offset_0 + i32((((v_p + u32(40i)) + (v_k * u32(4i))) + v_col)));
          (*v_viewNormal)[v_k] = ((*v_viewNormal)[v_k] + (bitcast<f32>(b_texels[cw_argument_index_546]) * v_normal[v_col]));
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
  water_normalize(v_viewNormal);
  var cw_tmp_547: f32;
  if (((v_flags & u32(1i)) != u32(0i))) {
    cw_tmp_547 = 1.0f;
  } else {
    cw_tmp_547 = v_transparency;
  }
  (*v_color)[3i] = cw_tmp_547;
}

fn sample_mip(cw_buffer_arg_0: i32, cw_arg_base: u32, cw_arg_width: u32, cw_arg_height: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_sampler: u32, cw_arg_channel: u32, cw_arg_level: u32, cw_arg_linear: u32) -> f32 {
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
  var cw_tmp_556: f32;
  if (((v_sampler & u32(8192i)) != u32(0i))) {
    var cw_tmp_555: f32;
    if ((v_channel == u32(3i))) {
      cw_tmp_555 = 1.0f;
    } else {
      var cw_tmp_554: f32;
      if (((v_sampler & u32(16384i)) != u32(0i))) {
        cw_tmp_554 = 1.0f;
      } else {
        cw_tmp_554 = 0.0f;
      }
      cw_tmp_555 = cw_tmp_554;
    }
    cw_tmp_556 = cw_tmp_555;
  } else {
    cw_tmp_556 = 0.0f;
  }
  var v_borderValue: f32 = cw_tmp_556;
  if (((v_sampler & 536870912u) != 0u)) {
    var v_description: u32 = b_texels[(cw_buffer_offset_0 + i32((v_base + 5u)))];
    var v_kind: u32 = (v_description & 15u);
    var v_range: u32 = (v_description >> 4u);
    var v_component: u32 = v_channel;
    if (((v_kind == 4u) || (v_kind == 5u))) {
      var cw_tmp_557: u32;
      if ((v_channel == 3u)) {
        cw_tmp_557 = 3u;
      } else {
        cw_tmp_557 = 0u;
      }
      v_component = cw_tmp_557;
    }
    if ((v_kind == 7u)) {
      v_component = 0u;
    }
    if (((v_sampler & u32(8192i)) != 0u)) {
      v_component = 0u;
    }
    let cw_argument_index_558 = (cw_buffer_offset_0 + i32(((v_base + 1u) + v_component)));
    v_borderValue = bitcast<f32>(b_texels[cw_argument_index_558]);
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
      var cw_tmp_559: f32;
      if ((v_channel == 3u)) {
        cw_tmp_559 = 1.0f;
      } else {
        cw_tmp_559 = 0.0f;
      }
      v_borderValue = cw_tmp_559;
    }
    if ((((v_sampler & u32(8192i)) != 0u) && (v_channel == 3u))) {
      v_borderValue = 1.0f;
    }
    v_base = b_texels[(cw_buffer_offset_0 + i32(v_base))];
  }
  var cw_tmp_560: i32;
  if (((v_sampler & u32(32768i)) != u32(0i))) {
    cw_tmp_560 = 4i;
  } else {
    cw_tmp_560 = 1i;
  }
  var v_stride: u32 = u32(cw_tmp_560);
  {
    var v_l: u32 = u32(0i);
    loop {
      if (!(v_l < v_level)) { break; }
      v_base = (v_base + ((v_width * v_height) * v_stride));
      var cw_tmp_561: u32;
      if ((v_width > u32(1i))) {
        cw_tmp_561 = (v_width / u32(2i));
      } else {
        cw_tmp_561 = u32(1i);
      }
      v_width = cw_tmp_561;
      var cw_tmp_562: u32;
      if ((v_height > u32(1i))) {
        cw_tmp_562 = (v_height / u32(2i));
      } else {
        cw_tmp_562 = u32(1i);
      }
      v_height = cw_tmp_562;
      continuing {
        v_l += u32(1);
      }
    }
  }
  var v_ws: u32 = ((v_sampler >> u32(9i)) & u32(3i));
  var v_wt: u32 = ((v_sampler >> u32(11i)) & u32(3i));
  if (((v_sampler & 1073741824u) != 0u)) {
    v_u = min(1.0f, max(0.0f, v_u));
    var cw_tmp_563: u32;
    if ((v_linear != 0u)) {
      cw_tmp_563 = 3u;
    } else {
      cw_tmp_563 = 0u;
    }
    v_ws = cw_tmp_563;
  }
  if (((v_sampler & 2147483648u) != 0u)) {
    v_v = min(1.0f, max(0.0f, v_v));
    var cw_tmp_564: u32;
    if ((v_linear != 0u)) {
      cw_tmp_564 = 3u;
    } else {
      cw_tmp_564 = 0u;
    }
    v_wt = cw_tmp_564;
  }
  var cw_tmp_568: f32;
  if ((v_ws == u32(3i))) {
    cw_tmp_568 = min(2.0f, max((-1.0f), v_u));
  } else {
    var cw_tmp_567: f32;
    if ((v_ws == u32(0i))) {
      cw_tmp_567 = min(1.0f, max(0.0f, v_u));
    } else {
      var cw_tmp_565: f32;
      if ((v_ws == u32(2i))) {
        cw_tmp_565 = 2.0f;
      } else {
        cw_tmp_565 = 1.0f;
      }
      var cw_tmp_566: f32;
      if ((v_ws == u32(2i))) {
        cw_tmp_566 = 2.0f;
      } else {
        cw_tmp_566 = 1.0f;
      }
      cw_tmp_567 = (v_u - (floor(precise_divide(v_u, cw_tmp_565)) * cw_tmp_566));
    }
    cw_tmp_568 = cw_tmp_567;
  }
  v_u = cw_tmp_568;
  var cw_tmp_572: f32;
  if ((v_wt == u32(3i))) {
    cw_tmp_572 = min(2.0f, max((-1.0f), v_v));
  } else {
    var cw_tmp_571: f32;
    if ((v_wt == u32(0i))) {
      cw_tmp_571 = min(1.0f, max(0.0f, v_v));
    } else {
      var cw_tmp_569: f32;
      if ((v_wt == u32(2i))) {
        cw_tmp_569 = 2.0f;
      } else {
        cw_tmp_569 = 1.0f;
      }
      var cw_tmp_570: f32;
      if ((v_wt == u32(2i))) {
        cw_tmp_570 = 2.0f;
      } else {
        cw_tmp_570 = 1.0f;
      }
      cw_tmp_571 = (v_v - (floor(precise_divide(v_v, cw_tmp_569)) * cw_tmp_570));
    }
    cw_tmp_572 = cw_tmp_571;
  }
  v_v = cw_tmp_572;
  var cw_tmp_573: f32;
  if ((v_linear != u32(0i))) {
    cw_tmp_573 = 0.5f;
  } else {
    cw_tmp_573 = 0.0f;
  }
  var v_x: f32 = ((v_u * f32(v_width)) - cw_tmp_573);
  var cw_tmp_574: f32;
  if ((v_linear != u32(0i))) {
    cw_tmp_574 = 0.5f;
  } else {
    cw_tmp_574 = 0.0f;
  }
  var v_y: f32 = ((v_v * f32(v_height)) - cw_tmp_574);
  var v_ix: i32 = i32(floor(v_x));
  var v_iy: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - floor(v_x));
  var v_fy: f32 = (v_y - floor(v_y));
  var v_result: f32 = 0.0f;
  var cw_tmp_575: i32;
  if ((v_linear != u32(0i))) {
    cw_tmp_575 = 2i;
  } else {
    cw_tmp_575 = 1i;
  }
  var v_taps: u32 = u32(cw_tmp_575);
  {
    var v_dy: u32 = u32(0i);
    loop {
      if (!(v_dy < v_taps)) { break; }
      {
        var v_dx: u32 = u32(0i);
        loop {
          if (!(v_dx < v_taps)) { break; }
          var v_address: u32 = (v_base + (((u32(f_sampler_index((v_iy + i32(v_dy)), i32(v_height), v_wt)) * v_width) + u32(f_sampler_index((v_ix + i32(v_dx)), i32(v_width), v_ws))) * v_stride));
          var cw_tmp_578: f32;
          if ((v_linear != u32(0i))) {
            var cw_tmp_576: f32;
            if ((v_dx == u32(0i))) {
              cw_tmp_576 = (1.0f - v_fx);
            } else {
              cw_tmp_576 = v_fx;
            }
            var cw_tmp_577: f32;
            if ((v_dy == u32(0i))) {
              cw_tmp_577 = (1.0f - v_fy);
            } else {
              cw_tmp_577 = v_fy;
            }
            cw_tmp_578 = (cw_tmp_576 * cw_tmp_577);
          } else {
            cw_tmp_578 = 1.0f;
          }
          var v_weight: f32 = cw_tmp_578;
          var v_border: u32 = select(u32(0), u32(1), (((v_ws == u32(3i)) && (((v_ix + i32(v_dx)) < 0i) || ((v_ix + i32(v_dx)) >= i32(v_width)))) || ((v_wt == u32(3i)) && (((v_iy + i32(v_dy)) < 0i) || ((v_iy + i32(v_dy)) >= i32(v_height))))));
          var cw_tmp_583: f32;
          if (((v_sampler & u32(32768i)) != u32(0i))) {
            let cw_argument_index_579 = (cw_buffer_offset_0 + i32((v_address + v_channel)));
            cw_tmp_583 = bitcast<f32>(b_texels[cw_argument_index_579]);
          } else {
            var cw_tmp_582: f32;
            if (((v_sampler & u32(8192i)) != u32(0i))) {
              var cw_tmp_581: f32;
              if ((v_channel == u32(3i))) {
                cw_tmp_581 = 1.0f;
              } else {
                let cw_argument_index_580 = (cw_buffer_offset_0 + i32(v_address));
                cw_tmp_581 = bitcast<f32>(b_texels[cw_argument_index_580]);
              }
              cw_tmp_582 = cw_tmp_581;
            } else {
              cw_tmp_582 = precise_divide(f32(((b_texels[(cw_buffer_offset_0 + i32(v_address))] >> (v_channel * u32(8i))) & u32(255i))), 255.0f);
            }
            cw_tmp_583 = cw_tmp_582;
          }
          var v_value: f32 = cw_tmp_583;
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
fn shadow_mipped(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_reference: f32, cw_arg_lod: f32) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_reference: f32 = cw_arg_reference;
  var v_lod: f32 = cw_arg_lod;
  var v_sampler: u32 = b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 3u)))];
  var v_base: u32 = b_texels[(cw_buffer_offset_0 + i32(v_descriptor))];
  if (((v_sampler & 536870912u) != 0u)) {
    let cw_argument_index_584 = (cw_buffer_offset_0 + i32((v_base + 8u)));
    var v_bias: f32 = min(16.0f, max((-16.0f), bitcast<f32>(b_texels[cw_argument_index_584])));
    let cw_argument_index_585 = (cw_buffer_offset_0 + i32((v_base + 7u)));
    let cw_argument_index_586 = (cw_buffer_offset_0 + i32((v_base + 6u)));
    v_lod = min(bitcast<f32>(b_texels[cw_argument_index_585]), max(bitcast<f32>(b_texels[cw_argument_index_586]), (v_lod + v_bias)));
  }
  var v_filter: u32 = ((v_sampler >> 5u) & 7u);
  var v_magnification: u32 = ((v_sampler >> 8u) & 1u);
  var v_last: u32 = (v_sampler & 31u);
  var cw_tmp_587: f32;
  if (((v_magnification != 0u) && ((v_filter == 2u) || (v_filter == 4u)))) {
    cw_tmp_587 = 0.5f;
  } else {
    cw_tmp_587 = 0.0f;
  }
  var v_crossover: f32 = cw_tmp_587;
  if ((v_lod <= v_crossover)) {
    return shadow_mip((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, 0u, v_magnification);
  }
  if ((v_filter < 2u)) {
    return shadow_mip((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, 0u, v_filter);
  }
  v_lod = min(f32(v_last), max(0.0f, v_lod));
  var v_linear: u32 = (v_filter & 1u);
  if ((v_filter < 4u)) {
    return shadow_mip((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, u32(floor((v_lod + 0.5f))), v_linear);
  }
  var v_low: u32 = u32(floor(v_lod));
  var cw_tmp_588: u32;
  if ((v_low < v_last)) {
    cw_tmp_588 = (v_low + 1u);
  } else {
    cw_tmp_588 = v_low;
  }
  var v_high: u32 = cw_tmp_588;
  var v_fraction: f32 = (v_lod - f32(v_low));
  return ((shadow_mip((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, v_low, v_linear) * (1.0f - v_fraction)) + (shadow_mip((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_reference, v_high, v_linear) * v_fraction));
}
fn water_normalize(v_v: ptr<function, array<f32, 3>>) {
  var v_length: f32 = sqrt(max(1e-12f, ((((*v_v)[0i] * (*v_v)[0i]) + ((*v_v)[1i] * (*v_v)[1i])) + ((*v_v)[2i] * (*v_v)[2i]))));
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      (*v_v)[v_k] = precise_divide((*v_v)[v_k], v_length);
      continuing {
        v_k += u32(1);
      }
    }
  }
}
fn water_wave_chain(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_time: f32, cw_arg_dudx: f32, cw_arg_dvdx: f32, cw_arg_dudy: f32, cw_arg_dvdy: f32, v_waves: ptr<function, array<f32, 18>>) {
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
      var cw_tmp_593: f32;
      if ((v_layer == u32(0i))) {
        cw_tmp_593 = 0.05f;
      } else {
        var cw_tmp_592: f32;
        if ((v_layer == u32(1i))) {
          cw_tmp_592 = 0.1f;
        } else {
          var cw_tmp_591: f32;
          if ((v_layer == u32(2i))) {
            cw_tmp_591 = 0.25f;
          } else {
            var cw_tmp_590: f32;
            if ((v_layer == u32(3i))) {
              cw_tmp_590 = 0.5f;
            } else {
              var cw_tmp_589: f32;
              if ((v_layer == u32(4i))) {
                cw_tmp_589 = 1.0f;
              } else {
                cw_tmp_589 = 2.0f;
              }
              cw_tmp_590 = cw_tmp_589;
            }
            cw_tmp_591 = cw_tmp_590;
          }
          cw_tmp_592 = cw_tmp_591;
        }
        cw_tmp_593 = cw_tmp_592;
      }
      var v_scale: f32 = cw_tmp_593;
      var cw_tmp_598: f32;
      if ((v_layer == u32(0i))) {
        cw_tmp_598 = 0.04f;
      } else {
        var cw_tmp_597: f32;
        if ((v_layer == u32(1i))) {
          cw_tmp_597 = 0.08f;
        } else {
          var cw_tmp_596: f32;
          if ((v_layer == u32(2i))) {
            cw_tmp_596 = 0.07f;
          } else {
            var cw_tmp_595: f32;
            if ((v_layer == u32(3i))) {
              cw_tmp_595 = 0.09f;
            } else {
              var cw_tmp_594: f32;
              if ((v_layer == u32(4i))) {
                cw_tmp_594 = 0.4f;
              } else {
                cw_tmp_594 = 0.7f;
              }
              cw_tmp_595 = cw_tmp_594;
            }
            cw_tmp_596 = cw_tmp_595;
          }
          cw_tmp_597 = cw_tmp_596;
        }
        cw_tmp_598 = cw_tmp_597;
      }
      var v_speed: f32 = cw_tmp_598;
      var cw_tmp_603: f32;
      if ((v_layer == u32(0i))) {
        cw_tmp_603 = (-0.015f);
      } else {
        var cw_tmp_602: f32;
        if ((v_layer == u32(1i))) {
          cw_tmp_602 = 0.02f;
        } else {
          var cw_tmp_601: f32;
          if ((v_layer == u32(2i))) {
            cw_tmp_601 = (-0.04f);
          } else {
            var cw_tmp_600: f32;
            if ((v_layer == u32(3i))) {
              cw_tmp_600 = 0.03f;
            } else {
              var cw_tmp_599: f32;
              if ((v_layer == u32(4i))) {
                cw_tmp_599 = (-0.02f);
              } else {
                cw_tmp_599 = 0.1f;
              }
              cw_tmp_600 = cw_tmp_599;
            }
            cw_tmp_601 = cw_tmp_600;
          }
          cw_tmp_602 = cw_tmp_601;
        }
        cw_tmp_603 = cw_tmp_602;
      }
      var v_tx: f32 = cw_tmp_603;
      var cw_tmp_608: f32;
      if ((v_layer == u32(0i))) {
        cw_tmp_608 = (-0.005f);
      } else {
        var cw_tmp_607: f32;
        if ((v_layer == u32(1i))) {
          cw_tmp_607 = 0.015f;
        } else {
          var cw_tmp_606: f32;
          if ((v_layer == u32(2i))) {
            cw_tmp_606 = (-0.03f);
          } else {
            var cw_tmp_605: f32;
            if ((v_layer == u32(3i))) {
              cw_tmp_605 = 0.04f;
            } else {
              var cw_tmp_604: f32;
              if ((v_layer == u32(4i))) {
                cw_tmp_604 = 0.1f;
              } else {
                cw_tmp_604 = (-0.06f);
              }
              cw_tmp_605 = cw_tmp_604;
            }
            cw_tmp_606 = cw_tmp_605;
          }
          cw_tmp_607 = cw_tmp_606;
        }
        cw_tmp_608 = cw_tmp_607;
      }
      var v_ty: f32 = cw_tmp_608;
      var v_coords: array<f32, 6>;
      {
        var v_sample: u32 = u32(0i);
        loop {
          if (!(v_sample < u32(3i))) { break; }
          let cw_argument_index_609 = ((v_sample * u32(3i)) + u32(2i));
          var cw_tmp_610: f32;
          if ((abs(v_previous[cw_argument_index_609]) > 0.000001f)) {
            cw_tmp_610 = v_previous[((v_sample * u32(3i)) + u32(2i))];
          } else {
            cw_tmp_610 = 1.0f;
          }
          var v_denominator: f32 = cw_tmp_610;
          var cw_tmp_612: f32;
          if ((v_sample == u32(1i))) {
            cw_tmp_612 = v_dudx;
          } else {
            var cw_tmp_611: f32;
            if ((v_sample == u32(2i))) {
              cw_tmp_611 = v_dudy;
            } else {
              cw_tmp_611 = 0.0f;
            }
            cw_tmp_612 = cw_tmp_611;
          }
          v_coords[(v_sample * u32(2i))] = (((((v_u + cw_tmp_612) * 75.0f) * v_scale) + (v_time * ((0.1f * v_speed) + v_tx))) - (precise_divide(v_previous[(v_sample * u32(3i))], v_denominator) * 0.05f));
          var cw_tmp_614: f32;
          if ((v_sample == u32(1i))) {
            cw_tmp_614 = v_dvdx;
          } else {
            var cw_tmp_613: f32;
            if ((v_sample == u32(2i))) {
              cw_tmp_613 = v_dvdy;
            } else {
              cw_tmp_613 = 0.0f;
            }
            cw_tmp_614 = cw_tmp_613;
          }
          v_coords[((v_sample * u32(2i)) + u32(1i))] = (((((v_v + cw_tmp_614) * 75.0f) * v_scale) + (v_time * (((-0.16f) * v_speed) + v_ty))) - (precise_divide(v_previous[((v_sample * u32(3i)) + u32(1i))], v_denominator) * 0.05f));
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
              let cw_argument_index_615 = (cw_buffer_offset_0 + i32(v_descriptor));
              let cw_argument_index_616 = (cw_buffer_offset_0 + i32((v_descriptor + u32(1i))));
              let cw_argument_index_617 = (cw_buffer_offset_0 + i32((v_descriptor + u32(2i))));
              let cw_argument_index_618 = (v_sample * u32(2i));
              let cw_argument_index_619 = ((v_sample * u32(2i)) + u32(1i));
              let cw_argument_index_620 = (cw_buffer_offset_0 + i32((v_descriptor + u32(3i))));
              v_previous[((v_sample * u32(3i)) + v_k)] = ((2.0f * sample_texture_lod((cw_buffer_offset_0 + 0i), b_texels[cw_argument_index_615], b_texels[cw_argument_index_616], b_texels[cw_argument_index_617], v_coords[cw_argument_index_618], v_coords[cw_argument_index_619], v_lod, b_texels[cw_argument_index_620], v_k)) - 1.0f);
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
fn water_sample(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_channel: u32) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_channel: u32 = cw_arg_channel;
  let cw_argument_index_621 = (cw_buffer_offset_0 + i32(v_descriptor));
  let cw_argument_index_622 = (cw_buffer_offset_0 + i32((v_descriptor + u32(1i))));
  let cw_argument_index_623 = (cw_buffer_offset_0 + i32((v_descriptor + u32(2i))));
  let cw_argument_index_624 = (cw_buffer_offset_0 + i32((v_descriptor + u32(3i))));
  return sample_texture_lod((cw_buffer_offset_0 + 0i), b_texels[cw_argument_index_621], b_texels[cw_argument_index_622], b_texels[cw_argument_index_623], v_u, v_v, 0.0f, b_texels[cw_argument_index_624], v_channel);
}
fn water_rain_combined(cw_arg_u: f32, cw_arg_v: f32, cw_arg_time: f32, cw_arg_detail: u32, v_output: ptr<function, array<f32, 4>>) {
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
  var cw_tmp_625: i32;
  if ((v_detail == u32(2i))) {
    cw_tmp_625 = 5i;
  } else {
    cw_tmp_625 = 2i;
  }
  var v_layers: u32 = u32(cw_tmp_625);
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
      water_rain(v_x, v_y, v_time, v_detail, &v_value);
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
fn water_wave(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_scale: f32, cw_arg_speed: f32, cw_arg_time: f32, cw_arg_tx: f32, cw_arg_ty: f32, v_previous: ptr<function, array<f32, 3>>, v_output: ptr<function, array<f32, 3>>) {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_descriptor: u32 = cw_arg_descriptor;
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_scale: f32 = cw_arg_scale;
  var v_speed: f32 = cw_arg_speed;
  var v_time: f32 = cw_arg_time;
  var v_tx: f32 = cw_arg_tx;
  var v_ty: f32 = cw_arg_ty;
  var cw_tmp_626: f32;
  if ((abs((*v_previous)[2i]) > 0.000001f)) {
    cw_tmp_626 = (*v_previous)[2i];
  } else {
    cw_tmp_626 = 1.0f;
  }
  var v_denominator: f32 = cw_tmp_626;
  v_u = (((((v_u * 75.0f) * v_scale) + (((0.5f * v_time) * 0.2f) * v_speed)) - (precise_divide((*v_previous)[0i], v_denominator) * 0.05f)) + (v_time * v_tx));
  v_v = (((((v_v * 75.0f) * v_scale) - (((0.8f * v_time) * 0.2f) * v_speed)) - (precise_divide((*v_previous)[1i], v_denominator) * 0.05f)) + (v_time * v_ty));
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      (*v_output)[v_k] = ((2.0f * water_sample((cw_buffer_offset_0 + 0i), v_descriptor, v_u, v_v, v_k)) - 1.0f);
      continuing {
        v_k += u32(1);
      }
    }
  }
}
fn shadow_mip(cw_buffer_arg_0: i32, cw_arg_descriptor: u32, cw_arg_u: f32, cw_arg_v: f32, cw_arg_reference: f32, cw_arg_level: u32, cw_arg_linear: u32) -> f32 {
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
  var cw_tmp_627: f32;
  if (((v_sampler & u32(16384i)) != u32(0i))) {
    cw_tmp_627 = 1.0f;
  } else {
    cw_tmp_627 = 0.0f;
  }
  var v_borderValue: f32 = cw_tmp_627;
  if (((v_sampler & 536870912u) != 0u)) {
    let cw_argument_index_628 = (cw_buffer_offset_0 + i32((v_base + 1u)));
    v_borderValue = bitcast<f32>(b_texels[cw_argument_index_628]);
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
      var cw_tmp_629: u32;
      if ((v_width > 1u)) {
        cw_tmp_629 = (v_width / 2u);
      } else {
        cw_tmp_629 = 1u;
      }
      v_width = cw_tmp_629;
      var cw_tmp_630: u32;
      if ((v_height > 1u)) {
        cw_tmp_630 = (v_height / 2u);
      } else {
        cw_tmp_630 = 1u;
      }
      v_height = cw_tmp_630;
      continuing {
        v_l += u32(1);
      }
    }
  }
  var v_ws: u32 = ((v_sampler >> u32(9i)) & u32(3i));
  var v_wt: u32 = ((v_sampler >> u32(11i)) & u32(3i));
  if (((v_sampler & 1073741824u) != 0u)) {
    v_u = min(1.0f, max(0.0f, v_u));
    var cw_tmp_631: u32;
    if ((v_linear != 0u)) {
      cw_tmp_631 = 3u;
    } else {
      cw_tmp_631 = 0u;
    }
    v_ws = cw_tmp_631;
  }
  if (((v_sampler & 2147483648u) != 0u)) {
    v_v = min(1.0f, max(0.0f, v_v));
    var cw_tmp_632: u32;
    if ((v_linear != 0u)) {
      cw_tmp_632 = 3u;
    } else {
      cw_tmp_632 = 0u;
    }
    v_wt = cw_tmp_632;
  }
  var cw_tmp_636: f32;
  if ((v_ws == u32(3i))) {
    cw_tmp_636 = min(2.0f, max((-1.0f), v_u));
  } else {
    var cw_tmp_635: f32;
    if ((v_ws == u32(0i))) {
      cw_tmp_635 = min(1.0f, max(0.0f, v_u));
    } else {
      var cw_tmp_633: f32;
      if ((v_ws == u32(2i))) {
        cw_tmp_633 = 2.0f;
      } else {
        cw_tmp_633 = 1.0f;
      }
      var cw_tmp_634: f32;
      if ((v_ws == u32(2i))) {
        cw_tmp_634 = 2.0f;
      } else {
        cw_tmp_634 = 1.0f;
      }
      cw_tmp_635 = (v_u - (floor(precise_divide(v_u, cw_tmp_633)) * cw_tmp_634));
    }
    cw_tmp_636 = cw_tmp_635;
  }
  v_u = cw_tmp_636;
  var cw_tmp_640: f32;
  if ((v_wt == u32(3i))) {
    cw_tmp_640 = min(2.0f, max((-1.0f), v_v));
  } else {
    var cw_tmp_639: f32;
    if ((v_wt == u32(0i))) {
      cw_tmp_639 = min(1.0f, max(0.0f, v_v));
    } else {
      var cw_tmp_637: f32;
      if ((v_wt == u32(2i))) {
        cw_tmp_637 = 2.0f;
      } else {
        cw_tmp_637 = 1.0f;
      }
      var cw_tmp_638: f32;
      if ((v_wt == u32(2i))) {
        cw_tmp_638 = 2.0f;
      } else {
        cw_tmp_638 = 1.0f;
      }
      cw_tmp_639 = (v_v - (floor(precise_divide(v_v, cw_tmp_637)) * cw_tmp_638));
    }
    cw_tmp_640 = cw_tmp_639;
  }
  v_v = cw_tmp_640;
  var cw_tmp_641: f32;
  if ((v_linear != u32(0i))) {
    cw_tmp_641 = 0.5f;
  } else {
    cw_tmp_641 = 0.0f;
  }
  var v_x: f32 = ((v_u * f32(v_width)) - cw_tmp_641);
  var cw_tmp_642: f32;
  if ((v_linear != u32(0i))) {
    cw_tmp_642 = 0.5f;
  } else {
    cw_tmp_642 = 0.0f;
  }
  var v_y: f32 = ((v_v * f32(v_height)) - cw_tmp_642);
  var v_ix: i32 = i32(floor(v_x));
  var v_iy: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - floor(v_x));
  var v_fy: f32 = (v_y - floor(v_y));
  var v_result: f32 = 0.0f;
  var cw_tmp_643: i32;
  if ((v_linear != u32(0i))) {
    cw_tmp_643 = 2i;
  } else {
    cw_tmp_643 = 1i;
  }
  var v_taps: u32 = u32(cw_tmp_643);
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
          var v_address: u32 = ((v_base + (u32(f_sampler_index(v_yy, i32(v_height), v_wt)) * v_width)) + u32(f_sampler_index(v_xx, i32(v_width), v_ws)));
          var cw_tmp_645: f32;
          if ((v_border != u32(0i))) {
            cw_tmp_645 = v_borderValue;
          } else {
            let cw_argument_index_644 = (cw_buffer_offset_0 + i32(v_address));
            cw_tmp_645 = bitcast<f32>(b_texels[cw_argument_index_644]);
          }
          var v_depth: f32 = cw_tmp_645;
          var cw_tmp_648: f32;
          if ((v_linear != u32(0i))) {
            var cw_tmp_646: f32;
            if ((v_dx == u32(0i))) {
              cw_tmp_646 = (1.0f - v_fx);
            } else {
              cw_tmp_646 = v_fx;
            }
            var cw_tmp_647: f32;
            if ((v_dy == u32(0i))) {
              cw_tmp_647 = (1.0f - v_fy);
            } else {
              cw_tmp_647 = v_fy;
            }
            cw_tmp_648 = (cw_tmp_646 * cw_tmp_647);
          } else {
            cw_tmp_648 = 1.0f;
          }
          var v_weight: f32 = cw_tmp_648;
          var v_comparedReference: f32 = v_reference;
          if (((b_texels[(cw_buffer_offset_0 + i32((v_descriptor + 5u)))] & 8u) == 0u)) {
            v_comparedReference = min(1.0f, max(0.0f, v_comparedReference));
            v_depth = min(1.0f, max(0.0f, v_depth));
          }
          let cw_argument_index_649 = (cw_buffer_offset_0 + i32((v_descriptor + u32(4i))));
          v_result = (v_result + (v_weight * f32(f_compare_value(v_comparedReference, v_depth, b_texels[cw_argument_index_649]))));
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
fn water_rain(cw_arg_u: f32, cw_arg_v: f32, cw_arg_time: f32, cw_arg_detail: u32, v_output: ptr<function, array<f32, 4>>) {
  var v_u: f32 = cw_arg_u;
  var v_v: f32 = cw_arg_v;
  var v_time: f32 = cw_arg_time;
  var v_detail: u32 = cw_arg_detail;
  var v_x: f32 = (v_u * 10.0f);
  var v_y: f32 = (v_v * 10.0f);
  var v_cx: f32 = floor(v_x);
  var v_cy: f32 = floor(v_y);
  var v_adjusted: f32 = ((v_time * 1.2f) + f_water_fract(precise_divide((v_cx * v_cy), ((v_cx + v_cy) + 0.1f))));
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
  var cw_tmp_650: i32;
  if ((v_detail != u32(0i))) {
    cw_tmp_650 = 4i;
  } else {
    cw_tmp_650 = 1i;
  }
  var v_rings: u32 = u32(cw_tmp_650);
  {
    var v_ring: u32 = u32(0i);
    loop {
      if (!(v_ring < v_rings)) { break; }
      var v_value: array<f32, 4>;
      water_rain_circle(f_water_fract(v_x), f_water_fract(v_y), v_cx, v_cy, (v_adjusted - precise_divide(f32(v_ring), 6.0f)), v_detail, &v_value);
      var cw_tmp_653: f32;
      if ((v_ring == u32(0i))) {
        cw_tmp_653 = 1.0f;
      } else {
        var cw_tmp_652: f32;
        if ((v_ring == u32(1i))) {
          cw_tmp_652 = 0.5f;
        } else {
          var cw_tmp_651: f32;
          if ((v_ring == u32(2i))) {
            cw_tmp_651 = 0.25f;
          } else {
            cw_tmp_651 = 0.125f;
          }
          cw_tmp_652 = cw_tmp_651;
        }
        cw_tmp_653 = cw_tmp_652;
      }
      var v_weight: f32 = cw_tmp_653;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          var cw_tmp_654: f32;
          if (((v_k < u32(2i)) && ((v_ring % u32(2i)) != u32(0i)))) {
            cw_tmp_654 = (-1.0f);
          } else {
            cw_tmp_654 = 1.0f;
          }
          (*v_output)[v_k] = ((*v_output)[v_k] + ((v_value[v_k] * v_weight) * cw_tmp_654));
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
fn water_rain_circle(cw_arg_x: f32, cw_arg_y: f32, cw_arg_cellX: f32, cw_arg_cellY: f32, cw_arg_time: f32, cw_arg_detail: u32, v_output: ptr<function, array<f32, 4>>) {
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
  var v_seed: f32 = f_water_fract(precise_divide(floor(v_time), 1000.0f));
  var v_cx: f32 = ((precise_divide((v_cellX * v_cellY), 8.0f) + (v_cellY * 0.3f)) + (v_cellX * 0.2f));
  var v_cy: f32 = ((precise_divide((v_cellX * v_cellY), 14.0f) + (v_cellY * 0.5f)) + (v_cellX * 0.7f));
  v_cx = f_water_fract((v_cx * (f_water_scramble(f_water_scramble((v_seed + precise_divide(v_cx, 1000.0f)), 4.0f), 3.0f) + 1.0f)));
  v_cy = f_water_fract((v_cy * (f_water_scramble(f_water_scramble((v_seed + precise_divide(v_cy, 1000.0f)), 3.5f), 3.0f) + 1.0f)));
  var v_dx: f32 = (v_x - (0.5f + (0.3f * ((2.0f * v_cx) - 1.0f))));
  var v_dy: f32 = (v_y - (0.5f + (0.3f * ((2.0f * v_cy) - 1.0f))));
  var v_distance: f32 = sqrt(((v_dx * v_dx) + (v_dy * v_dy)));
  var v_phase: f32 = f_water_fract(v_time);
  var v_ring: f32 = (((v_phase - precise_divide(v_distance, 0.2f)) * 6.0f) - 1.0f);
  var cw_tmp_656: bool = (v_ring < (-1.0f));
  if (!cw_tmp_656) {
    var cw_tmp_655: f32;
    if ((v_detail != u32(0i))) {
      cw_tmp_655 = 1.0f;
    } else {
      cw_tmp_655 = 0.5f;
    }
    cw_tmp_656 = (v_ring > cw_tmp_655);
  }
  if (cw_tmp_656) {
    return;
  }
  var v_energy: f32 = (1.0f - v_phase);
  var v_height: f32 = f_water_blip(((v_ring * 2.0f) + 0.5f));
  (*v_output)[3i] = ((v_height * v_energy) * v_energy);
  if ((v_detail == u32(0i))) {
    return;
  }
  if ((v_distance > 1.0f)) {
    v_dx = precise_divide(v_dx, v_distance);
    v_dy = precise_divide(v_dy, v_distance);
  }
  var v_t: f32 = min(1.0f, max((-1.0f), v_ring));
  var v_n: f32 = ((v_t * v_t) - 1.0f);
  var v_derivative: f32 = ((((-6.0f) * v_t) * v_n) * v_n);
  (*v_output)[0i] = (((((-v_dx) * v_derivative) * 5.0f) * v_energy) * v_energy);
  (*v_output)[1i] = (((((-v_dy) * v_derivative) * 5.0f) * v_energy) * v_energy);
  (*v_output)[2i] = 0.5f;
  normalize_four(v_output);
  var v_limit: f32 = f_water_blip(min(0.0f, v_ring));
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
fn normalize_four(v_v: ptr<function, array<f32, 4>>) {
  var v_length: f32 = sqrt(max(1e-12f, ((((*v_v)[0i] * (*v_v)[0i]) + ((*v_v)[1i] * (*v_v)[1i])) + ((*v_v)[2i] * (*v_v)[2i]))));
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      (*v_v)[v_k] = precise_divide((*v_v)[v_k], v_length);
      continuing {
        v_k += u32(1);
      }
    }
  }
}


fn shade_material(input: RasterVaryings, front: bool, sample: u32) -> MaterialResult {
  let v_t = input.triangle * 4u;
  let v_m = b_triangles[v_t + 3u] * 12u;
  let v_flags = MATERIAL_FLAGS;
  let v_control = b_materials[v_m + 9u];
  let v_raster = params.raster_offset + (v_m / 12u) * 50u;
  let v_ia = b_triangles[v_t] * 10u;
  let v_ib = b_triangles[v_t + 1u] * 10u;
  let v_ic = b_triangles[v_t + 2u] * 10u;
  let v_aw = b_vertices[v_ia + 3u]; let v_bw = b_vertices[v_ib + 3u]; let v_cw = b_vertices[v_ic + 3u];
  let v_x = u32(input.position.x); let v_y = u32(input.position.y);
  let v_px = input.position.x; let v_py = input.position.y;
  let v_sample = sample;
  let v_front = select(0u, 1u, front);
  let v_multisample = select(0u, 1u, params.sample_count > 1u && b_attributes[v_raster + 27u] != 0.0);
  let v_sampleX = fract(v_px); let v_sampleY = fract(v_py);
  if (v_multisample != 0u) {
    if (((u32(b_attributes[v_raster + 26u]) >> sample) & 1u) == 0u) { discard; }
    let rank = (sample + (v_x * 3u + v_y * 5u) % params.sample_count) % params.sample_count;
    var covered = clamp(b_attributes[v_raster + 24u], 0.0, 1.0) >= (f32(rank) + 0.5) / f32(params.sample_count);
    if (b_attributes[v_raster + 25u] != 0.0) { covered = !covered; }
    if (!covered) { discard; }
  }
  let ha = homogeneous_screen(v_ia); let hb = homogeneous_screen(v_ib); let hc = homogeneous_screen(v_ic);
  let ca = cross(hb, hc); let cb = cross(hc, ha); let cc = cross(ha, hb);
  let determinant = dot(ha, ca);
  if (abs(determinant) < 1e-20) { discard; }
  var v_dax = ca.x / determinant; var v_dbx = cb.x / determinant; var v_dcx = cc.x / determinant;
  var v_day = ca.y / determinant; var v_dby = cb.y / determinant; var v_dcy = cc.y / determinant;
  let screen_point = vec3<f32>(v_px, v_py, 1.0);
  let projective_weights = vec3<f32>(dot(ca, screen_point), dot(cb, screen_point), dot(cc, screen_point)) / determinant;
  var v_inv = input.position.w;
  var v_a = input.weights.x; var v_b = input.weights.y; var v_c = input.weights.z;
  if (v_aw <= 0.0 || v_bw <= 0.0 || v_cw <= 0.0) {
    // Recover the original triangle's attributes at eye-plane crossings. This
    // basis remains finite even when a source corner cannot be divided by w.
    v_inv = projective_weights.x + projective_weights.y + projective_weights.z;
    if (abs(v_inv) < 1e-20) { discard; }
    v_a = projective_weights.x / v_inv;
    v_b = projective_weights.y / v_inv;
    v_c = projective_weights.z / v_inv;
  }
  var v_gradAx = v_dax * v_aw; var v_gradBx = v_dbx * v_bw; var v_gradCx = v_dcx * v_cw;
  var v_gradAy = v_day * v_aw; var v_gradBy = v_dby * v_bw; var v_gradCy = v_dcy * v_cw;
  var v_pointFade = 1.0; var v_spriteU = 0.0; var v_spriteV = 0.0; var v_spriteDx = 0.0; var v_spriteDy = 0.0;
  var v_spriteMask = 0u;
  // Depth range is applied after fixed-function homogeneous clipping, as in GL.
  let near_depth = clamp(b_attributes[v_raster + 2u], 0.0, 1.0);
  let far_depth = clamp(b_attributes[v_raster + 3u], 0.0, 1.0);
  let depth_scale = select(0.5, 1.0, (v_flags & 8388608u) != 0u);
  let depth_bias = select(0.5, 0.0, (v_flags & 8388608u) != 0u);
  let depth_a = b_vertices[v_ia + 2u] * depth_scale + v_aw * depth_bias;
  let depth_b = b_vertices[v_ib + 2u] * depth_scale + v_bw * depth_bias;
  let depth_c = b_vertices[v_ic + 2u] * depth_scale + v_cw * depth_bias;
  let dzdx = (v_dax * depth_a + v_dbx * depth_b + v_dcx * depth_c) * (far_depth - near_depth);
  let dzdy = (v_day * depth_a + v_dby * depth_b + v_dcy * depth_c) * (far_depth - near_depth);
  // Derive window depth from the same homogeneous plane used for gradients.
  // This avoids implementation-dependent fragment-position interpolation at
  // an original endpoint with w == 0 while retaining hardware clipping.
  let window_depth = dot(projective_weights, vec3<f32>(depth_a, depth_b, depth_c));
  var v_z = near_depth + window_depth * (far_depth - near_depth);
  var depth_unit = select(1.0 / 16777216.0, 1.0 / 65536.0, params.depth_bits == 16u);
  if (params.depth_bits == 0u) {
    // Native float depth spacing; use the largest finite vertex depth when
    // possible, falling back to the fragment for an eye-plane endpoint.
    var largest = abs(v_z);
    if (abs(v_aw) > 1e-20) { largest = max(largest, abs(near_depth + depth_a / v_aw * (far_depth - near_depth))); }
    if (abs(v_bw) > 1e-20) { largest = max(largest, abs(near_depth + depth_b / v_bw * (far_depth - near_depth))); }
    if (abs(v_cw) > 1e-20) { largest = max(largest, abs(near_depth + depth_c / v_cw * (far_depth - near_depth))); }
    let exponent = (bitcast<u32>(largest) >> 23u) & 255u;
    depth_unit = bitcast<f32>(select(1u, (exponent - min(exponent, 23u)) << 23u, exponent > 23u));
  }
  let offset_state = v_raster + select(41u, 39u, front);
  v_z += max(abs(dzdx), abs(dzdy)) * b_attributes[offset_state] + b_attributes[offset_state + 1u] * depth_unit;
  if ((v_flags & 262144u) != 0u) { v_z = clamp(v_z, min(near_depth, far_depth), max(near_depth, far_depth)); }
  v_z = f_store_depth_value(v_z, params.depth_bits);
  // All producer-generated point/line metadata uses the screenPrimitiveDraw
  // material flag (including projected particles and thin ribbons). Keep this
  // family out of ordinary triangle pipelines before driver compilation.
  if ((v_flags & 4194304u) != 0u) {
      var v_lineBase: u32 = (params.point_fade_offset + ((v_ia / 10u) * 12u));
      var cw_tmp_83: u32;
      if (((b_attributes[(v_lineBase + 7u)] > 0.0f) && (b_attributes[(v_lineBase + 11u)] > 0.0f))) {
        cw_tmp_83 = 1u;
      } else {
        cw_tmp_83 = 0u;
      }
      var v_generatedLine: u32 = cw_tmp_83;
      if ((v_generatedLine != 0u)) {
        var v_w0: f32 = b_attributes[(v_lineBase + 7u)];
        var v_w1: f32 = b_attributes[(v_lineBase + 11u)];
        var v_x0: f32 = (((precise_divide(b_attributes[(v_lineBase + 4u)], v_w0) * 0.5f) + 0.5f) * f32(params.width));
        var v_y0: f32 = ((0.5f - (precise_divide(b_attributes[(v_lineBase + 5u)], v_w0) * 0.5f)) * f32(params.height));
        var v_dx: f32 = ((((precise_divide(b_attributes[(v_lineBase + 8u)], v_w1) * 0.5f) + 0.5f) * f32(params.width)) - v_x0);
        var v_dy: f32 = (((0.5f - (precise_divide(b_attributes[(v_lineBase + 9u)], v_w1) * 0.5f)) * f32(params.height)) - v_y0);
        var v_length2: f32 = ((v_dx * v_dx) + (v_dy * v_dy));
        if ((v_length2 <= 1e-12f)) {
          discard;
        }
        var v_qx: f32 = (v_px - v_x0);
        var v_qy: f32 = (v_py - v_y0);
        var v_lineWidth: f32 = b_attributes[(v_lineBase + 2u)];
        var v_along: f32 = precise_divide(((v_qx * v_dx) + (v_qy * v_dy)), v_length2);
        if (((v_multisample == 0u) && ((u32(b_attributes[(v_raster + 49u)]) & 128u) != 0u))) {
          var v_coverage: f32 = f_line_rectangle_coverage((-v_qx), (-v_qy), v_dx, v_dy, v_lineWidth);
          if ((v_coverage <= 0.0f)) {
            discard;
          }
          v_pointFade = (v_pointFade * v_coverage);
        } else {
          if ((v_multisample == 0u)) {
            if ((f_line_wide_diamond((-v_qx), (-v_qy), v_dx, v_dy, max(1.0f, floor((v_lineWidth + 0.5f)))) == 0u)) {
              discard;
            }
          } else {
            var v_perpendicular: f32 = ((v_qx * v_dy) - (v_qy * v_dx));
            if ((((v_along < 0.0f) || (v_along >= 1.0f)) || ((v_perpendicular * v_perpendicular) > (((v_lineWidth * v_lineWidth) * 0.25f) * v_length2)))) {
              discard;
            }
          }
        }
        var cw_tmp_84: f32;
        if (((v_along > 0.0f) && (v_along < 1.0f))) {
          cw_tmp_84 = 1.0f;
        } else {
          cw_tmp_84 = 0.0f;
        }
        var v_gradient: f32 = cw_tmp_84;
        v_along = min(1.0f, max(0.0f, v_along));
        var v_reciprocal: f32 = (precise_divide((1.0f - v_along), v_w0) + precise_divide(v_along, v_w1));
        var v_parameter: f32 = precise_divide(precise_divide(v_along, v_w1), v_reciprocal);
        var v_derivative: f32 = precise_divide(v_gradient, (((v_w0 * v_w1) * v_reciprocal) * v_reciprocal));
        var v_parameters: array<f32, 3>;
        var v_ws: array<f32, 3>;
        var v_basis: array<f32, 3>;
        var v_gx: array<f32, 3>;
        var v_gy: array<f32, 3>;
        v_parameters[0i] = b_attributes[(v_lineBase + 1u)];
        v_parameters[1i] = b_attributes[((params.point_fade_offset + ((v_ib / 10u) * 12u)) + 1u)];
        v_parameters[2i] = b_attributes[((params.point_fade_offset + ((v_ic / 10u) * 12u)) + 1u)];
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
          discard;
        }
        var v_weight: f32 = precise_divide((v_parameter - v_parameters[v_low]), v_span);
        var v_sum: f32 = (((1.0f - v_weight) * v_ws[v_low]) + (v_weight * v_ws[v_high]));
        if ((v_sum <= 0.0f)) {
          discard;
        }
        {
          var v_k: u32 = 0u;
          loop {
            if (!(v_k < 3u)) { break; }
            var cw_tmp_86: f32;
            if ((v_k == v_low)) {
              cw_tmp_86 = (1.0f - v_weight);
            } else {
              var cw_tmp_85: f32;
              if ((v_k == v_high)) {
                cw_tmp_85 = v_weight;
              } else {
                cw_tmp_85 = 0.0f;
              }
              cw_tmp_86 = cw_tmp_85;
            }
            var v_p: f32 = cw_tmp_86;
            var cw_tmp_88: f32;
            if ((v_k == v_low)) {
              cw_tmp_88 = precise_divide((-1.0f), v_span);
            } else {
              var cw_tmp_87: f32;
              if ((v_k == v_high)) {
                cw_tmp_87 = precise_divide(1.0f, v_span);
              } else {
                cw_tmp_87 = 0.0f;
              }
              cw_tmp_88 = cw_tmp_87;
            }
            var v_dp: f32 = cw_tmp_88;
            v_basis[v_k] = precise_divide((v_p * v_ws[v_k]), v_sum);
            var v_d: f32 = (precise_divide(((v_dp * v_ws[v_k]) - precise_divide((v_basis[v_k] * (v_ws[v_high] - v_ws[v_low])), v_span)), v_sum) * v_derivative);
            v_gx[v_k] = precise_divide((v_d * v_dx), v_length2);
            v_gy[v_k] = precise_divide((v_d * v_dy), v_length2);
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
        // Expanded line support triangles carry the centreline's interpolation
        // rule. Keep fragment depth consistent with those adjusted weights.
        v_z = near_depth + (v_a * depth_a / v_aw + v_b * depth_b / v_bw + v_c * depth_c / v_cw) * (far_depth - near_depth);
        v_z += max(abs(dzdx), abs(dzdy)) * b_attributes[offset_state] + b_attributes[offset_state + 1u] * depth_unit;
        if ((v_flags & 262144u) != 0u) { v_z = clamp(v_z, min(near_depth, far_depth), max(near_depth, far_depth)); }
        v_z = f_store_depth_value(v_z, params.depth_bits);
        v_inv = v_a / v_aw + v_b / v_bw + v_c / v_cw;
        v_a = (v_a / v_aw) / v_inv;
        v_b = (v_b / v_bw) / v_inv;
        v_c = (v_c / v_cw) / v_inv;
        v_dax = v_gradAx / v_aw; v_dbx = v_gradBx / v_bw; v_dcx = v_gradCx / v_cw;
        v_day = v_gradAy / v_aw; v_dby = v_gradBy / v_bw; v_dcy = v_gradCy / v_cw;
      }
      var v_pointMetadata: array<f32, 4>;
      {
        var v_channel: u32 = u32(0i);
        loop {
          if (!(v_channel < u32(4i))) { break; }
          v_pointMetadata[v_channel] = (((v_a * b_attributes[((params.point_fade_offset + ((v_ia / 10u) * 12u)) + v_channel)]) + (v_b * b_attributes[((params.point_fade_offset + ((v_ib / 10u) * 12u)) + v_channel)])) + (v_c * b_attributes[((params.point_fade_offset + ((v_ic / 10u) * 12u)) + v_channel)]));
          continuing {
            v_channel += u32(1);
          }
        }
      }
      v_pointFade = (v_pointFade * v_pointMetadata[0i]);
      if ((v_pointMetadata[3i] > 0.0f)) {
        let cw_argument_index_98 = 1i;
        let cw_argument_index_99 = 2i;
        let cw_argument_index_100 = 3i;
        var v_coverage: f32 = f_point_disk_coverage(v_pointMetadata[cw_argument_index_98], v_pointMetadata[cw_argument_index_99], v_pointMetadata[cw_argument_index_100]);
        if ((v_coverage <= 0.0f)) {
          discard;
        }
        v_pointFade = (v_pointFade * v_coverage);
      }
      if ((v_pointMetadata[3i] < 0.0f)) {
        var v_pointFlags: u32 = u32(b_attributes[(v_raster + 49u)]);
        v_spriteMask = ((v_pointFlags >> 2u) & 15u);
        v_spriteDx = precise_divide((-0.5f), v_pointMetadata[3i]);
        var cw_tmp_101: f32;
        if (((v_pointFlags & 64u) != 0u)) {
          cw_tmp_101 = (-v_spriteDx);
        } else {
          cw_tmp_101 = v_spriteDx;
        }
        v_spriteDy = cw_tmp_101;
        var cw_tmp_102: f32;
        if ((v_multisample != 0u)) {
          cw_tmp_102 = (0.5f - v_sampleX);
        } else {
          cw_tmp_102 = 0.0f;
        }
        var v_localX: f32 = (v_pointMetadata[1i] + cw_tmp_102);
        var cw_tmp_103: f32;
        if ((v_multisample != 0u)) {
          cw_tmp_103 = (v_sampleY - 0.5f);
        } else {
          cw_tmp_103 = 0.0f;
        }
        var v_localY: f32 = (v_pointMetadata[2i] + cw_tmp_103);
        v_spriteU = (0.5f + (v_localX * v_spriteDx));
        v_spriteV = (0.5f - (v_localY * v_spriteDy));
      }
  }
      var v_u: f32 = (((v_a * b_vertices[(v_ia + u32(8i))]) + (v_b * b_vertices[(v_ib + u32(8i))])) + (v_c * b_vertices[(v_ic + u32(8i))]));
      var v_v: f32 = (((v_a * b_vertices[(v_ia + u32(9i))]) + (v_b * b_vertices[(v_ib + u32(9i))])) + (v_c * b_vertices[(v_ic + u32(9i))]));
      var v_dudx: f32 = (precise_divide((((v_dax * (b_vertices[(v_ia + u32(8i))] - v_u)) + (v_dbx * (b_vertices[(v_ib + u32(8i))] - v_u))) + (v_dcx * (b_vertices[(v_ic + u32(8i))] - v_u))), v_inv) * f32(b_materials[(v_m + u32(1i))]));
      var v_dvdx: f32 = (precise_divide((((v_dax * (b_vertices[(v_ia + u32(9i))] - v_v)) + (v_dbx * (b_vertices[(v_ib + u32(9i))] - v_v))) + (v_dcx * (b_vertices[(v_ic + u32(9i))] - v_v))), v_inv) * f32(b_materials[(v_m + u32(2i))]));
      var v_dudy: f32 = (precise_divide((((v_day * (b_vertices[(v_ia + u32(8i))] - v_u)) + (v_dby * (b_vertices[(v_ib + u32(8i))] - v_u))) + (v_dcy * (b_vertices[(v_ic + u32(8i))] - v_u))), v_inv) * f32(b_materials[(v_m + u32(1i))]));
      var v_dvdy: f32 = (precise_divide((((v_day * (b_vertices[(v_ia + u32(9i))] - v_v)) + (v_dby * (b_vertices[(v_ib + u32(9i))] - v_v))) + (v_dcy * (b_vertices[(v_ic + u32(9i))] - v_v))), v_inv) * f32(b_materials[(v_m + u32(2i))]));
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
      if ((params.fixed_enabled != u32(0i))) {
        var cw_tmp_104: u32;
        if ((v_front != u32(0i))) {
          cw_tmp_104 = 0u;
        } else {
          cw_tmp_104 = 8u;
        }
        v_fa = ((params.fixed_offset + ((v_ia / u32(10i)) * u32(16i))) + cw_tmp_104);
        var cw_tmp_105: u32;
        if ((v_front != u32(0i))) {
          cw_tmp_105 = 0u;
        } else {
          cw_tmp_105 = 8u;
        }
        v_fb = ((params.fixed_offset + ((v_ib / u32(10i)) * u32(16i))) + cw_tmp_105);
        var cw_tmp_106: u32;
        if ((v_front != u32(0i))) {
          cw_tmp_106 = 0u;
        } else {
          cw_tmp_106 = 8u;
        }
        v_fc = ((params.fixed_offset + ((v_ic / u32(10i)) * u32(16i))) + cw_tmp_106);
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
          var cw_tmp_107: f32;
          if ((v_fixedLit != u32(0i))) {
            cw_tmp_107 = (((v_a * b_attributes[(v_fa + v_k)]) + (v_b * b_attributes[(v_fb + v_k)])) + (v_c * b_attributes[(v_fc + v_k)]));
          } else {
            cw_tmp_107 = (((v_a * b_vertices[((v_ia + u32(4i)) + v_k)]) + (v_b * b_vertices[((v_ib + u32(4i)) + v_k)])) + (v_c * b_vertices[((v_ic + u32(4i)) + v_k)]));
          }
          v_color[v_k] = cw_tmp_107;
          if ((((v_flags & u32(1i)) != u32(0i)) && ((v_flags & u32(547840i)) == u32(0i)))) {
            var cw_tmp_115: f32;
            if (((v_flags & u32(512i)) != u32(0i))) {
              let cw_argument_index_108 = v_m;
              let cw_argument_index_109 = (v_m + u32(1i));
              let cw_argument_index_110 = (v_m + u32(2i));
              let cw_argument_index_111 = (v_m + u32(11i));
              cw_tmp_115 = sample_atlas(0i, b_materials[cw_argument_index_108], b_materials[cw_argument_index_109], b_materials[cw_argument_index_110], v_u, v_v, v_dudx, v_dvdx, v_dudy, v_dvdy, b_materials[cw_argument_index_111], v_k);
            } else {
              let cw_argument_index_112 = v_m;
              let cw_argument_index_113 = (v_m + u32(1i));
              let cw_argument_index_114 = (v_m + u32(2i));
              cw_tmp_115 = sample_legacy_texture(0i, b_materials[cw_argument_index_112], b_materials[cw_argument_index_113], b_materials[cw_argument_index_114], v_u, v_v, v_flags, v_k);
            }
            v_color[v_k] = (v_color[v_k] * cw_tmp_115);
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
        var cw_tmp_116: u32;
        if ((b_attributes[(v_raster + u32(30i))] == 1.0f)) {
          cw_tmp_116 = 1u;
        } else {
          cw_tmp_116 = 0u;
        }
        var v_shadow: u32 = cw_tmp_116;
        var cw_tmp_117: u32;
        if ((b_attributes[(v_raster + u32(30i))] == 2.0f)) {
          cw_tmp_117 = 1u;
        } else {
          cw_tmp_117 = 0u;
        }
        var v_outline: u32 = cw_tmp_117;
        var cw_tmp_118: f32;
        if ((v_outline != 0u)) {
          cw_tmp_118 = (b_attributes[(v_raster + u32(31i))] * 0.5f);
        } else {
          cw_tmp_118 = 0.0f;
        }
        var v_outlineWidth: f32 = cw_tmp_118;
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
              var v_scale: f32 = precise_divide((-b_attributes[(v_raster + u32(28i))]), b_attributes[(v_raster + u32(29i))]);
              v_gu = (v_gu + (b_attributes[(v_raster + u32(31i))] * v_scale));
              v_gv = (v_gv + (b_attributes[(v_raster + u32(32i))] * v_scale));
            }
            var cw_tmp_119: u32;
            if (((v_flags & 1048576u) != 0u)) {
              cw_tmp_119 = 0u;
            } else {
              cw_tmp_119 = 3u;
            }
            var v_channel: u32 = cw_tmp_119;
            if (((v_flags & 2097152u) == 0u)) {
              let cw_argument_index_120 = v_m;
              let cw_argument_index_121 = (v_m + u32(1i));
              let cw_argument_index_122 = (v_m + u32(2i));
              let cw_argument_index_123 = (v_m + u32(11i));
              var v_coverage: f32 = sample_atlas(0i, b_materials[cw_argument_index_120], b_materials[cw_argument_index_121], b_materials[cw_argument_index_122], v_gu, v_gv, v_dudx, v_dvdx, v_dudy, v_dvdy, b_materials[cw_argument_index_123], v_channel);
              if ((v_outline != 0u)) {
                var v_delta: f32 = precise_divide(((1.6f * b_attributes[(v_raster + u32(31i))]) * b_attributes[(v_raster + u32(28i))]), b_attributes[(v_raster + u32(29i))]);
                var v_outer: f32 = v_coverage;
                {
                  var v_oy: u32 = u32(0i);
                  loop {
                    if (!(v_oy < 3u)) { break; }
                    {
                      var v_ox: u32 = u32(0i);
                      loop {
                        if (!(v_ox < 3u)) { break; }
                        let cw_argument_index_124 = v_m;
                        let cw_argument_index_125 = (v_m + u32(1i));
                        let cw_argument_index_126 = (v_m + u32(2i));
                        let cw_argument_index_127 = (v_m + u32(11i));
                        var v_local: f32 = sample_atlas(0i, b_materials[cw_argument_index_124], b_materials[cw_argument_index_125], b_materials[cw_argument_index_126], (v_gu + (((f32(v_ox) - 1.0f) * v_delta) * 0.5f)), (v_gv + (((f32(v_oy) - 1.0f) * v_delta) * 0.5f)), v_dudx, v_dvdx, v_dudy, v_dvdy, b_materials[cw_argument_index_127], v_channel);
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
              var cw_tmp_128: u32;
              if ((v_channel == 0u)) {
                cw_tmp_128 = 1u;
              } else {
                cw_tmp_128 = 0u;
              }
              v_channel = cw_tmp_128;
              var v_dxu: f32 = precise_divide((0.75f * v_dudx), f32(b_materials[(v_m + u32(1i))]));
              var v_dxv: f32 = precise_divide((0.75f * v_dvdx), f32(b_materials[(v_m + u32(2i))]));
              var v_dyu: f32 = precise_divide((0.75f * v_dudy), f32(b_materials[(v_m + u32(1i))]));
              var v_dyv: f32 = precise_divide((0.75f * v_dvdy), f32(b_materials[(v_m + u32(2i))]));
              var v_textureDimension: f32 = b_attributes[(v_raster + u32(29i))];
              var v_glyphDimension: f32 = b_attributes[(v_raster + u32(28i))];
              var v_distance: f32 = precise_divide((sqrt((((v_dxu + v_dyu) * (v_dxu + v_dyu)) + ((v_dxv + v_dyv) * (v_dxv + v_dyv)))) * v_textureDimension), v_glyphDimension);
              var v_nx: u32 = u32(min(4.0f, max(2.0f, floor((v_textureDimension * sqrt(((v_dxu * v_dxu) + (v_dxv * v_dxv))))))));
              var v_ny: u32 = u32(min(4.0f, max(2.0f, floor((v_textureDimension * sqrt(((v_dyu * v_dyu) + (v_dyv * v_dyv))))))));
              var v_blend: f32 = precise_divide((1.5f * v_distance), f32((v_nx * v_ny)));
              var v_halfBlend: f32 = (v_blend * 0.5f);
              let cw_argument_index_129 = v_m;
              let cw_argument_index_130 = (v_m + u32(1i));
              let cw_argument_index_131 = (v_m + u32(2i));
              let cw_argument_index_132 = (v_m + u32(11i));
              var v_center: f32 = sample_texture_lod(0i, b_materials[cw_argument_index_129], b_materials[cw_argument_index_130], b_materials[cw_argument_index_131], v_gu, v_gv, 0.0f, b_materials[cw_argument_index_132], v_channel);
              var cw_tmp_133: f32;
              if ((v_center == 0.0f)) {
                cw_tmp_133 = (-1.0f);
              } else {
                cw_tmp_133 = ((v_center - 0.5f) * precise_divide(1.41f, 6.0f));
              }
              var v_edge: f32 = cw_tmp_133;
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
                          var v_su: f32 = ((((v_gu - (v_dxu * 0.5f)) - (v_dyu * 0.5f)) + precise_divide((v_dxu * f32(v_sx)), f32((v_nx - 1u)))) + precise_divide((v_dyu * f32(v_sy)), f32((v_ny - 1u))));
                          var v_sv: f32 = ((((v_gv - (v_dxv * 0.5f)) - (v_dyv * 0.5f)) + precise_divide((v_dxv * f32(v_sx)), f32((v_nx - 1u)))) + precise_divide((v_dyv * f32(v_sy)), f32((v_ny - 1u))));
                          let cw_argument_index_134 = v_m;
                          let cw_argument_index_135 = (v_m + u32(1i));
                          let cw_argument_index_136 = (v_m + u32(2i));
                          let cw_argument_index_137 = (v_m + u32(11i));
                          var v_value: f32 = sample_texture_lod(0i, b_materials[cw_argument_index_134], b_materials[cw_argument_index_135], b_materials[cw_argument_index_136], v_su, v_sv, 0.0f, b_materials[cw_argument_index_137], v_channel);
                          var cw_tmp_138: f32;
                          if ((v_value == 0.0f)) {
                            cw_tmp_138 = (-1.0f);
                          } else {
                            cw_tmp_138 = ((v_value - 0.5f) * precise_divide(1.41f, 6.0f));
                          }
                          var v_e: f32 = cw_tmp_138;
                          var cw_tmp_139: f32;
                          if ((v_e > v_halfBlend)) {
                            cw_tmp_139 = 1.0f;
                          } else {
                            cw_tmp_139 = 0.0f;
                          }
                          var v_coverage: f32 = cw_tmp_139;
                          if ((((v_e > (-v_halfBlend)) && (v_e <= v_halfBlend)) && (v_blend > 0.0f))) {
                            v_coverage = min(1.0f, max(0.0f, precise_divide((v_e + v_halfBlend), v_blend)));
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
                              var v_transition: f32 = min(1.0f, max(0.0f, precise_divide((v_halfBlend - v_e), v_blend)));
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
                                  v_alpha = precise_divide((v_glyphAlpha * ((v_halfBlend + v_outlineWidth) + v_e)), v_blend);
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
                        v_color[v_k] = precise_divide(v_rgbSum[v_k], v_sum);
                        continuing {
                          v_k += u32(1);
                        }
                      }
                    }
                  }
                  v_color[3i] = precise_divide(v_sum, f32((v_nx * v_ny)));
                }
              }
            }
            if ((v_shadow != 0u)) {
              let cw_argument_index_140 = 3i;
              var cw_tmp_141: f32;
              if (((v_flags & 2097152u) != 0u)) {
                cw_tmp_141 = 0.6f;
              } else {
                cw_tmp_141 = 0.5f;
              }
              var v_alpha: f32 = f_render_power(max(0.0f, v_color[cw_argument_index_140]), cw_tmp_141);
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
          discard;
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
                let cw_argument_index_142 = v_t;
                let cw_argument_index_143 = (v_t + u32(1i));
                let cw_argument_index_144 = (v_t + u32(2i));
                v_samples[((v_unit * 4u) + v_k)] = sample_texture_environment(0i, 0i, v_environment, b_triangles[cw_argument_index_142], b_triangles[cw_argument_index_143], b_triangles[cw_argument_index_144], v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, v_spriteMask, v_spriteU, v_spriteV, v_spriteDx, v_spriteDy);
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
                      var cw_tmp_145: u32;
                      if ((v_k == 3u)) {
                        cw_tmp_145 = 18u;
                      } else {
                        cw_tmp_145 = 12u;
                      }
                      var v_descriptor: u32 = ((v_environment + cw_tmp_145) + v_argument);
                      var v_source: u32 = b_texels[v_descriptor];
                      var v_operand: u32 = b_texels[(v_descriptor + 3u)];
                      var cw_tmp_146: u32;
                      if ((v_operand >= 2u)) {
                        cw_tmp_146 = 3u;
                      } else {
                        cw_tmp_146 = v_k;
                      }
                      var v_channel: u32 = cw_tmp_146;
                      var cw_tmp_151: f32;
                      if ((v_source == 0u)) {
                        cw_tmp_151 = v_samples[((v_unit * 4u) + v_channel)];
                      } else {
                        var cw_tmp_150: f32;
                        if ((v_source == 1u)) {
                          cw_tmp_150 = v_primary[v_channel];
                        } else {
                          var cw_tmp_149: f32;
                          if ((v_source == 2u)) {
                            let cw_argument_index_147 = ((v_environment + 4u) + v_channel);
                            cw_tmp_149 = f_raster_unit_value(bitcast<f32>(b_texels[cw_argument_index_147]));
                          } else {
                            var cw_tmp_148: f32;
                            if ((v_source == 3u)) {
                              cw_tmp_148 = v_color[v_channel];
                            } else {
                              cw_tmp_148 = v_samples[(((v_source - 4u) * 4u) + v_channel)];
                            }
                            cw_tmp_149 = cw_tmp_148;
                          }
                          cw_tmp_150 = cw_tmp_149;
                        }
                        cw_tmp_151 = cw_tmp_150;
                      }
                      var v_value: f32 = cw_tmp_151;
                      var cw_tmp_152: f32;
                      if (((v_operand & 1u) != 0u)) {
                        cw_tmp_152 = (1.0f - v_value);
                      } else {
                        cw_tmp_152 = v_value;
                      }
                      v_arguments[((v_k * 3u) + v_argument)] = cw_tmp_152;
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
                  var cw_tmp_153: u32;
                  if ((v_k == 3u)) {
                    cw_tmp_153 = 9u;
                  } else {
                    cw_tmp_153 = 8u;
                  }
                  var v_operation: u32 = b_texels[(v_environment + cw_tmp_153)];
                  var cw_tmp_157: f32;
                  if (((v_rgbOperation >= 6u) && ((v_k < 3u) || (v_rgbOperation == 7u)))) {
                    cw_tmp_157 = v_dot;
                  } else {
                    let cw_argument_index_154 = (v_k * 3u);
                    let cw_argument_index_155 = ((v_k * 3u) + 1u);
                    let cw_argument_index_156 = ((v_k * 3u) + 2u);
                    cw_tmp_157 = f_combine_texture_arguments(v_arguments[cw_argument_index_154], v_arguments[cw_argument_index_155], v_arguments[cw_argument_index_156], v_operation);
                  }
                  var v_value: f32 = cw_tmp_157;
                  var cw_tmp_158: u32;
                  if (((v_k == 3u) && (v_rgbOperation != 7u))) {
                    cw_tmp_158 = 11u;
                  } else {
                    cw_tmp_158 = 10u;
                  }
                  var v_scale: u32 = b_texels[(v_environment + cw_tmp_158)];
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
                  let cw_argument_index_159 = v_k;
                  let cw_argument_index_160 = ((v_unit * 4u) + v_k);
                  let cw_argument_index_161 = ((v_unit * 4u) + 3u);
                  let cw_argument_index_162 = ((v_environment + 4u) + v_k);
                  let cw_argument_index_163 = (v_environment + 1u);
                  let cw_argument_index_164 = (v_environment + 2u);
                  v_color[v_k] = min(1.0f, max(0.0f, f_texture_environment(v_color[cw_argument_index_159], v_samples[cw_argument_index_160], v_samples[cw_argument_index_161], f_raster_unit_value(bitcast<f32>(b_texels[cw_argument_index_162])), b_texels[cw_argument_index_163], b_texels[cw_argument_index_164], v_k)));
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
        var cw_tmp_167: f32;
        if ((b_texels[(v_data + u32(5i))] != u32(0i))) {
          var cw_tmp_165: f32;
          if (((b_texels[(v_data + u32(7i))] & u32(1i)) != u32(0i))) {
            cw_tmp_165 = 1.0f;
          } else {
            cw_tmp_165 = v_color[3i];
          }
          cw_tmp_167 = cw_tmp_165;
        } else {
          let cw_argument_index_166 = (v_data + u32(6i));
          cw_tmp_167 = bitcast<f32>(b_texels[cw_argument_index_166]);
        }
        var v_alpha: f32 = cw_tmp_167;
        if (((v_flags & u32(1i)) != u32(0i))) {
          let cw_argument_index_168 = v_data;
          let cw_argument_index_169 = (v_data + u32(1i));
          let cw_argument_index_170 = (v_data + u32(2i));
          let cw_argument_index_171 = (v_data + u32(3i));
          v_alpha = (v_alpha * sample_atlas(0i, b_texels[cw_argument_index_168], b_texels[cw_argument_index_169], b_texels[cw_argument_index_170], v_u, v_v, v_dudx, v_dvdx, v_dudy, v_dvdy, b_texels[cw_argument_index_171], u32(3i)));
        }
        var v_function: u32 = b_texels[(v_data + u32(8i))];
        let cw_argument_index_172 = (v_data + u32(4i));
        var v_reference: f32 = bitcast<f32>(b_texels[cw_argument_index_172]);
        if ((((b_texels[(v_data + u32(7i))] & 4u) != 0u) && ((((v_function == 1u) || (v_function == 3u)) || (v_function == 4u)) || (v_function == 6u)))) {
          var v_quadAlpha: array<f32, 4>;
          {
            var v_lane: u32 = u32(0i);
            loop {
              if (!(v_lane < u32(4i))) { break; }
              var v_dx: f32 = ((f32(((v_x - (v_x % 2u)) + (v_lane % 2u))) + 0.5f) - v_px);
              var v_dy: f32 = ((f32(((v_y - (v_y % 2u)) + (v_lane / 2u))) + 0.5f) - v_py);
              var v_qi: f32 = ((v_inv + (v_dx * ((v_dax + v_dbx) + v_dcx))) + (v_dy * ((v_day + v_dby) + v_dcy)));
              var cw_tmp_173: f32;
              if ((abs(v_qi) > 1e-12f)) {
                cw_tmp_173 = v_qi;
              } else {
                cw_tmp_173 = 1e-12f;
              }
              v_qi = cw_tmp_173;
              var v_qa: f32 = precise_divide((((v_a * v_inv) + (v_dx * v_dax)) + (v_dy * v_day)), v_qi);
              var v_qb: f32 = precise_divide((((v_b * v_inv) + (v_dx * v_dbx)) + (v_dy * v_dby)), v_qi);
              var v_qc: f32 = precise_divide((((v_c * v_inv) + (v_dx * v_dcx)) + (v_dy * v_dcy)), v_qi);
              var cw_tmp_176: f32;
              if ((b_texels[(v_data + u32(5i))] != u32(0i))) {
                var cw_tmp_174: f32;
                if (((b_texels[(v_data + u32(7i))] & 1u) != 0u)) {
                  cw_tmp_174 = 1.0f;
                } else {
                  cw_tmp_174 = (((v_qa * b_vertices[(v_ia + u32(7i))]) + (v_qb * b_vertices[(v_ib + u32(7i))])) + (v_qc * b_vertices[(v_ic + u32(7i))]));
                }
                cw_tmp_176 = cw_tmp_174;
              } else {
                let cw_argument_index_175 = (v_data + u32(6i));
                cw_tmp_176 = bitcast<f32>(b_texels[cw_argument_index_175]);
              }
              var v_value: f32 = cw_tmp_176;
              if (((v_flags & 1u) != 0u)) {
                var v_qu: f32 = (((v_qa * b_vertices[(v_ia + u32(8i))]) + (v_qb * b_vertices[(v_ib + u32(8i))])) + (v_qc * b_vertices[(v_ic + u32(8i))]));
                var v_qv: f32 = (((v_qa * b_vertices[(v_ia + u32(9i))]) + (v_qb * b_vertices[(v_ib + u32(9i))])) + (v_qc * b_vertices[(v_ic + u32(9i))]));
                var v_ux: f32 = (precise_divide((((v_dax * (b_vertices[(v_ia + u32(8i))] - v_qu)) + (v_dbx * (b_vertices[(v_ib + u32(8i))] - v_qu))) + (v_dcx * (b_vertices[(v_ic + u32(8i))] - v_qu))), v_qi) * f32(b_texels[(v_data + u32(1i))]));
                var v_vx: f32 = (precise_divide((((v_dax * (b_vertices[(v_ia + u32(9i))] - v_qv)) + (v_dbx * (b_vertices[(v_ib + u32(9i))] - v_qv))) + (v_dcx * (b_vertices[(v_ic + u32(9i))] - v_qv))), v_qi) * f32(b_texels[(v_data + u32(2i))]));
                var v_uy: f32 = (precise_divide((((v_day * (b_vertices[(v_ia + u32(8i))] - v_qu)) + (v_dby * (b_vertices[(v_ib + u32(8i))] - v_qu))) + (v_dcy * (b_vertices[(v_ic + u32(8i))] - v_qu))), v_qi) * f32(b_texels[(v_data + u32(1i))]));
                var v_vy: f32 = (precise_divide((((v_day * (b_vertices[(v_ia + u32(9i))] - v_qv)) + (v_dby * (b_vertices[(v_ib + u32(9i))] - v_qv))) + (v_dcy * (b_vertices[(v_ic + u32(9i))] - v_qv))), v_qi) * f32(b_texels[(v_data + u32(2i))]));
                let cw_argument_index_177 = v_data;
                let cw_argument_index_178 = (v_data + u32(1i));
                let cw_argument_index_179 = (v_data + u32(2i));
                let cw_argument_index_180 = (v_data + u32(3i));
                v_value = (v_value * sample_atlas(0i, b_texels[cw_argument_index_177], b_texels[cw_argument_index_178], b_texels[cw_argument_index_179], v_qu, v_qv, v_ux, v_vx, v_uy, v_vy, b_texels[cw_argument_index_180], u32(3i)));
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
          var v_coverage: f32 = (precise_divide((v_alpha - min(0.9999f, max(0.0001f, v_reference))), max(v_alphaWidth, 0.0001f)) + 0.5f);
          var cw_tmp_181: f32;
          if (((v_function == 1u) || (v_function == 3u))) {
            cw_tmp_181 = (1.0f - v_coverage);
          } else {
            cw_tmp_181 = v_coverage;
          }
          v_alpha = cw_tmp_181;
        } else {
          if ((f_compare_value(v_alpha, v_reference, v_function) == u32(0i))) {
            discard;
          }
        }
        if ((((b_texels[(v_data + u32(7i))] & u32(2i)) != u32(0i)) && (v_alpha <= 0.5f))) {
          discard;
        }
        v_color[0i] = 1.0f;
        v_color[1i] = 1.0f;
        v_color[2i] = 1.0f;
        v_color[3i] = v_alpha;
      }
      if (((v_flags & u32(2048i)) != u32(0i))) {
        var v_data: u32 = b_materials[v_m];
        var v_features: u32 = MATERIAL_FEATURES;
        var v_mode: u32 = MATERIAL_MODE;
        var cw_tmp_182: u32;
        if (((v_features & u32(16777216i)) != u32(0i))) {
          cw_tmp_182 = b_texels[(params.cluster_offset + (v_m / u32(12i)))];
        } else {
          cw_tmp_182 = u32(0i);
        }
        var v_cluster: u32 = cw_tmp_182;
        var v_layers: u32 = MATERIAL_LAYERS;
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
          var cw_tmp_183: i32;
          if (((v_features & u32(512i)) != u32(0i))) {
            cw_tmp_183 = 176i;
          } else {
            cw_tmp_183 = 224i;
          }
          var v_heightMap: u32 = (v_data + u32(cw_tmp_183));
          var v_ix: f32 = max(1e-12f, (((v_inv + v_dax) + v_dbx) + v_dcx));
          var v_iy: f32 = max(1e-12f, (((v_inv + v_day) + v_dby) + v_dcy));
          {
            var v_axis: u32 = u32(0i);
            loop {
              if (!(v_axis < u32(2i))) { break; }
              v_offsets[v_axis] = material_parallax(0i, 0i, v_heightMap, (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_axis);
              v_offsets[(v_axis + u32(2i))] = (material_parallax(0i, 0i, v_heightMap, (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), precise_divide(((v_a * v_inv) + v_dax), v_ix), precise_divide(((v_b * v_inv) + v_dbx), v_ix), precise_divide(((v_c * v_inv) + v_dcx), v_ix), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_ix, v_axis) - v_offsets[v_axis]);
              v_offsets[(v_axis + u32(4i))] = (material_parallax(0i, 0i, v_heightMap, (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), precise_divide(((v_a * v_inv) + v_day), v_iy), precise_divide(((v_b * v_inv) + v_dby), v_iy), precise_divide(((v_c * v_inv) + v_dcy), v_iy), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_iy, v_axis) - v_offsets[v_axis]);
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
              v_normal[v_k] = (((v_a * b_attributes[(((params.falloff_offset + ((v_ia / 10u) * 4u)) + 1u) + v_k)]) + (v_b * b_attributes[(((params.falloff_offset + ((v_ib / 10u) * 4u)) + 1u) + v_k)])) + (v_c * b_attributes[(((params.falloff_offset + ((v_ic / 10u) * 4u)) + 1u) + v_k)]));
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
              let cw_argument_index_184 = 0i;
              let cw_argument_index_185 = 1i;
              let cw_argument_index_186 = 2i;
              let cw_argument_index_187 = 3i;
              let cw_argument_index_188 = 4i;
              let cw_argument_index_189 = 5i;
              v_mapped[v_k] = ((sample_material_layer(0i, 0i, (v_data + u32(176i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, v_offsets[cw_argument_index_184], v_offsets[cw_argument_index_185], v_offsets[cw_argument_index_186], v_offsets[cw_argument_index_187], v_offsets[cw_argument_index_188], v_offsets[cw_argument_index_189]) * 2.0f) - 1.0f);
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
            v_normal[v_k] = precise_divide(v_normal[v_k], v_normalLength);
            v_eye[v_k] = precise_divide(v_position[v_k], v_eyeLength);
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
        let cw_argument_index_190 = (v_data + u32(71i));
        var v_clipDistance: f32 = bitcast<f32>(b_texels[cw_argument_index_190]);
        {
          var v_row: u32 = u32(0i);
          loop {
            if (!(v_row < u32(3i))) { break; }
            let cw_argument_index_191 = (((v_data + u32(52i)) + u32(12i)) + v_row);
            var v_world: f32 = bitcast<f32>(b_texels[cw_argument_index_191]);
            {
              var v_col: u32 = u32(0i);
              loop {
                if (!(v_col < u32(3i))) { break; }
                let cw_argument_index_192 = (((v_data + u32(52i)) + (v_col * u32(4i))) + v_row);
                v_world = (v_world + (bitcast<f32>(b_texels[cw_argument_index_192]) * v_position[v_col]));
                continuing {
                  v_col += u32(1);
                }
              }
            }
            let cw_argument_index_193 = ((v_data + u32(68i)) + v_row);
            v_clipDistance = (v_clipDistance + (v_world * bitcast<f32>(b_texels[cw_argument_index_193])));
            continuing {
              v_row += u32(1);
            }
          }
        }
        if (((v_clipDistance < 0.0f) && ((v_features & u32(16384i)) == u32(0i)))) {
          discard;
        }
        if (((v_features & u32(524288i)) != u32(0i))) {
          var v_particle: u32 = (v_data + b_texels[(v_data + u32(79i))]);
          var v_world: array<f32, 4>;
          {
            var v_row: u32 = u32(0i);
            loop {
              if (!(v_row < u32(4i))) { break; }
              let cw_argument_index_194 = (((v_data + u32(52i)) + u32(12i)) + v_row);
              v_world[v_row] = bitcast<f32>(b_texels[cw_argument_index_194]);
              {
                var v_col: u32 = u32(0i);
                loop {
                  if (!(v_col < u32(3i))) { break; }
                  let cw_argument_index_195 = (((v_data + u32(52i)) + (v_col * u32(4i))) + v_row);
                  v_world[v_row] = (v_world[v_row] + (bitcast<f32>(b_texels[cw_argument_index_195]) * v_position[v_col]));
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
                  let cw_argument_index_196 = (((v_particle + u32(16i)) + (v_col * u32(4i))) + v_row);
                  v_coord[v_row] = (v_coord[v_row] + (bitcast<f32>(b_texels[cw_argument_index_196]) * v_world[v_col]));
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
          let cw_argument_index_197 = (v_particle + u32(12i));
          let cw_argument_index_198 = (v_particle + u32(13i));
          let cw_argument_index_199 = (v_particle + u32(14i));
          let cw_argument_index_200 = (v_particle + u32(15i));
          var v_sceneDepth: f32 = sample_texture_lod(0i, b_texels[cw_argument_index_197], b_texels[cw_argument_index_198], b_texels[cw_argument_index_199], ((v_coord[0i] * 0.5f) + 0.5f), ((v_coord[1i] * 0.5f) + 0.5f), 0.0f, b_texels[cw_argument_index_200], u32(0i));
          var cw_tmp_201: bool;
          if (((v_features & u32(65536i)) != u32(0i))) {
            cw_tmp_201 = (v_coord[2i] < v_sceneDepth);
          } else {
            cw_tmp_201 = (((v_coord[2i] * 0.5f) + 0.5f) > v_sceneDepth);
          }
          if (cw_tmp_201) {
            discard;
          }
        }
        var v_diffuse: array<f32, 4>;
        var v_ambient: array<f32, 3>;
        var v_specular: array<f32, 3>;
        var v_lighting: array<f32, 3>;
        var v_shine: array<f32, 3>;
        var cw_tmp_202: f32;
        if ((((v_features & ((69210112u | 268435456u) | 536870912u)) != 0u) && ((v_features & u32(65536i)) == u32(0i)))) {
          cw_tmp_202 = (((v_a * b_vertices[(v_ia + u32(2i))]) + (v_b * b_vertices[(v_ib + u32(2i))])) + (v_c * b_vertices[(v_ic + u32(2i))]));
        } else {
          cw_tmp_202 = (-v_position[2i]);
        }
        var v_linearDepth: f32 = cw_tmp_202;
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
        // The packet declares whether this material has any shadow cascades.
        // Avoid compiling the full comparison-sampler graph for zero shadows.
        if (HAS_SHADOWS != 0u) {
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
                let cw_argument_index_203 = (((v_descriptor + u32(8i)) + u32(12i)) + v_row);
                v_coords[v_row] = bitcast<f32>(b_texels[cw_argument_index_203]);
                let cw_argument_index_204 = (((v_descriptor + u32(24i)) + u32(12i)) + v_row);
                v_region[v_row] = bitcast<f32>(b_texels[cw_argument_index_204]);
                {
                  var v_col: u32 = u32(0i);
                  loop {
                    if (!(v_col < u32(3i))) { break; }
                    var v_unitNormal: f32 = (((v_a * b_attributes[((((v_ia / u32(10i)) * u32(34i)) + u32(23i)) + v_col)]) + (v_b * b_attributes[((((v_ib / u32(10i)) * u32(34i)) + u32(23i)) + v_col)])) + (v_c * b_attributes[((((v_ic / u32(10i)) * u32(34i)) + u32(23i)) + v_col)]));
                    let cw_argument_index_205 = (v_descriptor + u32(6i));
                    var v_offset: f32 = (v_unitNormal * bitcast<f32>(b_texels[cw_argument_index_205]));
                    let cw_argument_index_206 = (((v_descriptor + u32(8i)) + (v_col * u32(4i))) + v_row);
                    v_coords[v_row] = (v_coords[v_row] + (bitcast<f32>(b_texels[cw_argument_index_206]) * (v_position[v_col] + v_offset)));
                    let cw_argument_index_207 = (((v_descriptor + u32(24i)) + (v_col * u32(4i))) + v_row);
                    v_region[v_row] = (v_region[v_row] + (bitcast<f32>(b_texels[cw_argument_index_207]) * v_position[v_col]));
                    let cw_argument_index_208 = (v_descriptor + u32(6i));
                    var v_normalOffset: f32 = bitcast<f32>(b_texels[cw_argument_index_208]);
                    var v_av: f32 = (((b_attributes[(((v_ia / u32(10i)) * u32(34i)) + v_col)] + (b_attributes[((((v_ia / u32(10i)) * u32(34i)) + u32(23i)) + v_col)] * v_normalOffset)) - v_position[v_col]) - v_offset);
                    var v_bv: f32 = (((b_attributes[(((v_ib / u32(10i)) * u32(34i)) + v_col)] + (b_attributes[((((v_ib / u32(10i)) * u32(34i)) + u32(23i)) + v_col)] * v_normalOffset)) - v_position[v_col]) - v_offset);
                    var v_cv: f32 = (((b_attributes[(((v_ic / u32(10i)) * u32(34i)) + v_col)] + (b_attributes[((((v_ic / u32(10i)) * u32(34i)) + u32(23i)) + v_col)] * v_normalOffset)) - v_position[v_col]) - v_offset);
                    let cw_argument_index_209 = (((v_descriptor + u32(8i)) + (v_col * u32(4i))) + v_row);
                    var v_coefficient: f32 = bitcast<f32>(b_texels[cw_argument_index_209]);
                    v_coordsDx[v_row] = (v_coordsDx[v_row] + precise_divide((v_coefficient * (((v_dax * v_av) + (v_dbx * v_bv)) + (v_dcx * v_cv))), v_inv));
                    v_coordsDy[v_row] = (v_coordsDy[v_row] + precise_divide((v_coefficient * (((v_day * v_av) + (v_dby * v_bv)) + (v_dcy * v_cv))), v_inv));
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
            let cw_argument_index_210 = 3i;
            if ((abs(v_coords[cw_argument_index_210]) < 1e-12f)) {
              continue;
            }
            var v_sx: f32 = precise_divide(v_coords[0i], v_coords[3i]);
            var v_sy: f32 = precise_divide(v_coords[1i], v_coords[3i]);
            var v_sz: f32 = precise_divide(v_coords[2i], v_coords[3i]);
            if (((((v_sx <= 0.0f) || (v_sx >= 1.0f)) || (v_sy <= 0.0f)) || (v_sy >= 1.0f))) {
              continue;
            }
            v_shadowing = min(v_shadowing, sample_shadow_compare(0i, v_descriptor, v_sx, v_sy, v_sz, (precise_divide((v_coordsDx[0i] - (v_sx * v_coordsDx[3i])), v_coords[3i]) * f32(b_texels[(v_descriptor + u32(1i))])), (precise_divide((v_coordsDx[1i] - (v_sy * v_coordsDx[3i])), v_coords[3i]) * f32(b_texels[(v_descriptor + u32(2i))])), (precise_divide((v_coordsDy[0i] - (v_sx * v_coordsDy[3i])), v_coords[3i]) * f32(b_texels[(v_descriptor + u32(1i))])), (precise_divide((v_coordsDy[1i] - (v_sy * v_coordsDy[3i])), v_coords[3i]) * f32(b_texels[(v_descriptor + u32(2i))]))));
            if (((b_texels[(v_descriptor + u32(5i))] & u32(2i)) != u32(0i))) {
              v_shadowDebug[b_texels[(v_descriptor + u32(7i))]] = (v_shadowDebug[b_texels[(v_descriptor + u32(7i))]] + 0.1f);
            }
            v_shadowDone = select(u32(0), u32(1), ((((((v_sx > 0.05f) && (v_sx < 0.95f)) && (v_sy > 0.05f)) && (v_sy < 0.95f)) && (v_sz > 0.0f)) && (v_sz < 1.0f)));
            if (((b_texels[(v_descriptor + u32(5i))] & u32(1i)) != u32(0i))) {
              let cw_argument_index_211 = 3i;
              if ((abs(v_region[cw_argument_index_211]) < 1e-12f)) {
                v_shadowDone = u32(0i);
              } else {
                v_shadowDone = select(u32(0), u32(1), ((((((v_shadowDone != u32(0i)) && (precise_divide(v_region[0i], v_region[3i]) > (-1.0f))) && (precise_divide(v_region[0i], v_region[3i]) < 1.0f)) && (precise_divide(v_region[1i], v_region[3i]) > (-1.0f))) && (precise_divide(v_region[1i], v_region[3i]) < 1.0f)) && (precise_divide(v_region[2i], v_region[3i]) < 1.0f)));
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
            let cw_argument_index_212 = (v_data + u32(326i));
            var v_start: f32 = bitcast<f32>(b_texels[cw_argument_index_212]);
            let cw_argument_index_213 = (v_data + u32(327i));
            var v_end: f32 = bitcast<f32>(b_texels[cw_argument_index_213]);
            var v_fade: f32 = min(1.0f, max(0.0f, precise_divide((v_linearDepth - v_start), max(0.000001f, (v_end - v_start)))));
            v_shadowing = ((v_shadowing * (1.0f - v_fade)) + v_fade);
          }
        }
        }
        let cw_argument_index_214 = (v_data + u32(46i));
        var v_shininess: f32 = max(0.0001f, bitcast<f32>(b_texels[cw_argument_index_214]));
        if (((v_features & u32(8192i)) != u32(0i))) {
          v_shininess = 128.0f;
        }
        if (((v_layers & u32(32i)) != u32(0i))) {
          v_shininess = max(0.0001f, (255.0f * sample_layer(0i, 0i, (v_data + u32(200i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i))));
        }
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(4i))) { break; }
            var cw_tmp_216: f32;
            if (((v_mode == u32(2i)) || (v_mode == u32(4i)))) {
              cw_tmp_216 = v_color[v_k];
            } else {
              let cw_argument_index_215 = ((v_data + u32(12i)) + v_k);
              cw_tmp_216 = bitcast<f32>(b_texels[cw_argument_index_215]);
            }
            v_diffuse[v_k] = cw_tmp_216;
            continuing {
              v_k += u32(1);
            }
          }
        }
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            var cw_tmp_218: f32;
            if (((v_mode == u32(2i)) || (v_mode == u32(3i)))) {
              cw_tmp_218 = v_color[v_k];
            } else {
              let cw_argument_index_217 = ((v_data + u32(8i)) + v_k);
              cw_tmp_218 = bitcast<f32>(b_texels[cw_argument_index_217]);
            }
            v_ambient[v_k] = cw_tmp_218;
            var cw_tmp_220: f32;
            if ((v_mode == u32(5i))) {
              cw_tmp_220 = v_color[v_k];
            } else {
              let cw_argument_index_219 = ((v_data + u32(16i)) + v_k);
              cw_tmp_220 = bitcast<f32>(b_texels[cw_argument_index_219]);
            }
            v_specular[v_k] = cw_tmp_220;
            if ((((v_features & 536870912u) != 0u) && ((v_layers & 16u) != 0u))) {
              v_specular[v_k] = (v_specular[v_k] * sample_layer(0i, 0i, (v_data + u32(176i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i)));
            }
            if (((v_layers & u32(32i)) != u32(0i))) {
              v_specular[v_k] = sample_layer(0i, 0i, (v_data + u32(200i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k);
            }
            if (((v_features & u32(8192i)) != u32(0i))) {
              let cw_argument_index_221 = 0i;
              let cw_argument_index_222 = 1i;
              let cw_argument_index_223 = 2i;
              let cw_argument_index_224 = 3i;
              let cw_argument_index_225 = 4i;
              let cw_argument_index_226 = 5i;
              v_specular[v_k] = sample_material_layer(0i, 0i, (v_data + u32(224i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i), v_offsets[cw_argument_index_221], v_offsets[cw_argument_index_222], v_offsets[cw_argument_index_223], v_offsets[cw_argument_index_224], v_offsets[cw_argument_index_225], v_offsets[cw_argument_index_226]);
            }
            var cw_tmp_228: f32;
            if ((v_mode == u32(1i))) {
              cw_tmp_228 = v_color[v_k];
            } else {
              let cw_argument_index_227 = ((v_data + u32(20i)) + v_k);
              cw_tmp_228 = bitcast<f32>(b_texels[cw_argument_index_227]);
            }
            let cw_argument_index_229 = (v_data + u32(47i));
            v_lighting[v_k] = (cw_tmp_228 * bitcast<f32>(b_texels[cw_argument_index_229]));
            if ((((v_features & 536870912u) != 0u) && ((v_layers & 8u) != 0u))) {
              v_lighting[v_k] = (v_lighting[v_k] * sample_layer(0i, 0i, (v_data + u32(152i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k));
            }
            v_shine[v_k] = 0.0f;
            continuing {
              v_k += u32(1);
            }
          }
        }
        let cw_argument_index_230 = 2i;
        var v_cell: u32 = cluster_cell(0i, v_cluster, v_px, (f32(params.height) - v_py), v_position[cw_argument_index_230]);
        var cw_tmp_231: u32;
        if ((v_cluster != u32(0i))) {
          cw_tmp_231 = cluster_count(0i, v_cluster, v_cell);
        } else {
          cw_tmp_231 = b_texels[(v_data + u32(6i))];
        }
        var v_pointCount: u32 = cw_tmp_231;
        if (((v_features & (8388608u | 268435456u | 16384u)) == 0u)) {
          {
            var v_light: u32 = u32(0i);
            loop {
              if (!(v_light <= v_pointCount)) { break; }
              var cw_tmp_233: u32;
              if ((v_light == u32(0i))) {
                cw_tmp_233 = (v_data + u32(24i));
              } else {
                var cw_tmp_232: u32;
                if ((v_cluster != u32(0i))) {
                  cw_tmp_232 = cluster_light(0i, v_cluster, v_cell, (v_light - u32(1i)));
                } else {
                  cw_tmp_232 = ((v_data + b_texels[(v_data + u32(7i))]) + ((v_light - u32(1i)) * u32(16i)));
                }
                cw_tmp_233 = cw_tmp_232;
              }
              var v_record: u32 = cw_tmp_233;
              var v_direction: array<f32, 3>;
              var v_distance: f32 = 0.0f;
              {
                var v_k: u32 = u32(0i);
                loop {
                  if (!(v_k < u32(3i))) { break; }
                  let cw_argument_index_234 = (v_record + v_k);
                  var cw_tmp_235: f32;
                  if ((v_light == u32(0i))) {
                    cw_tmp_235 = 0.0f;
                  } else {
                    cw_tmp_235 = v_position[v_k];
                  }
                  v_direction[v_k] = (bitcast<f32>(b_texels[cw_argument_index_234]) - cw_tmp_235);
                  v_distance = (v_distance + (v_direction[v_k] * v_direction[v_k]));
                  continuing {
                    v_k += u32(1);
                  }
                }
              }
              v_distance = sqrt(max(v_distance, 1e-12f));
              var v_attenuation: f32 = 1.0f;
              if ((v_light != u32(0i))) {
                let cw_argument_index_236 = (v_record + u32(15i));
                var v_radius: f32 = bitcast<f32>(b_texels[cw_argument_index_236]);
                if (((((v_features & u32(1i)) == u32(0i)) || (v_cluster != u32(0i))) && (v_distance > v_radius))) {
                  continue;
                }
                if ((v_cluster != u32(0i))) {
                  let cw_argument_index_237 = 2i;
                  v_attenuation = (v_attenuation * cluster_distance_fade(0i, v_cluster, v_position[cw_argument_index_237], v_radius));
                }
                let cw_argument_index_238 = (v_record + u32(3i));
                let cw_argument_index_239 = (v_record + u32(7i));
                let cw_argument_index_240 = (v_record + u32(11i));
                var v_denominator: f32 = ((bitcast<f32>(b_texels[cw_argument_index_238]) + (bitcast<f32>(b_texels[cw_argument_index_239]) * v_distance)) + ((bitcast<f32>(b_texels[cw_argument_index_240]) * v_distance) * v_distance));
                v_attenuation = precise_divide(v_attenuation, max(v_denominator, 1e-12f));
                if ((((v_features & u32(1i)) == u32(0i)) || (v_cluster != u32(0i)))) {
                  var v_fade: f32 = min(1.0f, max(0.0f, precise_divide((precise_divide(v_distance, max(v_radius, 0.000001f)) - 0.75f), 0.25f)));
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
                  v_direction[v_k] = precise_divide(v_direction[v_k], v_distance);
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
                    v_spec = (v_spec + precise_divide((v_normal[v_k] * v_halfVector[v_k]), v_halfLength));
                    continuing {
                      v_k += u32(1);
                    }
                  }
                }
                v_spec = f_render_power(max(v_spec, 0.0f), v_shininess);
              }
              {
                var v_k: u32 = u32(0i);
                loop {
                  if (!(v_k < u32(3i))) { break; }
                  let cw_argument_index_241 = ((v_record + u32(8i)) + v_k);
                  var cw_tmp_242: f32;
                  if ((v_light == u32(0i))) {
                    cw_tmp_242 = v_shadowing;
                  } else {
                    cw_tmp_242 = 1.0f;
                  }
                  let cw_argument_index_243 = ((v_record + u32(4i)) + v_k);
                  v_lighting[v_k] = (v_lighting[v_k] + (((((v_diffuse[v_k] * bitcast<f32>(b_texels[cw_argument_index_241])) * max(v_lambert, 0.0f)) * cw_tmp_242) + (v_ambient[v_k] * bitcast<f32>(b_texels[cw_argument_index_243]))) * v_attenuation));
                  let cw_argument_index_244 = ((v_record + u32(12i)) + v_k);
                  let cw_argument_index_245 = (v_data + u32(48i));
                  var cw_tmp_246: f32;
                  if ((v_light == u32(0i))) {
                    cw_tmp_246 = v_shadowing;
                  } else {
                    cw_tmp_246 = 1.0f;
                  }
                  v_shine[v_k] = (v_shine[v_k] + (((((v_specular[v_k] * bitcast<f32>(b_texels[cw_argument_index_244])) * v_spec) * v_attenuation) * bitcast<f32>(b_texels[cw_argument_index_245])) * cw_tmp_246));
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
              var v_la: u32 = (params.lighting_offset + ((v_ia / u32(10i)) * u32(12i)));
              var v_lb: u32 = (params.lighting_offset + ((v_ib / u32(10i)) * u32(12i)));
              var v_lc: u32 = (params.lighting_offset + ((v_ic / u32(10i)) * u32(12i)));
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
              v_envUV[v_axis] = environment_coordinate(0i, 0i, v_data, (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_axis);
              v_envDx[v_axis] = (environment_coordinate(0i, 0i, v_data, (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), precise_divide(((v_a * v_inv) + v_dax), v_ix), precise_divide(((v_b * v_inv) + v_dbx), v_ix), precise_divide(((v_c * v_inv) + v_dcx), v_ix), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_ix, v_axis) - v_envUV[v_axis]);
              v_envDy[v_axis] = (environment_coordinate(0i, 0i, v_data, (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), precise_divide(((v_a * v_inv) + v_day), v_iy), precise_divide(((v_b * v_inv) + v_dby), v_iy), precise_divide(((v_c * v_inv) + v_dcy), v_iy), v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_iy, v_axis) - v_envUV[v_axis]);
              continuing {
                v_axis += u32(1);
              }
            }
          }
          var v_width: f32 = f32(b_texels[(v_data + u32(249i))]);
          var v_height: f32 = f32(b_texels[(v_data + u32(250i))]);
          var v_luma: f32 = 1.0f;
          if (((v_layers & u32(256i)) != u32(0i))) {
            let cw_argument_index_247 = (v_data + u32(77i));
            let cw_argument_index_248 = (v_data + u32(78i));
            v_luma = min(1.0f, max(0.0f, ((sample_layer(0i, 0i, (v_data + u32(272i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(2i)) * bitcast<f32>(b_texels[cw_argument_index_247])) + bitcast<f32>(b_texels[cw_argument_index_248]))));
          }
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              let cw_argument_index_249 = (v_data + u32(248i));
              let cw_argument_index_250 = (v_data + u32(249i));
              let cw_argument_index_251 = (v_data + u32(250i));
              let cw_argument_index_252 = 0i;
              let cw_argument_index_253 = 1i;
              let cw_argument_index_254 = (v_data + u32(251i));
              let cw_argument_index_255 = ((v_data + u32(73i)) + v_k);
              v_environment[v_k] = ((sample_atlas(0i, b_texels[cw_argument_index_249], b_texels[cw_argument_index_250], b_texels[cw_argument_index_251], v_envUV[cw_argument_index_252], v_envUV[cw_argument_index_253], (v_envDx[0i] * v_width), (v_envDx[1i] * v_height), (v_envDy[0i] * v_width), (v_envDy[1i] * v_height), b_texels[cw_argument_index_254], v_k) * bitcast<f32>(b_texels[cw_argument_index_255])) * v_luma);
              if (((v_layers & u32(512i)) != u32(0i))) {
                v_environment[v_k] = (v_environment[v_k] * sample_layer(0i, 0i, (v_data + u32(296i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k));
              }
              continuing {
                v_k += u32(1);
              }
            }
          }
        }
        var cw_tmp_256: f32;
        if (((v_layers & u32(4i)) != u32(0i))) {
          cw_tmp_256 = (sample_layer(0i, 0i, (v_data + u32(128i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i)) * v_diffuse[3i]);
        } else {
          cw_tmp_256 = 0.0f;
        }
        var v_decalAlpha: f32 = cw_tmp_256;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(4i))) { break; }
            var cw_tmp_263: f32;
            if (((v_flags & u32(1i)) != u32(0i))) {
              let cw_argument_index_257 = 0i;
              let cw_argument_index_258 = 1i;
              let cw_argument_index_259 = 2i;
              let cw_argument_index_260 = 3i;
              let cw_argument_index_261 = 4i;
              let cw_argument_index_262 = 5i;
              cw_tmp_263 = sample_material_layer(0i, 0i, (v_data + u32(224i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, v_offsets[cw_argument_index_257], v_offsets[cw_argument_index_258], v_offsets[cw_argument_index_259], v_offsets[cw_argument_index_260], v_offsets[cw_argument_index_261], v_offsets[cw_argument_index_262]);
            } else {
              cw_tmp_263 = 1.0f;
            }
            var v_sample: f32 = cw_tmp_263;
            if (((v_k == u32(3i)) && ((v_features & u32(5120i)) != u32(0i)))) {
              v_sample = 1.0f;
            }
            if (((v_layers & u32(1i)) != u32(0i))) {
              v_sample = (v_sample * sample_layer(0i, 0i, (v_data + u32(80i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k));
            }
            if ((v_k < u32(3i))) {
              if (((v_layers & u32(2i)) != u32(0i))) {
                v_sample = (v_sample * (2.0f * sample_layer(0i, 0i, (v_data + u32(104i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k)));
              }
              if (((v_layers & u32(4i)) != u32(0i))) {
                v_sample = ((v_sample * (1.0f - v_decalAlpha)) + (sample_layer(0i, 0i, (v_data + u32(128i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k) * v_decalAlpha));
              }
              if (((v_features & u32(2048i)) != u32(0i))) {
                v_sample = (v_sample + v_environment[v_k]);
              }
              var cw_tmp_266: f32;
              if (((v_features & u32(2i)) != u32(0i))) {
                let cw_argument_index_264 = v_k;
                cw_tmp_266 = min(1.0f, max(v_lighting[cw_argument_index_264], 0.0f));
              } else {
                let cw_argument_index_265 = v_k;
                cw_tmp_266 = max(v_lighting[cw_argument_index_265], 0.0f);
              }
              v_color[v_k] = ((v_sample * cw_tmp_266) + v_shine[v_k]);
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
                v_color[v_k] = (v_color[v_k] + sample_layer(0i, 0i, (v_data + u32(152i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k));
              }
            } else {
              var cw_tmp_267: f32;
              if (((v_features & (16384u | 1073741824u)) != 0u)) {
                cw_tmp_267 = 1.0f;
              } else {
                cw_tmp_267 = v_diffuse[v_k];
              }
              v_color[v_k] = (v_sample * cw_tmp_267);
            }
            continuing {
              v_k += u32(1);
            }
          }
        }
        if (((v_features & u32(67108864i)) != u32(0i))) {
          var v_depth: f32 = (((v_a * b_attributes[(((v_ia / u32(10i)) * u32(34i)) + u32(9i))]) + (v_b * b_attributes[(((v_ib / u32(10i)) * u32(34i)) + u32(9i))])) + (v_c * b_attributes[(((v_ic / u32(10i)) * u32(34i)) + u32(9i))]));
          let cw_argument_index_268 = (v_data + u32(320i));
          var v_start: f32 = bitcast<f32>(b_texels[cw_argument_index_268]);
          let cw_argument_index_269 = (v_data + u32(321i));
          var v_end: f32 = bitcast<f32>(b_texels[cw_argument_index_269]);
          var v_fade: f32 = min(1.0f, max(0.0f, precise_divide((v_depth - v_start), max(0.000001f, (v_end - v_start)))));
          v_color[3i] = (v_color[3i] * (1.0f - ((v_fade * v_fade) * (3.0f - (2.0f * v_fade)))));
        }
        if (((v_layers & u32(1024i)) != u32(0i))) {
          v_color[3i] = (v_color[3i] * sample_layer(0i, 0i, (v_data + u32(328i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(3i)));
        }
        if ((((v_features & u32(64i)) != u32(0i)) && ((v_layers & u32(1i)) != u32(0i)))) {
          var cw_tmp_270: i32;
          if (((v_features & u32(128i)) != u32(0i))) {
            cw_tmp_270 = 5i;
          } else {
            cw_tmp_270 = 4i;
          }
          v_color[3i] = (v_color[3i] * (1.0f + (0.25f * sample_layer(0i, 0i, (v_data + u32(80i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(cw_tmp_270)))));
        }
        if (((((v_features & u32(64i)) != u32(0i)) && ((v_flags & u32(1i)) != u32(0i))) && ((v_features & u32(5120i)) == u32(0i)))) {
          var cw_tmp_271: i32;
          if (((v_features & u32(128i)) != u32(0i))) {
            cw_tmp_271 = 5i;
          } else {
            cw_tmp_271 = 4i;
          }
          let cw_argument_index_272 = 0i;
          let cw_argument_index_273 = 1i;
          let cw_argument_index_274 = 2i;
          let cw_argument_index_275 = 3i;
          let cw_argument_index_276 = 4i;
          let cw_argument_index_277 = 5i;
          var v_coverageLod: f32 = sample_material_layer(0i, 0i, (v_data + u32(224i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, u32(cw_tmp_271), v_offsets[cw_argument_index_272], v_offsets[cw_argument_index_273], v_offsets[cw_argument_index_274], v_offsets[cw_argument_index_275], v_offsets[cw_argument_index_276], v_offsets[cw_argument_index_277]);
          v_color[3i] = (v_color[3i] * (1.0f + (max(v_coverageLod, 0.0f) * 0.25f)));
        }
        if (((v_features & 268435456u) != 0u)) {
          v_color[3i] = (v_color[3i] * (((v_a * b_attributes[(params.falloff_offset + ((v_ia / 10u) * 4u))]) + (v_b * b_attributes[(params.falloff_offset + ((v_ib / 10u) * 4u))])) + (v_c * b_attributes[(params.falloff_offset + ((v_ic / 10u) * 4u))])));
        }
        if (((v_features & u32(4194304i)) == u32(0i))) {
          let cw_argument_index_278 = (v_data + u32(49i));
          var v_reference: f32 = bitcast<f32>(b_texels[cw_argument_index_278]);
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
                var cw_tmp_279: f32;
                if ((abs(v_qi) > 1e-12f)) {
                  cw_tmp_279 = v_qi;
                } else {
                  cw_tmp_279 = 1e-12f;
                }
                v_qi = cw_tmp_279;
                var v_qa: f32 = precise_divide((((v_a * v_inv) + (v_dx * v_dax)) + (v_dy * v_day)), v_qi);
                var v_qb: f32 = precise_divide((((v_b * v_inv) + (v_dx * v_dbx)) + (v_dy * v_dby)), v_qi);
                var v_qc: f32 = precise_divide((((v_c * v_inv) + (v_dx * v_dcx)) + (v_dy * v_dcy)), v_qi);
                v_quadAlpha[v_lane] = material_alpha(0i, 0i, 0i, v_data, v_flags, params.falloff_offset, (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_qa, v_qb, v_qc, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_qi);
                continuing {
                  v_lane += u32(1);
                }
              }
            }
            var v_row: u32 = ((v_y % 2u) * 2u);
            var v_column: u32 = (v_x % 2u);
            var v_alphaWidth: f32 = (abs((v_quadAlpha[(v_row + u32(1i))] - v_quadAlpha[v_row])) + abs((v_quadAlpha[(v_column + u32(2i))] - v_quadAlpha[v_column])));
            var v_coverage: f32 = (precise_divide((v_color[3i] - min(0.9999f, max(0.0001f, v_reference))), max(v_alphaWidth, 0.0001f)) + 0.5f);
            var cw_tmp_280: f32;
            if (((v_function == 1u) || (v_function == 3u))) {
              cw_tmp_280 = (1.0f - v_coverage);
            } else {
              cw_tmp_280 = v_coverage;
            }
            v_color[3i] = cw_tmp_280;
          } else {
            let cw_argument_index_281 = 3i;
            if ((f_compare_value(v_color[cw_argument_index_281], v_reference, v_function) == u32(0i))) {
              discard;
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
              v_footprint[v_k] = precise_divide((((v_dax * v_va) + (v_dbx * v_vb)) + (v_dcx * v_vc)), v_inv);
              v_footprint[(u32(3i) + v_k)] = precise_divide((((v_day * v_va) + (v_dby * v_vb)) + (v_dcy * v_vc)), v_inv);
              continuing {
                v_k += u32(1);
              }
            }
          }
          shade_water(0i, v_data, &v_position, &v_footprint, v_shadowing, precise_divide((f32(v_x) + 0.5f), f32(params.width)), (1.0f - precise_divide((f32(v_y) + 0.5f), f32(params.height))), v_z, v_linearDepth, &v_color, &v_waterNormal, v_cluster, v_px, (f32(params.height) - v_py));
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
          let cw_argument_index_282 = (v_distortion + u32(5i));
          var v_ratio: f32 = max(0.000001f, bitcast<f32>(b_texels[cw_argument_index_282]));
          let cw_argument_index_283 = v_distortion;
          let cw_argument_index_284 = (v_distortion + u32(1i));
          let cw_argument_index_285 = (v_distortion + u32(2i));
          let cw_argument_index_286 = (v_distortion + u32(3i));
          var v_sceneDepth: f32 = sample_texture_lod(0i, b_texels[cw_argument_index_283], b_texels[cw_argument_index_284], b_texels[cw_argument_index_285], precise_divide(precise_divide((f32(v_x) + 0.5f), f32(params.width)), v_ratio), precise_divide((1.0f - precise_divide((f32(v_y) + 0.5f), f32(params.height))), v_ratio), 0.0f, b_texels[cw_argument_index_286], u32(0i));
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(4i))) { break; }
              let cw_argument_index_287 = 0i;
              let cw_argument_index_288 = 1i;
              let cw_argument_index_289 = 2i;
              let cw_argument_index_290 = 3i;
              let cw_argument_index_291 = 4i;
              let cw_argument_index_292 = 5i;
              v_color[v_k] = sample_material_layer(0i, 0i, (v_data + u32(224i)), (v_ia / u32(10i)), (v_ib / u32(10i)), (v_ic / u32(10i)), v_a, v_b, v_c, v_dax, v_dbx, v_dcx, v_day, v_dby, v_dcy, v_inv, v_k, v_offsets[cw_argument_index_287], v_offsets[cw_argument_index_288], v_offsets[cw_argument_index_289], v_offsets[cw_argument_index_290], v_offsets[cw_argument_index_291], v_offsets[cw_argument_index_292]);
              continuing {
                v_k += u32(1);
              }
            }
          }
          v_color[3i] = (v_color[3i] * v_diffuse[3i]);
          if ((v_color[3i] < 0.1f)) {
            discard;
          }
          var cw_tmp_293: bool;
          if (((v_features & u32(65536i)) != u32(0i))) {
            cw_tmp_293 = (v_z < v_sceneDepth);
          } else {
            cw_tmp_293 = (v_z > v_sceneDepth);
          }
          var v_occluded: u32 = select(u32(0), u32(1), cw_tmp_293);
          var cw_tmp_295: f32;
          if ((v_occluded != u32(0i))) {
            cw_tmp_295 = 0.0f;
          } else {
            let cw_argument_index_294 = (v_distortion + u32(4i));
            cw_tmp_295 = (bitcast<f32>(b_texels[cw_argument_index_294]) * v_color[3i]);
          }
          var v_strength: f32 = cw_tmp_295;
          v_color[0i] = (((v_color[0i] * 2.0f) - 1.0f) * v_strength);
          v_color[1i] = (((v_color[1i] * 2.0f) - 1.0f) * v_strength);
          var cw_tmp_296: f32;
          if ((v_occluded != u32(0i))) {
            cw_tmp_296 = 1.0f;
          } else {
            cw_tmp_296 = 0.0f;
          }
          v_color[2i] = cw_tmp_296;
          v_writeNormal = u32(0i);
        }
        if ((((v_features & u32(32i)) != u32(0i)) && ((v_features & u32(4194304i)) == u32(0i)))) {
          var cw_tmp_297: f32;
          if (((v_features & ((67112960u | 268435456u) | 536870912u)) != 0u)) {
            cw_tmp_297 = (((v_a * b_attributes[(((v_ia / u32(10i)) * u32(34i)) + u32(9i))]) + (v_b * b_attributes[(((v_ib / u32(10i)) * u32(34i)) + u32(9i))])) + (v_c * b_attributes[(((v_ic / u32(10i)) * u32(34i)) + u32(9i))]));
          } else {
            cw_tmp_297 = v_eyeLength;
          }
          var v_euclidean: f32 = cw_tmp_297;
          var cw_tmp_298: f32;
          if (((v_features & u32(4i)) != u32(0i))) {
            cw_tmp_298 = v_euclidean;
          } else {
            cw_tmp_298 = abs(v_linearDepth);
          }
          var v_distance: f32 = cw_tmp_298;
          let cw_argument_index_299 = (v_data + u32(44i));
          var v_start: f32 = bitcast<f32>(b_texels[cw_argument_index_299]);
          let cw_argument_index_300 = (v_data + u32(45i));
          var v_end: f32 = bitcast<f32>(b_texels[cw_argument_index_300]);
          var cw_tmp_301: f32;
          if (((v_features & u32(8i)) != u32(0i))) {
            cw_tmp_301 = (1.0f - exp(precise_divide(((-2.0f) * max(0.0f, (v_distance - (v_start * 0.5f)))), max(0.000001f, (v_end - (v_start * 0.5f))))));
          } else {
            cw_tmp_301 = min(1.0f, max(0.0f, precise_divide((v_distance - v_start), max(0.000001f, (v_end - v_start)))));
          }
          var v_fog: f32 = cw_tmp_301;
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              var cw_tmp_303: f32;
              if (((v_features & u32(16i)) != u32(0i))) {
                cw_tmp_303 = 0.0f;
              } else {
                let cw_argument_index_302 = ((v_data + u32(40i)) + v_k);
                cw_tmp_303 = (bitcast<f32>(b_texels[cw_argument_index_302]) * v_fog);
              }
              v_color[v_k] = ((v_color[v_k] * (1.0f - v_fog)) + cw_tmp_303);
              continuing {
                v_k += u32(1);
              }
            }
          }
          if (((v_features & u32(1048576i)) != u32(0i))) {
            var v_sky: u32 = ((v_data + b_texels[(v_data + u32(79i))]) + u32(32i));
            let cw_argument_index_304 = (v_sky + u32(4i));
            var v_far: f32 = bitcast<f32>(b_texels[cw_argument_index_304]);
            let cw_argument_index_305 = (v_sky + u32(5i));
            var v_begin: f32 = bitcast<f32>(b_texels[cw_argument_index_305]);
            var v_fade: f32 = min(1.0f, max(0.0f, precise_divide((v_far - v_distance), max(0.000001f, (v_far - v_begin)))));
            v_fade = (v_fade * v_fade);
            {
              var v_k: u32 = u32(0i);
              loop {
                if (!(v_k < u32(3i))) { break; }
                var cw_tmp_310: f32;
                if (((v_features & u32(16i)) != u32(0i))) {
                  cw_tmp_310 = 0.0f;
                } else {
                  let cw_argument_index_306 = v_sky;
                  let cw_argument_index_307 = (v_sky + u32(1i));
                  let cw_argument_index_308 = (v_sky + u32(2i));
                  let cw_argument_index_309 = (v_sky + u32(3i));
                  cw_tmp_310 = sample_texture_lod(0i, b_texels[cw_argument_index_306], b_texels[cw_argument_index_307], b_texels[cw_argument_index_308], precise_divide((f32(v_x) + 0.5f), f32(params.width)), (1.0f - precise_divide((f32(v_y) + 0.5f), f32(params.height))), 0.0f, b_texels[cw_argument_index_309], v_k);
                }
                var v_background: f32 = cw_tmp_310;
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
          let cw_argument_index_311 = v_particle;
          let cw_argument_index_312 = (v_particle + u32(1i));
          let cw_argument_index_313 = (v_particle + u32(2i));
          let cw_argument_index_314 = (v_particle + u32(3i));
          var v_sceneDepth: f32 = sample_texture_lod(0i, b_texels[cw_argument_index_311], b_texels[cw_argument_index_312], b_texels[cw_argument_index_313], precise_divide((f32(v_x) + 0.5f), f32(params.width)), (1.0f - precise_divide((f32(v_y) + 0.5f), f32(params.height))), 0.0f, b_texels[cw_argument_index_314], u32(0i));
          if (((v_features & u32(65536i)) != u32(0i))) {
            v_sceneDepth = (1.0f - v_sceneDepth);
          }
          let cw_argument_index_315 = (v_particle + u32(4i));
          var v_near: f32 = bitcast<f32>(b_texels[cw_argument_index_315]);
          let cw_argument_index_316 = (v_particle + u32(5i));
          var v_far: f32 = bitcast<f32>(b_texels[cw_argument_index_316]);
          v_sceneDepth = precise_divide((v_near * v_far), (((v_far - v_near) * v_sceneDepth) - v_far));
          let cw_argument_index_317 = (v_particle + u32(6i));
          var v_size: f32 = bitcast<f32>(b_texels[cw_argument_index_317]);
          let cw_argument_index_318 = (v_particle + u32(8i));
          var v_falloff: f32 = bitcast<f32>(b_texels[cw_argument_index_318]);
          var v_delta: f32 = min(1.0f, max(0.0f, precise_divide((v_position[2i] - v_sceneDepth), max(0.000001f, (v_size * 0.33f)))));
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
            var v_fade: f32 = min(1.0f, max(0.0f, precise_divide(v_eyeLength, max(v_falloff, 0.000001f))));
            v_fade = (1.0f - (v_fade * v_fade));
            v_fade = (1.0f - (v_fade * v_fade));
            v_bias = ((v_dot * v_fade) * (1.0f - f_render_power((1.0f - v_dot), 1.3f)));
          }
          v_color[3i] = (v_color[3i] * ((0.845f * f_render_power(v_delta, 1.3f)) * v_bias));
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
        var v_pass: u32 = SKY_PASS;
        if ((v_pass == u32(5i))) {
          let cw_argument_index_319 = v_data;
          let cw_argument_index_320 = (v_data + u32(1i));
          let cw_argument_index_321 = (v_data + u32(2i));
          let cw_argument_index_322 = (v_data + u32(3i));
          var v_alpha: f32 = sample_atlas(0i, b_texels[cw_argument_index_319], b_texels[cw_argument_index_320], b_texels[cw_argument_index_321], v_u, v_v, v_dudx, v_dvdx, v_dudy, v_dvdy, b_texels[cw_argument_index_322], u32(3i));
          if ((v_alpha <= 0.8f)) {
            discard;
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
        let cw_argument_index_323 = (v_data + u32(9i));
        var v_opacity: f32 = bitcast<f32>(b_texels[cw_argument_index_323]);
        var v_phaseAlpha: f32 = 1.0f;
        var v_maskAlpha: f32 = 1.0f;
        var v_maskScaleX: f32 = 1.0f;
        var v_maskScaleY: f32 = 1.0f;
        if ((v_pass == u32(3i))) {
          v_maskScaleX = precise_divide(f32(b_texels[(v_data + u32(5i))]), f32(b_materials[(v_m + u32(1i))]));
          v_maskScaleY = precise_divide(f32(b_texels[(v_data + u32(6i))]), f32(b_materials[(v_m + u32(2i))]));
          let cw_argument_index_324 = v_data;
          let cw_argument_index_325 = (v_data + u32(1i));
          let cw_argument_index_326 = (v_data + u32(2i));
          let cw_argument_index_327 = (v_data + u32(3i));
          v_phaseAlpha = sample_atlas(0i, b_texels[cw_argument_index_324], b_texels[cw_argument_index_325], b_texels[cw_argument_index_326], v_u, v_v, v_dudx, v_dvdx, v_dudy, v_dvdy, b_texels[cw_argument_index_327], u32(3i));
          let cw_argument_index_328 = (v_data + u32(4i));
          let cw_argument_index_329 = (v_data + u32(5i));
          let cw_argument_index_330 = (v_data + u32(6i));
          let cw_argument_index_331 = (v_data + u32(7i));
          let cw_argument_index_332 = (v_data + u32(17i));
          v_maskAlpha = (sample_atlas(0i, b_texels[cw_argument_index_328], b_texels[cw_argument_index_329], b_texels[cw_argument_index_330], v_u, v_v, (v_dudx * v_maskScaleX), (v_dvdx * v_maskScaleY), (v_dudy * v_maskScaleX), (v_dvdy * v_maskScaleY), b_texels[cw_argument_index_331], u32(3i)) * bitcast<f32>(b_texels[cw_argument_index_332]));
        }
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(4i))) { break; }
            let cw_argument_index_333 = ((v_data + u32(18i)) + v_k);
            var v_emission: f32 = bitcast<f32>(b_texels[cw_argument_index_333]);
            var v_sample: f32 = 1.0f;
            if (((v_pass >= u32(1i)) && (v_pass <= u32(4i)))) {
              let cw_argument_index_334 = v_data;
              let cw_argument_index_335 = (v_data + u32(1i));
              let cw_argument_index_336 = (v_data + u32(2i));
              let cw_argument_index_337 = (v_data + u32(3i));
              v_sample = sample_atlas(0i, b_texels[cw_argument_index_334], b_texels[cw_argument_index_335], b_texels[cw_argument_index_336], v_u, v_v, v_dudx, v_dvdx, v_dudy, v_dvdy, b_texels[cw_argument_index_337], v_k);
            }
            if ((v_pass == u32(0i))) {
              var cw_tmp_338: f32;
              if ((v_k == u32(3i))) {
                cw_tmp_338 = v_vertexAlpha;
              } else {
                cw_tmp_338 = 1.0f;
              }
              v_color[v_k] = (v_emission * cw_tmp_338);
            }
            if ((v_pass == u32(1i))) {
              var cw_tmp_339: f32;
              if ((v_k == u32(3i))) {
                cw_tmp_339 = (v_vertexAlpha * v_opacity);
              } else {
                cw_tmp_339 = 1.0f;
              }
              v_color[v_k] = (v_sample * cw_tmp_339);
            }
            if ((v_pass == u32(2i))) {
              let cw_argument_index_340 = ((v_data + u32(26i)) + v_k);
              var v_fog: f32 = bitcast<f32>(b_texels[cw_argument_index_340]);
              var cw_tmp_341: f32;
              if ((v_k == u32(3i))) {
                cw_tmp_341 = ((v_sample * v_vertexAlpha) * v_opacity);
              } else {
                cw_tmp_341 = ((v_fog * (1.0f - v_vertexAlpha)) + (min(1.0f, max(0.0f, (v_sample * v_emission))) * v_vertexAlpha));
              }
              v_color[v_k] = cw_tmp_341;
            }
            if ((v_pass == u32(3i))) {
              let cw_argument_index_342 = (v_data + u32(4i));
              let cw_argument_index_343 = (v_data + u32(5i));
              let cw_argument_index_344 = (v_data + u32(6i));
              let cw_argument_index_345 = (v_data + u32(7i));
              var v_mask: f32 = sample_atlas(0i, b_texels[cw_argument_index_342], b_texels[cw_argument_index_343], b_texels[cw_argument_index_344], v_u, v_v, (v_dudx * v_maskScaleX), (v_dvdx * v_maskScaleY), (v_dudy * v_maskScaleX), (v_dvdy * v_maskScaleY), b_texels[cw_argument_index_345], v_k);
              var cw_tmp_349: f32;
              if ((v_k == u32(3i))) {
                cw_tmp_349 = v_maskAlpha;
              } else {
                let cw_argument_index_346 = ((v_data + u32(14i)) + v_k);
                let cw_argument_index_347 = ((v_data + u32(10i)) + v_k);
                let cw_argument_index_348 = (v_data + u32(17i));
                cw_tmp_349 = (((v_mask * bitcast<f32>(b_texels[cw_argument_index_346])) * v_maskAlpha) + (((v_sample * bitcast<f32>(b_texels[cw_argument_index_347])) * v_phaseAlpha) * bitcast<f32>(b_texels[cw_argument_index_348])));
              }
              v_color[v_k] = cw_tmp_349;
            }
            if ((v_pass == u32(4i))) {
              var cw_tmp_351: f32;
              if ((v_k == u32(3i))) {
                let cw_argument_index_350 = (v_data + u32(25i));
                cw_tmp_351 = bitcast<f32>(b_texels[cw_argument_index_350]);
              } else {
                cw_tmp_351 = 1.0f;
              }
              v_color[v_k] = (v_sample * cw_tmp_351);
            }
            if ((v_pass == u32(6i))) {
              var cw_tmp_353: f32;
              if ((v_k == u32(3i))) {
                let cw_argument_index_352 = (v_data + u32(25i));
                cw_tmp_353 = bitcast<f32>(b_texels[cw_argument_index_352]);
              } else {
                cw_tmp_353 = v_emission;
              }
              v_color[v_k] = cw_tmp_353;
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
        let cw_argument_index_354 = (v_raster + 23u);
        var v_fog: u32 = bitcast<u32>(b_attributes[cw_argument_index_354]);
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
        var cw_tmp_356: f32;
        if (((b_texels[v_fog] & 4u) != 0u)) {
          cw_tmp_356 = sqrt((((v_position[0i] * v_position[0i]) + (v_position[1i] * v_position[1i])) + (v_position[2i] * v_position[2i])));
        } else {
          let cw_argument_index_355 = 2i;
          cw_tmp_356 = abs(v_position[cw_argument_index_355]);
        }
        var v_distance: f32 = cw_tmp_356;
        if (((b_texels[v_fog] & 8u) != 0u)) {
          v_distance = (((v_a * b_attributes[(((v_ia / 10u) * 34u) + 9u)]) + (v_b * b_attributes[(((v_ib / 10u) * 34u) + 9u)])) + (v_c * b_attributes[(((v_ic / 10u) * 34u) + 9u)]));
        }
        if (((b_texels[v_fog] & 16u) != 0u)) {
          let cw_argument_index_357 = (v_fog + 8u);
          v_distance = bitcast<f32>(b_texels[cw_argument_index_357]);
        }
        let cw_argument_index_358 = (v_fog + 1u);
        var v_density: f32 = bitcast<f32>(b_texels[cw_argument_index_358]);
        let cw_argument_index_359 = (v_fog + 2u);
        var v_start: f32 = bitcast<f32>(b_texels[cw_argument_index_359]);
        let cw_argument_index_360 = (v_fog + 3u);
        var v_end: f32 = bitcast<f32>(b_texels[cw_argument_index_360]);
        var v_factor: f32 = 0.0f;
        if ((v_mode == 0u)) {
          var cw_tmp_362: f32;
          if ((v_end != v_start)) {
            cw_tmp_362 = precise_divide((v_end - v_distance), (v_end - v_start));
          } else {
            var cw_tmp_361: f32;
            if ((v_distance < v_end)) {
              cw_tmp_361 = 1.0f;
            } else {
              cw_tmp_361 = 0.0f;
            }
            cw_tmp_362 = cw_tmp_361;
          }
          v_factor = cw_tmp_362;
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
            let cw_argument_index_363 = ((v_fog + 4u) + v_k);
            v_color[v_k] = ((v_factor * v_color[v_k]) + ((1.0f - v_factor) * f_raster_unit_value(bitcast<f32>(b_texels[cw_argument_index_363]))));
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
            let cw_argument_index_364 = v_k;
            v_color[v_k] = min(1.0f, max(0.0f, v_color[cw_argument_index_364]));
            continuing {
              v_k += u32(1);
            }
          }
        }
      }
      v_color[3i] = (v_color[3i] * v_pointFade);
      if (((v_flags & u32(128i)) != u32(0i))) {
        let cw_argument_index_365 = 3i;
        let cw_argument_index_366 = (v_m + u32(4i));
        if ((f_compare_value(v_color[cw_argument_index_365], f_raster_unit_value(bitcast<f32>(b_materials[cw_argument_index_366])), ((v_control >> u32(4i)) & u32(15i))) == u32(0i))) {
          discard;
        }
      } else {
        if ((v_color[3i] < precise_divide(f32(b_materials[(v_m + u32(4i))]), 255.0f))) {
          discard;
        }
      }
      if (((v_multisample != 0u) && ((v_flags & 65536u) != 0u))) {
        var v_rank: u32 = ((v_sample + (((v_x * 3u) + (v_y * 5u)) % params.sample_count)) % params.sample_count);
        let cw_argument_index_367 = 3i;
        var v_coverage: f32 = min(1.0f, max(0.0f, v_color[cw_argument_index_367]));
        if ((v_coverage < precise_divide((f32(v_rank) + 0.5f), f32(params.sample_count)))) {
          discard;
        }
      }
      if (((v_multisample != 0u) && ((v_flags & 131072u) != 0u))) {
        v_color[3i] = 1.0f;
      }

  var result: MaterialResult;
  result.color = vec4<f32>(v_color[0], v_color[1], v_color[2], v_color[3]);
  let normal_alpha = select(v_pointFade, 1.0, v_multisample != 0u && (v_flags & 131072u) != 0u);
  result.normal = vec4<f32>(v_fragmentNormal[0], v_fragmentNormal[1], v_fragmentNormal[2], normal_alpha);
  // Normalized targets clamp the blend inputs as GL does; the attachment
  // performs final conversion after native blending.
  if (params.color_storage != 1u && params.color_storage != 2u) {
    let lower = select(0.0, -1.0, params.color_storage == 5u || params.color_storage == 6u);
    result.color = clamp(result.color, vec4<f32>(lower), vec4<f32>(1.0));
  }
  if (params.normal_storage != 1u && params.normal_storage != 2u) {
    let lower = select(0.0, -1.0, params.normal_storage == 5u || params.normal_storage == 6u);
    result.normal = clamp(result.normal, vec4<f32>(lower), vec4<f32>(1.0));
  }
  result.depth = v_z;
  return result;
}
@fragment fn fragment_color(input: RasterVaryings, @builtin(front_facing) front: bool, @builtin(sample_index) sample: u32) -> ColorOutput {
  let result = shade_material(input, front, sample);
  return ColorOutput(result.color, result.depth);
}
@fragment fn fragment_normal(input: RasterVaryings, @builtin(front_facing) front: bool, @builtin(sample_index) sample: u32) -> NormalOutput {
  let result = shade_material(input, front, sample);
  return NormalOutput(result.color, result.normal, result.depth);
}
@fragment fn fragment_depth(input: RasterVaryings, @builtin(front_facing) front: bool, @builtin(sample_index) sample: u32) -> @builtin(frag_depth) f32 {
  return shade_material(input, front, sample).depth;
}
@fragment fn fragment_query(input: RasterVaryings, @builtin(front_facing) front: bool, @builtin(sample_index) sample: u32) -> ColorOutput {
  // The material still performs alpha and sample-coverage discards. Native
  // depth/stencil tests select the samples accumulated into the query target.
  let result = shade_material(input, front, sample);
  return ColorOutput(vec4<f32>(1.0, 0.0, 0.0, 0.0), result.depth);
}
