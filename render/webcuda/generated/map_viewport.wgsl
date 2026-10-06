// CUDA WebShader 0.1.1. Generated from kernel map_viewport.
@group(0) @binding(0) var<storage, read_write> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_attributes: array<f32>;
struct CWParams {
  p_point_fade_offset: u32,
  p_vertex_count: u32,
  p_width: u32,
  p_height: u32,
  p_viewport_x: i32,
  p_viewport_y: i32,
  p_viewport_width: u32,
  p_viewport_height: u32,
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
  if ((v_i >= cw_params.p_vertex_count)) {
    return;
  }
  var v_v: u32 = (v_i * u32(10i));
  var v_w: f32 = b_vertices[(v_v + u32(3i))];
  b_vertices[v_v] = (cw_divide_f32((b_vertices[v_v] * f32(cw_params.p_viewport_width)), f32(cw_params.p_width)) + (v_w * (cw_divide_f32(((2.0f * f32(cw_params.p_viewport_x)) + f32(cw_params.p_viewport_width)), f32(cw_params.p_width)) - 1.0f)));
  b_vertices[(v_v + u32(1i))] = (cw_divide_f32((b_vertices[(v_v + u32(1i))] * f32(cw_params.p_viewport_height)), f32(cw_params.p_height)) + (v_w * (cw_divide_f32(((2.0f * f32(cw_params.p_viewport_y)) + f32(cw_params.p_viewport_height)), f32(cw_params.p_height)) - 1.0f)));
  var v_metadata: u32 = (cw_params.p_point_fade_offset + (v_i * 12u));
  if (((b_attributes[(v_metadata + 7u)] > 0.0f) && (b_attributes[(v_metadata + 11u)] > 0.0f))) {
    {
      var v_endpoint: u32 = 0u;
      loop {
        if (!(v_endpoint < 2u)) { break; }
        var v_base: u32 = ((v_metadata + 4u) + (v_endpoint * 4u));
        var v_endpointW: f32 = b_attributes[(v_base + 3u)];
        b_attributes[v_base] = (cw_divide_f32((b_attributes[v_base] * f32(cw_params.p_viewport_width)), f32(cw_params.p_width)) + (v_endpointW * (cw_divide_f32(((2.0f * f32(cw_params.p_viewport_x)) + f32(cw_params.p_viewport_width)), f32(cw_params.p_width)) - 1.0f)));
        b_attributes[(v_base + 1u)] = (cw_divide_f32((b_attributes[(v_base + 1u)] * f32(cw_params.p_viewport_height)), f32(cw_params.p_height)) + (v_endpointW * (cw_divide_f32(((2.0f * f32(cw_params.p_viewport_y)) + f32(cw_params.p_viewport_height)), f32(cw_params.p_height)) - 1.0f)));
        continuing {
          v_endpoint += u32(1);
        }
      }
    }
  }
}
