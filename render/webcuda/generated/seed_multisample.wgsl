// CUDA WebShader 0.1.1. Generated from kernel seed_multisample.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_samples: array<f32>;
struct CWParams {
  p_pixel_count: u32,
  p_sample_count: u32,
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
  if ((v_i >= (cw_params.p_pixel_count * cw_params.p_sample_count))) {
    return;
  }
  var v_pixel: u32 = (v_i % cw_params.p_pixel_count);
  var v_sample: u32 = (v_i / cw_params.p_pixel_count);
  var v_base: u32 = ((v_sample * cw_params.p_pixel_count) * u32(10i));
  {
    var v_channel: u32 = u32(0i);
    loop {
      if (!(v_channel < u32(9i))) { break; }
      b_samples[((v_base + (v_pixel * u32(9i))) + v_channel)] = b_source[((v_pixel * u32(9i)) + v_channel)];
      continuing {
        v_channel += u32(1);
      }
    }
  }
  b_samples[((v_base + (cw_params.p_pixel_count * u32(9i))) + v_pixel)] = b_source[((cw_params.p_pixel_count * u32(9i)) + v_pixel)];
}
