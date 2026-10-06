// CUDA WebShader 0.1.1. Generated from kernel deform_groundcover.
@group(0) @binding(0) var<storage, read_write> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_attributes: array<f32>;
@group(0) @binding(2) var<storage, read> b_records: array<u32>;
@group(0) @binding(3) var<storage, read> b_instances: array<f32>;
@group(0) @binding(4) var<storage, read> b_params: array<f32>;
@group(0) @binding(5) var<storage, read> b_matrices: array<f32>;
@group(0) @binding(6) var<storage, read> b_matrix_ids: array<u32>;
struct CWParams {
  p_record_count: u32,
  cw_pad_4: u32,
  cw_pad_8: u32,
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
  var v_i: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_i >= cw_params.p_record_count)) {
    return;
  }
  var v_vertex: u32 = b_records[(v_i * u32(3i))];
  var v_instance: u32 = (b_records[((v_i * u32(3i)) + u32(1i))] * u32(7i));
  var v_p: u32 = (b_records[((v_i * u32(3i)) + u32(2i))] * u32(40i));
  var v_v: u32 = (v_vertex * u32(10i));
  var v_a: u32 = (v_vertex * u32(34i));
  var v_m: u32 = (b_matrix_ids[v_vertex] * u32(32i));
  let cw_argument_index_0 = (v_instance + u32(4i));
  var v_sx: f32 = sin(b_instances[cw_argument_index_0]);
  let cw_argument_index_1 = (v_instance + u32(4i));
  var v_cx: f32 = cos(b_instances[cw_argument_index_1]);
  let cw_argument_index_2 = (v_instance + u32(5i));
  var v_sy: f32 = sin(b_instances[cw_argument_index_2]);
  let cw_argument_index_3 = (v_instance + u32(5i));
  var v_cy: f32 = cos(b_instances[cw_argument_index_3]);
  let cw_argument_index_4 = (v_instance + u32(6i));
  var v_sz: f32 = sin(b_instances[cw_argument_index_4]);
  let cw_argument_index_5 = (v_instance + u32(6i));
  var v_cz: f32 = cos(b_instances[cw_argument_index_5]);
  var v_rotation: array<f32, 9>;
  v_rotation[0i] = ((v_cz * v_cy) + ((v_sx * v_sy) * v_sz));
  v_rotation[1i] = ((-v_sz) * v_cx);
  v_rotation[2i] = ((v_cz * v_sy) + ((v_sz * v_sx) * v_cy));
  v_rotation[3i] = ((v_sz * v_cy) + ((v_cz * v_sx) * v_sy));
  v_rotation[4i] = (v_cz * v_cx);
  v_rotation[5i] = ((v_sz * v_sy) - ((v_cz * v_sx) * v_cy));
  v_rotation[6i] = ((-v_sy) * v_cx);
  v_rotation[7i] = v_sx;
  v_rotation[8i] = (v_cx * v_cy);
  var v_height: f32 = b_vertices[(v_v + u32(2i))];
  var v_position: array<f32, 4>;
  var v_normal: array<f32, 3>;
  var v_tangent: array<f32, 3>;
  {
    var v_row: u32 = u32(0i);
    loop {
      if (!(v_row < u32(3i))) { break; }
      v_position[v_row] = b_instances[(v_instance + v_row)];
      v_normal[v_row] = 0.0f;
      v_tangent[v_row] = 0.0f;
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(3i))) { break; }
          v_position[v_row] = (v_position[v_row] + ((v_rotation[((v_col * u32(3i)) + v_row)] * b_instances[(v_instance + u32(3i))]) * b_vertices[(v_v + v_col)]));
          v_normal[v_row] = (v_normal[v_row] + (v_rotation[((v_col * u32(3i)) + v_row)] * b_attributes[((v_a + u32(3i)) + v_col)]));
          v_tangent[v_row] = (v_tangent[v_row] + (b_attributes[((v_a + u32(6i)) + v_col)] * v_rotation[((v_row * u32(3i)) + v_col)]));
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
  v_position[3i] = 1.0f;
  var v_view: array<f32, 4>;
  var v_world: array<f32, 4>;
  var v_center: array<f32, 4>;
  {
    var v_row: u32 = u32(0i);
    loop {
      if (!(v_row < u32(4i))) { break; }
      v_view[v_row] = 0.0f;
      v_center[v_row] = b_matrices[((v_m + u32(12i)) + v_row)];
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(4i))) { break; }
          v_view[v_row] = (v_view[v_row] + (b_matrices[((v_m + (v_col * u32(4i))) + v_row)] * v_position[v_col]));
          continuing {
            v_col += u32(1);
          }
        }
      }
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(3i))) { break; }
          v_center[v_row] = (v_center[v_row] + (b_matrices[((v_m + (v_col * u32(4i))) + v_row)] * b_instances[(v_instance + v_col)]));
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
  var v_distance: f32 = sqrt(((((v_center[0i] * v_center[0i]) + (v_center[1i] * v_center[1i])) + (v_center[2i] * v_center[2i])) + (v_center[3i] * v_center[3i])));
  if ((v_distance > b_params[(v_p + u32(39i))])) {
    {
      var v_row: u32 = u32(0i);
      loop {
        if (!(v_row < u32(3i))) { break; }
        b_vertices[(v_v + v_row)] = b_instances[(v_instance + v_row)];
        continuing {
          v_row += u32(1);
        }
      }
    }
    b_vertices[(v_v + u32(3i))] = 1.0f;
    return;
  }
  var v_va: f32 = b_params[v_p];
  var v_vb: f32 = b_params[(v_p + u32(4i))];
  var v_vc: f32 = b_params[(v_p + u32(8i))];
  var v_vd: f32 = b_params[(v_p + u32(1i))];
  var v_ve: f32 = b_params[(v_p + u32(5i))];
  var v_vf: f32 = b_params[(v_p + u32(9i))];
  var v_vg: f32 = b_params[(v_p + u32(2i))];
  var v_vh: f32 = b_params[(v_p + u32(6i))];
  var v_vj: f32 = b_params[(v_p + u32(10i))];
  var v_viewDet: f32 = (((v_va * ((v_ve * v_vj) - (v_vf * v_vh))) - (v_vb * ((v_vd * v_vj) - (v_vf * v_vg)))) + (v_vc * ((v_vd * v_vh) - (v_ve * v_vg))));
  var cw_tmp_6: f32;
  if ((abs(v_viewDet) > 1e-12f)) {
    cw_tmp_6 = cw_divide_f32(1.0f, v_viewDet);
  } else {
    cw_tmp_6 = 0.0f;
  }
  var v_viewInverse: f32 = cw_tmp_6;
  var v_vx: f32 = (v_view[0i] - (b_params[(v_p + u32(12i))] * v_view[3i]));
  var v_vy: f32 = (v_view[1i] - (b_params[(v_p + u32(13i))] * v_view[3i]));
  var v_vz: f32 = (v_view[2i] - (b_params[(v_p + u32(14i))] * v_view[3i]));
  v_world[0i] = ((((((v_ve * v_vj) - (v_vf * v_vh)) * v_vx) + (((v_vc * v_vh) - (v_vb * v_vj)) * v_vy)) + (((v_vb * v_vf) - (v_vc * v_ve)) * v_vz)) * v_viewInverse);
  v_world[1i] = ((((((v_vf * v_vg) - (v_vd * v_vj)) * v_vx) + (((v_va * v_vj) - (v_vc * v_vg)) * v_vy)) + (((v_vc * v_vd) - (v_va * v_vf)) * v_vz)) * v_viewInverse);
  v_world[2i] = ((((((v_vd * v_vh) - (v_ve * v_vg)) * v_vx) + (((v_vb * v_vg) - (v_va * v_vh)) * v_vy)) + (((v_va * v_ve) - (v_vb * v_vd)) * v_vz)) * v_viewInverse);
  v_world[3i] = v_view[3i];
  var v_wind: f32 = b_params[(v_p + u32(32i))];
  var v_time: f32 = b_params[(v_p + u32(33i))];
  var v_speed: f32 = sqrt((((2.0f * v_wind) * v_wind) + 1.0f));
  var v_dx: f32 = (v_world[0i] - b_params[(v_p + u32(34i))]);
  var v_dy: f32 = (v_world[1i] - b_params[(v_p + u32(35i))]);
  var v_footDistance: f32 = sqrt(((v_dx * v_dx) + (v_dy * v_dy)));
  var v_stomp: f32 = 0.0f;
  if ((b_params[(v_p + u32(37i))] > 0.5f)) {
    var cw_tmp_8: f32;
    if ((b_params[(v_p + u32(38i))] < 0.5f)) {
      cw_tmp_8 = 50.0f;
    } else {
      var cw_tmp_7: f32;
      if ((b_params[(v_p + u32(38i))] < 1.5f)) {
        cw_tmp_7 = 80.0f;
      } else {
        cw_tmp_7 = 150.0f;
      }
      cw_tmp_8 = cw_tmp_7;
    }
    var v_range: f32 = cw_tmp_8;
    var cw_tmp_10: f32;
    if ((b_params[(v_p + u32(38i))] < 0.5f)) {
      cw_tmp_10 = 20.0f;
    } else {
      var cw_tmp_9: f32;
      if ((b_params[(v_p + u32(38i))] < 1.5f)) {
        cw_tmp_9 = 40.0f;
      } else {
        cw_tmp_9 = 60.0f;
      }
      cw_tmp_10 = cw_tmp_9;
    }
    var v_reach: f32 = cw_tmp_10;
    if (((v_footDistance > 0.0f) && (v_footDistance < v_range))) {
      v_stomp = (cw_divide_f32(v_reach, v_footDistance) - cw_divide_f32(v_reach, v_range));
    }
    if ((b_params[(v_p + u32(37i))] > 1.5f)) {
      var cw_tmp_11: f32;
      if ((v_height != 0.0f)) {
        cw_tmp_11 = cw_divide_f32((v_world[2i] - b_params[(v_p + u32(36i))]), v_height);
      } else {
        cw_tmp_11 = 0.0f;
      }
      var v_relative: f32 = cw_tmp_11;
      v_stomp = (v_stomp * min(1.0f, max(0.0f, v_relative)));
    }
  }
  var v_bend: f32 = min(1.0f, max(0.0f, (0.02f * v_height)));
  {
    var v_axis: u32 = u32(0i);
    loop {
      if (!(v_axis < u32(2i))) { break; }
      var v_coordinate: f32 = v_world[v_axis];
      var v_harmonics: f32 = (((((1.0f - (0.1f * v_speed)) * sin((v_time + cw_divide_f32(v_coordinate, 1100.0f)))) + ((1.0f - (0.04f * v_speed)) * cos(((2.0f * v_time) + cw_divide_f32(v_coordinate, 750.0f))))) + ((1.0f + (0.14f * v_speed)) * sin(((3.0f * v_time) + cw_divide_f32(v_coordinate, 500.0f))))) + ((1.0f + (0.28f * v_speed)) * sin(((5.0f * v_time) + cw_divide_f32(v_coordinate, 200.0f)))));
      var cw_tmp_12: f32;
      if ((v_axis == u32(0i))) {
        cw_tmp_12 = v_dx;
      } else {
        cw_tmp_12 = v_dy;
      }
      v_world[v_axis] = (v_world[v_axis] + (v_bend * ((v_harmonics * ((2.0f * v_wind) + 0.1f)) + (v_stomp * cw_tmp_12))));
      continuing {
        v_axis += u32(1);
      }
    }
  }
  {
    var v_row: u32 = u32(0i);
    loop {
      if (!(v_row < u32(4i))) { break; }
      v_view[v_row] = 0.0f;
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(4i))) { break; }
          v_view[v_row] = (v_view[v_row] + (b_params[(((v_p + u32(16i)) + (v_col * u32(4i))) + v_row)] * v_world[v_col]));
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
  var v_aa: f32 = b_matrices[v_m];
  var v_b: f32 = b_matrices[(v_m + u32(4i))];
  var v_c: f32 = b_matrices[(v_m + u32(8i))];
  var v_d: f32 = b_matrices[(v_m + u32(1i))];
  var v_e: f32 = b_matrices[(v_m + u32(5i))];
  var v_f: f32 = b_matrices[(v_m + u32(9i))];
  var v_g: f32 = b_matrices[(v_m + u32(2i))];
  var v_h: f32 = b_matrices[(v_m + u32(6i))];
  var v_j: f32 = b_matrices[(v_m + u32(10i))];
  var v_det: f32 = (((v_aa * ((v_e * v_j) - (v_f * v_h))) - (v_b * ((v_d * v_j) - (v_f * v_g)))) + (v_c * ((v_d * v_h) - (v_e * v_g))));
  var cw_tmp_13: f32;
  if ((abs(v_det) > 1e-12f)) {
    cw_tmp_13 = cw_divide_f32(1.0f, v_det);
  } else {
    cw_tmp_13 = 0.0f;
  }
  var v_inverse: f32 = cw_tmp_13;
  var v_x: f32 = (v_view[0i] - (b_matrices[(v_m + u32(12i))] * v_view[3i]));
  var v_y: f32 = (v_view[1i] - (b_matrices[(v_m + u32(13i))] * v_view[3i]));
  var v_z: f32 = (v_view[2i] - (b_matrices[(v_m + u32(14i))] * v_view[3i]));
  b_vertices[v_v] = ((((((v_e * v_j) - (v_f * v_h)) * v_x) + (((v_c * v_h) - (v_b * v_j)) * v_y)) + (((v_b * v_f) - (v_c * v_e)) * v_z)) * v_inverse);
  b_vertices[(v_v + u32(1i))] = ((((((v_f * v_g) - (v_d * v_j)) * v_x) + (((v_aa * v_j) - (v_c * v_g)) * v_y)) + (((v_c * v_d) - (v_aa * v_f)) * v_z)) * v_inverse);
  b_vertices[(v_v + u32(2i))] = ((((((v_d * v_h) - (v_e * v_g)) * v_x) + (((v_b * v_g) - (v_aa * v_h)) * v_y)) + (((v_aa * v_e) - (v_b * v_d)) * v_z)) * v_inverse);
  b_vertices[(v_v + u32(3i))] = v_view[3i];
  {
    var v_axis: u32 = u32(0i);
    loop {
      if (!(v_axis < u32(3i))) { break; }
      b_attributes[((v_a + u32(3i)) + v_axis)] = v_normal[v_axis];
      b_attributes[((v_a + u32(6i)) + v_axis)] = v_tangent[v_axis];
      continuing {
        v_axis += u32(1);
      }
    }
  }
}
