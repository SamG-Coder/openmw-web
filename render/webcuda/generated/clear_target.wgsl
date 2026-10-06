// CUDA WebShader 0.1.1. Generated from kernel clear_target.
@group(0) @binding(0) var<storage, read_write> b_target: array<f32>;
struct CWParams {
  p_pixel_count: u32,
  p_red: f32,
  p_green: f32,
  p_blue: f32,
  p_alpha: f32,
  p_depth: f32,
  cw_pad_24: u32,
  cw_pad_28: u32,
}
@group(0) @binding(1) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);




































@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_p: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_p >= cw_params.p_pixel_count)) {
    return;
  }
  b_target[(v_p * u32(9i))] = cw_params.p_red;
  b_target[((v_p * u32(9i)) + u32(1i))] = cw_params.p_green;
  b_target[((v_p * u32(9i)) + u32(2i))] = cw_params.p_blue;
  b_target[((v_p * u32(9i)) + u32(3i))] = cw_params.p_alpha;
  b_target[((v_p * u32(9i)) + u32(4i))] = cw_params.p_depth;
  b_target[((v_p * u32(9i)) + u32(5i))] = cw_params.p_red;
  b_target[((v_p * u32(9i)) + u32(6i))] = cw_params.p_green;
  b_target[((v_p * u32(9i)) + u32(7i))] = cw_params.p_blue;
  b_target[((v_p * u32(9i)) + u32(8i))] = cw_params.p_alpha;
  b_target[((cw_params.p_pixel_count * 9u) + v_p)] = 0.0f;
}
