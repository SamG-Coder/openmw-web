// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: ripple_blob.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_target: array<f32>;
@group(0) @binding(2) var<storage, read> b_positions: array<f32>;
struct KernelParams {
  p_width: u32,
  p_height: u32,
  p_count: u32,
  p_offset_x: f32,
  p_offset_y: f32,
  p_time: f32,
  gpu_pad_24: u32,
  gpu_pad_28: u32,
}
@group(0) @binding(3) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn gpu_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }
fn f_gpu_buffer_helper_0(gpu_buffer_arg_0: i32, gpu_arg_width: u32, gpu_arg_height: u32, gpu_arg_x: f32, gpu_arg_y: f32, gpu_arg_channel: u32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var gpu_buffer_offset_0: i32 = gpu_buffer_arg_0;
  var v_width: u32 = gpu_arg_width;
  var v_height: u32 = gpu_arg_height;
  var v_x: f32 = gpu_arg_x;
  var v_y: f32 = gpu_arg_y;
  var v_channel: u32 = gpu_arg_channel;
  v_x = (v_x - 0.5f);
  v_y = (v_y - 0.5f);
  var v_ix: i32 = i32(floor(v_x));
  var v_iy: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - floor(v_x));
  var v_fy: f32 = (v_y - floor(v_y));
  var v_sum: f32 = 0.0f;
  {
    var v_dy: i32 = 0i;
    loop {
      if (!(v_dy < 2i)) { break; }
      {
        var v_dx: i32 = 0i;
        loop {
          if (!(v_dx < 2i)) { break; }
          var v_sx: i32 = (v_ix + v_dx);
          var v_sy: i32 = (v_iy + v_dy);
          var gpu_tmp_1: i32;
          if ((v_sx < 0i)) {
            gpu_tmp_1 = 0i;
          } else {
            var gpu_tmp_0: i32;
            if ((v_sx >= i32(v_width))) {
              gpu_tmp_0 = (i32(v_width) - 1i);
            } else {
              gpu_tmp_0 = v_sx;
            }
            gpu_tmp_1 = gpu_tmp_0;
          }
          v_sx = gpu_tmp_1;
          var gpu_tmp_3: i32;
          if ((v_sy < 0i)) {
            gpu_tmp_3 = 0i;
          } else {
            var gpu_tmp_2: i32;
            if ((v_sy >= i32(v_height))) {
              gpu_tmp_2 = (i32(v_height) - 1i);
            } else {
              gpu_tmp_2 = v_sy;
            }
            gpu_tmp_3 = gpu_tmp_2;
          }
          v_sy = gpu_tmp_3;
          var gpu_tmp_4: f32;
          if ((v_dx == 0i)) {
            gpu_tmp_4 = (1.0f - v_fx);
          } else {
            gpu_tmp_4 = v_fx;
          }
          var gpu_tmp_5: f32;
          if ((v_dy == 0i)) {
            gpu_tmp_5 = (1.0f - v_fy);
          } else {
            gpu_tmp_5 = v_fy;
          }
          v_sum = (v_sum + ((b_source[(gpu_buffer_offset_0 + i32(((((((v_height - u32(1i)) - u32(v_sy)) * v_width) + u32(v_sx)) * u32(9i)) + v_channel)))] * gpu_tmp_4) * gpu_tmp_5));
          continuing {
            v_dx += i32(1);
          }
        }
      }
      continuing {
        v_dy += i32(1);
      }
    }
  }
  return v_sum;
}

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_i: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_i >= (gpu_params.p_width * gpu_params.p_height))) {
    return;
  }
  var v_x: f32 = (f32((v_i % gpu_params.p_width)) + 0.5f);
  var v_y: f32 = (f32(((gpu_params.p_height - u32(1i)) - (v_i / gpu_params.p_width))) + 0.5f);
  var v_color: array<f32, 4>;
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(4i))) { break; }
      v_color[v_c] = f_gpu_buffer_helper_0(0i, gpu_params.p_width, gpu_params.p_height, (v_x + gpu_params.p_offset_x), (v_y + gpu_params.p_offset_y), v_c, gpu_thread, gpu_block, gpu_grid);
      continuing {
        v_c += u32(1);
      }
    }
  }
  var v_multiplier: f32 = ((1.0f + (0.055f * sin((16.0f * gpu_params.p_time)))) + (0.065f * sin((12.87645f * gpu_params.p_time))));
  {
    var v_p: u32 = u32(0i);
    loop {
      if (!(v_p < gpu_params.p_count)) { break; }
      var v_size: f32 = (v_multiplier * b_positions[((v_p * u32(3i)) + u32(2i))]);
      if ((v_size <= 0.0f)) {
        continue;
      }
      var v_dx: f32 = ((b_positions[(v_p * u32(3i))] + gpu_params.p_offset_x) - v_x);
      var v_dy: f32 = ((b_positions[((v_p * u32(3i)) + u32(1i))] + gpu_params.p_offset_y) - v_y);
      var v_displace: f32 = min(1.0f, max(0.0f, ((0.2f * abs((gpu_divide_f32(sqrt(((v_dx * v_dx) + (v_dy * v_dy))), v_size) - 1.0f))) + 0.8f)));
      v_color[0i] = ((-1.0f) + ((v_color[0i] + 1.0f) * v_displace));
      v_color[1i] = ((-1.0f) + ((v_color[1i] + 1.0f) * v_displace));
      continuing {
        v_p += u32(1);
      }
    }
  }
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(4i))) { break; }
      b_target[((v_i * u32(9i)) + v_c)] = v_color[v_c];
      continuing {
        v_c += u32(1);
      }
    }
  }
}
