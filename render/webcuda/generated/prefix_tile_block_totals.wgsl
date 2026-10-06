// CUDA WebShader 0.1.1. Generated from kernel prefix_tile_block_totals.
@group(0) @binding(0) var<storage, read> b_counts: array<u32>;
@group(0) @binding(1) var<storage, read_write> b_blocks: array<u32>;
@group(0) @binding(2) var<storage, read_write> b_summary: array<u32>;
struct CWParams {
  p_tile_count: u32,
  p_max_words: u32,
  cw_pad_8: u32,
  cw_pad_12: u32,
}
@group(0) @binding(3) var<uniform> cw_params: CWParams;
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
  var v_next: u32 = (cw_params.p_tile_count + 1u);
  b_summary[0i] = 0u;
  b_summary[1i] = b_counts[cw_params.p_tile_count];
  if ((v_next > cw_params.p_max_words)) {
    b_summary[1i] = 2u;
    return;
  }
  var v_block_count: u32 = ((cw_params.p_tile_count + 255u) / 256u);
  {
    var v_block: u32 = u32(0i);
    loop {
      if (!(v_block < v_block_count)) { break; }
      var v_count: u32 = b_blocks[v_block];
      if ((v_count > (cw_params.p_max_words - v_next))) {
        b_summary[1i] = 2u;
        return;
      }
      b_blocks[v_block] = v_next;
      v_next = (v_next + v_count);
      continuing {
        v_block += u32(1);
      }
    }
  }
  b_summary[0i] = v_next;
}
