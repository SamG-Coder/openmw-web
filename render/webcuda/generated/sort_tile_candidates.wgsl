// CUDA WebShader 0.1.1. Generated from kernel sort_tile_candidates.
@group(0) @binding(0) var<storage, read> b_counts: array<u32>;
@group(0) @binding(1) var<storage, read_write> b_candidates: array<u32>;
struct CWParams {
  p_tile_count: u32,
  p_capacity: u32,
  cw_pad_8: u32,
  cw_pad_12: u32,
}
@group(0) @binding(2) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);



@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_tile: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_tile >= cw_params.p_tile_count)) {
    return;
  }
  var v_n: u32 = b_counts[v_tile];
  var cw_tmp_3: u32;
  if ((cw_params.p_capacity == 0u)) {
    cw_tmp_3 = b_candidates[v_tile];
  } else {
    cw_tmp_3 = (v_tile * cw_params.p_capacity);
  }
  var v_base: u32 = cw_tmp_3;
  if (((v_n < 2u) || ((cw_params.p_capacity != 0u) && (v_n > cw_params.p_capacity)))) {
    return;
  }
  var v_start: u32 = (v_n / 2u);
  var v_end: u32 = v_n;
  {
    loop {
      if (!(v_end > 1u)) { break; }
      var v_root: u32;
      if ((v_start > 0u)) {
        v_start -= u32(1);
        v_root = v_start;
      } else {
        v_end -= u32(1);
        var v_top: u32 = b_candidates[v_base];
        b_candidates[v_base] = b_candidates[(v_base + v_end)];
        b_candidates[(v_base + v_end)] = v_top;
        v_root = 0u;
      }
      var v_value: u32 = b_candidates[(v_base + v_root)];
      {
        loop {
          if (!(((v_root * 2u) + 1u) < v_end)) { break; }
          var v_child: u32 = ((v_root * 2u) + 1u);
          if ((((v_child + 1u) < v_end) && (b_candidates[(v_base + v_child)] < b_candidates[((v_base + v_child) + 1u)]))) {
            v_child += u32(1);
          }
          if ((v_value >= b_candidates[(v_base + v_child)])) {
            break;
          }
          b_candidates[(v_base + v_root)] = b_candidates[(v_base + v_child)];
          v_root = v_child;
        }
      }
      b_candidates[(v_base + v_root)] = v_value;
    }
  }
}
