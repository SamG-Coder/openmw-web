// CUDA WebShader 0.1.1. Generated from kernel expand_particles.
@group(0) @binding(0) var<storage, read_write> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_attributes: array<f32>;
@group(0) @binding(2) var<storage, read> b_matrices: array<f32>;
@group(0) @binding(3) var<storage, read> b_matrix_ids: array<u32>;
struct CWParams {
  p_vertex_count: u32,
  cw_pad_4: u32,
  cw_pad_8: u32,
  cw_pad_12: u32,
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
  if ((v_i >= cw_params.p_vertex_count)) {
    return;
  }
  var v_d: u32 = (v_i * u32(34i));
  var v_m: u32 = (b_matrix_ids[v_i] * u32(32i));
  var v_mode: f32 = b_attributes[v_d];
  if ((((v_mode < 2.0f) || (v_mode > 8.0f)) || (v_mode == 7.0f))) {
    return;
  }
  var v_normal: array<f32, 3>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_normal[v_k] = b_attributes[((v_d + u32(21i)) + v_k)];
      continuing {
        v_k += u32(1);
      }
    }
  }
  if ((v_mode >= 5.0f)) {
    b_source[((v_i * u32(10i)) + u32(7i))] = (b_source[((v_i * u32(10i)) + u32(7i))] * b_attributes[(v_d + u32(9i))]);
    if ((v_mode == 6.0f)) {
      var v_length: f32 = 0.0f;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          v_length = (v_length + (b_attributes[((v_d + u32(10i)) + v_k)] * b_attributes[((v_d + u32(10i)) + v_k)]));
          continuing {
            v_k += u32(1);
          }
        }
      }
      v_length = sqrt(v_length);
      var cw_tmp_1: f32;
      if ((v_length > 0.0f)) {
        let cw_argument_index_0 = (v_d + u32(14i));
        cw_tmp_1 = cw_divide_f32((b_attributes[(v_d + u32(13i))] * sqrt(b_attributes[cw_argument_index_0])), v_length);
      } else {
        cw_tmp_1 = 0.0f;
      }
      var v_scale: f32 = cw_tmp_1;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          b_attributes[((v_d + u32(10i)) + v_k)] = (b_attributes[((v_d + u32(10i)) + v_k)] * v_scale);
          continuing {
            v_k += u32(1);
          }
        }
      }
    }
    {
      var v_k: u32 = u32(3i);
      loop {
        if (!(v_k < u32(9i))) { break; }
        var cw_tmp_2: f32;
        if ((v_k < u32(6i))) {
          cw_tmp_2 = v_normal[(v_k - u32(3i))];
        } else {
          cw_tmp_2 = 0.0f;
        }
        b_attributes[(v_d + v_k)] = cw_tmp_2;
        continuing {
          v_k += u32(1);
        }
      }
    }
    b_attributes[(v_d + u32(9i))] = 0.0f;
    return;
  }
  var v_axes: array<f32, 6>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(6i))) { break; }
      v_axes[v_k] = b_attributes[((v_d + u32(3i)) + v_k)];
      continuing {
        v_k += u32(1);
      }
    }
  }
  var v_angle: array<f32, 3>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_angle[v_k] = b_attributes[((v_d + u32(10i)) + v_k)];
      continuing {
        v_k += u32(1);
      }
    }
  }
  let cw_argument_index_3 = (v_d + u32(14i));
  var v_size: f32 = (b_attributes[(v_d + u32(13i))] * sqrt(b_attributes[cw_argument_index_3]));
  {
    var v_axis: u32 = u32(0i);
    loop {
      if (!(v_axis < u32(2i))) { break; }
      var v_x: f32 = v_axes[(v_axis * u32(3i))];
      var v_y: f32 = v_axes[((v_axis * u32(3i)) + u32(1i))];
      var v_z: f32 = v_axes[((v_axis * u32(3i)) + u32(2i))];
      var v_scale: f32 = 1.0f;
      if ((v_mode < 4.0f)) {
        var v_length2: f32 = 0.0f;
        {
          var v_row: u32 = u32(0i);
          loop {
            if (!(v_row < u32(3i))) { break; }
            var v_value: f32 = (((b_matrices[(v_m + (v_row * u32(4i)))] * v_x) + (b_matrices[((v_m + (v_row * u32(4i))) + u32(1i))] * v_y)) + (b_matrices[((v_m + (v_row * u32(4i))) + u32(2i))] * v_z));
            v_length2 = (v_length2 + (v_value * v_value));
            continuing {
              v_row += u32(1);
            }
          }
        }
        var cw_tmp_4: f32;
        if ((v_mode == 2.0f)) {
          cw_tmp_4 = cw_divide_f32(1.0f, sqrt(max(v_length2, 1e-12f)));
        } else {
          cw_tmp_4 = cw_divide_f32(1.0f, max(v_length2, 1e-12f));
        }
        v_scale = cw_tmp_4;
      }
      v_x = (v_x * v_scale);
      v_y = (v_y * v_scale);
      v_z = (v_z * v_scale);
      let cw_argument_index_5 = 0i;
      var v_cx: f32 = cos(v_angle[cw_argument_index_5]);
      let cw_argument_index_6 = 0i;
      var v_sx: f32 = sin(v_angle[cw_argument_index_6]);
      let cw_argument_index_7 = 1i;
      var v_cy: f32 = cos(v_angle[cw_argument_index_7]);
      let cw_argument_index_8 = 1i;
      var v_sy: f32 = sin(v_angle[cw_argument_index_8]);
      let cw_argument_index_9 = 2i;
      var v_cz: f32 = cos(v_angle[cw_argument_index_9]);
      let cw_argument_index_10 = 2i;
      var v_sz: f32 = sin(v_angle[cw_argument_index_10]);
      var v_ry: f32 = ((v_y * v_cx) - (v_z * v_sx));
      var v_rz: f32 = ((v_y * v_sx) + (v_z * v_cx));
      v_y = v_ry;
      v_z = v_rz;
      var v_rx: f32 = ((v_x * v_cy) + (v_z * v_sy));
      v_rz = (((-v_x) * v_sy) + (v_z * v_cy));
      v_x = v_rx;
      v_z = v_rz;
      v_rx = ((v_x * v_cz) - (v_y * v_sz));
      v_ry = ((v_x * v_sz) + (v_y * v_cz));
      v_x = v_rx;
      v_y = v_ry;
      if ((v_mode < 4.0f)) {
        {
          var v_row: u32 = u32(0i);
          loop {
            if (!(v_row < u32(3i))) { break; }
            v_axes[((v_axis * u32(3i)) + v_row)] = (((b_matrices[(v_m + (v_row * u32(4i)))] * v_x) + (b_matrices[((v_m + (v_row * u32(4i))) + u32(1i))] * v_y)) + (b_matrices[((v_m + (v_row * u32(4i))) + u32(2i))] * v_z));
            continuing {
              v_row += u32(1);
            }
          }
        }
      } else {
        v_axes[(v_axis * u32(3i))] = v_x;
        v_axes[((v_axis * u32(3i)) + u32(1i))] = v_y;
        v_axes[((v_axis * u32(3i)) + u32(2i))] = v_z;
      }
      continuing {
        v_axis += u32(1);
      }
    }
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      b_source[((v_i * u32(10i)) + v_k)] = (b_source[((v_i * u32(10i)) + v_k)] + (v_size * ((v_axes[v_k] * b_attributes[(v_d + u32(1i))]) + (v_axes[(u32(3i) + v_k)] * b_attributes[(v_d + u32(2i))]))));
      continuing {
        v_k += u32(1);
      }
    }
  }
  b_source[((v_i * u32(10i)) + u32(7i))] = (b_source[((v_i * u32(10i)) + u32(7i))] * b_attributes[(v_d + u32(9i))]);
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(34i))) { break; }
      if (((v_k != u32(16i)) && (v_k != u32(17i)))) {
        b_attributes[(v_d + v_k)] = 0.0f;
      }
      continuing {
        v_k += u32(1);
      }
    }
  }
  {
    var v_unit: u32 = u32(0i);
    loop {
      if (!(v_unit < u32(4i))) { break; }
      b_attributes[((v_d + 27u) + (v_unit * 2u))] = 1.0f;
      continuing {
        v_unit += u32(1);
      }
    }
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      b_attributes[((v_d + u32(3i)) + v_k)] = v_normal[v_k];
      continuing {
        v_k += u32(1);
      }
    }
  }
}
