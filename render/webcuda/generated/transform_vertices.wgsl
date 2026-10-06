// CUDA WebShader 0.1.1. Generated from kernel transform_vertices.
@group(0) @binding(0) var<storage, read> b_positions: array<f32>;
@group(0) @binding(1) var<storage, read> b_matrices: array<f32>;
@group(0) @binding(2) var<storage, read> b_matrix_ids: array<u32>;
@group(0) @binding(3) var<storage, read_write> b_clip: array<f32>;
struct CWParams {
  p_vertex_count: u32,
  cw_pad_4: u32,
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
  var v_i: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_i >= cw_params.p_vertex_count)) {
    return;
  }
  var v_p: u32 = (v_i * u32(3i));
  var v_m: u32 = (b_matrix_ids[v_i] * u32(16i));
  var v_x: f32 = b_positions[v_p];
  var v_y: f32 = b_positions[(v_p + u32(1i))];
  var v_z: f32 = b_positions[(v_p + u32(2i))];
  b_clip[(v_i * u32(4i))] = ((((b_matrices[v_m] * v_x) + (b_matrices[(v_m + u32(4i))] * v_y)) + (b_matrices[(v_m + u32(8i))] * v_z)) + b_matrices[(v_m + u32(12i))]);
  b_clip[((v_i * u32(4i)) + u32(1i))] = ((((b_matrices[(v_m + u32(1i))] * v_x) + (b_matrices[(v_m + u32(5i))] * v_y)) + (b_matrices[(v_m + u32(9i))] * v_z)) + b_matrices[(v_m + u32(13i))]);
  b_clip[((v_i * u32(4i)) + u32(2i))] = ((((b_matrices[(v_m + u32(2i))] * v_x) + (b_matrices[(v_m + u32(6i))] * v_y)) + (b_matrices[(v_m + u32(10i))] * v_z)) + b_matrices[(v_m + u32(14i))]);
  b_clip[((v_i * u32(4i)) + u32(3i))] = ((((b_matrices[(v_m + u32(3i))] * v_x) + (b_matrices[(v_m + u32(7i))] * v_y)) + (b_matrices[(v_m + u32(11i))] * v_z)) + b_matrices[(v_m + u32(15i))]);
}
