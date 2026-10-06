// CUDA WebShader 0.1.1. Generated from kernel prepare_cluster_lights.
@group(0) @binding(0) var<storage, read_write> b_lights: array<f32>;
@group(0) @binding(1) var<storage, read> b_inputs: array<f32>;
struct CWParams {
  p_light_count: u32,
  cw_pad_4: u32,
  cw_pad_8: u32,
  cw_pad_12: u32,
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
  if ((v_i >= cw_params.p_light_count)) {
    return;
  }
  var v_record: u32 = (v_i * 20u);
  var v_fade: u32 = (20u + (v_i * 5u));
  var v_position: array<f32, 4>;
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      v_position[v_k] = b_lights[(v_record + v_k)];
      continuing {
        v_k += u32(1);
      }
    }
  }
  {
    var v_row: u32 = u32(0i);
    loop {
      if (!(v_row < u32(4i))) { break; }
      var v_value: f32 = 0.0f;
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(4i))) { break; }
          v_value = (v_value + (b_inputs[((v_col * 4u) + v_row)] * v_position[v_col]));
          continuing {
            v_col += u32(1);
          }
        }
      }
      b_lights[(v_record + v_row)] = v_value;
      continuing {
        v_row += u32(1);
      }
    }
  }
  var v_amount: f32 = 1.0f;
  var v_end: f32 = b_inputs[(v_fade + 4u)];
  if ((v_end != 0.0f)) {
    var v_distance: f32 = 0.0f;
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(3i))) { break; }
        v_distance = (v_distance + (b_inputs[(v_fade + v_k)] * b_inputs[(v_fade + v_k)]));
        continuing {
          v_k += u32(1);
        }
      }
    }
    v_amount = (1.0f - min(1.0f, max(0.0f, cw_divide_f32((sqrt(v_distance) - b_inputs[(v_fade + 3u)]), (v_end - b_inputs[(v_fade + 3u)])))));
  }
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(4i))) { break; }
      b_lights[((v_record + 4u) + v_k)] = (b_lights[((v_record + 4u) + v_k)] * v_amount);
      b_lights[((v_record + 12u) + v_k)] = (b_lights[((v_record + 12u) + v_k)] * v_amount);
      continuing {
        v_k += u32(1);
      }
    }
  }
  b_lights[(v_record + 19u)] = (b_lights[(v_record + 19u)] * b_inputs[16i]);
}
