// CUDA WebShader 0.1.1. Generated from kernel generate_depth_mip.
@group(0) @binding(0) var<storage, read_write> b_texels: array<u32>;
struct CWParams {
  p_source: u32,
  p_destination: u32,
  p_width: u32,
  p_height: u32,
  p_depth_bits: u32,
  cw_pad_20: u32,
  cw_pad_24: u32,
  cw_pad_28: u32,
}
@group(0) @binding(1) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn cw_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }







fn f_store_depth_value(cw_arg_value: f32, cw_arg_bits: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> f32 {
  var v_value: f32 = cw_arg_value;
  var v_bits: u32 = cw_arg_bits;
  v_value = min(1.0f, max(0.0f, v_value));
  if ((v_bits == 0u)) {
    return v_value;
  }
  var cw_tmp_7: f32;
  if ((v_bits == 16u)) {
    cw_tmp_7 = 65535.0f;
  } else {
    cw_tmp_7 = 16777215.0f;
  }
  var v_maximum: f32 = cw_tmp_7;
  return min(1.0f, cw_divide_f32(floor(((v_value * v_maximum) + 0.5f)), v_maximum));
}























@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_i: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  var cw_tmp_30: u32;
  if ((cw_params.p_width > 1u)) {
    cw_tmp_30 = (cw_params.p_width / 2u);
  } else {
    cw_tmp_30 = 1u;
  }
  var v_dw: u32 = cw_tmp_30;
  var cw_tmp_31: u32;
  if ((cw_params.p_height > 1u)) {
    cw_tmp_31 = (cw_params.p_height / 2u);
  } else {
    cw_tmp_31 = 1u;
  }
  var v_dh: u32 = cw_tmp_31;
  if ((v_i >= (v_dw * v_dh))) {
    return;
  }
  var v_x0: u32 = (((v_i % v_dw) * cw_params.p_width) / v_dw);
  var v_x1: u32 = ((((v_i % v_dw) + 1u) * cw_params.p_width) / v_dw);
  var v_y0: u32 = (((v_i / v_dw) * cw_params.p_height) / v_dh);
  var v_y1: u32 = ((((v_i / v_dw) + 1u) * cw_params.p_height) / v_dh);
  var v_sum: f32 = 0.0f;
  {
    var v_y: u32 = v_y0;
    loop {
      if (!(v_y < v_y1)) { break; }
      {
        var v_x: u32 = v_x0;
        loop {
          if (!(v_x < v_x1)) { break; }
          let cw_argument_index_32 = ((cw_params.p_source + (v_y * cw_params.p_width)) + v_x);
          v_sum = (v_sum + bitcast<f32>(b_texels[cw_argument_index_32]));
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
  b_texels[(cw_params.p_destination + v_i)] = bitcast<u32>(f_store_depth_value(cw_divide_f32(v_sum, f32(((v_x1 - v_x0) * (v_y1 - v_y0)))), cw_params.p_depth_bits, cw_thread, cw_block, cw_grid));
}
