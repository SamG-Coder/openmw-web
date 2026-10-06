// CUDA WebShader 0.1.1. Generated from kernel assemble_unlit_falloff.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read> b_weights: array<f32>;
@group(0) @binding(2) var<storage, read> b_valid: array<u32>;
@group(0) @binding(3) var<storage, read_write> b_attributes: array<f32>;
struct CWParams {
  p_slot_count: u32,
  p_falloff_offset: u32,
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
  var v_slot: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_slot >= cw_params.p_slot_count)) {
    return;
  }
  var cw_tmp_0: u32;
  if (((b_valid[v_slot] & 2147483648u) != 0u)) {
    cw_tmp_0 = (b_valid[v_slot] & 2147483647u);
  } else {
    cw_tmp_0 = v_slot;
  }
  var v_sourceSlot: u32 = cw_tmp_0;
  {
    var v_vertex: u32 = u32(0i);
    loop {
      if (!(v_vertex < u32(3i))) { break; }
      {
        var v_channel: u32 = u32(0i);
        loop {
          if (!(v_channel < u32(4i))) { break; }
          var v_value: f32 = 0.0f;
          if ((b_valid[v_slot] != 0u)) {
            {
              var v_corner: u32 = u32(0i);
              loop {
                if (!(v_corner < u32(3i))) { break; }
                v_value = (v_value + (b_weights[(((v_sourceSlot * 12u) + (v_vertex * 4u)) + v_corner)] * b_source[(((((v_sourceSlot / 7u) * 3u) + v_corner) * 4u) + v_channel)]));
                continuing {
                  v_corner += u32(1);
                }
              }
            }
          }
          b_attributes[((cw_params.p_falloff_offset + (((v_slot * 3u) + v_vertex) * 4u)) + v_channel)] = v_value;
          continuing {
            v_channel += u32(1);
          }
        }
      }
      continuing {
        v_vertex += u32(1);
      }
    }
  }
}
