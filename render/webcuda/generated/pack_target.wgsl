// CUDA WebShader 0.1.1. Generated from kernel pack_target.
@group(0) @binding(0) var<storage, read> b_target: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_pixels: array<u32>;
struct CWParams {
  p_width: u32,
  p_height: u32,
  p_row_pixels: u32,
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
  if ((v_i >= (cw_params.p_width * cw_params.p_height))) {
    return;
  }
  let cw_argument_index_32 = (v_i * u32(9i));
  var v_r: u32 = u32(((min(1.0f, max(0.0f, b_target[cw_argument_index_32])) * 255.0f) + 0.5f));
  let cw_argument_index_33 = ((v_i * u32(9i)) + u32(1i));
  var v_g: u32 = u32(((min(1.0f, max(0.0f, b_target[cw_argument_index_33])) * 255.0f) + 0.5f));
  let cw_argument_index_34 = ((v_i * u32(9i)) + u32(2i));
  var v_b: u32 = u32(((min(1.0f, max(0.0f, b_target[cw_argument_index_34])) * 255.0f) + 0.5f));
  let cw_argument_index_35 = ((v_i * u32(9i)) + u32(3i));
  var v_a: u32 = u32(((min(1.0f, max(0.0f, b_target[cw_argument_index_35])) * 255.0f) + 0.5f));
  b_pixels[(((v_i / cw_params.p_width) * cw_params.p_row_pixels) + (v_i % cw_params.p_width))] = (((v_r | (v_g << u32(8i))) | (v_b << u32(16i))) | (v_a << u32(24i)));
}
