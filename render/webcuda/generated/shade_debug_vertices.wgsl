// CUDA WebShader 0.1.1. Generated from kernel shade_debug_vertices.
@group(0) @binding(0) var<storage, read_write> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read> b_attributes: array<f32>;
@group(0) @binding(2) var<storage, read> b_matrix_ids: array<u32>;
@group(0) @binding(3) var<storage, read> b_params: array<f32>;
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
  var v_p: u32 = (b_matrix_ids[v_i] * 16u);
  var v_v: u32 = (v_i * 10u);
  var v_kind: u32 = u32(b_params[v_p]);
  if ((v_kind == 0u)) {
    return;
  }
  if (((v_kind == 2u) || (v_kind == 3u))) {
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(3i))) { break; }
        b_vertices[(v_v + v_k)] = ((b_vertices[(v_v + v_k)] * b_params[((v_p + 12u) + v_k)]) + b_params[((v_p + 8u) + v_k)]);
        continuing {
          v_k += u32(1);
        }
      }
    }
    b_vertices[(v_v + 3u)] = 1.0f;
    var v_lighting: f32 = 0.5f;
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(3i))) { break; }
        var cw_tmp_0: f32;
        if ((v_kind == 3u)) {
          cw_tmp_0 = 1.0f;
        } else {
          cw_tmp_0 = b_attributes[(((v_i * 34u) + 3u) + v_k)];
        }
        var v_normal: f32 = cw_tmp_0;
        var cw_tmp_2: f32;
        if ((v_k == 0u)) {
          cw_tmp_2 = 1.0f;
        } else {
          var cw_tmp_1: f32;
          if ((v_k == 1u)) {
            cw_tmp_1 = 0.5f;
          } else {
            cw_tmp_1 = 2.0f;
          }
          cw_tmp_2 = cw_tmp_1;
        }
        var v_light: f32 = cw_tmp_2;
        v_lighting = (v_lighting + ((v_normal * v_light) * cw_divide_f32(0.5f, sqrt(5.25f))));
        continuing {
          v_k += u32(1);
        }
      }
    }
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(3i))) { break; }
        var cw_tmp_3: f32;
        if ((v_kind == 3u)) {
          cw_tmp_3 = b_attributes[(((v_i * 34u) + 3u) + v_k)];
        } else {
          cw_tmp_3 = b_params[((v_p + 4u) + v_k)];
        }
        b_vertices[((v_v + 4u) + v_k)] = (cw_tmp_3 * v_lighting);
        continuing {
          v_k += u32(1);
        }
      }
    }
    b_vertices[(v_v + 7u)] = 1.0f;
  } else {
    if (((v_kind == 4u) || (b_params[(v_p + 1u)] == 0.0f))) {
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(4i))) { break; }
          b_vertices[((v_v + 4u) + v_k)] = b_params[((v_p + 4u) + v_k)];
          continuing {
            v_k += u32(1);
          }
        }
      }
    }
  }
}
