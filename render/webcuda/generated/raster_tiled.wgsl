// CUDA WebShader 0.1.1. Generated from kernel raster_tiled.
@group(0) @binding(0) var<storage, read> b_clip: array<f32>;
@group(0) @binding(1) var<storage, read> b_colors: array<f32>;
@group(0) @binding(2) var<storage, read> b_indices: array<u32>;
@group(0) @binding(3) var<storage, read> b_counts: array<u32>;
@group(0) @binding(4) var<storage, read> b_candidates: array<u32>;
@group(0) @binding(5) var<storage, read_write> b_rgba: array<f32>;
@group(0) @binding(6) var<storage, read_write> b_depth: array<f32>;
struct CWParams {
  p_width: u32,
  p_height: u32,
  p_capacity: u32,
  cw_pad_12: u32,
}
@group(0) @binding(7) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn cw_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }




@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_pixel: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_pixel >= (cw_params.p_width * cw_params.p_height))) {
    return;
  }
  var v_columns: u32 = ((cw_params.p_width + u32(15i)) / u32(16i));
  var v_tile: u32 = ((((v_pixel / cw_params.p_width) / u32(16i)) * v_columns) + ((v_pixel % cw_params.p_width) / u32(16i)));
  var v_count: u32 = b_counts[v_tile];
  if ((v_count > cw_params.p_capacity)) {
    b_rgba[(v_pixel * u32(4i))] = 1.0f;
    b_rgba[((v_pixel * u32(4i)) + u32(1i))] = 0.0f;
    b_rgba[((v_pixel * u32(4i)) + u32(2i))] = 1.0f;
    b_rgba[((v_pixel * u32(4i)) + u32(3i))] = 1.0f;
    b_depth[v_pixel] = 1.0f;
    return;
  }
  var v_px: f32 = (f32((v_pixel % cw_params.p_width)) + 0.5f);
  var v_py: f32 = (f32((v_pixel / cw_params.p_width)) + 0.5f);
  var v_best: f32 = 1.0f;
  var v_red: f32 = 0.0f;
  var v_green: f32 = 0.0f;
  var v_blue: f32 = 0.0f;
  {
    var v_candidate: u32 = u32(0i);
    loop {
      if (!(v_candidate < v_count)) { break; }
      var v_t: u32 = b_candidates[((v_tile * cw_params.p_capacity) + v_candidate)];
      var v_ia: u32 = (b_indices[(v_t * u32(3i))] * u32(4i));
      var v_ib: u32 = (b_indices[((v_t * u32(3i)) + u32(1i))] * u32(4i));
      var v_ic: u32 = (b_indices[((v_t * u32(3i)) + u32(2i))] * u32(4i));
      var v_aw: f32 = b_clip[(v_ia + u32(3i))];
      var v_bw: f32 = b_clip[(v_ib + u32(3i))];
      var v_cw: f32 = b_clip[(v_ic + u32(3i))];
      if ((((v_aw <= 0.0f) || (v_bw <= 0.0f)) || (v_cw <= 0.0f))) {
        continue;
      }
      var v_ax: f32 = (((cw_divide_f32(b_clip[v_ia], v_aw) * 0.5f) + 0.5f) * f32(cw_params.p_width));
      var v_ay: f32 = ((0.5f - (cw_divide_f32(b_clip[(v_ia + u32(1i))], v_aw) * 0.5f)) * f32(cw_params.p_height));
      var v_bx: f32 = (((cw_divide_f32(b_clip[v_ib], v_bw) * 0.5f) + 0.5f) * f32(cw_params.p_width));
      var v_by: f32 = ((0.5f - (cw_divide_f32(b_clip[(v_ib + u32(1i))], v_bw) * 0.5f)) * f32(cw_params.p_height));
      var v_cx: f32 = (((cw_divide_f32(b_clip[v_ic], v_cw) * 0.5f) + 0.5f) * f32(cw_params.p_width));
      var v_cy: f32 = ((0.5f - (cw_divide_f32(b_clip[(v_ic + u32(1i))], v_cw) * 0.5f)) * f32(cw_params.p_height));
      var v_area: f32 = (((v_bx - v_ax) * (v_cy - v_ay)) - ((v_by - v_ay) * (v_cx - v_ax)));
      if ((abs(v_area) < 0.000001f)) {
        continue;
      }
      var v_a: f32 = cw_divide_f32((((v_bx - v_px) * (v_cy - v_py)) - ((v_by - v_py) * (v_cx - v_px))), v_area);
      var v_b: f32 = cw_divide_f32((((v_cx - v_px) * (v_ay - v_py)) - ((v_cy - v_py) * (v_ax - v_px))), v_area);
      var v_c: f32 = ((1.0f - v_a) - v_b);
      if ((((v_a < 0.0f) || (v_b < 0.0f)) || (v_c < 0.0f))) {
        continue;
      }
      var v_z: f32 = ((((cw_divide_f32((v_a * b_clip[(v_ia + u32(2i))]), v_aw) + cw_divide_f32((v_b * b_clip[(v_ib + u32(2i))]), v_bw)) + cw_divide_f32((v_c * b_clip[(v_ic + u32(2i))]), v_cw)) * 0.5f) + 0.5f);
      if (((v_z < 0.0f) || (v_z >= v_best))) {
        continue;
      }
      v_best = v_z;
      var v_recip: f32 = ((cw_divide_f32(v_a, v_aw) + cw_divide_f32(v_b, v_bw)) + cw_divide_f32(v_c, v_cw));
      v_a = cw_divide_f32(cw_divide_f32(v_a, v_aw), v_recip);
      v_b = cw_divide_f32(cw_divide_f32(v_b, v_bw), v_recip);
      v_c = cw_divide_f32(cw_divide_f32(v_c, v_cw), v_recip);
      v_red = (((v_a * b_colors[v_ia]) + (v_b * b_colors[v_ib])) + (v_c * b_colors[v_ic]));
      v_green = (((v_a * b_colors[(v_ia + u32(1i))]) + (v_b * b_colors[(v_ib + u32(1i))])) + (v_c * b_colors[(v_ic + u32(1i))]));
      v_blue = (((v_a * b_colors[(v_ia + u32(2i))]) + (v_b * b_colors[(v_ib + u32(2i))])) + (v_c * b_colors[(v_ic + u32(2i))]));
      continuing {
        v_candidate += u32(1);
      }
    }
  }
  b_depth[v_pixel] = v_best;
  b_rgba[(v_pixel * u32(4i))] = v_red;
  b_rgba[((v_pixel * u32(4i)) + u32(1i))] = v_green;
  b_rgba[((v_pixel * u32(4i)) + u32(2i))] = v_blue;
  b_rgba[((v_pixel * u32(4i)) + u32(3i))] = 1.0f;
}
