// CUDA WebShader 0.1.1. Generated from kernel summarize_tile_counts.
@group(0) @binding(0) var<storage, read> b_counts: array<u32>;
@group(0) @binding(1) var<storage, read_write> b_summary: array<atomic<u32>>;
struct CWParams {
  p_tile_count: u32,
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
  var v_tile: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_tile >= cw_params.p_tile_count)) {
    return;
  }
  _ = atomicMax(&b_summary[0i], b_counts[v_tile]);
  if ((v_tile == 0u)) {
    atomicStore(&b_summary[1i], b_counts[cw_params.p_tile_count]);
  }
}
