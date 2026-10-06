// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: generate_mip.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read_write> b_texels: array<u32>;
struct KernelParams {
  p_source: u32,
  p_destination: u32,
  p_width: u32,
  p_height: u32,
}
@group(0) @binding(1) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);




































@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_i: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  var gpu_tmp_32: u32;
  if ((gpu_params.p_width > u32(1i))) {
    gpu_tmp_32 = (gpu_params.p_width / u32(2i));
  } else {
    gpu_tmp_32 = u32(1i);
  }
  var v_dw: u32 = gpu_tmp_32;
  var gpu_tmp_33: u32;
  if ((gpu_params.p_height > u32(1i))) {
    gpu_tmp_33 = (gpu_params.p_height / u32(2i));
  } else {
    gpu_tmp_33 = u32(1i);
  }
  var v_dh: u32 = gpu_tmp_33;
  if ((v_i >= (v_dw * v_dh))) {
    return;
  }
  var v_x0: u32 = (((v_i % v_dw) * gpu_params.p_width) / v_dw);
  var v_x1: u32 = ((((v_i % v_dw) + u32(1i)) * gpu_params.p_width) / v_dw);
  var v_y0: u32 = (((v_i / v_dw) * gpu_params.p_height) / v_dh);
  var v_y1: u32 = ((((v_i / v_dw) + u32(1i)) * gpu_params.p_height) / v_dh);
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
              v_sum = (v_sum + ((b_texels[((gpu_params.p_source + (v_y * gpu_params.p_width)) + v_x)] >> (v_c * u32(8i))) & u32(255i)));
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
  b_texels[(gpu_params.p_destination + v_i)] = v_packed;
}
