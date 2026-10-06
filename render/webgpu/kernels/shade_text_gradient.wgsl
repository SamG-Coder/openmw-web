// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: shade_text_gradient.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read_write> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read> b_ranges: array<u32>;
@group(0) @binding(2) var<storage, read> b_colors: array<f32>;
struct KernelParams {
  p_range_count: u32,
  gpu_pad_4: u32,
  gpu_pad_8: u32,
  gpu_pad_12: u32,
}
@group(0) @binding(3) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn gpu_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_r: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_r >= gpu_params.p_range_count)) {
    return;
  }
  var v_first: u32 = b_ranges[(v_r * 3u)];
  var v_count: u32 = b_ranges[((v_r * 3u) + 1u)];
  var v_p: u32 = (b_ranges[((v_r * 3u) + 2u)] * 16u);
  if ((v_count == 0u)) {
    return;
  }
  var v_minx: f32 = 3.402823466e+38f;
  var v_miny: f32 = 3.402823466e+38f;
  var v_maxx: f32 = 1.175494351e-38f;
  var v_maxy: f32 = 1.175494351e-38f;
  {
    var v_n: u32 = u32(0i);
    loop {
      if (!(v_n < v_count)) { break; }
      var v_v: u32 = ((v_first + v_n) * 10u);
      let gpu_argument_index_0 = v_v;
      v_minx = min(v_minx, b_vertices[gpu_argument_index_0]);
      let gpu_argument_index_1 = v_v;
      v_maxx = max(v_maxx, b_vertices[gpu_argument_index_1]);
      let gpu_argument_index_2 = (v_v + 1u);
      v_miny = min(v_miny, b_vertices[gpu_argument_index_2]);
      let gpu_argument_index_3 = (v_v + 1u);
      v_maxy = max(v_maxy, b_vertices[gpu_argument_index_3]);
      continuing {
        v_n += u32(1);
      }
    }
  }
  {
    var v_n: u32 = u32(0i);
    loop {
      if (!(v_n < v_count)) { break; }
      var v_v: u32 = ((v_first + v_n) * 10u);
      var gpu_tmp_4: f32;
      if ((v_maxx != v_minx)) {
        gpu_tmp_4 = gpu_divide_f32((b_vertices[v_v] - v_minx), (v_maxx - v_minx));
      } else {
        gpu_tmp_4 = 0.0f;
      }
      var v_x: f32 = gpu_tmp_4;
      var gpu_tmp_5: f32;
      if ((v_maxy != v_miny)) {
        gpu_tmp_5 = gpu_divide_f32((b_vertices[(v_v + 1u)] - v_miny), (v_maxy - v_miny));
      } else {
        gpu_tmp_5 = 0.0f;
      }
      var v_y: f32 = gpu_tmp_5;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(4i))) { break; }
          var v_left: f32 = ((b_colors[((v_p + 4u) + v_k)] * (1.0f - v_y)) + (b_colors[(v_p + v_k)] * v_y));
          var v_right: f32 = ((b_colors[((v_p + 8u) + v_k)] * (1.0f - v_y)) + (b_colors[((v_p + 12u) + v_k)] * v_y));
          b_vertices[((v_v + 4u) + v_k)] = ((v_left * (1.0f - v_x)) + (v_right * v_x));
          continuing {
            v_k += u32(1);
          }
        }
      }
      continuing {
        v_n += u32(1);
      }
    }
  }
}
