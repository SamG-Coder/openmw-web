// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: debug_scene.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read> b_depth: array<f32>;
@group(0) @binding(2) var<storage, read> b_normals: array<f32>;
@group(0) @binding(3) var<storage, read> b_settings: array<f32>;
@group(0) @binding(4) var<storage, read_write> b_target: array<f32>;
struct KernelParams {
  p_width: u32,
  p_height: u32,
  p_source_width: u32,
  p_source_height: u32,
  p_depth_width: u32,
  p_depth_height: u32,
  p_normal_width: u32,
  p_normal_height: u32,
  p_flags: u32,
  gpu_pad_36: u32,
  gpu_pad_40: u32,
  gpu_pad_44: u32,
}
@group(0) @binding(5) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn gpu_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }









fn f_gpu_buffer_helper_0(gpu_buffer_arg_0: i32, gpu_arg_width: u32, gpu_arg_height: u32, gpu_arg_u: f32, gpu_arg_v: f32, gpu_arg_channel: u32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var gpu_buffer_offset_0: i32 = gpu_buffer_arg_0;
  var v_width: u32 = gpu_arg_width;
  var v_height: u32 = gpu_arg_height;
  var v_u: f32 = gpu_arg_u;
  var v_v: f32 = gpu_arg_v;
  var v_channel: u32 = gpu_arg_channel;
  var v_x: f32 = ((min(1.0f, max(0.0f, v_u)) * f32(v_width)) - 0.5f);
  var v_y: f32 = (((1.0f - min(1.0f, max(0.0f, v_v))) * f32(v_height)) - 0.5f);
  var v_ix: i32 = i32(floor(v_x));
  var v_iy: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - floor(v_x));
  var v_fy: f32 = (v_y - floor(v_y));
  var v_value: f32 = 0.0f;
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
          var gpu_tmp_9: i32;
          if ((v_sx < 0i)) {
            gpu_tmp_9 = 0i;
          } else {
            var gpu_tmp_8: i32;
            if ((v_sx >= i32(v_width))) {
              gpu_tmp_8 = (i32(v_width) - 1i);
            } else {
              gpu_tmp_8 = v_sx;
            }
            gpu_tmp_9 = gpu_tmp_8;
          }
          v_sx = gpu_tmp_9;
          var gpu_tmp_11: i32;
          if ((v_sy < 0i)) {
            gpu_tmp_11 = 0i;
          } else {
            var gpu_tmp_10: i32;
            if ((v_sy >= i32(v_height))) {
              gpu_tmp_10 = (i32(v_height) - 1i);
            } else {
              gpu_tmp_10 = v_sy;
            }
            gpu_tmp_11 = gpu_tmp_10;
          }
          v_sy = gpu_tmp_11;
          var gpu_tmp_12: f32;
          if ((v_dx == 0i)) {
            gpu_tmp_12 = (1.0f - v_fx);
          } else {
            gpu_tmp_12 = v_fx;
          }
          var gpu_tmp_13: f32;
          if ((v_dy == 0i)) {
            gpu_tmp_13 = (1.0f - v_fy);
          } else {
            gpu_tmp_13 = v_fy;
          }
          v_value = (v_value + ((b_source[(gpu_buffer_offset_0 + i32(((((u32(v_sy) * v_width) + u32(v_sx)) * u32(9i)) + v_channel)))] * gpu_tmp_12) * gpu_tmp_13));
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
  return v_value;
}
fn f_gpu_buffer_helper_1(gpu_buffer_arg_0: i32, gpu_arg_width: u32, gpu_arg_height: u32, gpu_arg_u: f32, gpu_arg_v: f32, gpu_arg_channel: u32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var gpu_buffer_offset_0: i32 = gpu_buffer_arg_0;
  var v_width: u32 = gpu_arg_width;
  var v_height: u32 = gpu_arg_height;
  var v_u: f32 = gpu_arg_u;
  var v_v: f32 = gpu_arg_v;
  var v_channel: u32 = gpu_arg_channel;
  var v_x: f32 = ((min(1.0f, max(0.0f, v_u)) * f32(v_width)) - 0.5f);
  var v_y: f32 = (((1.0f - min(1.0f, max(0.0f, v_v))) * f32(v_height)) - 0.5f);
  var v_ix: i32 = i32(floor(v_x));
  var v_iy: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - floor(v_x));
  var v_fy: f32 = (v_y - floor(v_y));
  var v_value: f32 = 0.0f;
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
          var gpu_tmp_15: i32;
          if ((v_sx < 0i)) {
            gpu_tmp_15 = 0i;
          } else {
            var gpu_tmp_14: i32;
            if ((v_sx >= i32(v_width))) {
              gpu_tmp_14 = (i32(v_width) - 1i);
            } else {
              gpu_tmp_14 = v_sx;
            }
            gpu_tmp_15 = gpu_tmp_14;
          }
          v_sx = gpu_tmp_15;
          var gpu_tmp_17: i32;
          if ((v_sy < 0i)) {
            gpu_tmp_17 = 0i;
          } else {
            var gpu_tmp_16: i32;
            if ((v_sy >= i32(v_height))) {
              gpu_tmp_16 = (i32(v_height) - 1i);
            } else {
              gpu_tmp_16 = v_sy;
            }
            gpu_tmp_17 = gpu_tmp_16;
          }
          v_sy = gpu_tmp_17;
          var gpu_tmp_18: f32;
          if ((v_dx == 0i)) {
            gpu_tmp_18 = (1.0f - v_fx);
          } else {
            gpu_tmp_18 = v_fx;
          }
          var gpu_tmp_19: f32;
          if ((v_dy == 0i)) {
            gpu_tmp_19 = (1.0f - v_fy);
          } else {
            gpu_tmp_19 = v_fy;
          }
          v_value = (v_value + ((b_depth[(gpu_buffer_offset_0 + i32(((((u32(v_sy) * v_width) + u32(v_sx)) * u32(9i)) + v_channel)))] * gpu_tmp_18) * gpu_tmp_19));
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
  return v_value;
}
fn f_gpu_buffer_helper_2(gpu_buffer_arg_0: i32, gpu_arg_width: u32, gpu_arg_height: u32, gpu_arg_u: f32, gpu_arg_v: f32, gpu_arg_channel: u32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var gpu_buffer_offset_0: i32 = gpu_buffer_arg_0;
  var v_width: u32 = gpu_arg_width;
  var v_height: u32 = gpu_arg_height;
  var v_u: f32 = gpu_arg_u;
  var v_v: f32 = gpu_arg_v;
  var v_channel: u32 = gpu_arg_channel;
  var v_x: f32 = ((min(1.0f, max(0.0f, v_u)) * f32(v_width)) - 0.5f);
  var v_y: f32 = (((1.0f - min(1.0f, max(0.0f, v_v))) * f32(v_height)) - 0.5f);
  var v_ix: i32 = i32(floor(v_x));
  var v_iy: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - floor(v_x));
  var v_fy: f32 = (v_y - floor(v_y));
  var v_value: f32 = 0.0f;
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
          var gpu_tmp_21: i32;
          if ((v_sx < 0i)) {
            gpu_tmp_21 = 0i;
          } else {
            var gpu_tmp_20: i32;
            if ((v_sx >= i32(v_width))) {
              gpu_tmp_20 = (i32(v_width) - 1i);
            } else {
              gpu_tmp_20 = v_sx;
            }
            gpu_tmp_21 = gpu_tmp_20;
          }
          v_sx = gpu_tmp_21;
          var gpu_tmp_23: i32;
          if ((v_sy < 0i)) {
            gpu_tmp_23 = 0i;
          } else {
            var gpu_tmp_22: i32;
            if ((v_sy >= i32(v_height))) {
              gpu_tmp_22 = (i32(v_height) - 1i);
            } else {
              gpu_tmp_22 = v_sy;
            }
            gpu_tmp_23 = gpu_tmp_22;
          }
          v_sy = gpu_tmp_23;
          var gpu_tmp_24: f32;
          if ((v_dx == 0i)) {
            gpu_tmp_24 = (1.0f - v_fx);
          } else {
            gpu_tmp_24 = v_fx;
          }
          var gpu_tmp_25: f32;
          if ((v_dy == 0i)) {
            gpu_tmp_25 = (1.0f - v_fy);
          } else {
            gpu_tmp_25 = v_fy;
          }
          v_value = (v_value + ((b_normals[(gpu_buffer_offset_0 + i32(((((u32(v_sy) * v_width) + u32(v_sx)) * u32(9i)) + v_channel)))] * gpu_tmp_24) * gpu_tmp_25));
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
  return v_value;
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
  var v_u: f32 = gpu_divide_f32((f32((v_i % gpu_params.p_width)) + 0.5f), f32(gpu_params.p_width));
  var v_v: f32 = (1.0f - gpu_divide_f32((f32((v_i / gpu_params.p_width)) + 0.5f), f32(gpu_params.p_height)));
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(4i))) { break; }
      b_target[((v_i * 9u) + v_c)] = f_gpu_buffer_helper_0(0i, gpu_params.p_source_width, gpu_params.p_source_height, v_u, v_v, v_c, gpu_thread, gpu_block, gpu_grid);
      continuing {
        v_c += u32(1);
      }
    }
  }
  if (((gpu_params.p_flags & 1u) != 0u)) {
    var v_z: f32 = f_gpu_buffer_helper_1(0i, gpu_params.p_depth_width, gpu_params.p_depth_height, v_u, v_v, 4u, gpu_thread, gpu_block, gpu_grid);
    var v_near_plane: f32 = b_settings[0i];
    var v_far_plane: f32 = b_settings[1i];
    var v_distance: f32;
    if (((gpu_params.p_flags & 8u) != 0u)) {
      v_distance = gpu_divide_f32((v_near_plane * v_far_plane), (v_far_plane + (v_z * (v_near_plane - v_far_plane))));
    } else {
      v_distance = gpu_divide_f32(((2.0f * v_near_plane) * v_far_plane), ((v_far_plane + v_near_plane) - (((v_z * 2.0f) - 1.0f) * (v_far_plane - v_near_plane))));
    }
    {
      var v_c: u32 = u32(0i);
      loop {
        if (!(v_c < u32(3i))) { break; }
        b_target[((v_i * 9u) + v_c)] = (gpu_divide_f32(v_distance, v_far_plane) * b_settings[2i]);
        continuing {
          v_c += u32(1);
        }
      }
    }
    b_target[((v_i * 9u) + 3u)] = 1.0f;
  }
  if ((((gpu_params.p_flags & 2u) != 0u) && (((gpu_params.p_flags & 1u) == 0u) || (v_u < 0.5f)))) {
    var v_n: array<f32, 3>;
    {
      var v_c: u32 = u32(0i);
      loop {
        if (!(v_c < u32(3i))) { break; }
        v_n[v_c] = ((f_gpu_buffer_helper_2(0i, gpu_params.p_normal_width, gpu_params.p_normal_height, v_u, v_v, (5u + v_c), gpu_thread, gpu_block, gpu_grid) * 2.0f) - 1.0f);
        continuing {
          v_c += u32(1);
        }
      }
    }
    {
      var v_c: u32 = u32(0i);
      loop {
        if (!(v_c < u32(3i))) { break; }
        var v_value: f32 = v_n[v_c];
        if (((gpu_params.p_flags & 4u) != 0u)) {
          v_value = (((v_n[0i] * b_settings[(3u + (v_c * 4u))]) + (v_n[1i] * b_settings[(4u + (v_c * 4u))])) + (v_n[2i] * b_settings[(5u + (v_c * 4u))]));
        }
        b_target[((v_i * 9u) + v_c)] = ((v_value * 0.5f) + 0.5f);
        continuing {
          v_c += u32(1);
        }
      }
    }
  }
}
