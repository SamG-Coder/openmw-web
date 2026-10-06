// CUDA WebShader 0.1.1. Generated from kernel prefix_tile_blocks.
@group(0) @binding(0) var<storage, read> b_counts: array<u32>;
@group(0) @binding(1) var<storage, read_write> b_offsets: array<u32>;
@group(0) @binding(2) var<storage, read_write> b_blocks: array<u32>;
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
  var v_block: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  var v_begin: u32 = (v_block * 256u);
  if ((v_begin >= cw_params.p_tile_count)) {
    return;
  }
  var v_end: u32 = (v_begin + 256u);
  if ((v_end > cw_params.p_tile_count)) {
    v_end = cw_params.p_tile_count;
  }
  var v_sum: u32 = 0u;
  {
    var v_tile: u32 = v_begin;
    loop {
      if (!(v_tile < v_end)) { break; }
      b_offsets[v_tile] = v_sum;
      var v_value: u32 = b_counts[v_tile];
      if ((v_value > (cw_params.p_max_words - v_sum))) {
        b_blocks[v_block] = 4294967295u;
        return;
      }
      v_sum = (v_sum + v_value);
      continuing {
        v_tile += u32(1);
      }
    }
  }
  b_blocks[v_block] = v_sum;
}
