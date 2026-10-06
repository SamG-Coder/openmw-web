// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: generate_map.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_blocks: array<u32>;
@group(0) @binding(1) var<storage, read_write> b_pixels: array<u32>;
struct KernelParams {
  p_width: u32,
  p_height: u32,
  p_block_offset: u32,
  p_pixel_offset: u32,
  p_alpha_only: u32,
  gpu_pad_20: u32,
  gpu_pad_24: u32,
  gpu_pad_28: u32,
}
@group(0) @binding(2) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);


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
  var v_cells_x: u32 = b_blocks[gpu_params.p_block_offset];
  var v_cell_size: u32 = b_blocks[(gpu_params.p_block_offset + 2u)];
  var v_x: u32 = (v_i % gpu_params.p_width);
  var v_y: u32 = (v_i / gpu_params.p_width);
  var v_cell: u32 = (((v_y / v_cell_size) * v_cells_x) + (v_x / v_cell_size));
  var v_sample: u32 = (((((v_y % v_cell_size) * 9u) / v_cell_size) * 9u) + (((v_x % v_cell_size) * 9u) / v_cell_size));
  var v_index: u32 = b_blocks[(((gpu_params.p_block_offset + 1027u) + (v_cell * 81u)) + v_sample)];
  if ((v_index > 255u)) {
    v_index = 255u;
  }
  var v_packed: u32 = 4278190080u;
  if ((gpu_params.p_alpha_only != 0u)) {
    var gpu_tmp_0: u32;
    if ((v_index < 128u)) {
      gpu_tmp_0 = 0u;
    } else {
      gpu_tmp_0 = 4278190080u;
    }
    v_packed = (16777215u | gpu_tmp_0);
  } else {
    {
      var v_channel: u32 = u32(0i);
      loop {
        if (!(v_channel < u32(3i))) { break; }
        let gpu_argument_index_1 = (((gpu_params.p_block_offset + 3u) + (v_index * 4u)) + v_channel);
        var v_value: f32 = bitcast<f32>(b_blocks[gpu_argument_index_1]);
        var v_byte: u32 = u32((min(1.0f, max(0.0f, v_value)) * 255.0f));
        v_packed = (v_packed | (v_byte << (v_channel * 8u)));
        continuing {
          v_channel += u32(1);
        }
      }
    }
  }
  b_pixels[(gpu_params.p_pixel_offset + v_i)] = v_packed;
}
