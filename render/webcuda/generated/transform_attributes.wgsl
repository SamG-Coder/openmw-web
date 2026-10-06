// CUDA WebShader 0.1.1. Generated from kernel transform_attributes.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read> b_attributes: array<f32>;
@group(0) @binding(2) var<storage, read> b_matrices: array<f32>;
@group(0) @binding(3) var<storage, read> b_matrix_ids: array<u32>;
@group(0) @binding(4) var<storage, read_write> b_output: array<f32>;
@group(0) @binding(5) var<storage, read_write> b_lighting_origins: array<u32>;
struct CWParams {
  p_vertex_count: u32,
  p_track_lighting: u32,
  p_source_point_fade_offset: u32,
  cw_pad_12: u32,
}
@group(0) @binding(6) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn cw_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_i: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_i >= cw_params.p_vertex_count)) {
    return;
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(12i))) { break; }
      var cw_tmp_0: f32;
      if ((v_k == u32(0i))) {
        cw_tmp_0 = 1.0f;
      } else {
        cw_tmp_0 = 0.0f;
      }
      b_output[((cw_params.p_source_point_fade_offset + (v_i * u32(12i))) + v_k)] = cw_tmp_0;
      continuing {
        v_k += u32(1);
      }
    }
  }
  if ((cw_params.p_track_lighting != u32(0i))) {
    b_lighting_origins[(v_i * u32(3i))] = v_i;
    b_lighting_origins[((v_i * u32(3i)) + u32(1i))] = v_i;
    b_lighting_origins[((v_i * u32(3i)) + u32(2i))] = u32(0i);
  }
  var v_m: u32 = (b_matrix_ids[v_i] * u32(32i));
  var v_d: u32 = (v_i * u32(34i));
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(34i))) { break; }
      b_output[(v_d + v_k)] = b_attributes[(v_d + v_k)];
      continuing {
        v_k += u32(1);
      }
    }
  }
  if (((b_attributes[v_d] >= 5.0f) && (b_attributes[v_d] <= 8.0f))) {
    {
      var v_k: u32 = u32(10i);
      loop {
        if (!(v_k < u32(16i))) { break; }
        b_output[(v_d + v_k)] = 0.0f;
        continuing {
          v_k += u32(1);
        }
      }
    }
  }
  {
    var v_row: u32 = u32(0i);
    loop {
      if (!(v_row < u32(3i))) { break; }
      var v_value: f32 = 0.0f;
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(4i))) { break; }
          v_value = (v_value + (b_matrices[((v_m + (v_col * u32(4i))) + v_row)] * b_source[((v_i * u32(10i)) + v_col)]));
          continuing {
            v_col += u32(1);
          }
        }
      }
      b_output[(v_d + v_row)] = v_value;
      continuing {
        v_row += u32(1);
      }
    }
  }
  var v_a: f32 = b_matrices[v_m];
  var v_b: f32 = b_matrices[(v_m + u32(4i))];
  var v_c: f32 = b_matrices[(v_m + u32(8i))];
  var v_e: f32 = b_matrices[(v_m + u32(1i))];
  var v_f: f32 = b_matrices[(v_m + u32(5i))];
  var v_g: f32 = b_matrices[(v_m + u32(9i))];
  var v_h: f32 = b_matrices[(v_m + u32(2i))];
  var v_j: f32 = b_matrices[(v_m + u32(6i))];
  var v_k: f32 = b_matrices[(v_m + u32(10i))];
  var v_determinant: f32 = (((v_a * ((v_f * v_k) - (v_g * v_j))) - (v_b * ((v_e * v_k) - (v_g * v_h)))) + (v_c * ((v_e * v_j) - (v_f * v_h))));
  var cw_tmp_1: f32;
  if ((abs(v_determinant) > 1e-12f)) {
    cw_tmp_1 = cw_divide_f32(1.0f, v_determinant);
  } else {
    cw_tmp_1 = 0.0f;
  }
  var v_inv: f32 = cw_tmp_1;
  var v_nx: f32 = b_attributes[(v_d + u32(3i))];
  var v_ny: f32 = b_attributes[(v_d + u32(4i))];
  var v_nz: f32 = b_attributes[(v_d + u32(5i))];
  b_output[(v_d + u32(3i))] = ((((((v_f * v_k) - (v_g * v_j)) * v_nx) + (((v_g * v_h) - (v_e * v_k)) * v_ny)) + (((v_e * v_j) - (v_f * v_h)) * v_nz)) * v_inv);
  b_output[(v_d + u32(4i))] = ((((((v_c * v_j) - (v_b * v_k)) * v_nx) + (((v_a * v_k) - (v_c * v_h)) * v_ny)) + (((v_b * v_h) - (v_a * v_j)) * v_nz)) * v_inv);
  b_output[(v_d + u32(5i))] = ((((((v_b * v_g) - (v_c * v_f)) * v_nx) + (((v_c * v_e) - (v_a * v_g)) * v_ny)) + (((v_a * v_f) - (v_b * v_e)) * v_nz)) * v_inv);
  var v_nl: f32 = sqrt(max((((v_nx * v_nx) + (v_ny * v_ny)) + (v_nz * v_nz)), 1e-12f));
  var v_tx: f32 = b_attributes[(v_d + u32(6i))];
  var v_ty: f32 = b_attributes[(v_d + u32(7i))];
  var v_tz: f32 = b_attributes[(v_d + u32(8i))];
  var v_tl: f32 = sqrt(max((((v_tx * v_tx) + (v_ty * v_ty)) + (v_tz * v_tz)), 1e-12f));
  v_tx = cw_divide_f32(v_tx, v_tl);
  v_ty = cw_divide_f32(v_ty, v_tl);
  v_tz = cw_divide_f32(v_tz, v_tl);
  v_nx = cw_divide_f32(v_nx, v_nl);
  v_ny = cw_divide_f32(v_ny, v_nl);
  v_nz = cw_divide_f32(v_nz, v_nl);
  var v_handed: f32 = b_attributes[(v_d + u32(9i))];
  var v_bx: f32 = (((v_ny * v_tz) - (v_nz * v_ty)) * v_handed);
  var v_by: f32 = (((v_nz * v_tx) - (v_nx * v_tz)) * v_handed);
  var v_bz: f32 = (((v_nx * v_ty) - (v_ny * v_tx)) * v_handed);
  if ((b_attributes[v_d] == 1.0f)) {
    v_bx = 0.0f;
    v_by = v_nz;
    v_bz = (-v_ny);
    v_tx = (-((v_ny * v_bz) - (v_nz * v_by)));
    v_ty = (-((v_nz * v_bx) - (v_nx * v_bz)));
    v_tz = (-((v_nx * v_by) - (v_ny * v_bx)));
    var v_length: f32 = sqrt(max((((v_tx * v_tx) + (v_ty * v_ty)) + (v_tz * v_tz)), 1e-12f));
    v_tx = cw_divide_f32(v_tx, v_length);
    v_ty = cw_divide_f32(v_ty, v_length);
    v_tz = cw_divide_f32(v_tz, v_length);
  }
  {
    var v_basis: u32 = u32(0i);
    loop {
      if (!(v_basis < u32(3i))) { break; }
      var cw_tmp_3: f32;
      if ((v_basis == u32(0i))) {
        cw_tmp_3 = v_tx;
      } else {
        var cw_tmp_2: f32;
        if ((v_basis == u32(1i))) {
          cw_tmp_2 = v_bx;
        } else {
          cw_tmp_2 = v_nx;
        }
        cw_tmp_3 = cw_tmp_2;
      }
      var v_x: f32 = cw_tmp_3;
      var cw_tmp_5: f32;
      if ((v_basis == u32(0i))) {
        cw_tmp_5 = v_ty;
      } else {
        var cw_tmp_4: f32;
        if ((v_basis == u32(1i))) {
          cw_tmp_4 = v_by;
        } else {
          cw_tmp_4 = v_ny;
        }
        cw_tmp_5 = cw_tmp_4;
      }
      var v_y: f32 = cw_tmp_5;
      var cw_tmp_7: f32;
      if ((v_basis == u32(0i))) {
        cw_tmp_7 = v_tz;
      } else {
        var cw_tmp_6: f32;
        if ((v_basis == u32(1i))) {
          cw_tmp_6 = v_bz;
        } else {
          cw_tmp_6 = v_nz;
        }
        cw_tmp_7 = cw_tmp_6;
      }
      var v_z: f32 = cw_tmp_7;
      var cw_tmp_9: i32;
      if ((v_basis == u32(0i))) {
        cw_tmp_9 = 6i;
      } else {
        var cw_tmp_8: i32;
        if ((v_basis == u32(1i))) {
          cw_tmp_8 = 18i;
        } else {
          cw_tmp_8 = 3i;
        }
        cw_tmp_9 = cw_tmp_8;
      }
      var v_offset: u32 = u32(cw_tmp_9);
      b_output[(v_d + v_offset)] = ((((((v_f * v_k) - (v_g * v_j)) * v_x) + (((v_g * v_h) - (v_e * v_k)) * v_y)) + (((v_e * v_j) - (v_f * v_h)) * v_z)) * v_inv);
      b_output[((v_d + v_offset) + u32(1i))] = ((((((v_c * v_j) - (v_b * v_k)) * v_x) + (((v_a * v_k) - (v_c * v_h)) * v_y)) + (((v_b * v_h) - (v_a * v_j)) * v_z)) * v_inv);
      b_output[((v_d + v_offset) + u32(2i))] = ((((((v_b * v_g) - (v_c * v_f)) * v_x) + (((v_c * v_e) - (v_a * v_g)) * v_y)) + (((v_a * v_f) - (v_b * v_e)) * v_z)) * v_inv);
      continuing {
        v_basis += u32(1);
      }
    }
  }
  var v_eye: array<f32, 3>;
  var v_normal: array<f32, 3>;
  var v_eyeLength: f32 = 0.0f;
  var v_normalLength: f32 = 0.0f;
  var v_dot: f32 = 0.0f;
  {
    var v_row: u32 = u32(0i);
    loop {
      if (!(v_row < u32(3i))) { break; }
      v_eye[v_row] = b_output[(v_d + v_row)];
      v_normal[v_row] = b_output[((v_d + u32(3i)) + v_row)];
      v_eyeLength = (v_eyeLength + (v_eye[v_row] * v_eye[v_row]));
      v_normalLength = (v_normalLength + (v_normal[v_row] * v_normal[v_row]));
      continuing {
        v_row += u32(1);
      }
    }
  }
  v_eyeLength = sqrt(max(v_eyeLength, 1e-12f));
  v_normalLength = sqrt(max(v_normalLength, 1e-12f));
  b_output[(v_d + u32(9i))] = v_eyeLength;
  {
    var v_row: u32 = u32(0i);
    loop {
      if (!(v_row < u32(3i))) { break; }
      v_eye[v_row] = cw_divide_f32(v_eye[v_row], v_eyeLength);
      v_normal[v_row] = cw_divide_f32(v_normal[v_row], v_normalLength);
      v_dot = (v_dot + (v_eye[v_row] * v_normal[v_row]));
      b_output[((v_d + u32(23i)) + v_row)] = v_normal[v_row];
      continuing {
        v_row += u32(1);
      }
    }
  }
  var v_reflected: array<f32, 3>;
  {
    var v_row: u32 = u32(0i);
    loop {
      if (!(v_row < u32(3i))) { break; }
      v_reflected[v_row] = (v_eye[v_row] - ((2.0f * v_dot) * v_normal[v_row]));
      continuing {
        v_row += u32(1);
      }
    }
  }
  var v_denominator: f32 = (2.0f * sqrt(max(1e-12f, (((v_reflected[0i] * v_reflected[0i]) + (v_reflected[1i] * v_reflected[1i])) + ((v_reflected[2i] + 1.0f) * (v_reflected[2i] + 1.0f))))));
  b_output[(v_d + u32(21i))] = (cw_divide_f32(v_reflected[0i], v_denominator) + 0.5f);
  b_output[(v_d + u32(22i))] = (cw_divide_f32(v_reflected[1i], v_denominator) + 0.5f);
  if ((b_attributes[v_d] == (-1.0f))) {
    b_output[(v_d + u32(9i))] = b_attributes[(v_d + u32(2i))];
  }
}
