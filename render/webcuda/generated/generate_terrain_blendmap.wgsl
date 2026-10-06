// CUDA WebShader 0.1.1. Generated from kernel generate_terrain_blendmap.
@group(0) @binding(0) var<storage, read> b_blocks: array<u32>;
@group(0) @binding(1) var<storage, read_write> b_pixels: array<u32>;
struct CWParams {
  p_width: u32,
  p_height: u32,
  p_block_offset: u32,
  p_pixel_offset: u32,
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
  var v_mode: u32 = b_blocks[cw_params.p_block_offset];
  var v_layer: u32 = b_blocks[(cw_params.p_block_offset + 1u)];
  var v_source: u32 = b_blocks[(cw_params.p_block_offset + 2u)];
  var v_x: u32 = (v_i % cw_params.p_width);
  var v_y: u32 = (v_i / cw_params.p_width);
  var v_alpha: u32 = 0u;
  if ((v_mode == 0u)) {
    var v_inputWidth: u32 = b_blocks[v_source];
    var cw_tmp_0: u32;
    if ((b_blocks[(((v_source + 3u) + ((v_y / 2u) * v_inputWidth)) + (v_x / 2u))] == v_layer)) {
      cw_tmp_0 = 255u;
    } else {
      cw_tmp_0 = 0u;
    }
    v_alpha = cw_tmp_0;
  } else {
    var v_columns: u32 = b_blocks[v_source];
    var v_qx: u32 = (v_x / 16u);
    var v_qy: u32 = ((v_y + 15u) / 16u);
    var v_quad: u32 = b_blocks[(((v_source + 3u) + (v_qy * v_columns)) + v_qx)];
    if ((v_quad != 0u)) {
      var v_base: u32 = b_blocks[(v_source + v_quad)];
      var cw_tmp_1: u32;
      if ((v_base == v_layer)) {
        cw_tmp_1 = 255u;
      } else {
        cw_tmp_1 = 0u;
      }
      v_alpha = cw_tmp_1;
      var cw_tmp_2: u32;
      if ((v_y == 0u)) {
        cw_tmp_2 = 16u;
      } else {
        cw_tmp_2 = (((v_y - 1u) % 16u) + 1u);
      }
      var v_vertex: u32 = ((cw_tmp_2 * 17u) + (v_x % 16u));
      var v_begin: u32 = b_blocks[(((v_source + v_quad) + 1u) + v_vertex)];
      var v_end: u32 = b_blocks[(((v_source + v_quad) + 2u) + v_vertex)];
      {
        var v_record: u32 = v_begin;
        loop {
          if (!(v_record < v_end)) { break; }
          var v_paintedLayer: u32 = b_blocks[(v_source + v_record)];
          let cw_argument_index_3 = ((v_source + v_record) + 1u);
          var v_opacity: f32 = bitcast<f32>(b_blocks[cw_argument_index_3]);
          var v_delta: u32 = u32(min(255.0f, max(0.0f, (v_opacity * 255.0f))));
          if ((v_layer == v_base)) {
            var cw_tmp_4: u32;
            if ((v_alpha < v_delta)) {
              cw_tmp_4 = v_alpha;
            } else {
              cw_tmp_4 = v_delta;
            }
            v_alpha = (v_alpha - cw_tmp_4);
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
  b_pixels[(cw_params.p_pixel_offset + v_i)] = (16777215u | (v_alpha << 24u));
}
