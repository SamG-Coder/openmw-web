// CUDA WebShader 0.1.1. Generated from kernel bin_triangles.
@group(0) @binding(0) var<storage, read> b_clip: array<f32>;
@group(0) @binding(1) var<storage, read> b_indices: array<u32>;
@group(0) @binding(2) var<storage, read_write> b_counts: array<u32>;
@group(0) @binding(3) var<storage, read_write> b_candidates: array<u32>;
struct CWParams {
  p_width: u32,
  p_height: u32,
  p_triangle_count: u32,
  p_capacity: u32,
  p_vertex_stride: u32,
  p_triangle_stride: u32,
  cw_pad_24: u32,
  cw_pad_28: u32,
}
@group(0) @binding(4) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn cw_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }


@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_tile: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  var v_columns: u32 = ((cw_params.p_width + u32(15i)) / u32(16i));
  var v_rows: u32 = ((cw_params.p_height + u32(15i)) / u32(16i));
  if ((v_tile >= (v_columns * v_rows))) {
    return;
  }
  var v_left: f32 = f32(((v_tile % v_columns) * u32(16i)));
  var v_top: f32 = f32(((v_tile / v_columns) * u32(16i)));
  var v_right: f32 = min((v_left + 16.0f), f32(cw_params.p_width));
  var v_bottom: f32 = min((v_top + 16.0f), f32(cw_params.p_height));
  var v_count: u32 = u32(0i);
  {
    var v_t: u32 = u32(0i);
    loop {
      if (!(v_t < cw_params.p_triangle_count)) { break; }
      var v_min_x: f32 = f32(cw_params.p_width);
      var v_min_y: f32 = f32(cw_params.p_height);
      var v_max_x: f32 = 0.0f;
      var v_max_y: f32 = 0.0f;
      var v_usable: u32 = u32(1i);
      {
        var v_v: u32 = u32(0i);
        loop {
          if (!(v_v < u32(3i))) { break; }
          var v_i: u32 = (b_indices[((v_t * cw_params.p_triangle_stride) + v_v)] * cw_params.p_vertex_stride);
          var v_w: f32 = b_clip[(v_i + u32(3i))];
          if ((v_w <= 0.0f)) {
            v_usable = u32(0i);
            break;
          }
          var v_x: f32 = (((cw_divide_f32(b_clip[v_i], v_w) * 0.5f) + 0.5f) * f32(cw_params.p_width));
          var v_y: f32 = ((0.5f - (cw_divide_f32(b_clip[(v_i + u32(1i))], v_w) * 0.5f)) * f32(cw_params.p_height));
          v_min_x = min(v_min_x, v_x);
          v_max_x = max(v_max_x, v_x);
          v_min_y = min(v_min_y, v_y);
          v_max_y = max(v_max_y, v_y);
          continuing {
            v_v += u32(1);
          }
        }
      }
      if ((((((v_usable == u32(0i)) || (v_max_x < (v_left + 0.5f))) || (v_min_x > (v_right - 0.5f))) || (v_max_y < (v_top + 0.5f))) || (v_min_y > (v_bottom - 0.5f)))) {
        continue;
      }
      if ((v_count < cw_params.p_capacity)) {
        b_candidates[((v_tile * cw_params.p_capacity) + v_count)] = v_t;
      }
      v_count += u32(1);
      continuing {
        v_t += u32(1);
      }
    }
  }
  b_counts[v_tile] = v_count;
}
