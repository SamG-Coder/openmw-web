// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: resolve_camera.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read_write> b_texels: array<u32>;
@group(0) @binding(1) var<storage, read> b_materials: array<u32>;
@group(0) @binding(2) var<storage, read_write> b_status: array<atomic<u32>>;
struct KernelParams {
  p_material_count: u32,
  p_status_index: u32,
  gpu_pad_8: u32,
  gpu_pad_12: u32,
}
@group(0) @binding(3) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn gpu_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_i: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if (((v_i >= gpu_params.p_material_count) || ((b_materials[((v_i * u32(12i)) + u32(3i))] & u32(2048i)) == u32(0i)))) {
    return;
  }
  var v_data: u32 = b_materials[(v_i * u32(12i))];
  if (((b_texels[(v_data + 4u)] & 2147483648u) != 0u)) {
    var v_flags: u32 = b_texels[(v_data + 352u)];
    if (((v_flags & 1u) != 0u)) {
      var v_position: array<f32, 4>;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(4i))) { break; }
          let gpu_argument_index_0 = ((v_data + 24u) + v_k);
          v_position[v_k] = bitcast<f32>(b_texels[gpu_argument_index_0]);
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
              let gpu_argument_index_1 = (((v_data + 354u) + (v_col * 4u)) + v_row);
              v_value = (v_value + (bitcast<f32>(b_texels[gpu_argument_index_1]) * v_position[v_col]));
              continuing {
                v_col += u32(1);
              }
            }
          }
          b_texels[((v_data + 24u) + v_row)] = bitcast<u32>(v_value);
          continuing {
            v_row += u32(1);
          }
        }
      }
    }
    if (((v_flags & 2u) != 0u)) {
      {
        var v_light: u32 = u32(0i);
        loop {
          if (!(v_light < b_texels[(v_data + 6u)])) { break; }
          var v_record: u32 = ((v_data + b_texels[(v_data + 7u)]) + (v_light * 16u));
          var v_fade: u32 = ((v_data + 388u) + (v_light * 5u));
          var v_position: array<f32, 3>;
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              let gpu_argument_index_2 = (v_record + v_k);
              v_position[v_k] = bitcast<f32>(b_texels[gpu_argument_index_2]);
              continuing {
                v_k += u32(1);
              }
            }
          }
          {
            var v_row: u32 = u32(0i);
            loop {
              if (!(v_row < u32(3i))) { break; }
              let gpu_argument_index_3 = ((v_data + 382u) + v_row);
              var v_value: f32 = bitcast<f32>(b_texels[gpu_argument_index_3]);
              {
                var v_col: u32 = u32(0i);
                loop {
                  if (!(v_col < u32(3i))) { break; }
                  let gpu_argument_index_4 = (((v_data + 370u) + (v_col * 4u)) + v_row);
                  v_value = (v_value + (bitcast<f32>(b_texels[gpu_argument_index_4]) * v_position[v_col]));
                  continuing {
                    v_col += u32(1);
                  }
                }
              }
              b_texels[(v_record + v_row)] = bitcast<u32>(v_value);
              continuing {
                v_row += u32(1);
              }
            }
          }
          var v_amount: f32 = 1.0f;
          let gpu_argument_index_5 = (v_fade + 4u);
          var v_end: f32 = bitcast<f32>(b_texels[gpu_argument_index_5]);
          if ((v_end != 0.0f)) {
            var v_distance: f32 = 0.0f;
            {
              var v_k: u32 = u32(0i);
              loop {
                if (!(v_k < u32(3i))) { break; }
                let gpu_argument_index_6 = (v_fade + v_k);
                var v_value: f32 = bitcast<f32>(b_texels[gpu_argument_index_6]);
                v_distance = (v_distance + (v_value * v_value));
                continuing {
                  v_k += u32(1);
                }
              }
            }
            let gpu_argument_index_7 = (v_fade + 3u);
            var v_start: f32 = bitcast<f32>(b_texels[gpu_argument_index_7]);
            v_amount = (1.0f - min(1.0f, max(0.0f, gpu_divide_f32((sqrt(v_distance) - v_start), (v_end - v_start)))));
          }
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              let gpu_argument_index_8 = ((v_record + 8u) + v_k);
              b_texels[((v_record + 8u) + v_k)] = bitcast<u32>((bitcast<f32>(b_texels[gpu_argument_index_8]) * v_amount));
              let gpu_argument_index_9 = ((v_record + 12u) + v_k);
              b_texels[((v_record + 12u) + v_k)] = bitcast<u32>((bitcast<f32>(b_texels[gpu_argument_index_9]) * v_amount));
              continuing {
                v_k += u32(1);
              }
            }
          }
          let gpu_argument_index_10 = (v_record + 15u);
          let gpu_argument_index_11 = (v_data + 353u);
          b_texels[(v_record + 15u)] = bitcast<u32>((bitcast<f32>(b_texels[gpu_argument_index_10]) * bitcast<f32>(b_texels[gpu_argument_index_11])));
          continuing {
            v_light += u32(1);
          }
        }
      }
    }
    b_texels[(v_data + 4u)] = (b_texels[(v_data + 4u)] & (~2147483648u));
  }
  {
    var v_kind: u32 = u32(0i);
    loop {
      if (!(v_kind < u32(2i))) { break; }
      if (((v_kind == u32(0i)) && ((b_texels[(v_data + u32(4i))] & u32(32768i)) == u32(0i)))) {
        continue;
      }
      if (((v_kind == u32(1i)) && ((b_texels[(v_data + u32(4i))] & u32(2097152i)) == u32(0i)))) {
        continue;
      }
      var gpu_tmp_12: u32;
      if ((v_kind == u32(0i))) {
        gpu_tmp_12 = (v_data + u32(52i));
      } else {
        gpu_tmp_12 = ((v_data + b_texels[(v_data + u32(321i))]) + u32(40i));
      }
      var v_matrix: u32 = gpu_tmp_12;
      var v_augmented: array<f32, 32>;
      {
        var v_row: u32 = u32(0i);
        loop {
          if (!(v_row < u32(4i))) { break; }
          {
            var v_col: u32 = u32(0i);
            loop {
              if (!(v_col < u32(4i))) { break; }
              let gpu_argument_index_13 = ((v_matrix + (v_col * u32(4i))) + v_row);
              v_augmented[((v_row * u32(8i)) + v_col)] = bitcast<f32>(b_texels[gpu_argument_index_13]);
              var gpu_tmp_14: f32;
              if ((v_row == v_col)) {
                gpu_tmp_14 = 1.0f;
              } else {
                gpu_tmp_14 = 0.0f;
              }
              v_augmented[(((v_row * u32(8i)) + u32(4i)) + v_col)] = gpu_tmp_14;
              continuing {
                v_col += u32(1);
              }
            }
          }
          continuing {
            v_row += u32(1);
          }
        }
      }
      {
        var v_col: u32 = u32(0i);
        loop {
          if (!(v_col < u32(4i))) { break; }
          var v_pivot: u32 = v_col;
          let gpu_argument_index_15 = ((v_col * u32(8i)) + v_col);
          var v_largest: f32 = abs(v_augmented[gpu_argument_index_15]);
          {
            var v_row: u32 = (v_col + u32(1i));
            loop {
              if (!(v_row < u32(4i))) { break; }
              let gpu_argument_index_16 = ((v_row * u32(8i)) + v_col);
              if ((abs(v_augmented[gpu_argument_index_16]) > v_largest)) {
                v_pivot = v_row;
                let gpu_argument_index_17 = ((v_row * u32(8i)) + v_col);
                v_largest = abs(v_augmented[gpu_argument_index_17]);
              }
              continuing {
                v_row += u32(1);
              }
            }
          }
          if ((v_largest < 1e-12f)) {
            _ = atomicExchange(&b_status[gpu_params.p_status_index], u32(1i));
            return;
          }
          if ((v_pivot != v_col)) {
            {
              var v_k: u32 = u32(0i);
              loop {
                if (!(v_k < u32(8i))) { break; }
                var v_temp: f32 = v_augmented[((v_col * u32(8i)) + v_k)];
                v_augmented[((v_col * u32(8i)) + v_k)] = v_augmented[((v_pivot * u32(8i)) + v_k)];
                v_augmented[((v_pivot * u32(8i)) + v_k)] = v_temp;
                continuing {
                  v_k += u32(1);
                }
              }
            }
          }
          var v_divisor: f32 = v_augmented[((v_col * u32(8i)) + v_col)];
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(8i))) { break; }
              v_augmented[((v_col * u32(8i)) + v_k)] = gpu_divide_f32(v_augmented[((v_col * u32(8i)) + v_k)], v_divisor);
              continuing {
                v_k += u32(1);
              }
            }
          }
          {
            var v_row: u32 = u32(0i);
            loop {
              if (!(v_row < u32(4i))) { break; }
              if ((v_row != v_col)) {
                var v_factor: f32 = v_augmented[((v_row * u32(8i)) + v_col)];
                {
                  var v_k: u32 = u32(0i);
                  loop {
                    if (!(v_k < u32(8i))) { break; }
                    v_augmented[((v_row * u32(8i)) + v_k)] = (v_augmented[((v_row * u32(8i)) + v_k)] - (v_factor * v_augmented[((v_col * u32(8i)) + v_k)]));
                    continuing {
                      v_k += u32(1);
                    }
                  }
                }
              }
              continuing {
                v_row += u32(1);
              }
            }
          }
          continuing {
            v_col += u32(1);
          }
        }
      }
      {
        var v_row: u32 = u32(0i);
        loop {
          if (!(v_row < u32(4i))) { break; }
          {
            var v_col: u32 = u32(0i);
            loop {
              if (!(v_col < u32(4i))) { break; }
              let gpu_argument_index_18 = (((v_row * u32(8i)) + u32(4i)) + v_col);
              b_texels[((v_matrix + (v_col * u32(4i))) + v_row)] = bitcast<u32>(v_augmented[gpu_argument_index_18]);
              continuing {
                v_col += u32(1);
              }
            }
          }
          continuing {
            v_row += u32(1);
          }
        }
      }
      if ((v_kind == u32(0i))) {
        b_texels[(v_data + u32(4i))] = (b_texels[(v_data + u32(4i))] & (~32768u));
      }
      continuing {
        v_kind += u32(1);
      }
    }
  }
}
