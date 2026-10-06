// CUDA WebShader 0.1.1. Generated from kernel expand_screen_primitives.
@group(0) @binding(0) var<storage, read_write> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_attributes: array<f32>;
@group(0) @binding(2) var<storage, read> b_records: array<u32>;
@group(0) @binding(3) var<storage, read_write> b_lighting_origins: array<u32>;
@group(0) @binding(4) var<storage, read_write> b_fixed_lighting: array<f32>;
struct CWParams {
  p_primitive_count: u32,
  p_width: u32,
  p_height: u32,
  p_track_lighting: u32,
  p_fixed_enabled: u32,
  p_sample_count: u32,
  p_source_point_fade_offset: u32,
  cw_pad_28: u32,
}
@group(0) @binding(5) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn cw_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_i: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_i >= cw_params.p_primitive_count)) {
    return;
  }
  var v_r: u32 = (v_i * 12u);
  var v_a: u32 = b_records[v_r];
  var v_b: u32 = b_records[(v_r + 1u)];
  var v_output: u32 = b_records[(v_r + 2u)];
  var v_point: u32 = b_records[(v_r + 3u)];
  let cw_argument_index_0 = (v_r + 4u);
  var v_size: f32 = bitcast<f32>(b_records[cw_argument_index_0]);
  var v_start: array<f32, 4>;
  var v_finish: array<f32, 4>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      v_start[v_k] = b_vertices[((v_a * 10u) + v_k)];
      v_finish[v_k] = b_vertices[((v_b * 10u) + v_k)];
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_begin: f32 = 0.0f;
  var v_end: f32 = 1.0f;
  var v_alpha: f32 = 1.0f;
  var v_smoothRadius: f32 = 0.0f;
  var v_visible: u32 = 1u;
  {
    var v_plane: u32 = u32(0i);
    loop {
      if (!(v_plane < u32(6i))) { break; }
      if (((v_plane >= 4u) && ((b_records[(v_r + 11u)] & 32u) != 0u))) {
        continue;
      }
      var v_axis: u32 = (v_plane / u32(2i));
      var cw_tmp_1: f32;
      if (((v_plane % u32(2i)) == u32(0i))) {
        cw_tmp_1 = 1.0f;
      } else {
        cw_tmp_1 = (-1.0f);
      }
      var v_sign: f32 = cw_tmp_1;
      var v_p: f32 = (v_start[3i] + (v_sign * v_start[v_axis]));
      var v_q: f32 = (v_finish[3i] + (v_sign * v_finish[v_axis]));
      if (((v_plane == 4u) && ((b_records[(v_r + 11u)] & 512u) != 0u))) {
        v_p = v_start[2i];
        v_q = v_finish[2i];
      }
      if (((v_p < 0.0f) && (v_q < 0.0f))) {
        v_visible = 0u;
      } else {
        if ((v_p < 0.0f)) {
          v_begin = max(v_begin, cw_divide_f32(v_p, (v_p - v_q)));
        } else {
          if ((v_q < 0.0f)) {
            v_end = min(v_end, cw_divide_f32(v_p, (v_p - v_q)));
          }
        }
      }
      continuing {
        v_plane += u32(1);
      }
    }
  }
  var v_first: array<f32, 4>;
  var v_last: array<f32, 4>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      v_first[v_k] = (v_start[v_k] + (v_begin * (v_finish[v_k] - v_start[v_k])));
      v_last[v_k] = (v_start[v_k] + (v_end * (v_finish[v_k] - v_start[v_k])));
      continuing {
        v_k += u32(1);
      }
    }
  }
  if ((((v_end < v_begin) || (v_first[3i] <= 0.0f)) || (v_last[3i] <= 0.0f))) {
    v_visible = 0u;
  }
  var v_x: f32 = 0.0f;
  var v_y: f32 = 0.0f;
  var v_nx: f32 = 0.0f;
  var v_ny: f32 = 0.0f;
  var v_ex: f32 = 0.0f;
  var v_ey: f32 = 0.0f;
  if ((v_visible != 0u)) {
    if ((v_point != 0u)) {
      var v_distance: f32 = 0.0f;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          v_distance = (v_distance + (b_attributes[((v_a * 34u) + v_k)] * b_attributes[((v_a * 34u) + v_k)]));
          continuing {
            v_k += u32(1);
          }
        }
      }
      v_distance = sqrt(v_distance);
      let cw_argument_index_2 = (v_r + 8u);
      let cw_argument_index_3 = (v_r + 9u);
      let cw_argument_index_4 = (v_r + 10u);
      var v_attenuation: f32 = ((bitcast<f32>(b_records[cw_argument_index_2]) + (bitcast<f32>(b_records[cw_argument_index_3]) * v_distance)) + ((bitcast<f32>(b_records[cw_argument_index_4]) * v_distance) * v_distance));
      v_size = cw_divide_f32(v_size, sqrt(max(1e-12f, v_attenuation)));
      let cw_argument_index_5 = (v_r + 6u);
      let cw_argument_index_6 = (v_r + 5u);
      v_size = min(bitcast<f32>(b_records[cw_argument_index_5]), max(bitcast<f32>(b_records[cw_argument_index_6]), v_size));
      let cw_argument_index_7 = (v_r + 7u);
      var v_fade: f32 = bitcast<f32>(b_records[cw_argument_index_7]);
      var cw_tmp_8: u32;
      if (((cw_params.p_sample_count > 1u) && ((b_records[(v_r + 11u)] & 64u) != 0u))) {
        cw_tmp_8 = 1u;
      } else {
        cw_tmp_8 = 0u;
      }
      var v_multisample: u32 = cw_tmp_8;
      if ((((v_multisample != 0u) && (v_fade > 0.0f)) && (v_size < v_fade))) {
        var v_ratio: f32 = cw_divide_f32(v_size, v_fade);
        v_alpha = (v_ratio * v_ratio);
        v_size = v_fade;
      }
      var v_pointStyle: u32 = (b_records[(v_r + 11u)] & 384u);
      if (((v_multisample == 0u) && (v_pointStyle == 128u))) {
        v_smoothRadius = (v_size * 0.5f);
      }
      if (((v_multisample == 0u) && (v_pointStyle == 0u))) {
        v_size = max(1.0f, floor((v_size + 0.5f)));
      }
      var v_odd: f32 = (v_size - (2.0f * floor((v_size * 0.5f))));
      v_x = (((cw_divide_f32(v_first[0i], v_first[3i]) * 0.5f) + 0.5f) * f32(cw_params.p_width));
      v_y = (((cw_divide_f32(v_first[1i], v_first[3i]) * 0.5f) + 0.5f) * f32(cw_params.p_height));
      if (((v_multisample == 0u) && (v_pointStyle == 0u))) {
        var cw_tmp_9: f32;
        if ((v_odd > 0.0f)) {
          cw_tmp_9 = (floor(v_x) + 0.5f);
        } else {
          cw_tmp_9 = floor((v_x + 0.5f));
        }
        v_x = cw_tmp_9;
        var cw_tmp_10: f32;
        if ((v_odd > 0.0f)) {
          cw_tmp_10 = (floor(v_y) + 0.5f);
        } else {
          cw_tmp_10 = floor((v_y + 0.5f));
        }
        v_y = cw_tmp_10;
      }
    } else {
      var v_support: f32 = (max(v_size, max(1.0f, floor((v_size + 0.5f)))) + 2.0f);
      var v_dx: f32 = ((cw_divide_f32(v_last[0i], v_last[3i]) - cw_divide_f32(v_first[0i], v_first[3i])) * f32(cw_params.p_width));
      var v_dy: f32 = ((cw_divide_f32(v_last[1i], v_last[3i]) - cw_divide_f32(v_first[1i], v_first[3i])) * f32(cw_params.p_height));
      var v_length: f32 = sqrt(((v_dx * v_dx) + (v_dy * v_dy)));
      if ((v_length <= 0.000001f)) {
        v_visible = 0u;
      } else {
        v_nx = cw_divide_f32((cw_divide_f32((-v_dy), v_length) * v_support), f32(cw_params.p_width));
        v_ny = cw_divide_f32((cw_divide_f32(v_dx, v_length) * v_support), f32(cw_params.p_height));
        v_ex = cw_divide_f32((cw_divide_f32(v_dx, v_length) * v_support), f32(cw_params.p_width));
        v_ey = cw_divide_f32((cw_divide_f32(v_dy, v_length) * v_support), f32(cw_params.p_height));
      }
    }
  }
  {
    var v_corner: u32 = u32(0i);
    loop {
      if (!(v_corner < u32(4i))) { break; }
      var v_v: u32 = (v_output + v_corner);
      var cw_tmp_11: f32;
      if ((v_corner >= 2u)) {
        cw_tmp_11 = v_end;
      } else {
        cw_tmp_11 = v_begin;
      }
      var v_t: f32 = cw_tmp_11;
      var cw_tmp_12: f32;
      if (((v_corner == 0u) || (v_corner == 3u))) {
        cw_tmp_12 = (-1.0f);
      } else {
        cw_tmp_12 = 1.0f;
      }
      var v_side: f32 = cw_tmp_12;
      if ((cw_params.p_fixed_enabled != u32(0i))) {
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(16i))) { break; }
            b_fixed_lighting[((v_v * u32(16i)) + v_k)] = (b_fixed_lighting[((v_a * u32(16i)) + v_k)] + (v_t * (b_fixed_lighting[((v_b * u32(16i)) + v_k)] - b_fixed_lighting[((v_a * u32(16i)) + v_k)])));
            continuing {
              v_k += u32(1);
            }
          }
        }
      }
      if (((cw_params.p_fixed_enabled != u32(0i)) && (b_fixed_lighting[((v_v * u32(16i)) + u32(7i))] > 0.5f))) {
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(7i))) { break; }
            b_fixed_lighting[(((v_v * u32(16i)) + u32(8i)) + v_k)] = b_fixed_lighting[((v_v * u32(16i)) + v_k)];
            continuing {
              v_k += u32(1);
            }
          }
        }
        b_fixed_lighting[((v_v * u32(16i)) + u32(15i))] = 2.0f;
      }
      if ((cw_params.p_track_lighting != u32(0i))) {
        b_lighting_origins[(v_v * u32(3i))] = v_a;
        b_lighting_origins[((v_v * u32(3i)) + u32(1i))] = v_b;
        b_lighting_origins[((v_v * u32(3i)) + u32(2i))] = bitcast<u32>(v_t);
      }
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(10i))) { break; }
          b_vertices[((v_v * 10u) + v_k)] = (b_vertices[((v_a * 10u) + v_k)] + (v_t * (b_vertices[((v_b * 10u) + v_k)] - b_vertices[((v_a * 10u) + v_k)])));
          continuing {
            v_k += u32(1);
          }
        }
      }
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(34i))) { break; }
          b_attributes[((v_v * 34u) + v_k)] = (b_attributes[((v_a * 34u) + v_k)] + (v_t * (b_attributes[((v_b * 34u) + v_k)] - b_attributes[((v_a * 34u) + v_k)])));
          continuing {
            v_k += u32(1);
          }
        }
      }
      if ((v_visible == 0u)) {
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(4i))) { break; }
            b_vertices[((v_v * 10u) + v_k)] = 0.0f;
            continuing {
              v_k += u32(1);
            }
          }
        }
      } else {
        if ((v_point != 0u)) {
          var cw_tmp_13: f32;
          if ((v_corner >= 2u)) {
            cw_tmp_13 = 1.0f;
          } else {
            cw_tmp_13 = (-1.0f);
          }
          var v_horizontal: f32 = cw_tmp_13;
          var v_w: f32 = b_vertices[((v_v * 10u) + 3u)];
          var cw_tmp_14: f32;
          if ((v_smoothRadius > 0.0f)) {
            cw_tmp_14 = 0.5f;
          } else {
            cw_tmp_14 = 0.0f;
          }
          b_vertices[(v_v * 10u)] = (((cw_divide_f32((v_x + (v_horizontal * ((v_size * 0.5f) + cw_tmp_14))), f32(cw_params.p_width)) * 2.0f) - 1.0f) * v_w);
          var cw_tmp_15: f32;
          if ((v_smoothRadius > 0.0f)) {
            cw_tmp_15 = 0.5f;
          } else {
            cw_tmp_15 = 0.0f;
          }
          b_vertices[((v_v * 10u) + 1u)] = (((cw_divide_f32((v_y + (v_side * ((v_size * 0.5f) + cw_tmp_15))), f32(cw_params.p_height)) * 2.0f) - 1.0f) * v_w);
          var v_metadata: u32 = (cw_params.p_source_point_fade_offset + (v_v * 12u));
          b_attributes[v_metadata] = v_alpha;
          var cw_tmp_16: f32;
          if ((v_smoothRadius > 0.0f)) {
            cw_tmp_16 = 0.5f;
          } else {
            cw_tmp_16 = 0.0f;
          }
          b_attributes[(v_metadata + 1u)] = (v_horizontal * ((v_size * 0.5f) + cw_tmp_16));
          var cw_tmp_17: f32;
          if ((v_smoothRadius > 0.0f)) {
            cw_tmp_17 = 0.5f;
          } else {
            cw_tmp_17 = 0.0f;
          }
          b_attributes[(v_metadata + 2u)] = (v_side * ((v_size * 0.5f) + cw_tmp_17));
          var cw_tmp_18: f32;
          if (((b_records[(v_r + 11u)] & 256u) != 0u)) {
            cw_tmp_18 = ((-v_size) * 0.5f);
          } else {
            cw_tmp_18 = v_smoothRadius;
          }
          b_attributes[(v_metadata + 3u)] = cw_tmp_18;
          var v_sprite: u32 = b_records[(v_r + 11u)];
          var v_u: f32 = ((v_horizontal * 0.5f) + 0.5f);
          var cw_tmp_19: f32;
          if (((v_sprite & 16u) != 0u)) {
            cw_tmp_19 = ((v_side * 0.5f) + 0.5f);
          } else {
            cw_tmp_19 = (0.5f - (v_side * 0.5f));
          }
          var v_textureV: f32 = cw_tmp_19;
          {
            var v_unit: u32 = u32(0i);
            loop {
              if (!(v_unit < u32(4i))) { break; }
              if (((v_sprite & (1u << v_unit)) != 0u)) {
                var cw_tmp_20: u32;
                if ((v_unit == 0u)) {
                  cw_tmp_20 = 16u;
                } else {
                  cw_tmp_20 = (10u + ((v_unit - 1u) * 2u));
                }
                var v_coord: u32 = cw_tmp_20;
                b_attributes[((v_v * 34u) + v_coord)] = v_u;
                b_attributes[(((v_v * 34u) + v_coord) + 1u)] = v_textureV;
                b_attributes[(((v_v * 34u) + 26u) + (v_unit * 2u))] = 0.0f;
                b_attributes[(((v_v * 34u) + 27u) + (v_unit * 2u))] = 1.0f;
                if ((v_unit == 0u)) {
                  b_vertices[((v_v * 10u) + 8u)] = v_u;
                  b_vertices[((v_v * 10u) + 9u)] = v_textureV;
                }
              }
              continuing {
                v_unit += u32(1);
              }
            }
          }
        } else {
          var v_metadata: u32 = (cw_params.p_source_point_fade_offset + (v_v * 12u));
          var cw_tmp_21: f32;
          if ((v_corner >= 2u)) {
            cw_tmp_21 = 1.0f;
          } else {
            cw_tmp_21 = 0.0f;
          }
          b_attributes[(v_metadata + 1u)] = cw_tmp_21;
          b_attributes[(v_metadata + 2u)] = v_size;
          {
            var v_k: u32 = 0u;
            loop {
              if (!(v_k < 4u)) { break; }
              b_attributes[((v_metadata + 4u) + v_k)] = v_first[v_k];
              b_attributes[((v_metadata + 8u) + v_k)] = v_last[v_k];
              continuing {
                v_k += u32(1);
              }
            }
          }
          var cw_tmp_22: f32;
          if ((v_corner >= 2u)) {
            cw_tmp_22 = v_ex;
          } else {
            cw_tmp_22 = (-v_ex);
          }
          b_vertices[(v_v * 10u)] = (b_vertices[(v_v * 10u)] + (((v_side * v_nx) + cw_tmp_22) * b_vertices[((v_v * 10u) + 3u)]));
          var cw_tmp_23: f32;
          if ((v_corner >= 2u)) {
            cw_tmp_23 = v_ey;
          } else {
            cw_tmp_23 = (-v_ey);
          }
          b_vertices[((v_v * 10u) + 1u)] = (b_vertices[((v_v * 10u) + 1u)] + (((v_side * v_ny) + cw_tmp_23) * b_vertices[((v_v * 10u) + 3u)]));
        }
      }
      continuing {
        v_corner += u32(1);
      }
    }
  }
}
