// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: morph_vertices.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read_write> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read> b_ranges: array<u32>;
@group(0) @binding(2) var<storage, read> b_offsets: array<f32>;
struct KernelParams {
  p_range_count: u32,
  gpu_pad_4: u32,
  gpu_pad_8: u32,
  gpu_pad_12: u32,
}
@group(0) @binding(3) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);


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
  var v_vertex: u32 = (b_ranges[(v_i * u32(3i))] * u32(10i));
  var v_first: u32 = b_ranges[((v_i * u32(3i)) + u32(1i))];
  var v_count: u32 = b_ranges[((v_i * u32(3i)) + u32(2i))];
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      var v_value: f32 = b_vertices[(v_vertex + v_k)];
      {
        var v_j: u32 = u32(0i);
        loop {
          if (!(v_j < v_count)) { break; }
          v_value = (v_value + (b_offsets[(((v_first + v_j) * u32(4i)) + v_k)] * b_offsets[(((v_first + v_j) * u32(4i)) + u32(3i))]));
          continuing {
            v_j += u32(1);
          }
        }
      }
      b_vertices[(v_vertex + v_k)] = v_value;
      continuing {
        v_k += u32(1);
      }
    }
  }
}
