// CUDA WebShader 0.1.1. Generated from kernel prefix_clip_totals.
@group(0) @binding(0) var<storage, read_write> b_blocks: array<u32>;
@group(0) @binding(1) var<storage, read_write> b_summary: array<u32>;
struct CWParams {
  p_block_count: u32,
  cw_pad_4: u32,
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
  if ((v_i != 0u)) {
    return;
  }
  var v_total: u32 = 0u;
  {
    var v_block: u32 = 0u;
    loop {
      if (!(v_block < cw_params.p_block_count)) { break; }
      var v_count: u32 = b_blocks[v_block];
      b_blocks[v_block] = v_total;
      v_total = (v_total + v_count);
      continuing {
        v_block += u32(1);
      }
    }
  }
  b_summary[0i] = v_total;
}
