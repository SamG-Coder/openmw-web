// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: project_particles.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read> b_attributes: array<f32>;
@group(0) @binding(2) var<storage, read> b_matrices: array<f32>;
@group(0) @binding(3) var<storage, read> b_matrix_ids: array<u32>;
@group(0) @binding(4) var<storage, read_write> b_vertices: array<f32>;
@group(0) @binding(5) var<storage, read_write> b_varyings: array<f32>;
@group(0) @binding(6) var<storage, read_write> b_fixed_lighting: array<f32>;
@group(0) @binding(7) var<storage, read> b_fixed_endpoints: array<f32>;
struct KernelParams {
  p_vertex_count: u32,
  p_width: u32,
  p_height: u32,
  p_fixed_enabled: u32,
  p_track_world_particles: u32,
  p_world_particle_offset: u32,
  p_source_point_fade_offset: u32,
  p_sample_count: u32,
}
@group(0) @binding(8) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn gpu_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_i: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_i >= gpu_params.p_vertex_count)) {
    return;
  }
  var v_d: u32 = (v_i * u32(34i));
  var v_p: u32 = (v_i * u32(10i));
  var v_m: u32 = (b_matrix_ids[v_i] * u32(32i));
  var v_lighting: u32 = (gpu_params.p_world_particle_offset + (v_i * u32(24i)));
  if ((gpu_params.p_track_world_particles != u32(0i))) {
    b_varyings[v_lighting] = 0.0f;
  }
  var v_point_flags: u32 = u32(b_attributes[(v_d + u32(25i))]);
  var v_depth_clamp: u32 = (v_point_flags & 1u);
  var v_zero_to_one: u32 = (v_point_flags & 16u);
  var v_mode: f32 = b_attributes[v_d];
  if (((((v_mode != 5.0f) && (v_mode != 6.0f)) && (v_mode != 7.0f)) && (v_mode != 8.0f))) {
    return;
  }
  var v_side: f32 = b_attributes[(v_d + u32(2i))];
  var v_endpoint: f32 = ((b_attributes[(v_d + u32(1i))] + 1.0f) * 0.5f);
  var v_size: f32 = b_attributes[(v_d + u32(15i))];
  if (((v_mode == 5.0f) || (v_mode == 8.0f))) {
    if ((((v_mode == 8.0f) && (b_attributes[(v_d + u32(24i))] > 0.0f)) && (((-b_varyings[(v_d + u32(2i))]) <= 0.0f) || ((-b_varyings[(v_d + u32(2i))]) >= b_attributes[(v_d + u32(24i))])))) {
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(4i))) { break; }
          b_vertices[(v_p + v_k)] = 0.0f;
          continuing {
            v_k += u32(1);
          }
        }
      }
      return;
    }
    var v_w: f32 = b_vertices[(v_p + u32(3i))];
    var gpu_tmp_1: bool = (v_w <= 0.0f);
    if (!gpu_tmp_1) {
      let gpu_argument_index_0 = v_p;
      gpu_tmp_1 = (abs(b_vertices[gpu_argument_index_0]) > v_w);
    }
    var gpu_tmp_3: bool = gpu_tmp_1;
    if (!gpu_tmp_3) {
      let gpu_argument_index_2 = (v_p + u32(1i));
      gpu_tmp_3 = (abs(b_vertices[gpu_argument_index_2]) > v_w);
    }
    var gpu_tmp_7: bool = gpu_tmp_3;
    if (!gpu_tmp_7) {
      var gpu_tmp_6: bool = (v_depth_clamp == 0u);
      if (gpu_tmp_6) {
        var gpu_tmp_5: bool = (b_vertices[(v_p + u32(2i))] > v_w);
        if (!gpu_tmp_5) {
          var gpu_tmp_4: f32;
          if ((v_zero_to_one != 0u)) {
            gpu_tmp_4 = 0.0f;
          } else {
            gpu_tmp_4 = (-v_w);
          }
          gpu_tmp_5 = (b_vertices[(v_p + u32(2i))] < gpu_tmp_4);
        }
        gpu_tmp_6 = gpu_tmp_5;
      }
      gpu_tmp_7 = gpu_tmp_6;
    }
    if (gpu_tmp_7) {
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(4i))) { break; }
          b_vertices[(v_p + v_k)] = 0.0f;
          continuing {
            v_k += u32(1);
          }
        }
      }
      return;
    }
    if ((gpu_params.p_track_world_particles != u32(0i))) {
      b_varyings[v_lighting] = 1.0f;
      b_varyings[(v_lighting + u32(1i))] = 0.0f;
      {
        var v_axis: u32 = u32(0i);
        loop {
          if (!(v_axis < u32(3i))) { break; }
          b_varyings[((v_lighting + u32(2i)) + v_axis)] = b_varyings[(v_d + v_axis)];
          b_varyings[((v_lighting + u32(5i)) + v_axis)] = b_varyings[(v_d + v_axis)];
          var gpu_tmp_8: u32;
          if ((v_axis == u32(2i))) {
            gpu_tmp_8 = u32(3i);
          } else {
            gpu_tmp_8 = v_axis;
          }
          var v_clip: f32 = b_vertices[(v_p + gpu_tmp_8)];
          b_varyings[((v_lighting + u32(8i)) + v_axis)] = v_clip;
          b_varyings[((v_lighting + u32(11i)) + v_axis)] = v_clip;
          continuing {
            v_axis += u32(1);
          }
        }
      }
      {
        var v_channel: u32 = u32(0i);
        loop {
          if (!(v_channel < u32(4i))) { break; }
          b_varyings[((v_lighting + u32(14i)) + v_channel)] = b_source[((v_p + u32(4i)) + v_channel)];
          b_varyings[((v_lighting + u32(18i)) + v_channel)] = b_source[((v_p + u32(4i)) + v_channel)];
          continuing {
            v_channel += u32(1);
          }
        }
      }
    }
    var v_distance: f32 = sqrt((((b_varyings[v_d] * b_varyings[v_d]) + (b_varyings[(v_d + u32(1i))] * b_varyings[(v_d + u32(1i))])) + (b_varyings[(v_d + u32(2i))] * b_varyings[(v_d + u32(2i))])));
    var v_attenuation: f32 = ((b_attributes[(v_d + u32(10i))] + (b_attributes[(v_d + u32(11i))] * v_distance)) + ((b_attributes[(v_d + u32(12i))] * v_distance) * v_distance));
    v_size = gpu_divide_f32(v_size, sqrt(max(1e-12f, v_attenuation)));
    let gpu_argument_index_9 = (v_d + u32(19i));
    let gpu_argument_index_10 = (v_d + u32(18i));
    v_size = min(b_attributes[gpu_argument_index_9], max(b_attributes[gpu_argument_index_10], v_size));
    var v_fade: f32 = b_attributes[(v_d + u32(20i))];
    var gpu_tmp_11: u32;
    if (((gpu_params.p_sample_count > 1u) && ((v_point_flags & 2u) != 0u))) {
      gpu_tmp_11 = 1u;
    } else {
      gpu_tmp_11 = 0u;
    }
    var v_multisample: u32 = gpu_tmp_11;
    if ((((v_multisample != 0u) && (v_size < v_fade)) && (v_fade > 0.0f))) {
      var v_ratio: f32 = gpu_divide_f32(v_size, v_fade);
      b_varyings[(gpu_params.p_source_point_fade_offset + (v_i * 12u))] = (v_ratio * v_ratio);
      v_size = v_fade;
    }
    var v_pointStyle: u32 = (v_point_flags & 12u);
    var gpu_tmp_12: f32;
    if (((v_multisample == 0u) && (v_pointStyle == 4u))) {
      gpu_tmp_12 = (v_size * 0.5f);
    } else {
      gpu_tmp_12 = 0.0f;
    }
    var v_smoothRadius: f32 = gpu_tmp_12;
    if (((v_multisample == 0u) && (v_pointStyle == 0u))) {
      v_size = max(1.0f, floor((v_size + 0.5f)));
    }
    var v_odd: f32 = (v_size - (2.0f * floor((v_size * 0.5f))));
    var v_x: f32 = (((gpu_divide_f32(b_vertices[v_p], v_w) * 0.5f) + 0.5f) * f32(gpu_params.p_width));
    var v_y: f32 = (((gpu_divide_f32(b_vertices[(v_p + u32(1i))], v_w) * 0.5f) + 0.5f) * f32(gpu_params.p_height));
    if (((v_multisample == 0u) && (v_pointStyle == 0u))) {
      var gpu_tmp_13: f32;
      if ((v_odd > 0.0f)) {
        gpu_tmp_13 = (floor(v_x) + 0.5f);
      } else {
        gpu_tmp_13 = floor((v_x + 0.5f));
      }
      v_x = gpu_tmp_13;
      var gpu_tmp_14: f32;
      if ((v_odd > 0.0f)) {
        gpu_tmp_14 = (floor(v_y) + 0.5f);
      } else {
        gpu_tmp_14 = floor((v_y + 0.5f));
      }
      v_y = gpu_tmp_14;
    }
    var gpu_tmp_15: f32;
    if ((v_smoothRadius > 0.0f)) {
      gpu_tmp_15 = 0.5f;
    } else {
      gpu_tmp_15 = 0.0f;
    }
    var v_halfExtent: f32 = ((v_size * 0.5f) + gpu_tmp_15);
    b_varyings[((gpu_params.p_source_point_fade_offset + (v_i * 12u)) + 1u)] = (b_attributes[(v_d + u32(1i))] * v_halfExtent);
    b_varyings[((gpu_params.p_source_point_fade_offset + (v_i * 12u)) + 2u)] = (v_side * v_halfExtent);
    var gpu_tmp_16: f32;
    if (((v_point_flags & 8u) != 0u)) {
      gpu_tmp_16 = ((-v_size) * 0.5f);
    } else {
      gpu_tmp_16 = v_smoothRadius;
    }
    b_varyings[((gpu_params.p_source_point_fade_offset + (v_i * 12u)) + 3u)] = gpu_tmp_16;
    b_vertices[v_p] = (((gpu_divide_f32((v_x + (b_attributes[(v_d + u32(1i))] * v_halfExtent)), f32(gpu_params.p_width)) * 2.0f) - 1.0f) * v_w);
    b_vertices[(v_p + u32(1i))] = (((gpu_divide_f32((v_y + (v_side * v_halfExtent)), f32(gpu_params.p_height)) * 2.0f) - 1.0f) * v_w);
    return;
  }
  var v_view0: array<f32, 4>;
  var v_view1: array<f32, 4>;
  var v_clip0: array<f32, 4>;
  var v_clip1: array<f32, 4>;
  var v_motion: f32 = 0.0f;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_motion = (v_motion + (b_attributes[((v_d + u32(10i)) + v_k)] * b_attributes[((v_d + u32(10i)) + v_k)]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  {
    var v_row: u32 = u32(0i);
    loop {
      if (!(v_row < u32(4i))) { break; }
      v_view0[v_row] = 0.0f;
      v_view1[v_row] = 0.0f;
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(4i))) { break; }
          var v_a: f32 = b_source[(v_p + v_col)];
          var gpu_tmp_17: f32;
          if ((v_col < u32(3i))) {
            gpu_tmp_17 = b_attributes[((v_d + u32(10i)) + v_col)];
          } else {
            gpu_tmp_17 = 0.0f;
          }
          var v_b: f32 = (v_a + gpu_tmp_17);
          v_view0[v_row] = (v_view0[v_row] + (b_matrices[((v_m + (v_col * u32(4i))) + v_row)] * v_a));
          v_view1[v_row] = (v_view1[v_row] + (b_matrices[((v_m + (v_col * u32(4i))) + v_row)] * v_b));
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
  {
    var v_row: u32 = u32(0i);
    loop {
      if (!(v_row < u32(4i))) { break; }
      v_clip0[v_row] = 0.0f;
      v_clip1[v_row] = 0.0f;
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(4i))) { break; }
          v_clip0[v_row] = (v_clip0[v_row] + (b_matrices[(((v_m + u32(16i)) + (v_col * u32(4i))) + v_row)] * v_view0[v_col]));
          v_clip1[v_row] = (v_clip1[v_row] + (b_matrices[(((v_m + u32(16i)) + (v_col * u32(4i))) + v_row)] * v_view1[v_col]));
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
  var v_begin: f32 = 0.0f;
  var v_end: f32 = 1.0f;
  {
    var v_plane: u32 = u32(0i);
    loop {
      if (!(v_plane < u32(6i))) { break; }
      if (((v_plane >= 4u) && (v_depth_clamp != 0u))) {
        continue;
      }
      var v_axis: u32 = (v_plane / u32(2i));
      var gpu_tmp_18: f32;
      if (((v_plane % u32(2i)) == u32(0i))) {
        gpu_tmp_18 = 1.0f;
      } else {
        gpu_tmp_18 = (-1.0f);
      }
      var v_sign: f32 = gpu_tmp_18;
      var v_a: f32 = (v_clip0[3i] + (v_sign * v_clip0[v_axis]));
      var v_b: f32 = (v_clip1[3i] + (v_sign * v_clip1[v_axis]));
      if (((v_plane == 4u) && (v_zero_to_one != 0u))) {
        v_a = v_clip0[2i];
        v_b = v_clip1[2i];
      }
      if (((v_a < 0.0f) && (v_b < 0.0f))) {
        v_end = (-1.0f);
      } else {
        if ((v_a < 0.0f)) {
          v_begin = max(v_begin, gpu_divide_f32(v_a, (v_a - v_b)));
        } else {
          if ((v_b < 0.0f)) {
            v_end = min(v_end, gpu_divide_f32(v_a, (v_a - v_b)));
          }
        }
      }
      continuing {
        v_plane += u32(1);
      }
    }
  }
  var v_c0: array<f32, 4>;
  var v_c1: array<f32, 4>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      v_c0[v_k] = (v_clip0[v_k] + (v_begin * (v_clip1[v_k] - v_clip0[v_k])));
      v_c1[v_k] = (v_clip0[v_k] + (v_end * (v_clip1[v_k] - v_clip0[v_k])));
      continuing {
        v_k += u32(1);
      }
    }
  }
  if (((((v_end < v_begin) || (v_motion == 0.0f)) || (v_c0[3i] <= 0.0f)) || (v_c1[3i] <= 0.0f))) {
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(4i))) { break; }
        b_vertices[(v_p + v_k)] = 0.0f;
        continuing {
          v_k += u32(1);
        }
      }
    }
    return;
  }
  var v_dx: f32 = ((gpu_divide_f32(v_c1[0i], v_c1[3i]) - gpu_divide_f32(v_c0[0i], v_c0[3i])) * f32(gpu_params.p_width));
  var v_dy: f32 = ((gpu_divide_f32(v_c1[1i], v_c1[3i]) - gpu_divide_f32(v_c0[1i], v_c0[3i])) * f32(gpu_params.p_height));
  var v_length: f32 = sqrt(((v_dx * v_dx) + (v_dy * v_dy)));
  if ((v_length <= 0.000001f)) {
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(4i))) { break; }
        b_vertices[(v_p + v_k)] = 0.0f;
        continuing {
          v_k += u32(1);
        }
      }
    }
    return;
  }
  var v_lineMetadata: u32 = (gpu_params.p_source_point_fade_offset + (v_i * 12u));
  b_varyings[(v_lineMetadata + 1u)] = v_endpoint;
  b_varyings[(v_lineMetadata + 2u)] = v_size;
  {
    var v_k: u32 = 0u;
    loop {
      if (!(v_k < 4u)) { break; }
      b_varyings[((v_lineMetadata + 4u) + v_k)] = v_c0[v_k];
      b_varyings[((v_lineMetadata + 8u) + v_k)] = v_c1[v_k];
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_t: f32 = (v_begin + (v_endpoint * (v_end - v_begin)));
  if ((gpu_params.p_track_world_particles != u32(0i))) {
    b_varyings[v_lighting] = 2.0f;
    b_varyings[(v_lighting + u32(1i))] = v_t;
    {
      var v_axis: u32 = u32(0i);
      loop {
        if (!(v_axis < u32(3i))) { break; }
        b_varyings[((v_lighting + u32(2i)) + v_axis)] = v_view0[v_axis];
        b_varyings[((v_lighting + u32(5i)) + v_axis)] = v_view1[v_axis];
        var gpu_tmp_19: u32;
        if ((v_axis == u32(2i))) {
          gpu_tmp_19 = u32(3i);
        } else {
          gpu_tmp_19 = v_axis;
        }
        b_varyings[((v_lighting + u32(8i)) + v_axis)] = v_clip0[gpu_tmp_19];
        var gpu_tmp_20: u32;
        if ((v_axis == u32(2i))) {
          gpu_tmp_20 = u32(3i);
        } else {
          gpu_tmp_20 = v_axis;
        }
        b_varyings[((v_lighting + u32(11i)) + v_axis)] = v_clip1[gpu_tmp_20];
        continuing {
          v_axis += u32(1);
        }
      }
    }
    {
      var v_channel: u32 = u32(0i);
      loop {
        if (!(v_channel < u32(4i))) { break; }
        b_varyings[((v_lighting + u32(14i)) + v_channel)] = b_source[((v_p + u32(4i)) + v_channel)];
        var gpu_tmp_21: f32;
        if ((v_mode == 7.0f)) {
          gpu_tmp_21 = b_attributes[((v_d + u32(18i)) + v_channel)];
        } else {
          gpu_tmp_21 = b_source[((v_p + u32(4i)) + v_channel)];
        }
        b_varyings[((v_lighting + u32(18i)) + v_channel)] = gpu_tmp_21;
        continuing {
          v_channel += u32(1);
        }
      }
    }
  }
  if ((gpu_params.p_fixed_enabled != u32(0i))) {
    var gpu_tmp_22: f32;
    if (((v_mode == 7.0f) && (b_attributes[(v_d + u32(24i))] != 0.0f))) {
      gpu_tmp_22 = 1.0f;
    } else {
      gpu_tmp_22 = v_t;
    }
    var v_lightingT: f32 = gpu_tmp_22;
    {
      var v_channel: u32 = u32(0i);
      loop {
        if (!(v_channel < u32(16i))) { break; }
        b_fixed_lighting[((v_i * u32(16i)) + v_channel)] = ((b_fixed_endpoints[((v_i * u32(32i)) + v_channel)] * (1.0f - v_lightingT)) + (b_fixed_endpoints[(((v_i * u32(32i)) + u32(16i)) + v_channel)] * v_lightingT));
        continuing {
          v_channel += u32(1);
        }
      }
    }
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      b_vertices[(v_p + v_k)] = (v_clip0[v_k] + (v_t * (v_clip1[v_k] - v_clip0[v_k])));
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_support: f32 = (max(v_size, max(1.0f, floor((v_size + 0.5f)))) + 2.0f);
  var v_endSide: f32 = ((v_endpoint * 2.0f) - 1.0f);
  b_vertices[v_p] = (b_vertices[v_p] + (gpu_divide_f32((gpu_divide_f32((((-v_dy) * v_side) + (v_dx * v_endSide)), v_length) * v_support), f32(gpu_params.p_width)) * b_vertices[(v_p + u32(3i))]));
  b_vertices[(v_p + u32(1i))] = (b_vertices[(v_p + u32(1i))] + (gpu_divide_f32((gpu_divide_f32(((v_dx * v_side) + (v_dy * v_endSide)), v_length) * v_support), f32(gpu_params.p_height)) * b_vertices[(v_p + u32(3i))]));
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      b_varyings[(v_d + v_k)] = (v_view0[v_k] + (v_t * (v_view1[v_k] - v_view0[v_k])));
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_depth0: f32 = 0.0f;
  var v_depth1: f32 = 0.0f;
  var v_positionLength: f32 = 0.0f;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_depth0 = (v_depth0 + (v_view0[v_k] * v_view0[v_k]));
      v_depth1 = (v_depth1 + (v_view1[v_k] * v_view1[v_k]));
      v_positionLength = (v_positionLength + (b_varyings[(v_d + v_k)] * b_varyings[(v_d + v_k)]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  v_depth0 = sqrt(v_depth0);
  v_depth1 = sqrt(v_depth1);
  b_varyings[(v_d + u32(9i))] = (v_depth0 + (v_t * (v_depth1 - v_depth0)));
  var v_eyeLength: f32 = max(sqrt(v_positionLength), 1e-12f);
  var v_dot: f32 = 0.0f;
  var v_eye: array<f32, 3>;
  var v_normal: array<f32, 3>;
  var v_reflected: array<f32, 3>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_eye[v_k] = gpu_divide_f32(b_varyings[(v_d + v_k)], v_eyeLength);
      v_normal[v_k] = b_varyings[((v_d + u32(23i)) + v_k)];
      v_dot = (v_dot + (v_eye[v_k] * v_normal[v_k]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_reflected[v_k] = (v_eye[v_k] - ((2.0f * v_dot) * v_normal[v_k]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_denominator: f32 = (2.0f * sqrt(max(1e-12f, (((v_reflected[0i] * v_reflected[0i]) + (v_reflected[1i] * v_reflected[1i])) + ((v_reflected[2i] + 1.0f) * (v_reflected[2i] + 1.0f))))));
  b_varyings[(v_d + u32(21i))] = (gpu_divide_f32(v_reflected[0i], v_denominator) + 0.5f);
  b_varyings[(v_d + u32(22i))] = (gpu_divide_f32(v_reflected[1i], v_denominator) + 0.5f);
  if ((v_mode == 7.0f)) {
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(4i))) { break; }
        b_vertices[((v_p + u32(4i)) + v_k)] = (b_source[((v_p + u32(4i)) + v_k)] + (v_t * (b_attributes[((v_d + u32(18i)) + v_k)] - b_source[((v_p + u32(4i)) + v_k)])));
        continuing {
          v_k += u32(1);
        }
      }
    }
    var v_u: f32 = (b_source[(v_p + u32(8i))] + (v_t * (b_attributes[(v_d + u32(22i))] - b_source[(v_p + u32(8i))])));
    b_vertices[(v_p + u32(8i))] = v_u;
    b_vertices[(v_p + u32(9i))] = 0.5f;
    b_varyings[(v_d + u32(16i))] = v_u;
    b_varyings[(v_d + u32(17i))] = 0.5f;
  } else {
    b_vertices[(v_p + u32(8i))] = v_t;
    b_vertices[(v_p + u32(9i))] = v_t;
    b_varyings[(v_d + u32(16i))] = v_t;
    b_varyings[(v_d + u32(17i))] = v_t;
  }
}
