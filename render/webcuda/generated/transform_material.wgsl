// CUDA WebShader 0.1.1. Generated from kernel transform_material.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read> b_matrices: array<f32>;
@group(0) @binding(2) var<storage, read> b_matrix_ids: array<u32>;
@group(0) @binding(3) var<storage, read_write> b_vertices: array<f32>;
struct CWParams {
  p_vertex_count: u32,
  cw_pad_4: u32,
  cw_pad_8: u32,
  cw_pad_12: u32,
}
@group(0) @binding(4) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);


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
  var v_m: u32 = (b_matrix_ids[v_i] * u32(32i));
  var v_view: array<f32, 4>;
  {
    var v_row: u32 = u32(0i);
    loop {
      if (!(v_row < u32(4i))) { break; }
      v_view[v_row] = 0.0f;
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(4i))) { break; }
          v_view[v_row] = (v_view[v_row] + (b_matrices[((v_m + (v_col * u32(4i))) + v_row)] * b_source[((v_i * u32(10i)) + v_col)]));
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
      var v_sum: f32 = 0.0f;
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(4i))) { break; }
          v_sum = (v_sum + (b_matrices[(((v_m + u32(16i)) + (v_col * u32(4i))) + v_row)] * v_view[v_col]));
          continuing {
            v_col += u32(1);
          }
        }
      }
      b_vertices[((v_i * u32(10i)) + v_row)] = v_sum;
      continuing {
        v_row += u32(1);
      }
    }
  }
  {
    var v_k: u32 = u32(4i);
    loop {
      if (!(v_k < u32(10i))) { break; }
      b_vertices[((v_i * u32(10i)) + v_k)] = b_source[((v_i * u32(10i)) + v_k)];
      continuing {
        v_k += u32(1);
      }
    }
  }
}
