// CUDA WebShader 0.1.1. Generated from kernel pack_cluster_lights.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_target: array<u32>;
struct CWParams {
  p_light_count: u32,
  p_destination: u32,
  cw_pad_8: u32,
  cw_pad_12: u32,
}
@group(0) @binding(2) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);


@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_i: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_i >= cw_params.p_light_count)) {
    return;
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      let cw_argument_index_0 = ((v_i * u32(20i)) + v_k);
      b_target[((cw_params.p_destination + (v_i * u32(16i))) + v_k)] = bitcast<u32>(b_source[cw_argument_index_0]);
      let cw_argument_index_1 = (((v_i * u32(20i)) + u32(8i)) + v_k);
      b_target[(((cw_params.p_destination + (v_i * u32(16i))) + u32(4i)) + v_k)] = bitcast<u32>(b_source[cw_argument_index_1]);
      let cw_argument_index_2 = (((v_i * u32(20i)) + u32(4i)) + v_k);
      b_target[(((cw_params.p_destination + (v_i * u32(16i))) + u32(8i)) + v_k)] = bitcast<u32>(b_source[cw_argument_index_2]);
      let cw_argument_index_3 = (((v_i * u32(20i)) + u32(12i)) + v_k);
      b_target[(((cw_params.p_destination + (v_i * u32(16i))) + u32(12i)) + v_k)] = bitcast<u32>(b_source[cw_argument_index_3]);
      continuing {
        v_k += u32(1);
      }
    }
  }
  let cw_argument_index_4 = ((v_i * u32(20i)) + u32(16i));
  b_target[((cw_params.p_destination + (v_i * u32(16i))) + u32(3i))] = bitcast<u32>(b_source[cw_argument_index_4]);
  let cw_argument_index_5 = ((v_i * u32(20i)) + u32(17i));
  b_target[((cw_params.p_destination + (v_i * u32(16i))) + u32(7i))] = bitcast<u32>(b_source[cw_argument_index_5]);
  let cw_argument_index_6 = ((v_i * u32(20i)) + u32(18i));
  b_target[((cw_params.p_destination + (v_i * u32(16i))) + u32(11i))] = bitcast<u32>(b_source[cw_argument_index_6]);
  let cw_argument_index_7 = ((v_i * u32(20i)) + u32(19i));
  b_target[((cw_params.p_destination + (v_i * u32(16i))) + u32(15i))] = bitcast<u32>(b_source[cw_argument_index_7]);
}
