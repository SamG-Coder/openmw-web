// CUDA WebShader 0.1.1. Generated from kernel prepare_bethesda_vertices.
@group(0) @binding(0) var<storage, read> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read> b_attributes: array<f32>;
@group(0) @binding(2) var<storage, read> b_matrices: array<f32>;
@group(0) @binding(3) var<storage, read> b_matrix_ids: array<u32>;
@group(0) @binding(4) var<storage, read> b_varyings: array<f32>;
@group(0) @binding(5) var<storage, read_write> b_output: array<f32>;
struct CWParams {
  p_vertex_count: u32,
  p_track_world_particles: u32,
  p_world_particle_offset: u32,
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
  var v_m: u32 = (b_matrix_ids[v_i] * 32u);
  var v_view: array<f32, 3>;
  var v_normal: array<f32, 3>;
  var v_length: f32 = 0.0f;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_normal[v_k] = b_attributes[(((v_i * 34u) + 3u) + v_k)];
      v_length = (v_length + (v_normal[v_k] * v_normal[v_k]));
      v_view[v_k] = 0.0f;
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(4i))) { break; }
          v_view[v_k] = (v_view[v_k] + (b_matrices[((v_m + (v_col * 4u)) + v_k)] * b_vertices[((v_i * 10u) + v_col)]));
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
  var cw_tmp_0: f32;
  if ((v_length > 0.0f)) {
    cw_tmp_0 = cw_divide_f32(1.0f, sqrt(v_length));
  } else {
    cw_tmp_0 = 0.0f;
  }
  var v_normalScale: f32 = cw_tmp_0;
  var v_a: f32 = b_matrices[v_m];
  var v_b: f32 = b_matrices[(v_m + u32(4i))];
  var v_c: f32 = b_matrices[(v_m + u32(8i))];
  var v_d: f32 = b_matrices[(v_m + u32(1i))];
  var v_e: f32 = b_matrices[(v_m + u32(5i))];
  var v_f: f32 = b_matrices[(v_m + u32(9i))];
  var v_g: f32 = b_matrices[(v_m + u32(2i))];
  var v_h: f32 = b_matrices[(v_m + u32(6i))];
  var v_j: f32 = b_matrices[(v_m + u32(10i))];
  var v_det: f32 = (((v_a * ((v_e * v_j) - (v_f * v_h))) - (v_b * ((v_d * v_j) - (v_f * v_g)))) + (v_c * ((v_d * v_h) - (v_e * v_g))));
  var cw_tmp_1: f32;
  if ((v_det != 0.0f)) {
    cw_tmp_1 = cw_divide_f32(1.0f, v_det);
  } else {
    cw_tmp_1 = 0.0f;
  }
  var v_inverse: f32 = cw_tmp_1;
  var v_nx: f32 = ((((((v_e * v_j) - (v_f * v_h)) * v_normal[0i]) + (((v_f * v_g) - (v_d * v_j)) * v_normal[1i])) + (((v_d * v_h) - (v_e * v_g)) * v_normal[2i])) * v_inverse);
  var v_ny: f32 = ((((((v_c * v_h) - (v_b * v_j)) * v_normal[0i]) + (((v_a * v_j) - (v_c * v_g)) * v_normal[1i])) + (((v_b * v_g) - (v_a * v_h)) * v_normal[2i])) * v_inverse);
  var v_nz: f32 = ((((((v_b * v_f) - (v_c * v_e)) * v_normal[0i]) + (((v_c * v_d) - (v_a * v_f)) * v_normal[1i])) + (((v_a * v_e) - (v_b * v_d)) * v_normal[2i])) * v_inverse);
  b_output[((v_i * 6u) + 1u)] = v_nx;
  b_output[((v_i * 6u) + 2u)] = v_ny;
  b_output[((v_i * 6u) + 3u)] = v_nz;
  var v_viewLength: f32 = sqrt((((v_view[0i] * v_view[0i]) + (v_view[1i] * v_view[1i])) + (v_view[2i] * v_view[2i])));
  var cw_tmp_2: f32;
  if ((v_viewLength > 0.0f)) {
    cw_tmp_2 = abs(cw_divide_f32(((((v_nx * v_view[0i]) + (v_ny * v_view[1i])) + (v_nz * v_view[2i])) * v_normalScale), v_viewLength));
  } else {
    cw_tmp_2 = 0.0f;
  }
  var v_angle: f32 = cw_tmp_2;
  b_output[(v_i * 6u)] = v_angle;
  b_output[((v_i * 6u) + 4u)] = v_angle;
  b_output[((v_i * 6u) + 5u)] = 0.0f;
  var v_particle: u32 = (cw_params.p_world_particle_offset + (v_i * 24u));
  if (((cw_params.p_track_world_particles != 0u) && (b_varyings[v_particle] > 0.5f))) {
    {
      var v_endpoint: u32 = u32(0i);
      loop {
        if (!(v_endpoint < u32(2i))) { break; }
        var v_depth: f32 = 0.0f;
        var v_dot: f32 = 0.0f;
        {
          var v_axis: u32 = u32(0i);
          loop {
            if (!(v_axis < u32(3i))) { break; }
            var v_position: f32 = b_varyings[(((v_particle + 2u) + (v_endpoint * 3u)) + v_axis)];
            v_depth = (v_depth + (v_position * v_position));
            v_dot = (v_dot + (b_output[(((v_i * 6u) + 1u) + v_axis)] * v_position));
            continuing {
              v_axis += u32(1);
            }
          }
        }
        v_depth = sqrt(v_depth);
        var cw_tmp_3: f32;
        if ((v_depth > 0.0f)) {
          cw_tmp_3 = abs(cw_divide_f32((v_dot * v_normalScale), v_depth));
        } else {
          cw_tmp_3 = 0.0f;
        }
        b_output[((v_i * 6u) + (v_endpoint * 4u))] = cw_tmp_3;
        continuing {
          v_endpoint += u32(1);
        }
      }
    }
    b_output[((v_i * 6u) + 5u)] = b_varyings[(v_particle + 1u)];
  }
}
