// CUDA WebShader 0.1.1. Generated from kernel prepare_ribbon.
@group(0) @binding(0) var<storage, read> b_particles: array<f32>;
@group(0) @binding(1) var<storage, read> b_matrices: array<f32>;
@group(0) @binding(2) var<storage, read_write> b_vertices: array<f32>;
@group(0) @binding(3) var<storage, read_write> b_summary: array<u32>;
struct CWParams {
  p_particle_count: u32,
  p_max_skip: u32,
  p_width: u32,
  p_height: u32,
}
@group(0) @binding(4) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn cw_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_i: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_i != 0u)) {
    return;
  }
  b_summary[0i] = 0u;
  b_summary[1i] = 0u;
  b_summary[2i] = 0u;
  if ((cw_params.p_particle_count == 0u)) {
    return;
  }
  var v_p00: f32 = (b_matrices[16i] * (f32(cw_params.p_width) * 0.5f));
  var v_p20: f32 = ((b_matrices[24i] + b_matrices[27i]) * (f32(cw_params.p_width) * 0.5f));
  var v_p11: f32 = (b_matrices[21i] * (f32(cw_params.p_height) * 0.5f));
  var v_p21: f32 = ((b_matrices[25i] + b_matrices[27i]) * (f32(cw_params.p_height) * 0.5f));
  var v_magnitude: f32 = 0.0f;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      var v_a: f32 = ((b_matrices[(v_k * u32(4i))] * v_p00) + (b_matrices[((v_k * u32(4i)) + u32(2i))] * v_p20));
      var v_b: f32 = ((b_matrices[((v_k * u32(4i)) + u32(1i))] * v_p11) + (b_matrices[((v_k * u32(4i)) + u32(2i))] * v_p21));
      v_magnitude = (v_magnitude + ((v_a * v_a) + (v_b * v_b)));
      continuing {
        v_k += u32(1);
      }
    }
  }
  if ((v_magnitude <= 0.0f)) {
    b_summary[2i] = 1u;
    return;
  }
  var v_ratio: f32 = cw_divide_f32(0.7071067811f, sqrt(v_magnitude));
  var v_inverse_pixel: f32 = ((b_matrices[14i] * b_matrices[27i]) + (b_matrices[15i] * b_matrices[31i]));
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_inverse_pixel = (v_inverse_pixel + ((b_particles[v_k] * b_matrices[((v_k * u32(4i)) + u32(2i))]) * b_matrices[27i]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  v_inverse_pixel = (v_inverse_pixel * v_ratio);
  var v_error2: f32 = (v_inverse_pixel * v_inverse_pixel);
  var cw_tmp_0: u32;
  if ((abs(v_inverse_pixel) > b_particles[3i])) {
    cw_tmp_0 = 1u;
  } else {
    cw_tmp_0 = 0u;
  }
  var v_thin: u32 = cw_tmp_0;
  b_summary[1i] = v_thin;
  var v_eye: array<f32, 3>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_eye[v_k] = 0.0f;
      continuing {
        v_k += u32(1);
      }
    }
  }
  if ((v_thin == 0u)) {
    var v_augmented: array<f32, 32>;
    {
      var v_row: u32 = u32(0i);
      loop {
        if (!(v_row < u32(4i))) { break; }
        {
          var v_col: u32 = u32(0i);
          loop {
            if (!(v_col < u32(4i))) { break; }
            v_augmented[((v_row * u32(8i)) + v_col)] = b_matrices[((v_col * u32(4i)) + v_row)];
            var cw_tmp_1: f32;
            if ((v_row == v_col)) {
              cw_tmp_1 = 1.0f;
            } else {
              cw_tmp_1 = 0.0f;
            }
            v_augmented[(((v_row * u32(8i)) + u32(4i)) + v_col)] = cw_tmp_1;
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
      var v_col: u32 = u32(0i);
      loop {
        if (!(v_col < u32(4i))) { break; }
        var v_pivot: u32 = v_col;
        let cw_argument_index_2 = ((v_col * u32(8i)) + v_col);
        var v_largest: f32 = abs(v_augmented[cw_argument_index_2]);
        {
          var v_row: u32 = (v_col + u32(1i));
          loop {
            if (!(v_row < u32(4i))) { break; }
            let cw_argument_index_3 = ((v_row * u32(8i)) + v_col);
            if ((abs(v_augmented[cw_argument_index_3]) > v_largest)) {
              v_pivot = v_row;
              let cw_argument_index_4 = ((v_row * u32(8i)) + v_col);
              v_largest = abs(v_augmented[cw_argument_index_4]);
            }
            continuing {
              v_row += u32(1);
            }
          }
        }
        if ((v_largest < 1e-12f)) {
          b_summary[2i] = 1u;
          return;
        }
        if ((v_pivot != v_col)) {
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(8i))) { break; }
              var v_temp: f32 = v_augmented[((v_col * u32(8i)) + v_k)];
              v_augmented[((v_col * u32(8i)) + v_k)] = v_augmented[((v_pivot * u32(8i)) + v_k)];
              v_augmented[((v_pivot * u32(8i)) + v_k)] = v_temp;
              continuing {
                v_k += u32(1);
              }
            }
          }
        }
        var v_divisor: f32 = v_augmented[((v_col * u32(8i)) + v_col)];
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(8i))) { break; }
            v_augmented[((v_col * u32(8i)) + v_k)] = cw_divide_f32(v_augmented[((v_col * u32(8i)) + v_k)], v_divisor);
            continuing {
              v_k += u32(1);
            }
          }
        }
        {
          var v_row: u32 = u32(0i);
          loop {
            if (!(v_row < u32(4i))) { break; }
            if ((v_row != v_col)) {
              var v_factor: f32 = v_augmented[((v_row * u32(8i)) + v_col)];
              {
                var v_k: u32 = u32(0i);
                loop {
                  if (!(v_k < u32(8i))) { break; }
                  v_augmented[((v_row * u32(8i)) + v_k)] = (v_augmented[((v_row * u32(8i)) + v_k)] - (v_factor * v_augmented[((v_col * u32(8i)) + v_k)]));
                  continuing {
                    v_k += u32(1);
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
          v_col += u32(1);
        }
      }
    }
    var v_w: f32 = v_augmented[31i];
    if ((abs(v_w) < 1e-12f)) {
      b_summary[2i] = 1u;
      return;
    }
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(3i))) { break; }
        v_eye[v_k] = cw_divide_f32(v_augmented[((v_k * u32(8i)) + u32(7i))], v_w);
        continuing {
          v_k += u32(1);
        }
      }
    }
  }
  var v_delta: array<f32, 3>;
  v_delta[0i] = 0.0f;
  v_delta[1i] = 0.0f;
  v_delta[2i] = 1.0f;
  var v_current: u32 = 0u;
  var v_selected: u32 = 0u;
  {
    loop {
      if (!(v_current < cw_params.p_particle_count)) { break; }
      var v_next: u32 = (v_current + 1u);
      if ((v_next < cw_params.p_particle_count)) {
        var v_direction: array<f32, 3>;
        var v_length2: f32 = 0.0f;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            v_delta[v_k] = (b_particles[((v_next * 10u) + v_k)] - b_particles[((v_current * 10u) + v_k)]);
            v_direction[v_k] = v_delta[v_k];
            v_length2 = (v_length2 + (v_delta[v_k] * v_delta[v_k]));
            continuing {
              v_k += u32(1);
            }
          }
        }
        if ((v_length2 > 0.0f)) {
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              v_direction[v_k] = cw_divide_f32(v_direction[v_k], sqrt(v_length2));
              continuing {
                v_k += u32(1);
              }
            }
          }
        }
        var v_distance2: f32 = 0.0f;
        {
          var v_skipped: u32 = u32(0i);
          loop {
            if (!(((v_skipped < cw_params.p_max_skip) && (v_distance2 < v_error2)) && ((v_next + 1u) < cw_params.p_particle_count))) { break; }
            v_next += u32(1);
            {
              var v_k: u32 = u32(0i);
              loop {
                if (!(v_k < u32(3i))) { break; }
                v_delta[v_k] = (b_particles[((v_next * 10u) + v_k)] - b_particles[((v_current * 10u) + v_k)]);
                continuing {
                  v_k += u32(1);
                }
              }
            }
            var v_x: f32 = ((v_delta[1i] * v_direction[2i]) - (v_delta[2i] * v_direction[1i]));
            var v_y: f32 = ((v_delta[2i] * v_direction[0i]) - (v_delta[0i] * v_direction[2i]));
            var v_z: f32 = ((v_delta[0i] * v_direction[1i]) - (v_delta[1i] * v_direction[0i]));
            v_distance2 = (((v_x * v_x) + (v_y * v_y)) + (v_z * v_z));
            continuing {
              v_skipped += u32(1);
            }
          }
        }
      }
      var v_offset: array<f32, 3>;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          v_offset[v_k] = 0.0f;
          continuing {
            v_k += u32(1);
          }
        }
      }
      if ((v_thin == 0u)) {
        var v_eye_direction: array<f32, 3>;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            v_eye_direction[v_k] = (b_particles[((v_current * 10u) + v_k)] - v_eye[v_k]);
            continuing {
              v_k += u32(1);
            }
          }
        }
        v_offset[0i] = ((v_delta[1i] * v_eye_direction[2i]) - (v_delta[2i] * v_eye_direction[1i]));
        v_offset[1i] = ((v_delta[2i] * v_eye_direction[0i]) - (v_delta[0i] * v_eye_direction[2i]));
        v_offset[2i] = ((v_delta[0i] * v_eye_direction[1i]) - (v_delta[1i] * v_eye_direction[0i]));
        var v_length: f32 = sqrt((((v_offset[0i] * v_offset[0i]) + (v_offset[1i] * v_offset[1i])) + (v_offset[2i] * v_offset[2i])));
        if ((v_length > 0.0f)) {
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              v_offset[v_k] = (v_offset[v_k] * cw_divide_f32(b_particles[((v_current * 10u) + 3u)], v_length));
              continuing {
                v_k += u32(1);
              }
            }
          }
        }
      }
      {
        var v_side: u32 = u32(0i);
        loop {
          if (!(v_side < u32(2i))) { break; }
          var v_out: u32 = (((v_selected * 2u) + v_side) * 10u);
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              var cw_tmp_5: f32;
              if ((v_side == 0u)) {
                cw_tmp_5 = (-1.0f);
              } else {
                cw_tmp_5 = 1.0f;
              }
              b_vertices[(v_out + v_k)] = (b_particles[((v_current * 10u) + v_k)] + (v_offset[v_k] * cw_tmp_5));
              continuing {
                v_k += u32(1);
              }
            }
          }
          b_vertices[(v_out + 3u)] = 1.0f;
          {
            var v_c: u32 = u32(0i);
            loop {
              if (!(v_c < u32(4i))) { break; }
              b_vertices[((v_out + 4u) + v_c)] = b_particles[(((v_current * 10u) + 4u) + v_c)];
              continuing {
                v_c += u32(1);
              }
            }
          }
          b_vertices[(v_out + 7u)] = (b_vertices[(v_out + 7u)] * b_particles[((v_current * 10u) + 8u)]);
          b_vertices[(v_out + 8u)] = b_particles[((v_current * 10u) + 9u)];
          var cw_tmp_6: f32;
          if ((v_thin != 0u)) {
            cw_tmp_6 = 0.5f;
          } else {
            cw_tmp_6 = f32(v_side);
          }
          b_vertices[(v_out + 9u)] = cw_tmp_6;
          continuing {
            v_side += u32(1);
          }
        }
      }
      v_selected += u32(1);
      v_current = v_next;
    }
  }
  b_summary[0i] = v_selected;
}
