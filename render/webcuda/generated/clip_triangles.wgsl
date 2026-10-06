// CUDA WebShader 0.1.1. Generated from kernel clip_triangles.
@group(0) @binding(0) var<storage, read> b_clip: array<f32>;
@group(0) @binding(1) var<storage, read> b_indices: array<u32>;
@group(0) @binding(2) var<storage, read> b_materials: array<u32>;
@group(0) @binding(3) var<storage, read> b_polygon_edges: array<u32>;
@group(0) @binding(4) var<storage, read_write> b_positions: array<f32>;
@group(0) @binding(5) var<storage, read_write> b_weights: array<f32>;
@group(0) @binding(6) var<storage, read_write> b_valid: array<u32>;
struct CWParams {
  p_triangle_count: u32,
  p_vertex_stride: u32,
  p_triangle_stride: u32,
  cw_pad_12: u32,
}
@group(0) @binding(7) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn cw_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_tri: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_tri >= cw_params.p_triangle_count)) {
    return;
  }
  var cw_tmp_0: u32;
  if ((cw_params.p_triangle_stride == 4u)) {
    cw_tmp_0 = b_materials[((b_indices[((v_tri * cw_params.p_triangle_stride) + 3u)] * 12u) + 3u)];
  } else {
    cw_tmp_0 = 0u;
  }
  var v_flags: u32 = cw_tmp_0;
  var v_depth_clamp: u32 = (v_flags & 262144u);
  var v_expanded_primitive: u32 = (v_flags & 4194304u);
  var v_polygon: array<f32, 40>;
  var v_attributes: array<f32, 40>;
  var v_next_polygon: array<f32, 40>;
  var v_next_attributes: array<f32, 40>;
  var v_count: u32 = u32(3i);
  {
    var v_i: u32 = u32(0i);
    loop {
      if (!(v_i < u32(7i))) { break; }
      b_valid[((v_tri * u32(7i)) + v_i)] = u32(0i);
      continuing {
        v_i += u32(1);
      }
    }
  }
  {
    var v_i: u32 = u32(0i);
    loop {
      if (!(v_i < u32(3i))) { break; }
      var v_vertex: u32 = b_indices[((v_tri * cw_params.p_triangle_stride) + v_i)];
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(4i))) { break; }
          v_polygon[((v_i * u32(4i)) + v_k)] = b_clip[((v_vertex * cw_params.p_vertex_stride) + v_k)];
          var cw_tmp_1: f32;
          if ((v_i == v_k)) {
            cw_tmp_1 = 1.0f;
          } else {
            cw_tmp_1 = 0.0f;
          }
          v_attributes[((v_i * u32(4i)) + v_k)] = cw_tmp_1;
          continuing {
            v_k += u32(1);
          }
        }
      }
      var cw_tmp_2: u32;
      if ((v_i == 0u)) {
        cw_tmp_2 = 2u;
      } else {
        cw_tmp_2 = (v_i - 1u);
      }
      var v_previous: u32 = cw_tmp_2;
      var cw_tmp_3: f32;
      if ((((b_polygon_edges[v_tri] >> v_previous) & 1u) != 0u)) {
        cw_tmp_3 = 1.0f;
      } else {
        cw_tmp_3 = 0.0f;
      }
      v_attributes[((v_i * u32(4i)) + u32(3i))] = cw_tmp_3;
      continuing {
        v_i += u32(1);
      }
    }
  }
  {
    var v_plane: u32 = u32(0i);
    loop {
      if (!(v_plane < u32(6i))) { break; }
      if (((v_plane < 4u) && (v_expanded_primitive != 0u))) {
        continue;
      }
      if (((v_plane >= 4u) && (v_depth_clamp != 0u))) {
        continue;
      }
      if ((v_count < u32(3i))) {
        return;
      }
      var v_axis: u32 = (v_plane / u32(2i));
      var cw_tmp_4: f32;
      if (((v_plane % u32(2i)) == u32(0i))) {
        cw_tmp_4 = 1.0f;
      } else {
        cw_tmp_4 = (-1.0f);
      }
      var v_sign: f32 = cw_tmp_4;
      var v_output_count: u32 = u32(0i);
      {
        var v_i: u32 = u32(0i);
        loop {
          if (!(v_i < v_count)) { break; }
          var cw_tmp_5: u32;
          if ((v_i == u32(0i))) {
            cw_tmp_5 = (v_count - u32(1i));
          } else {
            cw_tmp_5 = (v_i - u32(1i));
          }
          var v_previous: u32 = cw_tmp_5;
          var v_d0: f32 = (v_polygon[((v_previous * u32(4i)) + u32(3i))] + (v_sign * v_polygon[((v_previous * u32(4i)) + v_axis)]));
          var v_d1: f32 = (v_polygon[((v_i * u32(4i)) + u32(3i))] + (v_sign * v_polygon[((v_i * u32(4i)) + v_axis)]));
          if (((v_plane == 4u) && ((v_flags & 8388608u) != 0u))) {
            v_d0 = v_polygon[((v_previous * u32(4i)) + u32(2i))];
            v_d1 = v_polygon[((v_i * u32(4i)) + u32(2i))];
          }
          var v_inside0: bool = (v_d0 >= 0.0f);
          var v_inside1: bool = (v_d1 >= 0.0f);
          if ((((v_inside0 != v_inside1) && (v_d0 != 0.0f)) && (v_d1 != 0.0f))) {
            var v_t: f32 = cw_divide_f32(v_d0, (v_d0 - v_d1));
            {
              var v_k: u32 = u32(0i);
              loop {
                if (!(v_k < u32(4i))) { break; }
                v_next_polygon[((v_output_count * u32(4i)) + v_k)] = (v_polygon[((v_previous * u32(4i)) + v_k)] + (v_t * (v_polygon[((v_i * u32(4i)) + v_k)] - v_polygon[((v_previous * u32(4i)) + v_k)])));
                v_next_attributes[((v_output_count * u32(4i)) + v_k)] = (v_attributes[((v_previous * u32(4i)) + v_k)] + (v_t * (v_attributes[((v_i * u32(4i)) + v_k)] - v_attributes[((v_previous * u32(4i)) + v_k)])));
                continuing {
                  v_k += u32(1);
                }
              }
            }
            var cw_tmp_6: f32;
            if (v_inside0) {
              cw_tmp_6 = v_attributes[((v_i * u32(4i)) + u32(3i))];
            } else {
              cw_tmp_6 = 1.0f;
            }
            v_next_attributes[((v_output_count * u32(4i)) + u32(3i))] = cw_tmp_6;
            v_output_count += u32(1);
          }
          if (v_inside1) {
            {
              var v_k: u32 = u32(0i);
              loop {
                if (!(v_k < u32(4i))) { break; }
                v_next_polygon[((v_output_count * u32(4i)) + v_k)] = v_polygon[((v_i * u32(4i)) + v_k)];
                v_next_attributes[((v_output_count * u32(4i)) + v_k)] = v_attributes[((v_i * u32(4i)) + v_k)];
                continuing {
                  v_k += u32(1);
                }
              }
            }
            if (((!v_inside0) && (v_d1 == 0.0f))) {
              v_next_attributes[((v_output_count * u32(4i)) + u32(3i))] = 1.0f;
            }
            v_output_count += u32(1);
          }
          continuing {
            v_i += u32(1);
          }
        }
      }
      v_count = v_output_count;
      {
        var v_i: u32 = u32(0i);
        loop {
          if (!(v_i < (v_count * u32(4i)))) { break; }
          v_polygon[v_i] = v_next_polygon[v_i];
          v_attributes[v_i] = v_next_attributes[v_i];
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
  if ((v_count < u32(3i))) {
    return;
  }
  {
    var v_fan: u32 = u32(0i);
    loop {
      if (!(v_fan < (v_count - u32(2i)))) { break; }
      var v_slot: u32 = ((v_tri * u32(7i)) + v_fan);
      if ((((v_polygon[3i] <= 0.0f) || (v_polygon[(((v_fan + u32(1i)) * u32(4i)) + u32(3i))] <= 0.0f)) || (v_polygon[(((v_fan + u32(2i)) * u32(4i)) + u32(3i))] <= 0.0f))) {
        continue;
      }
      b_valid[v_slot] = u32(1i);
      {
        var v_v: u32 = u32(0i);
        loop {
          if (!(v_v < u32(3i))) { break; }
          var cw_tmp_7: u32;
          if ((v_v == u32(0i))) {
            cw_tmp_7 = u32(0i);
          } else {
            cw_tmp_7 = (v_fan + v_v);
          }
          var v_from: u32 = cw_tmp_7;
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(4i))) { break; }
              b_positions[(((v_slot * u32(12i)) + (v_v * u32(4i))) + v_k)] = v_polygon[((v_from * u32(4i)) + v_k)];
              b_weights[(((v_slot * u32(12i)) + (v_v * u32(4i))) + v_k)] = v_attributes[((v_from * u32(4i)) + v_k)];
              continuing {
                v_k += u32(1);
              }
            }
          }
          var cw_tmp_8: u32;
          if (((v_from + 1u) == v_count)) {
            cw_tmp_8 = 0u;
          } else {
            cw_tmp_8 = (v_from + 1u);
          }
          var v_next: u32 = cw_tmp_8;
          var cw_tmp_9: f32;
          if ((((v_v == u32(1i)) || ((v_v == u32(0i)) && (v_fan == u32(0i)))) || ((v_v == u32(2i)) && (v_fan == (v_count - u32(3i)))))) {
            cw_tmp_9 = v_attributes[((v_next * u32(4i)) + u32(3i))];
          } else {
            cw_tmp_9 = 0.0f;
          }
          b_weights[(((v_slot * u32(12i)) + (v_v * u32(4i))) + u32(3i))] = cw_tmp_9;
          continuing {
            v_v += u32(1);
          }
        }
      }
      continuing {
        v_fan += u32(1);
      }
    }
  }
}
