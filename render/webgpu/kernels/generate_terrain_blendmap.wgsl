// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: generate_terrain_blendmap.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_blocks: array<u32>;
@group(0) @binding(1) var<storage, read_write> b_pixels: array<u32>;
struct KernelParams {
  p_width: u32,
  p_height: u32,
  p_block_offset: u32,
  p_pixel_offset: u32,
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
  var v_mode: u32 = b_blocks[gpu_params.p_block_offset];
  var v_layer: u32 = b_blocks[(gpu_params.p_block_offset + 1u)];
  var v_source: u32 = b_blocks[(gpu_params.p_block_offset + 2u)];
  var v_x: u32 = (v_i % gpu_params.p_width);
  var v_y: u32 = (v_i / gpu_params.p_width);
  var v_alpha: u32 = 0u;
  if ((v_mode == 0u)) {
    var v_inputWidth: u32 = b_blocks[v_source];
    var gpu_tmp_0: u32;
    if ((b_blocks[(((v_source + 3u) + ((v_y / 2u) * v_inputWidth)) + (v_x / 2u))] == v_layer)) {
      gpu_tmp_0 = 255u;
    } else {
      gpu_tmp_0 = 0u;
    }
    v_alpha = gpu_tmp_0;
  } else {
    var v_columns: u32 = b_blocks[v_source];
    var v_qx: u32 = (v_x / 16u);
    var v_qy: u32 = ((v_y + 15u) / 16u);
    var v_quad: u32 = b_blocks[(((v_source + 3u) + (v_qy * v_columns)) + v_qx)];
    if ((v_quad != 0u)) {
      var v_base: u32 = b_blocks[(v_source + v_quad)];
      var gpu_tmp_1: u32;
      if ((v_base == v_layer)) {
        gpu_tmp_1 = 255u;
      } else {
        gpu_tmp_1 = 0u;
      }
      v_alpha = gpu_tmp_1;
      var gpu_tmp_2: u32;
      if ((v_y == 0u)) {
        gpu_tmp_2 = 16u;
      } else {
        gpu_tmp_2 = (((v_y - 1u) % 16u) + 1u);
      }
      var v_vertex: u32 = ((gpu_tmp_2 * 17u) + (v_x % 16u));
      var v_begin: u32 = b_blocks[(((v_source + v_quad) + 1u) + v_vertex)];
      var v_end: u32 = b_blocks[(((v_source + v_quad) + 2u) + v_vertex)];
      {
        var v_record: u32 = v_begin;
        loop {
          if (!(v_record < v_end)) { break; }
          var v_paintedLayer: u32 = b_blocks[(v_source + v_record)];
          let gpu_argument_index_3 = ((v_source + v_record) + 1u);
          var v_opacity: f32 = bitcast<f32>(b_blocks[gpu_argument_index_3]);
          var v_delta: u32 = u32(min(255.0f, max(0.0f, (v_opacity * 255.0f))));
          if ((v_layer == v_base)) {
            var gpu_tmp_4: u32;
            if ((v_alpha < v_delta)) {
              gpu_tmp_4 = v_alpha;
            } else {
              gpu_tmp_4 = v_delta;
            }
            v_alpha = (v_alpha - gpu_tmp_4);
          }
          if ((v_layer == v_paintedLayer)) {
            v_alpha = v_delta;
          }
          continuing {
            v_record = (v_record + 2u);
          }
        }
      }
    }
  }
  b_pixels[(gpu_params.p_pixel_offset + v_i)] = (16777215u | (v_alpha << 24u));
}
