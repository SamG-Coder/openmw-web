// CUDA WebShader 0.1.1. Generated from kernel generate_mip.
@group(0) @binding(0) var<storage, read_write> b_texels: array<u32>;
struct CWParams {
  p_source: u32,
  p_destination: u32,
  p_width: u32,
  p_height: u32,
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
  var cw_tmp_32: u32;
  if ((cw_params.p_width > u32(1i))) {
    cw_tmp_32 = (cw_params.p_width / u32(2i));
  } else {
    cw_tmp_32 = u32(1i);
  }
  var v_dw: u32 = cw_tmp_32;
  var cw_tmp_33: u32;
  if ((cw_params.p_height > u32(1i))) {
    cw_tmp_33 = (cw_params.p_height / u32(2i));
  } else {
    cw_tmp_33 = u32(1i);
  }
  var v_dh: u32 = cw_tmp_33;
  if ((v_i >= (v_dw * v_dh))) {
    return;
  }
  var v_x0: u32 = (((v_i % v_dw) * cw_params.p_width) / v_dw);
  var v_x1: u32 = ((((v_i % v_dw) + u32(1i)) * cw_params.p_width) / v_dw);
  var v_y0: u32 = (((v_i / v_dw) * cw_params.p_height) / v_dh);
  var v_y1: u32 = ((((v_i / v_dw) + u32(1i)) * cw_params.p_height) / v_dh);
  var v_packed: u32 = u32(0i);
  var v_n: u32 = ((v_x1 - v_x0) * (v_y1 - v_y0));
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(4i))) { break; }
      var v_sum: u32 = u32(0i);
      {
        var v_y: u32 = v_y0;
        loop {
          if (!(v_y < v_y1)) { break; }
          {
            var v_x: u32 = v_x0;
            loop {
              if (!(v_x < v_x1)) { break; }
              v_sum = (v_sum + ((b_texels[((cw_params.p_source + (v_y * cw_params.p_width)) + v_x)] >> (v_c * u32(8i))) & u32(255i)));
              continuing {
                v_x += u32(1);
              }
            }
          }
          continuing {
            v_y += u32(1);
          }
        }
      }
      v_packed = (v_packed | (((v_sum + (v_n / u32(2i))) / v_n) << (v_c * u32(8i))));
      continuing {
        v_c += u32(1);
      }
    }
  }
  b_texels[(cw_params.p_destination + v_i)] = v_packed;
}
