// CUDA WebShader 0.1.1. Generated from kernel bin_triangle_bounds.
@group(0) @binding(0) var<storage, read> b_clip: array<f32>;
@group(0) @binding(1) var<storage, read> b_indices: array<u32>;
@group(0) @binding(2) var<storage, read_write> b_counts: array<atomic<u32>>;
@group(0) @binding(3) var<storage, read_write> b_candidates: array<u32>;
@group(0) @binding(4) var<storage, read> b_offsets: array<u32>;
@group(0) @binding(5) var<storage, read> b_summary: array<u32>;
@group(0) @binding(6) var<storage, read> b_materials: array<u32>;
@group(0) @binding(7) var<storage, read> b_attributes: array<f32>;
struct CWParams {
  p_width: u32,
  p_height: u32,
  p_triangle_count: u32,
  p_capacity: u32,
  p_scatter: u32,
  p_raster_offset: u32,
  p_sample_count: u32,
  cw_pad_28: u32,
}
@group(0) @binding(8) var<uniform> cw_params: CWParams;
const cw_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn cw_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }
fn f_tile_outside_edge(cw_arg_ax: f32, cw_arg_ay: f32, cw_arg_bx: f32, cw_arg_by: f32, cw_arg_left: f32, cw_arg_top: f32, cw_arg_right: f32, cw_arg_bottom: f32, cw_arg_sign: f32, cw_arg_margin: f32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var v_ax: f32 = cw_arg_ax;
  var v_ay: f32 = cw_arg_ay;
  var v_bx: f32 = cw_arg_bx;
  var v_by: f32 = cw_arg_by;
  var v_left: f32 = cw_arg_left;
  var v_top: f32 = cw_arg_top;
  var v_right: f32 = cw_arg_right;
  var v_bottom: f32 = cw_arg_bottom;
  var v_sign: f32 = cw_arg_sign;
  var v_margin: f32 = cw_arg_margin;
  var cw_tmp_0: f32;
  if ((((v_ay - v_by) * v_sign) >= 0.0f)) {
    cw_tmp_0 = v_right;
  } else {
    cw_tmp_0 = v_left;
  }
  var v_x: f32 = cw_tmp_0;
  var cw_tmp_1: f32;
  if ((((v_bx - v_ax) * v_sign) >= 0.0f)) {
    cw_tmp_1 = v_bottom;
  } else {
    cw_tmp_1 = v_top;
  }
  var v_y: f32 = cw_tmp_1;
  var v_edge: f32 = ((((v_ax - v_x) * (v_by - v_y)) - ((v_ay - v_y) * (v_bx - v_x))) * v_sign);
  var cw_tmp_2: u32;
  if ((v_edge < (-v_margin))) {
    cw_tmp_2 = 1u;
  } else {
    cw_tmp_2 = 0u;
  }
  return cw_tmp_2;
}
fn f_tile_scissor_begin(cw_arg_origin: u32, cw_arg_limit: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var v_origin: u32 = cw_arg_origin;
  var v_limit: u32 = cw_arg_limit;
  if (((v_origin & 2147483648u) != 0u)) {
    return 0u;
  }
  var cw_tmp_3: u32;
  if ((v_origin < v_limit)) {
    cw_tmp_3 = v_origin;
  } else {
    cw_tmp_3 = v_limit;
  }
  return cw_tmp_3;
}
fn f_tile_scissor_end(cw_arg_origin: u32, cw_arg_extent: u32, cw_arg_limit: u32, cw_thread: vec3<u32>, cw_block: vec3<u32>, cw_grid: vec3<u32>) -> u32 {
  var v_origin: u32 = cw_arg_origin;
  var v_extent: u32 = cw_arg_extent;
  var v_limit: u32 = cw_arg_limit;
  if (((v_origin & 2147483648u) != 0u)) {
    var v_distance: u32 = (0u - v_origin);
    var cw_tmp_4: u32;
    if ((v_extent > v_distance)) {
      cw_tmp_4 = (v_extent - v_distance);
    } else {
      cw_tmp_4 = 0u;
    }
    var v_end: u32 = cw_tmp_4;
    var cw_tmp_5: u32;
    if ((v_end < v_limit)) {
      cw_tmp_5 = v_end;
    } else {
      cw_tmp_5 = v_limit;
    }
    return cw_tmp_5;
  }
  if ((v_origin >= v_limit)) {
    return v_limit;
  }
  var cw_tmp_6: u32;
  if ((v_extent < (v_limit - v_origin))) {
    cw_tmp_6 = v_extent;
  } else {
    cw_tmp_6 = (v_limit - v_origin);
  }
  return (v_origin + cw_tmp_6);
}

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) cw_thread: vec3<u32>,
  @builtin(workgroup_id) cw_block: vec3<u32>,
  @builtin(num_workgroups) cw_grid: vec3<u32>
) {
  var v_t: u32 = (((cw_block.x + (cw_block.y * cw_grid.x)) * cw_block_size.x) + cw_thread.x);
  if (((v_t >= cw_params.p_triangle_count) || ((cw_params.p_scatter != 0u) && (b_summary[1i] != 0u)))) {
    return;
  }
  var v_minx: f32 = f32(cw_params.p_width);
  var v_miny: f32 = f32(cw_params.p_height);
  var v_maxx: f32 = 0.0f;
  var v_maxy: f32 = 0.0f;
  var v_xs: array<f32, 3>;
  var v_ys: array<f32, 3>;
  var v_magnitude: f32 = max(f32(cw_params.p_width), f32(cw_params.p_height));
  {
    var v_corner: u32 = u32(0i);
    loop {
      if (!(v_corner < u32(3i))) { break; }
      var v_i: u32 = (b_indices[((v_t * 4u) + v_corner)] * 10u);
      var v_w: f32 = b_clip[(v_i + 3u)];
      if ((v_w <= 0.0f)) {
        return;
      }
      var v_x: f32 = (((cw_divide_f32(b_clip[v_i], v_w) * 0.5f) + 0.5f) * f32(cw_params.p_width));
      var v_y: f32 = ((0.5f - (cw_divide_f32(b_clip[(v_i + 1u)], v_w) * 0.5f)) * f32(cw_params.p_height));
      v_xs[v_corner] = v_x;
      v_ys[v_corner] = v_y;
      v_magnitude = max(v_magnitude, max(abs(v_x), abs(v_y)));
      v_minx = min(v_minx, v_x);
      v_miny = min(v_miny, v_y);
      v_maxx = max(v_maxx, v_x);
      v_maxy = max(v_maxy, v_y);
      continuing {
        v_corner += u32(1);
      }
    }
  }
  var v_material: u32 = b_indices[((v_t * 4u) + 3u)];
  var v_m: u32 = (v_material * 12u);
  var v_control: u32 = b_materials[(v_m + 9u)];
  var v_raster: u32 = (cw_params.p_raster_offset + (v_material * 50u));
  var v_scissorX: u32 = b_materials[(v_m + 5u)];
  var v_scissorY: u32 = b_materials[(v_m + 6u)];
  var v_scissorWidth: u32 = b_materials[(v_m + 7u)];
  var v_scissorHeight: u32 = b_materials[(v_m + 8u)];
  if (((b_materials[(v_m + 3u)] & 16777216u) != 0u)) {
    var v_x0: u32 = f_tile_scissor_begin(v_scissorX, cw_params.p_width, cw_thread, cw_block, cw_grid);
    var v_x1: u32 = f_tile_scissor_end(v_scissorX, v_scissorWidth, cw_params.p_width, cw_thread, cw_block, cw_grid);
    var v_y0: u32 = f_tile_scissor_begin(v_scissorY, cw_params.p_height, cw_thread, cw_block, cw_grid);
    var v_y1: u32 = f_tile_scissor_end(v_scissorY, v_scissorHeight, cw_params.p_height, cw_thread, cw_block, cw_grid);
    v_scissorX = v_x0;
    v_scissorY = (cw_params.p_height - v_y1);
    v_scissorWidth = (v_x1 - v_x0);
    v_scissorHeight = (v_y1 - v_y0);
  }
  if (((((v_scissorX >= cw_params.p_width) || (v_scissorY >= cw_params.p_height)) || (v_scissorWidth == 0u)) || (v_scissorHeight == 0u))) {
    return;
  }
  if ((((b_materials[(v_m + 3u)] & 128u) != 0u) && (((v_control >> 14u) & 3u) == 3u))) {
    return;
  }
  if (((cw_params.p_sample_count > 1u) && (b_attributes[(v_raster + 27u)] != 0.0f))) {
    var v_sampleBits: u32 = ((1u << cw_params.p_sample_count) - 1u);
    if (((u32(b_attributes[(v_raster + 26u)]) & v_sampleBits) == 0u)) {
      return;
    }
    if ((((b_attributes[(v_raster + 24u)] <= 0.0f) && (b_attributes[(v_raster + 25u)] == 0.0f)) || ((b_attributes[(v_raster + 24u)] >= 1.0f) && (b_attributes[(v_raster + 25u)] != 0.0f)))) {
      return;
    }
  }
  var v_scissorEndX: u32 = cw_params.p_width;
  var v_scissorEndY: u32 = cw_params.p_height;
  if ((v_scissorWidth < (cw_params.p_width - v_scissorX))) {
    v_scissorEndX = (v_scissorX + v_scissorWidth);
  }
  if ((v_scissorHeight < (cw_params.p_height - v_scissorY))) {
    v_scissorEndY = (v_scissorY + v_scissorHeight);
  }
  var v_frontMode: u32 = ((v_control >> 27u) & 3u);
  var v_backMode: u32 = ((v_control >> 29u) & 3u);
  var v_padding: f32 = 0.0f;
  if (((v_frontMode == 1u) || (v_backMode == 1u))) {
    var v_linePadding: f32 = (b_attributes[(v_raster + 37u)] * 0.5f);
    if (((cw_params.p_sample_count == 1u) || (b_attributes[(v_raster + 27u)] == 0.0f))) {
      if (((u32(b_attributes[(v_raster + 49u)]) & 128u) != 0u)) {
        v_linePadding = (v_linePadding + 0.5f);
      } else {
        v_linePadding = (max(1.0f, floor((b_attributes[(v_raster + 37u)] + 0.5f))) * 0.5f);
      }
    }
    v_padding = max(v_padding, v_linePadding);
  }
  if (((v_frontMode == 2u) || (v_backMode == 2u))) {
    var v_pointSize: f32 = 0.0f;
    {
      var v_corner: u32 = 0u;
      loop {
        if (!(v_corner < 3u)) { break; }
        var v_vertex: u32 = (b_indices[((v_t * 4u) + v_corner)] * 34u);
        var v_distance2: f32 = 0.0f;
        {
          var v_axis: u32 = 0u;
          loop {
            if (!(v_axis < 3u)) { break; }
            v_distance2 = (v_distance2 + (b_attributes[(v_vertex + v_axis)] * b_attributes[(v_vertex + v_axis)]));
            continuing {
              v_axis += u32(1);
            }
          }
        }
        var v_attenuation: f32 = ((b_attributes[(v_raster + 46u)] + (b_attributes[(v_raster + 47u)] * sqrt(v_distance2))) + (b_attributes[(v_raster + 48u)] * v_distance2));
        var v_size: f32 = cw_divide_f32(b_attributes[(v_raster + 38u)], sqrt(max(1e-12f, v_attenuation)));
        let cw_argument_index_7 = (v_raster + 44u);
        let cw_argument_index_8 = (v_raster + 43u);
        v_size = min(b_attributes[cw_argument_index_7], max(b_attributes[cw_argument_index_8], v_size));
        v_pointSize = max(v_pointSize, v_size);
        continuing {
          v_corner += u32(1);
        }
      }
    }
    if (((cw_params.p_sample_count > 1u) && (b_attributes[(v_raster + 27u)] != 0.0f))) {
      let cw_argument_index_9 = (v_raster + 45u);
      v_pointSize = max(v_pointSize, b_attributes[cw_argument_index_9]);
    }
    var v_pointPadding: f32 = (v_pointSize * 0.5f);
    if (((cw_params.p_sample_count == 1u) || (b_attributes[(v_raster + 27u)] == 0.0f))) {
      var v_pointFlags: u32 = u32(b_attributes[(v_raster + 49u)]);
      if (((v_pointFlags & 3u) == 0u)) {
        v_pointPadding = ((max(1.0f, floor((v_pointSize + 0.5f))) * 0.5f) + 0.5f);
      } else {
        if (((v_pointFlags & 3u) == 1u)) {
          v_pointPadding = (v_pointPadding + 0.5f);
        }
      }
    }
    v_padding = max(v_padding, v_pointPadding);
  }
  v_minx = (v_minx - v_padding);
  v_miny = (v_miny - v_padding);
  v_maxx = (v_maxx + v_padding);
  v_maxy = (v_maxy + v_padding);
  var v_sampleMin: f32 = 0.5f;
  var v_sampleMax: f32 = 0.5f;
  if (((cw_params.p_sample_count > 1u) && (b_attributes[(v_raster + 27u)] != 0.0f))) {
    var cw_tmp_11: f32;
    if ((cw_params.p_sample_count == 2u)) {
      cw_tmp_11 = 0.25f;
    } else {
      var cw_tmp_10: f32;
      if ((cw_params.p_sample_count == 8u)) {
        cw_tmp_10 = 0.0625f;
      } else {
        cw_tmp_10 = 0.125f;
      }
      cw_tmp_11 = cw_tmp_10;
    }
    v_sampleMin = cw_tmp_11;
    v_sampleMax = (1.0f - v_sampleMin);
  }
  var v_firstx: f32 = ceil((v_minx - v_sampleMax));
  var v_firsty: f32 = ceil((v_miny - v_sampleMax));
  var v_lastx: f32 = floor((v_maxx - v_sampleMin));
  var v_lasty: f32 = floor((v_maxy - v_sampleMin));
  v_firstx = max(f32(v_scissorX), v_firstx);
  v_firsty = max(f32(v_scissorY), v_firsty);
  v_lastx = min(f32((v_scissorEndX - 1u)), v_lastx);
  v_lasty = min(f32((v_scissorEndY - 1u)), v_lasty);
  if (((v_firstx > v_lastx) || (v_firsty > v_lasty))) {
    return;
  }
  var v_columns: u32 = ((cw_params.p_width + 15u) / 16u);
  var v_x0: u32 = (u32(v_firstx) / 16u);
  var v_x1: u32 = (u32(v_lastx) / 16u);
  var v_y0: u32 = (u32(v_firsty) / 16u);
  var v_y1: u32 = (u32(v_lasty) / 16u);
  var v_area: f32 = (((v_xs[1i] - v_xs[0i]) * (v_ys[2i] - v_ys[0i])) - ((v_ys[1i] - v_ys[0i]) * (v_xs[2i] - v_xs[0i])));
  var v_margin: f32 = ((0.000030517578125f * v_magnitude) * v_magnitude);
  var cw_tmp_12: u32;
  if ((((v_frontMode == 0u) && (v_backMode == 0u)) && (abs(v_area) > v_margin))) {
    cw_tmp_12 = 1u;
  } else {
    cw_tmp_12 = 0u;
  }
  var v_testEdges: u32 = cw_tmp_12;
  var cw_tmp_13: f32;
  if ((v_area > 0.0f)) {
    cw_tmp_13 = 1.0f;
  } else {
    cw_tmp_13 = (-1.0f);
  }
  var v_sign: f32 = cw_tmp_13;
  {
    var v_y: u32 = v_y0;
    loop {
      if (!(v_y <= v_y1)) { break; }
      {
        var v_x: u32 = v_x0;
        loop {
          if (!(v_x <= v_x1)) { break; }
          if ((v_testEdges != 0u)) {
            var v_left: f32 = (f32((v_x * 16u)) + v_sampleMin);
            var v_top: f32 = (f32((v_y * 16u)) + v_sampleMin);
            var v_right: f32 = (min(f32(((v_x * 16u) + 15u)), f32((cw_params.p_width - 1u))) + v_sampleMax);
            var v_bottom: f32 = (min(f32(((v_y * 16u) + 15u)), f32((cw_params.p_height - 1u))) + v_sampleMax);
            let cw_argument_index_14 = 0i;
            let cw_argument_index_15 = 0i;
            let cw_argument_index_16 = 1i;
            let cw_argument_index_17 = 1i;
            var cw_tmp_22: bool = (f_tile_outside_edge(v_xs[cw_argument_index_14], v_ys[cw_argument_index_15], v_xs[cw_argument_index_16], v_ys[cw_argument_index_17], v_left, v_top, v_right, v_bottom, v_sign, v_margin, cw_thread, cw_block, cw_grid) != 0u);
            if (!cw_tmp_22) {
              let cw_argument_index_18 = 1i;
              let cw_argument_index_19 = 1i;
              let cw_argument_index_20 = 2i;
              let cw_argument_index_21 = 2i;
              cw_tmp_22 = (f_tile_outside_edge(v_xs[cw_argument_index_18], v_ys[cw_argument_index_19], v_xs[cw_argument_index_20], v_ys[cw_argument_index_21], v_left, v_top, v_right, v_bottom, v_sign, v_margin, cw_thread, cw_block, cw_grid) != 0u);
            }
            var cw_tmp_27: bool = cw_tmp_22;
            if (!cw_tmp_27) {
              let cw_argument_index_23 = 2i;
              let cw_argument_index_24 = 2i;
              let cw_argument_index_25 = 0i;
              let cw_argument_index_26 = 0i;
              cw_tmp_27 = (f_tile_outside_edge(v_xs[cw_argument_index_23], v_ys[cw_argument_index_24], v_xs[cw_argument_index_25], v_ys[cw_argument_index_26], v_left, v_top, v_right, v_bottom, v_sign, v_margin, cw_thread, cw_block, cw_grid) != 0u);
            }
            if (cw_tmp_27) {
              continue;
            }
          }
          var v_tile: u32 = ((v_y * v_columns) + v_x);
          var v_slot: u32 = atomicAdd(&b_counts[v_tile], 1u);
          if ((cw_params.p_capacity != 0u)) {
            if ((v_slot < cw_params.p_capacity)) {
              b_candidates[((v_tile * cw_params.p_capacity) + v_slot)] = v_t;
            }
          } else {
            if ((cw_params.p_scatter != 0u)) {
              b_candidates[(b_offsets[v_tile] + v_slot)] = v_t;
            }
          }
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
}
