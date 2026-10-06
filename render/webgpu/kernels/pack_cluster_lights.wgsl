// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: pack_cluster_lights.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_target: array<u32>;
struct KernelParams {
  p_light_count: u32,
  p_destination: u32,
  gpu_pad_8: u32,
  gpu_pad_12: u32,
}
@group(0) @binding(2) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);


@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_i: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_i >= gpu_params.p_light_count)) {
    return;
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      let gpu_argument_index_0 = ((v_i * u32(20i)) + v_k);
      b_target[((gpu_params.p_destination + (v_i * u32(16i))) + v_k)] = bitcast<u32>(b_source[gpu_argument_index_0]);
      let gpu_argument_index_1 = (((v_i * u32(20i)) + u32(8i)) + v_k);
      b_target[(((gpu_params.p_destination + (v_i * u32(16i))) + u32(4i)) + v_k)] = bitcast<u32>(b_source[gpu_argument_index_1]);
      let gpu_argument_index_2 = (((v_i * u32(20i)) + u32(4i)) + v_k);
      b_target[(((gpu_params.p_destination + (v_i * u32(16i))) + u32(8i)) + v_k)] = bitcast<u32>(b_source[gpu_argument_index_2]);
      let gpu_argument_index_3 = (((v_i * u32(20i)) + u32(12i)) + v_k);
      b_target[(((gpu_params.p_destination + (v_i * u32(16i))) + u32(12i)) + v_k)] = bitcast<u32>(b_source[gpu_argument_index_3]);
      continuing {
        v_k += u32(1);
      }
    }
  }
  let gpu_argument_index_4 = ((v_i * u32(20i)) + u32(16i));
  b_target[((gpu_params.p_destination + (v_i * u32(16i))) + u32(3i))] = bitcast<u32>(b_source[gpu_argument_index_4]);
  let gpu_argument_index_5 = ((v_i * u32(20i)) + u32(17i));
  b_target[((gpu_params.p_destination + (v_i * u32(16i))) + u32(7i))] = bitcast<u32>(b_source[gpu_argument_index_5]);
  let gpu_argument_index_6 = ((v_i * u32(20i)) + u32(18i));
  b_target[((gpu_params.p_destination + (v_i * u32(16i))) + u32(11i))] = bitcast<u32>(b_source[gpu_argument_index_6]);
  let gpu_argument_index_7 = ((v_i * u32(20i)) + u32(19i));
  b_target[((gpu_params.p_destination + (v_i * u32(16i))) + u32(15i))] = bitcast<u32>(b_source[gpu_argument_index_7]);
}
