// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: map_viewport.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read_write> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_attributes: array<f32>;
struct KernelParams {
  p_point_fade_offset: u32,
  p_vertex_count: u32,
  p_width: u32,
  p_height: u32,
  p_viewport_x: i32,
  p_viewport_y: i32,
  p_viewport_width: u32,
  p_viewport_height: u32,
}
@group(0) @binding(2) var<uniform> gpu_params: KernelParams;
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
  var v_v: u32 = (v_i * u32(10i));
  var v_w: f32 = b_vertices[(v_v + u32(3i))];
  b_vertices[v_v] = (gpu_divide_f32((b_vertices[v_v] * f32(gpu_params.p_viewport_width)), f32(gpu_params.p_width)) + (v_w * (gpu_divide_f32(((2.0f * f32(gpu_params.p_viewport_x)) + f32(gpu_params.p_viewport_width)), f32(gpu_params.p_width)) - 1.0f)));
  b_vertices[(v_v + u32(1i))] = (gpu_divide_f32((b_vertices[(v_v + u32(1i))] * f32(gpu_params.p_viewport_height)), f32(gpu_params.p_height)) + (v_w * (gpu_divide_f32(((2.0f * f32(gpu_params.p_viewport_y)) + f32(gpu_params.p_viewport_height)), f32(gpu_params.p_height)) - 1.0f)));
  var v_metadata: u32 = (gpu_params.p_point_fade_offset + (v_i * 12u));
  if (((b_attributes[(v_metadata + 7u)] > 0.0f) && (b_attributes[(v_metadata + 11u)] > 0.0f))) {
    {
      var v_endpoint: u32 = 0u;
      loop {
        if (!(v_endpoint < 2u)) { break; }
        var v_base: u32 = ((v_metadata + 4u) + (v_endpoint * 4u));
        var v_endpointW: f32 = b_attributes[(v_base + 3u)];
        b_attributes[v_base] = (gpu_divide_f32((b_attributes[v_base] * f32(gpu_params.p_viewport_width)), f32(gpu_params.p_width)) + (v_endpointW * (gpu_divide_f32(((2.0f * f32(gpu_params.p_viewport_x)) + f32(gpu_params.p_viewport_width)), f32(gpu_params.p_width)) - 1.0f)));
        b_attributes[(v_base + 1u)] = (gpu_divide_f32((b_attributes[(v_base + 1u)] * f32(gpu_params.p_viewport_height)), f32(gpu_params.p_height)) + (v_endpointW * (gpu_divide_f32(((2.0f * f32(gpu_params.p_viewport_y)) + f32(gpu_params.p_viewport_height)), f32(gpu_params.p_height)) - 1.0f)));
        continuing {
          v_endpoint += u32(1);
        }
      }
    }
  }
}
