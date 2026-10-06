// CUDA WebShader 0.1.1. Generated from kernel copy_depth_layout.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_target: array<f32>;
struct CWParams {
  p_pixel_count: u32,
  p_source_compact: u32,
  p_target_compact: u32,
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
  if ((v_i < cw_params.p_pixel_count)) {
    var cw_tmp_0: u32;
    if ((cw_params.p_target_compact != 0u)) {
      cw_tmp_0 = v_i;
    } else {
      cw_tmp_0 = ((v_i * 9u) + 4u);
    }
    var cw_tmp_1: u32;
    if ((cw_params.p_source_compact != 0u)) {
      cw_tmp_1 = v_i;
    } else {
      cw_tmp_1 = ((v_i * 9u) + 4u);
    }
    b_target[cw_tmp_0] = b_source[cw_tmp_1];
  }
}
