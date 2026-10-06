// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: transform_local_vertices.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read_write> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read> b_matrix_ids: array<u32>;
@group(0) @binding(2) var<storage, read> b_transforms: array<f32>;
@group(0) @binding(3) var<storage, read> b_matrices: array<f32>;
struct KernelParams {
  p_vertex_count: u32,
  gpu_pad_4: u32,
  gpu_pad_8: u32,
  gpu_pad_12: u32,
}
@group(0) @binding(4) var<uniform> gpu_params: KernelParams;
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
  var v_id: u32 = b_matrix_ids[v_i];
  var v_p: u32 = (v_id * 35u);
  var v_m: u32 = (v_id * 32u);
  if ((b_transforms[v_p] == 0.0f)) {
    return;
  }
  var v_source: array<f32, 4>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      v_source[v_k] = b_vertices[((v_i * 10u) + v_k)];
      continuing {
        v_k += u32(1);
      }
    }
  }
  if ((b_transforms[v_p] == 1.0f)) {
    {
      var v_row: u32 = u32(0i);
      loop {
        if (!(v_row < u32(4i))) { break; }
        var v_value: f32 = 0.0f;
        {
          var v_col: u32 = u32(0i);
          loop {
            if (!(v_col < u32(4i))) { break; }
            v_value = (v_value + (b_transforms[(((v_p + 1u) + (v_col * 4u)) + v_row)] * v_source[v_col]));
            continuing {
              v_col += u32(1);
            }
          }
        }
        b_vertices[((v_i * 10u) + v_row)] = v_value;
        continuing {
          v_row += u32(1);
        }
      }
    }
    return;
  }
  var v_d: u32 = (v_p + 17u);
  var v_work: array<f32, 32>;
  {
    var v_row: u32 = u32(0i);
    loop {
      if (!(v_row < u32(4i))) { break; }
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(8i))) { break; }
          var gpu_tmp_1: f32;
          if ((v_col < 4u)) {
            gpu_tmp_1 = b_matrices[((v_m + (v_col * 4u)) + v_row)];
          } else {
            var gpu_tmp_0: f32;
            if (((v_col - 4u) == v_row)) {
              gpu_tmp_0 = 1.0f;
            } else {
              gpu_tmp_0 = 0.0f;
            }
            gpu_tmp_1 = gpu_tmp_0;
          }
          var v_value: f32 = gpu_tmp_1;
          if (((v_col == 3u) && (v_row < 3u))) {
            v_value = 0.0f;
          }
          v_work[((v_row * 8u) + v_col)] = v_value;
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
  var v_invertible: u32 = 1u;
  {
    var v_col: u32 = u32(0i);
    loop {
      if (!(v_col < u32(4i))) { break; }
      var v_pivot: u32 = v_col;
      {
        var v_row: u32 = (v_col + 1u);
        loop {
          if (!(v_row < u32(4i))) { break; }
          let gpu_argument_index_2 = ((v_row * 8u) + v_col);
          let gpu_argument_index_3 = ((v_pivot * 8u) + v_col);
          if ((abs(v_work[gpu_argument_index_2]) > abs(v_work[gpu_argument_index_3]))) {
            v_pivot = v_row;
          }
          continuing {
            v_row += u32(1);
          }
        }
      }
      if ((v_work[((v_pivot * 8u) + v_col)] == 0.0f)) {
        v_invertible = 0u;
        break;
      }
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(8i))) { break; }
          var v_temp: f32 = v_work[((v_col * 8u) + v_k)];
          v_work[((v_col * 8u) + v_k)] = v_work[((v_pivot * 8u) + v_k)];
          v_work[((v_pivot * 8u) + v_k)] = v_temp;
          continuing {
            v_k += u32(1);
          }
        }
      }
      var v_divisor: f32 = v_work[((v_col * 8u) + v_col)];
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(8i))) { break; }
          v_work[((v_col * 8u) + v_k)] = gpu_divide_f32(v_work[((v_col * 8u) + v_k)], v_divisor);
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
            var v_factor: f32 = v_work[((v_row * 8u) + v_col)];
            {
              var v_k: u32 = u32(0i);
              loop {
                if (!(v_k < u32(8i))) { break; }
                v_work[((v_row * 8u) + v_k)] = (v_work[((v_row * 8u) + v_k)] - (v_factor * v_work[((v_col * 8u) + v_k)]));
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
  var v_inverse: array<f32, 16>;
  {
    var v_row: u32 = u32(0i);
    loop {
      if (!(v_row < u32(4i))) { break; }
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(4i))) { break; }
          var gpu_tmp_5: f32;
          if ((v_invertible != 0u)) {
            gpu_tmp_5 = v_work[(((v_row * 8u) + v_col) + 4u)];
          } else {
            var gpu_tmp_4: f32;
            if ((v_row == v_col)) {
              gpu_tmp_4 = 1.0f;
            } else {
              gpu_tmp_4 = 0.0f;
            }
            gpu_tmp_5 = gpu_tmp_4;
          }
          v_inverse[((v_col * 4u) + v_row)] = gpu_tmp_5;
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
  var v_position: array<f32, 3>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_position[v_k] = (v_source[v_k] - b_transforms[((v_d + 6u) + v_k)]);
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_qx: f32 = b_transforms[(v_d + u32(12i))];
  var v_qy: f32 = b_transforms[(v_d + u32(13i))];
  var v_qz: f32 = b_transforms[(v_d + u32(14i))];
  var v_qw: f32 = b_transforms[(v_d + u32(15i))];
  var v_tx: f32 = (2.0f * ((v_qy * v_position[2i]) - (v_qz * v_position[1i])));
  var v_ty: f32 = (2.0f * ((v_qz * v_position[0i]) - (v_qx * v_position[2i])));
  var v_tz: f32 = (2.0f * ((v_qx * v_position[1i]) - (v_qy * v_position[0i])));
  v_position[0i] = (v_position[0i] + (((v_qw * v_tx) + (v_qy * v_tz)) - (v_qz * v_ty)));
  v_position[1i] = (v_position[1i] + (((v_qw * v_ty) + (v_qz * v_tx)) - (v_qx * v_tz)));
  v_position[2i] = (v_position[2i] + (((v_qw * v_tz) + (v_qx * v_ty)) - (v_qy * v_tx)));
  if ((b_transforms[v_d] != 0.0f)) {
    var v_projected: array<f32, 9>;
    {
      var v_point: u32 = u32(0i);
      loop {
        if (!(v_point < u32(3i))) { break; }
        var v_local: array<f32, 4>;
        var v_view: array<f32, 4>;
        var v_clip: array<f32, 4>;
        {
          var v_row: u32 = u32(0i);
          loop {
            if (!(v_row < u32(4i))) { break; }
            var gpu_tmp_6: f32;
            if ((v_point == 0u)) {
              gpu_tmp_6 = 0.0f;
            } else {
              gpu_tmp_6 = v_inverse[(((v_point - 1u) * 4u) + v_row)];
            }
            v_local[v_row] = (v_inverse[(12u + v_row)] + gpu_tmp_6);
            continuing {
              v_row += u32(1);
            }
          }
        }
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            v_local[v_k] = (v_local[v_k] + (b_transforms[((v_d + 9u) + v_k)] * v_local[3i]));
            continuing {
              v_k += u32(1);
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
                v_view[v_row] = (v_view[v_row] + (b_matrices[((v_m + (v_col * 4u)) + v_row)] * v_local[v_col]));
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
            v_clip[v_row] = 0.0f;
            {
              var v_col: u32 = u32(0i);
              loop {
                if (!(v_col < u32(4i))) { break; }
                v_clip[v_row] = (v_clip[v_row] + (b_matrices[(((v_m + 16u) + (v_col * 4u)) + v_row)] * v_view[v_col]));
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
        var gpu_tmp_7: f32;
        if ((v_clip[3i] != 0.0f)) {
          gpu_tmp_7 = gpu_divide_f32(1.0f, v_clip[3i]);
        } else {
          gpu_tmp_7 = 1.0f;
        }
        var v_reciprocal: f32 = gpu_tmp_7;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            var gpu_tmp_8: f32;
            if ((v_k < 2u)) {
              gpu_tmp_8 = (b_transforms[((v_d + 16u) + v_k)] * 0.5f);
            } else {
              gpu_tmp_8 = 1.0f;
            }
            v_projected[((v_point * 3u) + v_k)] = ((v_clip[v_k] * v_reciprocal) * gpu_tmp_8);
            continuing {
              v_k += u32(1);
            }
          }
        }
        continuing {
          v_point += u32(1);
        }
      }
    }
    var v_lx: f32 = 0.0f;
    var v_ly: f32 = 0.0f;
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(3i))) { break; }
        var v_x: f32 = (v_projected[(3u + v_k)] - v_projected[v_k]);
        var v_y: f32 = (v_projected[(6u + v_k)] - v_projected[v_k]);
        v_lx = (v_lx + (v_x * v_x));
        v_ly = (v_ly + (v_y * v_y));
        continuing {
          v_k += u32(1);
        }
      }
    }
    var gpu_tmp_9: f32;
    if ((v_lx > 0.0f)) {
      gpu_tmp_9 = gpu_divide_f32(1.0f, sqrt(v_lx));
    } else {
      gpu_tmp_9 = 1.0f;
    }
    var v_sx: f32 = gpu_tmp_9;
    var gpu_tmp_10: f32;
    if ((v_ly > 0.0f)) {
      gpu_tmp_10 = gpu_divide_f32(1.0f, sqrt(v_ly));
    } else {
      gpu_tmp_10 = 1.0f;
    }
    var v_sy: f32 = gpu_tmp_10;
    if ((b_transforms[(v_d + u32(2i))] != 0.0f)) {
      v_position[0i] = (v_position[0i] * gpu_divide_f32(b_transforms[(v_d + u32(3i))], b_transforms[(v_d + u32(4i))]));
      v_position[1i] = (v_position[1i] * b_transforms[(v_d + u32(3i))]);
      v_position[2i] = (v_position[2i] * b_transforms[(v_d + u32(3i))]);
    }
    if ((b_transforms[v_d] == 1.0f)) {
      v_position[0i] = (v_position[0i] * v_sx);
      v_position[1i] = (v_position[1i] * v_sy);
      v_position[2i] = (v_position[2i] * v_sx);
    } else {
      var v_pixelHeight: f32 = gpu_divide_f32(b_transforms[(v_d + u32(3i))], v_sy);
      if ((v_pixelHeight == 0.0f)) {
        v_pixelHeight = 1.0f;
      }
      if ((v_pixelHeight > b_transforms[(v_d + u32(5i))])) {
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            v_position[v_k] = (v_position[v_k] * gpu_divide_f32(b_transforms[(v_d + u32(5i))], v_pixelHeight));
            continuing {
              v_k += u32(1);
            }
          }
        }
      }
    }
  }
  if ((b_transforms[(v_d + u32(1i))] != 0.0f)) {
    var v_rotated: array<f32, 3>;
    {
      var v_row: u32 = u32(0i);
      loop {
        if (!(v_row < u32(3i))) { break; }
        v_rotated[v_row] = v_inverse[(12u + v_row)];
        {
          var v_col: u32 = u32(0i);
          loop {
            if (!(v_col < u32(3i))) { break; }
            v_rotated[v_row] = (v_rotated[v_row] + (v_inverse[((v_col * 4u) + v_row)] * v_position[v_col]));
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
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(3i))) { break; }
        v_position[v_k] = v_rotated[v_k];
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
      b_vertices[((v_i * 10u) + v_k)] = (v_position[v_k] + b_transforms[((v_d + 9u) + v_k)]);
      continuing {
        v_k += u32(1);
      }
    }
  }
  b_vertices[((v_i * 10u) + 3u)] = 1.0f;
}
