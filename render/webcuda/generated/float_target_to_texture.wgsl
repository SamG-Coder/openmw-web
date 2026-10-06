// CUDA WebShader 0.1.1. Generated from kernel float_target_to_texture.
@group(0) @binding(0) var<storage, read> b_target: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_texels: array<u32>;
struct CWParams {
  p_width: u32,
  p_height: u32,
  p_offset: u32,
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
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(4i))) { break; }
      let cw_argument_index_32 = ((v_i * u32(9i)) + v_c);
      b_texels[((cw_params.p_offset + (((((cw_params.p_height - u32(1i)) - (v_i / cw_params.p_width)) * cw_params.p_width) + (v_i % cw_params.p_width)) * u32(4i))) + v_c)] = bitcast<u32>(b_target[cw_argument_index_32]);
      continuing {
        v_c += u32(1);
      }
    }
  }
}
