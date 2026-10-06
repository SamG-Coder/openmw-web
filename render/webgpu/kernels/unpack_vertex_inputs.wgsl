// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: unpack_vertex_inputs.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_inputs: array<f32>;
@group(0) @binding(1) var<storage, read> b_layouts: array<u32>;
@group(0) @binding(2) var<storage, read> b_matrix_ids: array<u32>;
@group(0) @binding(3) var<storage, read_write> b_vertices: array<f32>;
@group(0) @binding(4) var<storage, read_write> b_attributes: array<f32>;
@group(0) @binding(5) var<storage, read_write> b_secondary_colors: array<f32>;
struct KernelParams {
  p_vertex_count: u32,
  gpu_pad_4: u32,
  gpu_pad_8: u32,
  gpu_pad_12: u32,
}
@group(0) @binding(6) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn f_vertex_unorm8(gpu_arg_value: f32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var v_value: f32 = gpu_arg_value;
  var v_byte: u32 = u32(v_value);
  var v_repeated: u32 = ((((v_byte << 24u) | (v_byte << 16u)) | (v_byte << 8u)) | v_byte);
  if (((v_byte > 0u) && (v_byte < 255u))) {
    v_repeated = (v_repeated + 1u);
  }
  return (f32(v_repeated) * 2.3283064365386963e-10f);
}

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
  var v_d: u32 = (b_matrix_ids[v_i] * 32u);
  var v_j: u32 = (v_i - b_layouts[v_d]);
  var v_v: u32 = (v_i * 10u);
  var v_a: u32 = (v_i * 34u);
  if ((b_layouts[(v_d + 3u)] == 0u)) {
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(10i))) { break; }
        b_vertices[(v_v + v_k)] = b_inputs[((b_layouts[(v_d + 6u)] + (v_j * 10u)) + v_k)];
        continuing {
          v_k += u32(1);
        }
      }
    }
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(34i))) { break; }
        b_attributes[(v_a + v_k)] = b_inputs[((b_layouts[(v_d + 7u)] + (v_j * 34u)) + v_k)];
        continuing {
          v_k += u32(1);
        }
      }
    }
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(3i))) { break; }
        var v_value: f32 = b_inputs[((b_layouts[(v_d + 8u)] + (v_j * 3u)) + v_k)];
        var gpu_tmp_0: f32;
        if ((b_layouts[(v_d + 29u)] != 0u)) {
          gpu_tmp_0 = f_vertex_unorm8(v_value, gpu_thread, gpu_block, gpu_grid);
        } else {
          gpu_tmp_0 = v_value;
        }
        b_secondary_colors[((v_i * 3u) + v_k)] = gpu_tmp_0;
        continuing {
          v_k += u32(1);
        }
      }
    }
    return;
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(34i))) { break; }
      b_attributes[(v_a + v_k)] = 0.0f;
      continuing {
        v_k += u32(1);
      }
    }
  }
  if ((b_layouts[(v_d + 3u)] == 3u)) {
    var v_p: u32 = (b_layouts[(v_d + 6u)] + (v_j * 9u));
    var v_c: u32 = b_layouts[(v_d + 7u)];
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(3i))) { break; }
        b_vertices[(v_v + v_k)] = b_inputs[(v_p + v_k)];
        b_secondary_colors[((v_i * 3u) + v_k)] = b_inputs[(v_c + v_k)];
        continuing {
          v_k += u32(1);
        }
      }
    }
    b_vertices[(v_v + 3u)] = 1.0f;
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(4i))) { break; }
        let gpu_argument_index_1 = ((v_p + 3u) + v_k);
        b_vertices[((v_v + 4u) + v_k)] = f_vertex_unorm8(b_inputs[gpu_argument_index_1], gpu_thread, gpu_block, gpu_grid);
        continuing {
          v_k += u32(1);
        }
      }
    }
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(2i))) { break; }
        b_vertices[((v_v + 8u) + v_k)] = b_inputs[((v_p + 7u) + v_k)];
        b_attributes[((v_a + 16u) + v_k)] = b_inputs[((v_p + 7u) + v_k)];
        continuing {
          v_k += u32(1);
        }
      }
    }
    {
      var v_unit: u32 = u32(0i);
      loop {
        if (!(v_unit < u32(4i))) { break; }
        b_attributes[((v_a + 27u) + (v_unit * 2u))] = 1.0f;
        continuing {
          v_unit += u32(1);
        }
      }
    }
    return;
  }
  if ((b_layouts[(v_d + 3u)] == 2u)) {
    var v_p: u32 = (b_layouts[(v_d + 6u)] + ((v_j / 4u) * 17u));
    var v_c: u32 = b_layouts[(v_d + 7u)];
    var v_corner: u32 = (v_j % 4u);
    var gpu_tmp_2: f32;
    if (((v_corner == 1u) || (v_corner == 2u))) {
      gpu_tmp_2 = 1.0f;
    } else {
      gpu_tmp_2 = 0.0f;
    }
    var v_u: f32 = gpu_tmp_2;
    var gpu_tmp_3: f32;
    if ((v_corner >= 2u)) {
      gpu_tmp_3 = 1.0f;
    } else {
      gpu_tmp_3 = 0.0f;
    }
    var v_t: f32 = gpu_tmp_3;
    var v_mode: f32 = b_inputs[(v_p + 16u)];
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(3i))) { break; }
        b_vertices[(v_v + v_k)] = b_inputs[(v_p + v_k)];
        continuing {
          v_k += u32(1);
        }
      }
    }
    b_vertices[(v_v + 3u)] = 1.0f;
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(4i))) { break; }
        b_vertices[((v_v + 4u) + v_k)] = b_inputs[((v_p + 3u) + v_k)];
        continuing {
          v_k += u32(1);
        }
      }
    }
    var v_s: f32 = (b_inputs[(v_p + 7u)] + (v_u * b_inputs[(v_p + 9u)]));
    var v_r: f32 = (b_inputs[(v_p + 8u)] + (v_t * b_inputs[(v_p + 10u)]));
    if ((v_mode == 5.0f)) {
      v_s = 0.5f;
      v_r = 0.5f;
    }
    if ((v_mode == 6.0f)) {
      v_s = v_u;
      v_r = v_u;
    }
    if ((v_mode == 8.0f)) {
      v_s = v_u;
      v_r = (1.0f - v_t);
      b_attributes[(v_a + 24u)] = b_inputs[(v_c + 15u)];
    }
    b_vertices[(v_v + 8u)] = v_s;
    b_vertices[(v_v + 9u)] = v_r;
    b_attributes[v_a] = v_mode;
    b_attributes[(v_a + 1u)] = ((v_u * 2.0f) - 1.0f);
    b_attributes[(v_a + 2u)] = ((v_t * 2.0f) - 1.0f);
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(3i))) { break; }
        b_attributes[((v_a + 3u) + v_k)] = b_inputs[(v_c + v_k)];
        b_attributes[((v_a + 6u) + v_k)] = b_inputs[((v_c + 3u) + v_k)];
        b_attributes[((v_a + 10u) + v_k)] = b_inputs[((v_p + 13u) + v_k)];
        b_attributes[((v_a + 21u) + v_k)] = b_inputs[((v_c + 17u) + v_k)];
        var v_value: f32 = b_inputs[((v_c + 20u) + v_k)];
        var gpu_tmp_4: f32;
        if ((b_layouts[(v_d + 29u)] != 0u)) {
          gpu_tmp_4 = f_vertex_unorm8(v_value, gpu_thread, gpu_block, gpu_grid);
        } else {
          gpu_tmp_4 = v_value;
        }
        b_secondary_colors[((v_i * 3u) + v_k)] = gpu_tmp_4;
        continuing {
          v_k += u32(1);
        }
      }
    }
    b_attributes[(v_a + 9u)] = b_inputs[(v_p + 11u)];
    b_attributes[(v_a + 13u)] = b_inputs[(v_p + 12u)];
    b_attributes[(v_a + 14u)] = b_inputs[(v_c + 6u)];
    if ((((v_mode == 5.0f) || (v_mode == 6.0f)) || (v_mode == 8.0f))) {
      var gpu_tmp_5: u32;
      if ((v_mode == 6.0f)) {
        gpu_tmp_5 = 8u;
      } else {
        gpu_tmp_5 = 7u;
      }
      b_attributes[(v_a + 15u)] = b_inputs[(v_c + gpu_tmp_5)];
      if ((v_mode != 6.0f)) {
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            b_attributes[((v_a + 10u) + v_k)] = b_inputs[((v_c + 9u) + v_k)];
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
          b_attributes[((v_a + 18u) + v_k)] = b_inputs[((v_c + 12u) + v_k)];
          continuing {
            v_k += u32(1);
          }
        }
      }
    }
    b_attributes[(v_a + 16u)] = v_s;
    b_attributes[(v_a + 17u)] = v_r;
    b_attributes[(v_a + 25u)] = b_inputs[(v_c + 16u)];
    {
      var v_unit: u32 = u32(0i);
      loop {
        if (!(v_unit < u32(4i))) { break; }
        b_attributes[((v_a + 27u) + (v_unit * 2u))] = 1.0f;
        continuing {
          v_unit += u32(1);
        }
      }
    }
    return;
  }
  if ((v_j >= b_layouts[(v_d + 2u)])) {
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(10i))) { break; }
        b_vertices[(v_v + v_k)] = 0.0f;
        continuing {
          v_k += u32(1);
        }
      }
    }
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(3i))) { break; }
        var v_value: f32 = b_inputs[(b_layouts[(v_d + 5u)] + v_k)];
        var gpu_tmp_6: f32;
        if ((b_layouts[(v_d + 30u)] != 0u)) {
          gpu_tmp_6 = f_vertex_unorm8(v_value, gpu_thread, gpu_block, gpu_grid);
        } else {
          gpu_tmp_6 = v_value;
        }
        b_secondary_colors[((v_i * 3u) + v_k)] = gpu_tmp_6;
        continuing {
          v_k += u32(1);
        }
      }
    }
    return;
  }
  var v_position: u32 = (b_layouts[(v_d + 8u)] + (v_j * b_layouts[(v_d + 9u)]));
  var v_color: u32 = (b_layouts[(v_d + 10u)] + (v_j * b_layouts[(v_d + 11u)]));
  var v_secondary: u32 = (b_layouts[(v_d + 12u)] + (v_j * b_layouts[(v_d + 13u)]));
  var v_normal: u32 = (b_layouts[(v_d + 14u)] + (v_j * b_layouts[(v_d + 15u)]));
  var v_tangent: u32 = (b_layouts[(v_d + 16u)] + (v_j * b_layouts[(v_d + 17u)]));
  var v_fog: u32 = (b_layouts[(v_d + 18u)] + (v_j * b_layouts[(v_d + 19u)]));
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      b_vertices[(v_v + v_k)] = b_inputs[(v_position + v_k)];
      b_attributes[((v_a + 6u) + v_k)] = b_inputs[(v_tangent + v_k)];
      var v_value: f32 = b_inputs[(v_color + v_k)];
      var gpu_tmp_7: f32;
      if ((v_k < b_layouts[(v_d + 28u)])) {
        gpu_tmp_7 = f_vertex_unorm8(v_value, gpu_thread, gpu_block, gpu_grid);
      } else {
        gpu_tmp_7 = v_value;
      }
      b_vertices[((v_v + 4u) + v_k)] = gpu_tmp_7;
      continuing {
        v_k += u32(1);
      }
    }
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      var v_value: f32 = b_inputs[(v_secondary + v_k)];
      var gpu_tmp_8: f32;
      if ((b_layouts[(v_d + 29u)] != 0u)) {
        gpu_tmp_8 = f_vertex_unorm8(v_value, gpu_thread, gpu_block, gpu_grid);
      } else {
        gpu_tmp_8 = v_value;
      }
      b_secondary_colors[((v_i * 3u) + v_k)] = gpu_tmp_8;
      b_attributes[((v_a + 3u) + v_k)] = b_inputs[(v_normal + v_k)];
      continuing {
        v_k += u32(1);
      }
    }
  }
  var gpu_tmp_10: f32;
  if ((b_layouts[(v_d + 4u)] == 2u)) {
    gpu_tmp_10 = (-1.0f);
  } else {
    var gpu_tmp_9: f32;
    if ((b_layouts[(v_d + 4u)] == 1u)) {
      gpu_tmp_9 = 1.0f;
    } else {
      gpu_tmp_9 = 0.0f;
    }
    gpu_tmp_10 = gpu_tmp_9;
  }
  b_attributes[v_a] = gpu_tmp_10;
  if ((b_layouts[(v_d + 4u)] == 2u)) {
    b_attributes[(v_a + 2u)] = b_inputs[v_fog];
  }
  {
    var v_unit: u32 = u32(0i);
    loop {
      if (!(v_unit < u32(4i))) { break; }
      var v_coordinate: u32 = (b_layouts[((v_d + 20u) + (v_unit * 2u))] + (v_j * b_layouts[((v_d + 21u) + (v_unit * 2u))]));
      var gpu_tmp_11: u32;
      if ((v_unit == 0u)) {
        gpu_tmp_11 = 16u;
      } else {
        gpu_tmp_11 = (8u + (v_unit * 2u));
      }
      var v_uv: u32 = gpu_tmp_11;
      b_attributes[(v_a + v_uv)] = b_inputs[v_coordinate];
      b_attributes[((v_a + v_uv) + 1u)] = b_inputs[(v_coordinate + 1u)];
      b_attributes[((v_a + 26u) + (v_unit * 2u))] = b_inputs[(v_coordinate + 2u)];
      b_attributes[((v_a + 27u) + (v_unit * 2u))] = b_inputs[(v_coordinate + 3u)];
      if ((v_unit == 0u)) {
        b_vertices[(v_v + 8u)] = b_inputs[v_coordinate];
        b_vertices[(v_v + 9u)] = b_inputs[(v_coordinate + 1u)];
      }
      continuing {
        v_unit += u32(1);
      }
    }
  }
}
