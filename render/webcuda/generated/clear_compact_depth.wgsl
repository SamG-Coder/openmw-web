// CUDA WebShader 0.1.1. Generated from kernel clear_compact_depth.
@group(0) @binding(0) var<storage, read_write> b_target: array<f32>;
struct CWParams {
  p_pixel_count: u32,
  p_depth: f32,
  cw_pad_8: u32,
  cw_pad_12: u32,
}
@group(0) @binding(1) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);


@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_i: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_i < cw_params.p_pixel_count)) {
    b_target[v_i] = cw_params.p_depth;
  }
}
