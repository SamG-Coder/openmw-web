// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: generate_texture_coordinates.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read> b_source_attributes: array<f32>;
@group(0) @binding(2) var<storage, read> b_matrices: array<f32>;
@group(0) @binding(3) var<storage, read> b_matrix_ids: array<u32>;
@group(0) @binding(4) var<storage, read> b_descriptors: array<u32>;
@group(0) @binding(5) var<storage, read_write> b_attributes: array<f32>;
struct KernelParams {
  p_vertex_count: u32,
  gpu_pad_4: u32,
  gpu_pad_8: u32,
  gpu_pad_12: u32,
}
@group(0) @binding(6) var<uniform> gpu_params: KernelParams;
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
  var v_draw: u32 = b_matrix_ids[v_i];
  var v_v: u32 = (v_i * 34u);
  var v_m: u32 = (v_draw * 32u);
  var v_normal: array<f32, 3>;
  var v_unitNormal: array<f32, 3>;
  var v_reflected: array<f32, 3>;
  var v_eye: array<f32, 3>;
  var v_a: f32 = b_matrices[v_m];
  var v_b: f32 = b_matrices[(v_m + 4u)];
  var v_c: f32 = b_matrices[(v_m + 8u)];
  var v_d: f32 = b_matrices[(v_m + 1u)];
  var v_e: f32 = b_matrices[(v_m + 5u)];
  var v_f: f32 = b_matrices[(v_m + 9u)];
  var v_g: f32 = b_matrices[(v_m + 2u)];
  var v_h: f32 = b_matrices[(v_m + 6u)];
  var v_j: f32 = b_matrices[(v_m + 10u)];
  var v_determinant: f32 = (((v_a * ((v_e * v_j) - (v_f * v_h))) - (v_b * ((v_d * v_j) - (v_f * v_g)))) + (v_c * ((v_d * v_h) - (v_e * v_g))));
  var gpu_tmp_0: f32;
  if ((abs(v_determinant) > 1e-12f)) {
    gpu_tmp_0 = gpu_divide_f32(1.0f, v_determinant);
  } else {
    gpu_tmp_0 = 0.0f;
  }
  var v_inverse: f32 = gpu_tmp_0;
  var v_nx: f32 = b_source_attributes[(v_v + 3u)];
  var v_ny: f32 = b_source_attributes[(v_v + 4u)];
  var v_nz: f32 = b_source_attributes[(v_v + 5u)];
  v_normal[0i] = ((((((v_e * v_j) - (v_f * v_h)) * v_nx) + (((v_f * v_g) - (v_d * v_j)) * v_ny)) + (((v_d * v_h) - (v_e * v_g)) * v_nz)) * v_inverse);
  v_normal[1i] = ((((((v_c * v_h) - (v_b * v_j)) * v_nx) + (((v_a * v_j) - (v_c * v_g)) * v_ny)) + (((v_b * v_g) - (v_a * v_h)) * v_nz)) * v_inverse);
  v_normal[2i] = ((((((v_b * v_f) - (v_c * v_e)) * v_nx) + (((v_c * v_d) - (v_a * v_f)) * v_ny)) + (((v_a * v_e) - (v_b * v_d)) * v_nz)) * v_inverse);
  var v_length: f32 = 0.0f;
  var v_eyeLength: f32 = 0.0f;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_length = (v_length + (v_normal[v_k] * v_normal[v_k]));
      v_eye[v_k] = b_attributes[(v_v + v_k)];
      v_eyeLength = (v_eyeLength + (v_eye[v_k] * v_eye[v_k]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  v_length = sqrt(max(v_length, 1e-12f));
  v_eyeLength = sqrt(max(v_eyeLength, 1e-12f));
  var v_dot: f32 = 0.0f;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_unitNormal[v_k] = gpu_divide_f32(v_normal[v_k], v_length);
      v_eye[v_k] = gpu_divide_f32(v_eye[v_k], v_eyeLength);
      v_dot = (v_dot + (v_eye[v_k] * v_unitNormal[v_k]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_reflected[v_k] = (v_eye[v_k] - ((2.0f * v_dot) * v_unitNormal[v_k]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_sphere: f32 = (2.0f * sqrt(max(1e-12f, (((v_reflected[0i] * v_reflected[0i]) + (v_reflected[1i] * v_reflected[1i])) + ((v_reflected[2i] + 1.0f) * (v_reflected[2i] + 1.0f))))));
  var v_rx: f32 = (((v_d * v_h) - (v_e * v_g)) * v_inverse);
  var v_ry: f32 = (((v_b * v_g) - (v_a * v_h)) * v_inverse);
  var v_rz: f32 = (((v_a * v_e) - (v_b * v_d)) * v_inverse);
  var v_rescale: f32 = gpu_divide_f32(1.0f, sqrt(max((((v_rx * v_rx) + (v_ry * v_ry)) + (v_rz * v_rz)), 1e-12f)));
  {
    var v_unit: u32 = u32(0i);
    loop {
      if (!(v_unit < u32(4i))) { break; }
      var v_descriptor: u32 = ((v_draw * 144u) + (v_unit * 36u));
      var v_mask: u32 = b_descriptors[v_descriptor];
      var v_mode: u32 = b_descriptors[(v_descriptor + 1u)];
      var v_planePosition: array<f32, 4>;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(4i))) { break; }
          v_planePosition[v_k] = b_source[((v_i * 10u) + v_k)];
          continuing {
            v_k += u32(1);
          }
        }
      }
      if (((v_mode == 5u) && (v_mask != 0u))) {
        var v_system: array<f32, 20>;
        {
          var v_row: u32 = u32(0i);
          loop {
            if (!(v_row < u32(4i))) { break; }
            var v_eyePosition: f32 = 0.0f;
            {
              var v_col: u32 = u32(0i);
              loop {
                if (!(v_col < u32(4i))) { break; }
                let gpu_argument_index_1 = (((v_descriptor + 20u) + (v_col * 4u)) + v_row);
                v_system[((v_row * 5u) + v_col)] = bitcast<f32>(b_descriptors[gpu_argument_index_1]);
                v_eyePosition = (v_eyePosition + (b_matrices[((v_m + (v_col * 4u)) + v_row)] * b_source[((v_i * 10u) + v_col)]));
                continuing {
                  v_col += u32(1);
                }
              }
            }
            v_system[((v_row * 5u) + 4u)] = v_eyePosition;
            continuing {
              v_row += u32(1);
            }
          }
        }
        var v_valid: u32 = 1u;
        {
          var v_pivot: u32 = u32(0i);
          loop {
            if (!(v_pivot < u32(4i))) { break; }
            var v_selected: u32 = v_pivot;
            {
              var v_row: u32 = (v_pivot + 1u);
              loop {
                if (!(v_row < u32(4i))) { break; }
                let gpu_argument_index_2 = ((v_row * 5u) + v_pivot);
                let gpu_argument_index_3 = ((v_selected * 5u) + v_pivot);
                if ((abs(v_system[gpu_argument_index_2]) > abs(v_system[gpu_argument_index_3]))) {
                  v_selected = v_row;
                }
                continuing {
                  v_row += u32(1);
                }
              }
            }
            {
              var v_col: u32 = u32(0i);
              loop {
                if (!(v_col < u32(5i))) { break; }
                var v_saved: f32 = v_system[((v_pivot * 5u) + v_col)];
                v_system[((v_pivot * 5u) + v_col)] = v_system[((v_selected * 5u) + v_col)];
                v_system[((v_selected * 5u) + v_col)] = v_saved;
                continuing {
                  v_col += u32(1);
                }
              }
            }
            var v_divisor: f32 = v_system[((v_pivot * 5u) + v_pivot)];
            if ((v_divisor == 0.0f)) {
              v_valid = 0u;
              break;
            }
            {
              var v_col: u32 = u32(0i);
              loop {
                if (!(v_col < u32(5i))) { break; }
                v_system[((v_pivot * 5u) + v_col)] = gpu_divide_f32(v_system[((v_pivot * 5u) + v_col)], v_divisor);
                continuing {
                  v_col += u32(1);
                }
              }
            }
            {
              var v_row: u32 = u32(0i);
              loop {
                if (!(v_row < u32(4i))) { break; }
                if ((v_row != v_pivot)) {
                  var v_factor: f32 = v_system[((v_row * 5u) + v_pivot)];
                  {
                    var v_col: u32 = u32(0i);
                    loop {
                      if (!(v_col < u32(5i))) { break; }
                      v_system[((v_row * 5u) + v_col)] = (v_system[((v_row * 5u) + v_col)] - (v_factor * v_system[((v_pivot * 5u) + v_col)]));
                      continuing {
                        v_col += u32(1);
                      }
                    }
                  }
                }
                continuing {
                  v_row += u32(1);
                }
              }
            }
            continuing {
              v_pivot += u32(1);
            }
          }
        }
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(4i))) { break; }
            var gpu_tmp_4: f32;
            if ((v_valid != 0u)) {
              gpu_tmp_4 = v_system[((v_k * 5u) + 4u)];
            } else {
              gpu_tmp_4 = 0.0f;
            }
            v_planePosition[v_k] = gpu_tmp_4;
            continuing {
              v_k += u32(1);
            }
          }
        }
      }
      {
        var v_coordinate: u32 = u32(0i);
        loop {
          if (!(v_coordinate < u32(4i))) { break; }
          if (((v_mask & (1u << v_coordinate)) != 0u)) {
            var v_value: f32 = 0.0f;
            if (((v_mode == 1u) || (v_mode == 5u))) {
              {
                var v_k: u32 = u32(0i);
                loop {
                  if (!(v_k < u32(4i))) { break; }
                  let gpu_argument_index_5 = (((v_descriptor + 4u) + (v_coordinate * 4u)) + v_k);
                  v_value = (v_value + (v_planePosition[v_k] * bitcast<f32>(b_descriptors[gpu_argument_index_5])));
                  continuing {
                    v_k += u32(1);
                  }
                }
              }
            } else {
              if ((v_mode == 2u)) {
                v_value = (gpu_divide_f32(v_reflected[v_coordinate], v_sphere) + 0.5f);
              } else {
                if ((v_mode == 3u)) {
                  var v_flags: u32 = b_descriptors[(v_descriptor + 2u)];
                  var gpu_tmp_7: f32;
                  if (((v_flags & 1u) != 0u)) {
                    gpu_tmp_7 = v_unitNormal[v_coordinate];
                  } else {
                    var gpu_tmp_6: f32;
                    if (((v_flags & 2u) != 0u)) {
                      gpu_tmp_6 = v_rescale;
                    } else {
                      gpu_tmp_6 = 1.0f;
                    }
                    gpu_tmp_7 = (v_normal[v_coordinate] * gpu_tmp_6);
                  }
                  v_value = gpu_tmp_7;
                } else {
                  v_value = v_reflected[v_coordinate];
                }
              }
            }
            var gpu_tmp_9: u32;
            if ((v_coordinate < 2u)) {
              var gpu_tmp_8: u32;
              if ((v_unit == 0u)) {
                gpu_tmp_8 = 16u;
              } else {
                gpu_tmp_8 = (10u + ((v_unit - 1u) * 2u));
              }
              gpu_tmp_9 = (gpu_tmp_8 + v_coordinate);
            } else {
              gpu_tmp_9 = (((26u + (v_unit * 2u)) + v_coordinate) - 2u);
            }
            var v_offset: u32 = gpu_tmp_9;
            b_attributes[(v_v + v_offset)] = v_value;
          }
          continuing {
            v_coordinate += u32(1);
          }
        }
      }
      continuing {
        v_unit += u32(1);
      }
    }
  }
}
