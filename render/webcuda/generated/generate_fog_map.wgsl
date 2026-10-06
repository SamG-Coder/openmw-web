// CUDA WebShader 0.1.1. Generated from kernel generate_fog_map.
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

fn cw_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }

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
  var v_brush_count: u32 = b_blocks[cw_params.p_block_offset];
  var v_saved: u32 = b_blocks[((cw_params.p_block_offset + 1u) + v_i)];
  var v_brushes: u32 = ((cw_params.p_block_offset + 1u) + (cw_params.p_width * cw_params.p_height));
  var v_alpha: u32 = (v_saved >> 24u);
  var v_x: f32 = f32((v_i % cw_params.p_width));
  var v_y: f32 = f32((v_i / cw_params.p_width));
  {
    var v_b: u32 = u32(0i);
    loop {
      if (!(v_b < v_brush_count)) { break; }
      let cw_argument_index_0 = (v_brushes + (v_b * 3u));
      var v_dx: f32 = (v_x - bitcast<f32>(b_blocks[cw_argument_index_0]));
      let cw_argument_index_1 = ((v_brushes + (v_b * 3u)) + 1u);
      var v_dy: f32 = (v_y - bitcast<f32>(b_blocks[cw_argument_index_1]));
      let cw_argument_index_2 = ((v_brushes + (v_b * 3u)) + 2u);
      var v_fraction: f32 = min(1.0f, max(0.0f, cw_divide_f32(((v_dx * v_dx) + (v_dy * v_dy)), bitcast<f32>(b_blocks[cw_argument_index_2]))));
      var v_candidate: u32 = u32((v_fraction * 255.0f));
      if ((v_candidate < v_alpha)) {
        v_alpha = v_candidate;
      }
      continuing {
        v_b += u32(1);
      }
    }
  }
  var cw_tmp_3: u32;
  if ((v_brush_count == 0u)) {
    cw_tmp_3 = v_saved;
  } else {
    cw_tmp_3 = (v_alpha << 24u);
  }
  b_pixels[(cw_params.p_pixel_offset + v_i)] = cw_tmp_3;
}
