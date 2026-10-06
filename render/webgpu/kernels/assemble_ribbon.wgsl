// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: assemble_ribbon.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_prepared: array<f32>;
@group(0) @binding(1) var<storage, read> b_summary: array<u32>;
@group(0) @binding(2) var<storage, read_write> b_vertices: array<f32>;
@group(0) @binding(3) var<storage, read_write> b_attributes: array<f32>;
@group(0) @binding(4) var<storage, read_write> b_triangles: array<u32>;
@group(0) @binding(5) var<storage, read_write> b_status: array<atomic<u32>>;
@group(0) @binding(6) var<storage, read_write> b_flat_colors: array<u32>;
struct KernelParams {
  p_segment_count: u32,
  p_vertex_base: u32,
  p_triangle_base: u32,
  p_material: u32,
  p_line_material: u32,
  p_line_width: f32,
  p_normal_x: f32,
  p_normal_y: f32,
  p_normal_z: f32,
  p_status_index: u32,
  p_flat_color: u32,
  p_point_flags: u32,
}
@group(0) @binding(7) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);


@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_segment: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_segment >= gpu_params.p_segment_count)) {
    return;
  }
  if ((b_summary[2i] != 0u)) {
    _ = atomicExchange(&b_status[gpu_params.p_status_index], 1u);
    return;
  }
  var v_first: u32 = (gpu_params.p_vertex_base + (v_segment * 4u));
  var v_t: u32 = ((gpu_params.p_triangle_base + (v_segment * 2u)) * 4u);
  var v_thin: u32 = b_summary[1i];
  b_triangles[v_t] = v_first;
  b_triangles[(v_t + 1u)] = (v_first + 1u);
  b_triangles[(v_t + 2u)] = (v_first + 2u);
  var gpu_tmp_0: u32;
  if ((v_thin != 0u)) {
    gpu_tmp_0 = gpu_params.p_line_material;
  } else {
    gpu_tmp_0 = gpu_params.p_material;
  }
  b_triangles[(v_t + 3u)] = gpu_tmp_0;
  b_triangles[(v_t + 4u)] = v_first;
  b_triangles[(v_t + 5u)] = (v_first + 2u);
  b_triangles[(v_t + 6u)] = (v_first + 3u);
  b_triangles[(v_t + 7u)] = b_triangles[(v_t + 3u)];
  var gpu_tmp_1: u32;
  if ((gpu_params.p_flat_color != 0u)) {
    gpu_tmp_1 = (v_first + 2u);
  } else {
    gpu_tmp_1 = 4294967295u;
  }
  b_flat_colors[(gpu_params.p_triangle_base + (v_segment * u32(2i)))] = gpu_tmp_1;
  b_flat_colors[((gpu_params.p_triangle_base + (v_segment * u32(2i))) + u32(1i))] = b_flat_colors[(gpu_params.p_triangle_base + (v_segment * u32(2i)))];
  {
    var v_corner: u32 = u32(0i);
    loop {
      if (!(v_corner < u32(4i))) { break; }
      var v_p: u32 = ((v_first + v_corner) * 10u);
      var v_a: u32 = ((v_first + v_corner) * 34u);
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(10i))) { break; }
          b_vertices[(v_p + v_k)] = 0.0f;
          continuing {
            v_k += u32(1);
          }
        }
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
      if (((v_segment + 1u) >= b_summary[0i])) {
        continue;
      }
      var gpu_tmp_2: u32;
      if ((v_corner >= 2u)) {
        gpu_tmp_2 = 1u;
      } else {
        gpu_tmp_2 = 0u;
      }
      var v_point: u32 = (v_segment + gpu_tmp_2);
      var gpu_tmp_3: u32;
      if (((v_corner == 1u) || (v_corner == 2u))) {
        gpu_tmp_3 = 1u;
      } else {
        gpu_tmp_3 = 0u;
      }
      var v_side: u32 = gpu_tmp_3;
      var v_src: u32 = (((v_point * 2u) + v_side) * 10u);
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(10i))) { break; }
          b_vertices[(v_p + v_k)] = b_prepared[(v_src + v_k)];
          continuing {
            v_k += u32(1);
          }
        }
      }
      b_attributes[(v_a + 3u)] = gpu_params.p_normal_x;
      b_attributes[(v_a + 4u)] = gpu_params.p_normal_y;
      b_attributes[(v_a + 5u)] = gpu_params.p_normal_z;
      if ((v_thin != 0u)) {
        var v_start: u32 = (v_segment * 20u);
        var v_end: u32 = ((v_segment + 1u) * 20u);
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(10i))) { break; }
            b_vertices[(v_p + v_k)] = b_prepared[(v_start + v_k)];
            continuing {
              v_k += u32(1);
            }
          }
        }
        b_attributes[(v_a + 24u)] = f32(gpu_params.p_flat_color);
        b_attributes[(v_a + 25u)] = f32(gpu_params.p_point_flags);
        b_attributes[v_a] = 7.0f;
        var gpu_tmp_4: f32;
        if ((v_corner >= 2u)) {
          gpu_tmp_4 = 1.0f;
        } else {
          gpu_tmp_4 = (-1.0f);
        }
        b_attributes[(v_a + 1u)] = gpu_tmp_4;
        var gpu_tmp_5: f32;
        if ((v_side != 0u)) {
          gpu_tmp_5 = 1.0f;
        } else {
          gpu_tmp_5 = (-1.0f);
        }
        b_attributes[(v_a + 2u)] = gpu_tmp_5;
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            b_attributes[((v_a + 10u) + v_k)] = (b_prepared[(v_end + v_k)] - b_prepared[(v_start + v_k)]);
            continuing {
              v_k += u32(1);
            }
          }
        }
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(4i))) { break; }
            b_attributes[((v_a + 18u) + v_k)] = b_prepared[((v_end + 4u) + v_k)];
            continuing {
              v_k += u32(1);
            }
          }
        }
        b_attributes[(v_a + 22u)] = b_prepared[(v_end + 8u)];
        b_attributes[(v_a + 15u)] = gpu_params.p_line_width;
      }
      if ((gpu_params.p_flat_color != 0u)) {
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(4i))) { break; }
            b_vertices[((v_p + 4u) + v_k)] = b_prepared[((((v_segment + 1u) * 20u) + 4u) + v_k)];
            continuing {
              v_k += u32(1);
            }
          }
        }
      }
      b_attributes[(v_a + 16u)] = b_vertices[(v_p + 8u)];
      b_attributes[(v_a + 17u)] = b_vertices[(v_p + 9u)];
      continuing {
        v_corner += u32(1);
      }
    }
  }
}
