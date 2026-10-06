// CUDA WebShader 0.1.1. Generated from kernel assemble_fixed_lighting.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read> b_triangles: array<u32>;
@group(0) @binding(2) var<storage, read> b_flat_colors: array<u32>;
@group(0) @binding(3) var<storage, read> b_weights: array<f32>;
@group(0) @binding(4) var<storage, read> b_valid: array<u32>;
@group(0) @binding(5) var<storage, read_write> b_output: array<f32>;
struct CWParams {
  p_slot_count: u32,
  p_fixed_offset: u32,
  cw_pad_8: u32,
  cw_pad_12: u32,
}
@group(0) @binding(6) var<uniform> cw_params: CWParams;
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
  var v_original: u32 = (v_sourceSlot / u32(7i));
  var v_provoking: u32 = b_flat_colors[v_original];
  var v_frontOnly: u32 = select(u32(0), u32(1), (b_source[((b_triangles[(v_original * u32(4i))] * u32(16i)) + u32(15i))] > 1.5f));
  {
    var v_vertex: u32 = u32(0i);
    loop {
      if (!(v_vertex < u32(3i))) { break; }
      {
        var v_channel: u32 = u32(0i);
        loop {
          if (!(v_channel < u32(16i))) { break; }
          var v_value: f32 = 0.0f;
          if ((b_valid[v_slot] != u32(0i))) {
            if ((v_provoking != 4294967295u)) {
              var cw_tmp_1: u32;
              if (((v_frontOnly != u32(0i)) && (v_channel >= u32(8i)))) {
                cw_tmp_1 = (v_channel - u32(8i));
              } else {
                cw_tmp_1 = v_channel;
              }
              v_value = b_source[((v_provoking * u32(16i)) + cw_tmp_1)];
            } else {
              {
                var v_corner: u32 = u32(0i);
                loop {
                  if (!(v_corner < u32(3i))) { break; }
                  v_value = (v_value + (b_weights[(((v_sourceSlot * u32(12i)) + (v_vertex * u32(4i))) + v_corner)] * b_source[((b_triangles[((v_original * u32(4i)) + v_corner)] * u32(16i)) + v_channel)]));
                  continuing {
                    v_corner += u32(1);
                  }
                }
              }
            }
          }
          b_output[((cw_params.p_fixed_offset + (((v_slot * u32(3i)) + v_vertex) * u32(16i))) + v_channel)] = v_value;
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
