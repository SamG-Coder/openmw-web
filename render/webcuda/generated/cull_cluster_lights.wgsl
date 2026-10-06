// CUDA WebShader 0.1.1. Generated from kernel cull_cluster_lights.
@group(0) @binding(0) var<storage, read> b_clusters: array<f32>;
@group(0) @binding(1) var<storage, read> b_lights: array<f32>;
@group(0) @binding(2) var<storage, read_write> b_grid: array<u32>;
@group(0) @binding(3) var<storage, read_write> b_indices: array<u32>;
@group(0) @binding(4) var<storage, read_write> b_overflow: array<u32>;
struct CWParams {
  p_cluster_count: u32,
  p_light_count: u32,
  p_capacity: u32,
  cw_pad_12: u32,
}
@group(0) @binding(5) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);


@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_tile: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if ((v_tile >= cw_params.p_cluster_count)) {
    return;
  }
  var v_count: u32 = u32(0i);
  {
    var v_light: u32 = u32(0i);
    loop {
      if (!(v_light < cw_params.p_light_count)) { break; }
      var v_distance: f32 = 0.0f;
      {
        var v_axis: u32 = u32(0i);
        loop {
          if (!(v_axis < u32(3i))) { break; }
          var v_center: f32 = b_lights[((v_light * u32(20i)) + v_axis)];
          let cw_argument_index_0 = (((v_tile * u32(8i)) + u32(4i)) + v_axis);
          let cw_argument_index_1 = ((v_tile * u32(8i)) + v_axis);
          var v_closest: f32 = min(b_clusters[cw_argument_index_0], max(b_clusters[cw_argument_index_1], v_center));
          var v_delta: f32 = (v_closest - v_center);
          v_distance = (v_distance + (v_delta * v_delta));
          continuing {
            v_axis += u32(1);
          }
        }
      }
      var v_radius: f32 = b_lights[((v_light * u32(20i)) + u32(19i))];
      if ((v_distance <= (v_radius * v_radius))) {
        if ((v_count < cw_params.p_capacity)) {
          b_indices[((v_tile * cw_params.p_capacity) + v_count)] = v_light;
        }
        v_count += u32(1);
      }
      continuing {
        v_light += u32(1);
      }
    }
  }
  b_grid[(v_tile * u32(2i))] = (v_tile * cw_params.p_capacity);
  var cw_tmp_2: u32;
  if ((v_count < cw_params.p_capacity)) {
    cw_tmp_2 = v_count;
  } else {
    cw_tmp_2 = cw_params.p_capacity;
  }
  b_grid[((v_tile * u32(2i)) + u32(1i))] = cw_tmp_2;
  var cw_tmp_3: u32;
  if ((v_count > cw_params.p_capacity)) {
    cw_tmp_3 = v_count;
  } else {
    cw_tmp_3 = 0u;
  }
  b_overflow[v_tile] = cw_tmp_3;
}
