// CUDA WebShader 0.1.1. Generated from kernel capture_image.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_pixels: array<u32>;
struct CWParams {
  p_source_width: u32,
  p_source_height: u32,
  p_width: u32,
  p_height: u32,
  p_region_x: i32,
  p_region_y: i32,
  p_region_width: u32,
  p_region_height: u32,
}
@group(0) @binding(2) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn cw_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }
fn f_cw_buffer_helper_0(cw_buffer_arg_0: i32, cw_arg_width: u32, cw_arg_height: u32, cw_arg_x: i32, cw_arg_y: i32, cw_arg_c: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var cw_buffer_offset_0: i32 = cw_buffer_arg_0;
  var v_width: u32 = cw_arg_width;
  var v_height: u32 = cw_arg_height;
  var v_x: i32 = cw_arg_x;
  var v_y: i32 = cw_arg_y;
  var v_c: u32 = cw_arg_c;
  if (((((v_x < 0i) || (v_y < 0i)) || (v_x >= i32(v_width))) || (v_y >= i32(v_height)))) {
    return 0.0f;
  }
  return b_source[(cw_buffer_offset_0 + i32(((((u32(v_y) * v_width) + u32(v_x)) * 9u) + v_c)))];
}

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
  var v_aspect: f32 = cw_divide_f32(f32(cw_params.p_width), f32(cw_params.p_height));
  var v_left: i32 = (i32((f32(cw_params.p_region_width) - (f32(cw_params.p_region_height) * v_aspect))) / 2i);
  var v_top: i32 = (i32((f32(cw_params.p_region_height) - cw_divide_f32(f32(cw_params.p_region_width), v_aspect))) / 2i);
  if ((v_left < 0i)) {
    v_left = 0i;
  }
  if ((v_top < 0i)) {
    v_top = 0i;
  }
  var v_crop_width: u32 = (cw_params.p_region_width - (2u * u32(v_left)));
  var v_crop_height: u32 = (cw_params.p_region_height - (2u * u32(v_top)));
  var v_x: f32 = ((f32(v_left) + cw_divide_f32(((f32((v_i % cw_params.p_width)) + 0.5f) * f32(v_crop_width)), f32(cw_params.p_width))) - 0.5f);
  var v_y: f32 = ((f32(v_top) + cw_divide_f32(((f32(((cw_params.p_height - 1u) - (v_i / cw_params.p_width))) + 0.5f) * f32(v_crop_height)), f32(cw_params.p_height))) - 0.5f);
  v_x = min(f32(((cw_params.p_region_width - 1u) - u32(v_left))), max(f32(v_left), v_x));
  v_y = min(f32(((cw_params.p_region_height - 1u) - u32(v_top))), max(f32(v_top), v_y));
  var v_local_x: i32 = i32(floor(v_x));
  var v_local_y: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - f32(v_local_x));
  var v_fy: f32 = (v_y - f32(v_local_y));
  var v_x0: i32 = (cw_params.p_region_x + v_local_x);
  var v_y0: i32 = (((i32(cw_params.p_source_height) - cw_params.p_region_y) - i32(cw_params.p_region_height)) + v_local_y);
  var cw_tmp_0: i32;
  if (((v_local_x + 1i) < i32(cw_params.p_region_width))) {
    cw_tmp_0 = (v_x0 + 1i);
  } else {
    cw_tmp_0 = v_x0;
  }
  var v_x1: i32 = cw_tmp_0;
  var cw_tmp_1: i32;
  if (((v_local_y + 1i) < i32(cw_params.p_region_height))) {
    cw_tmp_1 = (v_y0 + 1i);
  } else {
    cw_tmp_1 = v_y0;
  }
  var v_y1: i32 = cw_tmp_1;
  var v_packed: u32 = 0u;
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(4i))) { break; }
      var v_a: f32 = f_cw_buffer_helper_0(0i, cw_params.p_source_width, cw_params.p_source_height, v_x0, v_y0, v_c, cw_thread, cw_block, cw_grid);
      var v_b: f32 = f_cw_buffer_helper_0(0i, cw_params.p_source_width, cw_params.p_source_height, v_x1, v_y0, v_c, cw_thread, cw_block, cw_grid);
      var v_d: f32 = f_cw_buffer_helper_0(0i, cw_params.p_source_width, cw_params.p_source_height, v_x0, v_y1, v_c, cw_thread, cw_block, cw_grid);
      var v_e: f32 = f_cw_buffer_helper_0(0i, cw_params.p_source_width, cw_params.p_source_height, v_x1, v_y1, v_c, cw_thread, cw_block, cw_grid);
      var v_value: f32 = (((v_a + ((v_b - v_a) * v_fx)) * (1.0f - v_fy)) + ((v_d + ((v_e - v_d) * v_fx)) * v_fy));
      var v_byte: u32 = u32(floor(((min(1.0f, max(0.0f, v_value)) * 255.0f) + 0.5f)));
      v_packed = (v_packed | (v_byte << (v_c * 8u)));
      continuing {
        v_c += u32(1);
      }
    }
  }
  b_pixels[v_i] = v_packed;
}
