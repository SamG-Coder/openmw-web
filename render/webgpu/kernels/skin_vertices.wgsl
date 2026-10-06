// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: skin_vertices.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read_write> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_attributes: array<f32>;
@group(0) @binding(2) var<storage, read> b_ranges: array<u32>;
@group(0) @binding(3) var<storage, read> b_weights: array<u32>;
@group(0) @binding(4) var<storage, read> b_bones: array<f32>;
@group(0) @binding(5) var<storage, read> b_transforms: array<f32>;
struct KernelParams {
  p_range_count: u32,
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
  if ((v_i >= gpu_params.p_range_count)) {
    return;
  }
  var v_vertex: u32 = b_ranges[(v_i * u32(4i))];
  var v_first: u32 = b_ranges[((v_i * u32(4i)) + u32(1i))];
  var v_count: u32 = b_ranges[((v_i * u32(4i)) + u32(2i))];
  var v_transform: u32 = (b_ranges[((v_i * u32(4i)) + u32(3i))] * u32(32i));
  var v_matrix: array<f32, 16>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(16i))) { break; }
      var gpu_tmp_0: f32;
      if ((v_k == u32(15i))) {
        gpu_tmp_0 = 1.0f;
      } else {
        gpu_tmp_0 = 0.0f;
      }
      v_matrix[v_k] = gpu_tmp_0;
      continuing {
        v_k += u32(1);
      }
    }
  }
  {
    var v_influence: u32 = u32(0i);
    loop {
      if (!(v_influence < v_count)) { break; }
      var v_bone: u32 = (b_weights[((v_first + v_influence) * u32(2i))] * u32(32i));
      let gpu_argument_index_1 = (((v_first + v_influence) * u32(2i)) + u32(1i));
      var v_weight: f32 = bitcast<f32>(b_weights[gpu_argument_index_1]);
      {
        var v_row: u32 = u32(0i);
        loop {
          if (!(v_row < u32(4i))) { break; }
          {
            var v_col: u32 = u32(0i);
            loop {
              if (!(v_col < u32(3i))) { break; }
              var v_value: f32 = 0.0f;
              {
                var v_k: u32 = u32(0i);
                loop {
                  if (!(v_k < u32(4i))) { break; }
                  v_value = (v_value + (b_bones[((v_bone + (v_row * u32(4i))) + v_k)] * b_bones[(((v_bone + u32(16i)) + (v_k * u32(4i))) + v_col)]));
                  continuing {
                    v_k += u32(1);
                  }
                }
              }
              v_matrix[((v_row * u32(4i)) + v_col)] = (v_matrix[((v_row * u32(4i)) + v_col)] + (v_value * v_weight));
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
      continuing {
        v_influence += u32(1);
      }
    }
  }
  {
    var v_stage: u32 = u32(0i);
    loop {
      if (!(v_stage < u32(2i))) { break; }
      var v_result: array<f32, 16>;
      {
        var v_row: u32 = u32(0i);
        loop {
          if (!(v_row < u32(4i))) { break; }
          {
            var v_col: u32 = u32(0i);
            loop {
              if (!(v_col < u32(4i))) { break; }
              var v_value: f32 = 0.0f;
              {
                var v_k: u32 = u32(0i);
                loop {
                  if (!(v_k < u32(4i))) { break; }
                  v_value = (v_value + (v_matrix[((v_row * u32(4i)) + v_k)] * b_transforms[(((v_transform + (v_stage * u32(16i))) + (v_k * u32(4i))) + v_col)]));
                  continuing {
                    v_k += u32(1);
                  }
                }
              }
              v_result[((v_row * u32(4i)) + v_col)] = v_value;
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
          if (!(v_k < u32(16i))) { break; }
          v_matrix[v_k] = v_result[v_k];
          continuing {
            v_k += u32(1);
          }
        }
      }
      continuing {
        v_stage += u32(1);
      }
    }
  }
  var v_position: array<f32, 3>;
  var v_normal: array<f32, 3>;
  var v_tangent: array<f32, 3>;
  var v_w: f32 = v_matrix[15i];
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      v_w = (v_w + (b_vertices[((v_vertex * u32(10i)) + v_k)] * v_matrix[((v_k * u32(4i)) + u32(3i))]));
      continuing {
        v_k += u32(1);
      }
    }
  }
  {
    var v_col: u32 = u32(0i);
    loop {
      if (!(v_col < u32(3i))) { break; }
      v_position[v_col] = v_matrix[(u32(12i) + v_col)];
      v_normal[v_col] = 0.0f;
      v_tangent[v_col] = 0.0f;
      {
        var v_row: u32 = u32(0i);
        loop {
          if (!(v_row < u32(3i))) { break; }
          v_position[v_col] = (v_position[v_col] + (b_vertices[((v_vertex * u32(10i)) + v_row)] * v_matrix[((v_row * u32(4i)) + v_col)]));
          v_normal[v_col] = (v_normal[v_col] + (b_attributes[(((v_vertex * u32(34i)) + u32(3i)) + v_row)] * v_matrix[((v_row * u32(4i)) + v_col)]));
          v_tangent[v_col] = (v_tangent[v_col] + (b_attributes[(((v_vertex * u32(34i)) + u32(6i)) + v_row)] * v_matrix[((v_row * u32(4i)) + v_col)]));
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
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      b_vertices[((v_vertex * u32(10i)) + v_k)] = gpu_divide_f32(v_position[v_k], v_w);
      b_attributes[(((v_vertex * u32(34i)) + u32(3i)) + v_k)] = v_normal[v_k];
      b_attributes[(((v_vertex * u32(34i)) + u32(6i)) + v_k)] = v_tangent[v_k];
      continuing {
        v_k += u32(1);
      }
    }
  }
}
