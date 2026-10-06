// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: snapshot_frame.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_target: array<f32>;
struct KernelParams {
  p_source_width: u32,
  p_source_height: u32,
  p_width: u32,
  p_height: u32,
}
@group(0) @binding(2) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn gpu_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }

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
  var v_valid: u32 = select(u32(0), u32(1), ((gpu_params.p_source_width > 0u) && (gpu_params.p_source_height > 0u)));
  var gpu_tmp_0: u32;
  if ((v_valid != 0u)) {
    gpu_tmp_0 = u32(gpu_divide_f32(((f32((v_i % gpu_params.p_width)) + 0.5f) * f32(gpu_params.p_source_width)), f32(gpu_params.p_width)));
  } else {
    gpu_tmp_0 = 0u;
  }
  var v_sx: u32 = gpu_tmp_0;
  var gpu_tmp_1: u32;
  if ((v_valid != 0u)) {
    gpu_tmp_1 = u32(gpu_divide_f32(((f32((v_i / gpu_params.p_width)) + 0.5f) * f32(gpu_params.p_source_height)), f32(gpu_params.p_height)));
  } else {
    gpu_tmp_1 = 0u;
  }
  var v_sy: u32 = gpu_tmp_1;
  if ((v_valid != 0u)) {
    if ((v_sx >= gpu_params.p_source_width)) {
      v_sx = (gpu_params.p_source_width - 1u);
    }
    if ((v_sy >= gpu_params.p_source_height)) {
      v_sy = (gpu_params.p_source_height - 1u);
    }
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      var gpu_tmp_2: f32;
      if ((v_valid != 0u)) {
        gpu_tmp_2 = b_source[((((v_sy * gpu_params.p_source_width) + v_sx) * 9u) + v_k)];
      } else {
        gpu_tmp_2 = 0.0f;
      }
      b_target[((v_i * 9u) + v_k)] = gpu_tmp_2;
      continuing {
        v_k += u32(1);
      }
    }
  }
  b_target[((v_i * 9u) + 3u)] = 1.0f;
  b_target[((v_i * 9u) + 4u)] = 1.0f;
  {
    var v_k: u32 = u32(5i);
    loop {
      if (!(v_k < u32(9i))) { break; }
      b_target[((v_i * 9u) + v_k)] = 0.0f;
      continuing {
        v_k += u32(1);
      }
    }
  }
  b_target[(((gpu_params.p_width * gpu_params.p_height) * 9u) + v_i)] = 0.0f;
}
