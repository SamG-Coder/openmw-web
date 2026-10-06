// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: shade_fixed_vertices.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read> b_attributes: array<f32>;
@group(0) @binding(2) var<storage, read> b_matrices: array<f32>;
@group(0) @binding(3) var<storage, read> b_matrix_ids: array<u32>;
@group(0) @binding(4) var<storage, read> b_descriptors: array<u32>;
@group(0) @binding(5) var<storage, read> b_secondary_colors: array<f32>;
@group(0) @binding(6) var<storage, read_write> b_output: array<f32>;
@group(0) @binding(7) var<storage, read_write> b_endpoints: array<f32>;
struct KernelParams {
  p_vertex_count: u32,
  p_capture_endpoints: u32,
  gpu_pad_8: u32,
  gpu_pad_12: u32,
}
@group(0) @binding(8) var<uniform> gpu_params: KernelParams;
const gpu_block_size: vec3<u32> = vec3<u32>(64u, 1u, 1u);

fn gpu_divide_f32(a: f32, b: f32) -> f32 { let q = a / b; if ((bitcast<u32>(q) & 0x7f800000u) == 0x7f800000u || (bitcast<u32>(q) & 0x7fffffffu) == 0u || (bitcast<u32>(b) & 0x7f800000u) == 0x7f800000u) { return q; } let residual = fma(-q, b, a); return q + residual / b; }

alias gpu_f64 = vec2<u32>;
fn gpu_d_shl(a: vec2<u32>, n: u32) -> vec2<u32> {
  if(n == 0u) { return a; }
  if(n >= 64u) { return vec2<u32>(0u); }
  if(n >= 32u) { return vec2<u32>(0u, a.x << (n - 32u)); }
  return vec2<u32>(a.x << n, (a.y << n) | (a.x >> (32u - n)));
}
fn gpu_d_shr(a: vec2<u32>, n: u32) -> vec2<u32> {
  if(n == 0u) { return a; }
  if(n >= 64u) { return vec2<u32>(0u); }
  if(n >= 32u) { return vec2<u32>(a.y >> (n - 32u), 0u); }
  return vec2<u32>((a.x >> n) | (a.y << (32u - n)), a.y >> n);
}
fn gpu_d_jam(a: vec2<u32>, n: u32) -> vec2<u32> {
  let shifted = gpu_d_shr(a, n);
  return shifted | vec2<u32>(select(0u, 1u, any(gpu_d_shl(shifted, n) != a)), 0u);
}
fn gpu_d_uadd(a: vec2<u32>, b: vec2<u32>) -> vec2<u32> {
  let low = a.x + b.x;
  return vec2<u32>(low, a.y + b.y + select(0u, 1u, low < a.x));
}
fn gpu_d_usub(a: vec2<u32>, b: vec2<u32>) -> vec2<u32> {
  return vec2<u32>(a.x - b.x, a.y - b.y - select(0u, 1u, a.x < b.x));
}
fn gpu_d_uless(a: vec2<u32>, b: vec2<u32>) -> bool {
  return a.y < b.y || (a.y == b.y && a.x < b.x);
}
fn gpu_d_nan(a: gpu_f64) -> bool { return (a.y & 2147483647u) > 2146435072u || ((a.y & 2147483647u) == 2146435072u && a.x != 0u); }
fn gpu_d_inf(a: gpu_f64) -> bool { return (a.y & 2147483647u) == 2146435072u && a.x == 0u; }
fn gpu_d_zero(a: gpu_f64) -> bool { return (a.y & 2147483647u) == 0u && a.x == 0u; }

struct CWDoubleParts { significand: vec2<u32>, exponent: i32, }
fn gpu_d_parts(a: gpu_f64) -> CWDoubleParts {
  let raw = (a.y >> 20u) & 2047u;
  var s = vec2<u32>(a.x, a.y & 1048575u);
  var e = i32(raw) - 1023i;
  if(raw != 0u) { s.y |= 1048576u; }
  else {
    e = -1022i;
    if(any(s != vec2<u32>(0u))) {
      loop { if((s.y & 1048576u) != 0u) { break; } s = gpu_d_shl(s, 1u); e--; }
    }
  }
  return CWDoubleParts(s,e);
}
// Input has its leading bit at bit 55 and three guard/round/sticky bits.
fn gpu_d_pack(sign: u32, exponent: i32, value: vec2<u32>) -> gpu_f64 {
  var e = exponent; var v = value;
  if(e < -1022i) { v = gpu_d_jam(v, u32(-1022i-e)); e = -1022i; }
  let tail = v.x & 7u;
  var s = gpu_d_shr(v, 3u);
  if(tail > 4u || (tail == 4u && (s.x & 1u) != 0u)) { s = gpu_d_uadd(s,vec2<u32>(1u,0u)); }
  if((s.y & 2097152u) != 0u) { s = gpu_d_shr(s,1u); e++; }
  if(e > 1023i) { return vec2<u32>(0u,sign | 2146435072u); }
  let field = select(0u, u32(e+1023i), (s.y & 1048576u) != 0u);
  return vec2<u32>(s.x, sign | (field << 20u) | (s.y & 1048575u));
}
fn gpu_d_from_f32(a: f32) -> gpu_f64 {
  let bits = bitcast<u32>(a); let sign = bits & 2147483648u;
  let field = (bits >> 23u) & 255u; var mantissa = bits & 8388607u;
  if(field == 255u) { return vec2<u32>(0u,sign | 2146435072u | select(0u,524288u,mantissa != 0u)); }
  if(field == 0u && mantissa == 0u) { return vec2<u32>(0u,sign); }
  var e = i32(field)-127i;
  if(field == 0u) { e = -126i; loop { if((mantissa & 8388608u) != 0u) { break; } mantissa <<= 1u; e--; } }
  let s = gpu_d_shl(vec2<u32>(mantissa & 8388607u,0u),29u);
  return vec2<u32>(s.x,sign | (u32(e+1023i) << 20u) | s.y);
}
fn gpu_d_from_u32(a: u32) -> gpu_f64 {
  if(a == 0u) { return vec2<u32>(0u); }
  let e = 31u-countLeadingZeros(a); let s = gpu_d_shl(vec2<u32>(a,0u),52u-e);
  return vec2<u32>(s.x,((e+1023u) << 20u) | (s.y & 1048575u));
}

fn gpu_d_to_f32(a: gpu_f64) -> f32 {
  let sign = a.y & 2147483648u;
  if(gpu_d_nan(a)) { return bitcast<f32>(sign | 2143289344u); }
  if(gpu_d_inf(a)) { return bitcast<f32>(sign | 2139095040u); }
  if(gpu_d_zero(a)) { return bitcast<f32>(sign); }
  let p = gpu_d_parts(a); var e = p.exponent;
  let shift = 29u + u32(max(-126i-e,0i));
  // Keep three rounding bits while reducing the 53-bit significand to 24 bits.
  let v = gpu_d_jam(p.significand,shift-3u); let tail = v.x & 7u;
  var s = gpu_d_shr(v,3u).x;
  if(tail > 4u || (tail == 4u && (s & 1u) != 0u)) { s++; }
  e = max(e,-126i);
  if(s >= 16777216u) { s >>= 1u; e++; }
  if(e > 127i) { return bitcast<f32>(sign | 2139095040u); }
  let field = select(0u,u32(e+127i),s >= 8388608u);
  return bitcast<f32>(sign | (field << 23u) | (s & 8388607u));
}






fn gpu_d_mul(a: gpu_f64,b: gpu_f64) -> gpu_f64 {
  let sign = (a.y ^ b.y) & 2147483648u;
  if(gpu_d_nan(a) || gpu_d_nan(b) || (gpu_d_inf(a) && gpu_d_zero(b)) || (gpu_d_inf(b) && gpu_d_zero(a))) { return vec2<u32>(0u,2146959360u); }
  if(gpu_d_inf(a) || gpu_d_inf(b)) { return vec2<u32>(0u,sign | 2146435072u); }
  if(gpu_d_zero(a) || gpu_d_zero(b)) { return vec2<u32>(0u,sign); }
  let pa = gpu_d_parts(a); let pb = gpu_d_parts(b);
  if(all(pa.significand == vec2<u32>(0u,1048576u))) { return gpu_d_pack(sign,pa.exponent+pb.exponent,gpu_d_shl(pb.significand,3u)); }
  if(all(pb.significand == vec2<u32>(0u,1048576u))) { return gpu_d_pack(sign,pa.exponent+pb.exponent,gpu_d_shl(pa.significand,3u)); }
  var product = vec4<u32>(0u); var term = vec4<u32>(pa.significand,0u,0u); var multiplier = pb.significand;
  for(var i = 0u; i < 53u; i++) {
    if((multiplier.x & 1u) != 0u) {
      var carry = 0u;
      for(var j = 0u; j < 4u; j++) {
        let p = product[j]; let s = p + term[j]; let t = s + carry;
        carry = select(0u,1u,s < p || t < s); product[j] = t;
      }
    }
    term = vec4<u32>(term.x << 1u,(term.y << 1u) | (term.x >> 31u),(term.z << 1u) | (term.y >> 31u),(term.w << 1u) | (term.z >> 31u));
    multiplier = gpu_d_shr(multiplier,1u);
  }
  let extra = select(0u,1u,(product.w & 512u) != 0u);
  for(var i = 0u; i < 49u+extra; i++) {
    product = vec4<u32>((product.x >> 1u) | (product.y << 31u) | (product.x & 1u),(product.y >> 1u) | (product.z << 31u),(product.z >> 1u) | (product.w << 31u),product.w >> 1u);
  }
  return gpu_d_pack(sign,pa.exponent+pb.exponent+i32(extra),product.xy);
}
fn gpu_d_div(a: gpu_f64,b: gpu_f64) -> gpu_f64 {
  let sign = (a.y ^ b.y) & 2147483648u;
  if(gpu_d_nan(a) || gpu_d_nan(b) || (gpu_d_inf(a) && gpu_d_inf(b)) || (gpu_d_zero(a) && gpu_d_zero(b))) { return vec2<u32>(0u,2146959360u); }
  if(gpu_d_inf(a) || gpu_d_zero(b)) { return vec2<u32>(0u,sign | 2146435072u); }
  if(gpu_d_zero(a) || gpu_d_inf(b)) { return vec2<u32>(0u,sign); }
  let pa = gpu_d_parts(a); let pb = gpu_d_parts(b); var e = pa.exponent-pb.exponent;
  var remainder = pa.significand; var q = vec2<u32>(0u);
  if(gpu_d_uless(remainder,pb.significand)) { remainder = gpu_d_shl(remainder,1u); e--; }
  for(var i = 0u; i < 56u; i++) {
    q = gpu_d_shl(q,1u);
    if(!gpu_d_uless(remainder,pb.significand)) { remainder = gpu_d_usub(remainder,pb.significand); q.x |= 1u; }
    if(i < 55u) { remainder = gpu_d_shl(remainder,1u); }
  }
  if(any(remainder != vec2<u32>(0u))) { q.x |= 1u; }
  return gpu_d_pack(sign,e,q);
}

// Restoring square root: 56 root bits include guard/round/sticky for binary64.




fn f_fixed_unit(gpu_arg_value: f32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var v_value: f32 = gpu_arg_value;
  return min(1.0f, max(0.0f, v_value));
}
fn f_gpu_buffer_helper_0(v_v: ptr<function, array<f32, 3>>, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) {
  var v_length: f32 = sqrt(max(((((*v_v)[0i] * (*v_v)[0i]) + ((*v_v)[1i] * (*v_v)[1i])) + ((*v_v)[2i] * (*v_v)[2i])), 1e-12f));
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(3i))) { break; }
      (*v_v)[v_k] = gpu_divide_f32((*v_v)[v_k], v_length);
      continuing {
        v_k += u32(1);
      }
    }
  }
}

fn gpu_pow_f32(base: f32, exponent: f32) -> f32 {
  if(exponent >= -64.0f && exponent <= 64.0f && exponent == trunc(exponent)) {
    var count=u32(abs(exponent));
    var value=gpu_d_from_f32(base);var product=gpu_d_from_u32(1u);
    loop {
      if(count == 0u) { break; }
      if((count & 1u) != 0u) { product=gpu_d_mul(product,value); }
      count >>= 1u;
      if(count != 0u) { value=gpu_d_mul(value,value); }
    }
    if(exponent < 0.0f) { product=gpu_d_div(gpu_d_from_u32(1u),product); }
    return gpu_d_to_f32(product);
  }
  return pow(base,exponent);
}

@compute @workgroup_size(64, 1, 1)
fn main(
  @builtin(local_invocation_id) gpu_thread: vec3<u32>,
  @builtin(workgroup_id) gpu_block: vec3<u32>,
  @builtin(num_workgroups) gpu_grid: vec3<u32>
) {
  var v_vertex: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_vertex >= gpu_params.p_vertex_count)) {
    return;
  }
  var v_draw: u32 = b_matrix_ids[v_vertex];
  var v_m: u32 = (v_draw * u32(32i));
  var v_d: u32 = (v_draw * u32(368i));
  var v_flags: u32 = b_descriptors[(v_d + u32(1i))];
  var v_mode: u32 = b_descriptors[(v_d + u32(2i))];
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(16i))) { break; }
      b_output[((v_vertex * u32(16i)) + v_k)] = 0.0f;
      continuing {
        v_k += u32(1);
      }
    }
  }
  if ((gpu_params.p_capture_endpoints != u32(0i))) {
    {
      var v_k: u32 = u32(0i);
      loop {
        if (!(v_k < u32(32i))) { break; }
        b_endpoints[((v_vertex * u32(32i)) + v_k)] = 0.0f;
        continuing {
          v_k += u32(1);
        }
      }
    }
  }
  if (((v_flags & u32(160i)) == u32(0i))) {
    return;
  }
  if (((v_flags & u32(128i)) == u32(0i))) {
    var v_primitive: f32 = b_attributes[(v_vertex * u32(34i))];
    var v_line: u32 = select(u32(0), u32(1), ((v_primitive == 6.0f) || (v_primitive == 7.0f)));
    {
      var v_endpoint: u32 = u32(0i);
      loop {
        var gpu_tmp_0: u32;
        if ((v_line != u32(0i))) {
          gpu_tmp_0 = 2u;
        } else {
          gpu_tmp_0 = 1u;
        }
        if (!(v_endpoint < gpu_tmp_0)) { break; }
        {
          var v_face: u32 = u32(0i);
          loop {
            if (!(v_face < u32(2i))) { break; }
            var v_destination: u32 = ((v_vertex * u32(16i)) + (v_face * u32(8i)));
            {
              var v_channel: u32 = u32(0i);
              loop {
                if (!(v_channel < u32(4i))) { break; }
                var gpu_tmp_1: f32;
                if (((v_primitive == 7.0f) && (v_endpoint != u32(0i)))) {
                  gpu_tmp_1 = b_attributes[(((v_vertex * u32(34i)) + u32(18i)) + v_channel)];
                } else {
                  gpu_tmp_1 = b_vertices[(((v_vertex * u32(10i)) + u32(4i)) + v_channel)];
                }
                var v_color: f32 = gpu_tmp_1;
                b_output[(v_destination + v_channel)] = f_fixed_unit(v_color, gpu_thread, gpu_block, gpu_grid);
                continuing {
                  v_channel += u32(1);
                }
              }
            }
            {
              var v_channel: u32 = u32(0i);
              loop {
                if (!(v_channel < u32(3i))) { break; }
                let gpu_argument_index_2 = ((v_vertex * u32(3i)) + v_channel);
                b_output[((v_destination + u32(4i)) + v_channel)] = f_fixed_unit(b_secondary_colors[gpu_argument_index_2], gpu_thread, gpu_block, gpu_grid);
                continuing {
                  v_channel += u32(1);
                }
              }
            }
            b_output[(v_destination + u32(7i))] = 1.0f;
            continuing {
              v_face += u32(1);
            }
          }
        }
        if (((v_line != u32(0i)) && (gpu_params.p_capture_endpoints != u32(0i)))) {
          {
            var v_channel: u32 = u32(0i);
            loop {
              if (!(v_channel < u32(16i))) { break; }
              b_endpoints[(((v_vertex * u32(32i)) + (v_endpoint * u32(16i))) + v_channel)] = b_output[((v_vertex * u32(16i)) + v_channel)];
              continuing {
                v_channel += u32(1);
              }
            }
          }
        }
        continuing {
          v_endpoint += u32(1);
        }
      }
    }
    return;
  }
  var v_primitive: f32 = b_attributes[(v_vertex * u32(34i))];
  var v_line: u32 = select(u32(0), u32(1), ((v_primitive == 6.0f) || (v_primitive == 7.0f)));
  var v_screenPrimitive: u32 = select(u32(0), u32(1), ((((v_primitive == 5.0f) || (v_primitive == 6.0f)) || (v_primitive == 7.0f)) || (v_primitive == 8.0f)));
  {
    var v_endpoint: u32 = u32(0i);
    loop {
      var gpu_tmp_3: u32;
      if ((v_line != u32(0i))) {
        gpu_tmp_3 = 2u;
      } else {
        gpu_tmp_3 = 1u;
      }
      if (!(v_endpoint < gpu_tmp_3)) { break; }
      var v_position: array<f32, 4>;
      {
        var v_row: u32 = u32(0i);
        loop {
          if (!(v_row < u32(4i))) { break; }
          v_position[v_row] = 0.0f;
          {
            var v_col: u32 = u32(0i);
            loop {
              if (!(v_col < u32(4i))) { break; }
              var gpu_tmp_4: f32;
              if ((((v_line != u32(0i)) && (v_endpoint != u32(0i))) && (v_col < u32(3i)))) {
                gpu_tmp_4 = b_attributes[(((v_vertex * u32(34i)) + u32(10i)) + v_col)];
              } else {
                gpu_tmp_4 = 0.0f;
              }
              v_position[v_row] = (v_position[v_row] + (b_matrices[((v_m + (v_col * u32(4i))) + v_row)] * (b_vertices[((v_vertex * u32(10i)) + v_col)] + gpu_tmp_4)));
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
      let gpu_argument_index_5 = 3i;
      if ((abs(v_position[gpu_argument_index_5]) > 1e-12f)) {
        {
          var v_k: u32 = u32(0i);
          loop {
            if (!(v_k < u32(3i))) { break; }
            v_position[v_k] = gpu_divide_f32(v_position[v_k], v_position[3i]);
            continuing {
              v_k += u32(1);
            }
          }
        }
      }
      var v_a: f32 = b_matrices[v_m];
      var v_b: f32 = b_matrices[(v_m + u32(4i))];
      var v_c: f32 = b_matrices[(v_m + u32(8i))];
      var v_e: f32 = b_matrices[(v_m + u32(1i))];
      var v_f: f32 = b_matrices[(v_m + u32(5i))];
      var v_g: f32 = b_matrices[(v_m + u32(9i))];
      var v_h: f32 = b_matrices[(v_m + u32(2i))];
      var v_j: f32 = b_matrices[(v_m + u32(6i))];
      var v_k: f32 = b_matrices[(v_m + u32(10i))];
      var v_determinant: f32 = (((v_a * ((v_f * v_k) - (v_g * v_j))) - (v_b * ((v_e * v_k) - (v_g * v_h)))) + (v_c * ((v_e * v_j) - (v_f * v_h))));
      var gpu_tmp_6: f32;
      if ((abs(v_determinant) > 1e-12f)) {
        gpu_tmp_6 = gpu_divide_f32(1.0f, v_determinant);
      } else {
        gpu_tmp_6 = 0.0f;
      }
      var v_inverse: f32 = gpu_tmp_6;
      var v_nmatrix: array<f32, 9>;
      v_nmatrix[0i] = (((v_f * v_k) - (v_g * v_j)) * v_inverse);
      v_nmatrix[1i] = (((v_g * v_h) - (v_e * v_k)) * v_inverse);
      v_nmatrix[2i] = (((v_e * v_j) - (v_f * v_h)) * v_inverse);
      v_nmatrix[3i] = (((v_c * v_j) - (v_b * v_k)) * v_inverse);
      v_nmatrix[4i] = (((v_a * v_k) - (v_c * v_h)) * v_inverse);
      v_nmatrix[5i] = (((v_b * v_h) - (v_a * v_j)) * v_inverse);
      v_nmatrix[6i] = (((v_b * v_g) - (v_c * v_f)) * v_inverse);
      v_nmatrix[7i] = (((v_c * v_e) - (v_a * v_g)) * v_inverse);
      v_nmatrix[8i] = (((v_a * v_f) - (v_b * v_e)) * v_inverse);
      var v_normal: array<f32, 3>;
      var v_viewer: array<f32, 3>;
      {
        var v_row: u32 = u32(0i);
        loop {
          if (!(v_row < u32(3i))) { break; }
          v_normal[v_row] = 0.0f;
          {
            var v_col: u32 = u32(0i);
            loop {
              if (!(v_col < u32(3i))) { break; }
              v_normal[v_row] = (v_normal[v_row] + (v_nmatrix[((v_row * u32(3i)) + v_col)] * b_attributes[(((v_vertex * u32(34i)) + u32(3i)) + v_col)]));
              continuing {
                v_col += u32(1);
              }
            }
          }
          var gpu_tmp_8: f32;
          if (((v_flags & u32(2i)) != u32(0i))) {
            gpu_tmp_8 = (-v_position[v_row]);
          } else {
            var gpu_tmp_7: f32;
            if ((v_row == u32(2i))) {
              gpu_tmp_7 = 1.0f;
            } else {
              gpu_tmp_7 = 0.0f;
            }
            gpu_tmp_8 = gpu_tmp_7;
          }
          v_viewer[v_row] = gpu_tmp_8;
          continuing {
            v_row += u32(1);
          }
        }
      }
      f_gpu_buffer_helper_0(&v_viewer, gpu_thread, gpu_block, gpu_grid);
      if (((v_flags & u32(8i)) != u32(0i))) {
        f_gpu_buffer_helper_0(&v_normal, gpu_thread, gpu_block, gpu_grid);
      } else {
        if (((v_flags & u32(16i)) != u32(0i))) {
          var v_scale: f32 = sqrt(max((((v_nmatrix[2i] * v_nmatrix[2i]) + (v_nmatrix[5i] * v_nmatrix[5i])) + (v_nmatrix[8i] * v_nmatrix[8i])), 1e-12f));
          {
            var v_axis: u32 = u32(0i);
            loop {
              if (!(v_axis < u32(3i))) { break; }
              v_normal[v_axis] = gpu_divide_f32(v_normal[v_axis], v_scale);
              continuing {
                v_axis += u32(1);
              }
            }
          }
        }
      }
      {
        var v_face: u32 = u32(0i);
        loop {
          if (!(v_face < u32(2i))) { break; }
          var gpu_tmp_9: u32;
          if ((((v_flags & u32(1i)) != u32(0i)) && (v_screenPrimitive == u32(0i)))) {
            gpu_tmp_9 = v_face;
          } else {
            gpu_tmp_9 = u32(0i);
          }
          var v_side: u32 = gpu_tmp_9;
          var v_material: u32 = ((v_d + u32(8i)) + (v_side * u32(17i)));
          var v_destination: u32 = ((v_vertex * u32(16i)) + (v_face * u32(8i)));
          var v_ambient: array<f32, 3>;
          var v_diffuse: array<f32, 4>;
          var v_specular: array<f32, 3>;
          var v_primary: array<f32, 3>;
          var v_secondary: array<f32, 3>;
          {
            var v_axis: u32 = u32(0i);
            loop {
              if (!(v_axis < u32(4i))) { break; }
              var gpu_tmp_10: f32;
              if (((v_primitive == 7.0f) && (v_endpoint != u32(0i)))) {
                gpu_tmp_10 = b_attributes[(((v_vertex * u32(34i)) + u32(18i)) + v_axis)];
              } else {
                gpu_tmp_10 = b_vertices[(((v_vertex * u32(10i)) + u32(4i)) + v_axis)];
              }
              var v_color: f32 = gpu_tmp_10;
              var gpu_tmp_12: f32;
              if (((v_mode == u32(2i)) || (v_mode == u32(4i)))) {
                gpu_tmp_12 = v_color;
              } else {
                let gpu_argument_index_11 = ((v_material + u32(4i)) + v_axis);
                gpu_tmp_12 = bitcast<f32>(b_descriptors[gpu_argument_index_11]);
              }
              v_diffuse[v_axis] = gpu_tmp_12;
              if ((v_axis < u32(3i))) {
                var gpu_tmp_14: f32;
                if (((v_mode == u32(2i)) || (v_mode == u32(3i)))) {
                  gpu_tmp_14 = v_color;
                } else {
                  let gpu_argument_index_13 = (v_material + v_axis);
                  gpu_tmp_14 = bitcast<f32>(b_descriptors[gpu_argument_index_13]);
                }
                v_ambient[v_axis] = gpu_tmp_14;
                var gpu_tmp_16: f32;
                if ((v_mode == u32(5i))) {
                  gpu_tmp_16 = v_color;
                } else {
                  let gpu_argument_index_15 = ((v_material + u32(8i)) + v_axis);
                  gpu_tmp_16 = bitcast<f32>(b_descriptors[gpu_argument_index_15]);
                }
                v_specular[v_axis] = gpu_tmp_16;
                var gpu_tmp_18: f32;
                if ((v_mode == u32(1i))) {
                  gpu_tmp_18 = v_color;
                } else {
                  let gpu_argument_index_17 = ((v_material + u32(12i)) + v_axis);
                  gpu_tmp_18 = bitcast<f32>(b_descriptors[gpu_argument_index_17]);
                }
                var v_emission: f32 = gpu_tmp_18;
                let gpu_argument_index_19 = ((v_d + u32(4i)) + v_axis);
                v_primary[v_axis] = (v_emission + (v_ambient[v_axis] * bitcast<f32>(b_descriptors[gpu_argument_index_19])));
                v_secondary[v_axis] = 0.0f;
              }
              continuing {
                v_axis += u32(1);
              }
            }
          }
          {
            var v_light: u32 = u32(0i);
            loop {
              if (!(v_light < u32(8i))) { break; }
              if (((b_descriptors[v_d] & (1u << v_light)) != u32(0i))) {
                var v_l: u32 = ((v_d + u32(48i)) + (v_light * u32(40i)));
                var v_lightPosition: array<f32, 4>;
                var v_spot: array<f32, 3>;
                {
                  var v_row: u32 = u32(0i);
                  loop {
                    if (!(v_row < u32(4i))) { break; }
                    v_lightPosition[v_row] = 0.0f;
                    {
                      var v_col: u32 = u32(0i);
                      loop {
                        if (!(v_col < u32(4i))) { break; }
                        let gpu_argument_index_20 = (((v_l + u32(24i)) + (v_col * u32(4i))) + v_row);
                        let gpu_argument_index_21 = (v_l + v_col);
                        v_lightPosition[v_row] = (v_lightPosition[v_row] + (bitcast<f32>(b_descriptors[gpu_argument_index_20]) * bitcast<f32>(b_descriptors[gpu_argument_index_21])));
                        continuing {
                          v_col += u32(1);
                        }
                      }
                    }
                    if ((v_row < u32(3i))) {
                      v_spot[v_row] = 0.0f;
                      {
                        var v_col: u32 = u32(0i);
                        loop {
                          if (!(v_col < u32(3i))) { break; }
                          let gpu_argument_index_22 = (((v_l + u32(24i)) + (v_col * u32(4i))) + v_row);
                          let gpu_argument_index_23 = ((v_l + u32(16i)) + v_col);
                          v_spot[v_row] = (v_spot[v_row] + (bitcast<f32>(b_descriptors[gpu_argument_index_22]) * bitcast<f32>(b_descriptors[gpu_argument_index_23])));
                          continuing {
                            v_col += u32(1);
                          }
                        }
                      }
                    }
                    continuing {
                      v_row += u32(1);
                    }
                  }
                }
                var v_direction: array<f32, 3>;
                var v_distance: f32 = 0.0f;
                {
                  var v_axis: u32 = u32(0i);
                  loop {
                    if (!(v_axis < u32(3i))) { break; }
                    var gpu_tmp_24: f32;
                    if ((v_lightPosition[3i] == 0.0f)) {
                      gpu_tmp_24 = v_lightPosition[v_axis];
                    } else {
                      gpu_tmp_24 = (gpu_divide_f32(v_lightPosition[v_axis], v_lightPosition[3i]) - v_position[v_axis]);
                    }
                    v_direction[v_axis] = gpu_tmp_24;
                    v_distance = (v_distance + (v_direction[v_axis] * v_direction[v_axis]));
                    continuing {
                      v_axis += u32(1);
                    }
                  }
                }
                v_distance = sqrt(max(v_distance, 1e-12f));
                {
                  var v_axis: u32 = u32(0i);
                  loop {
                    if (!(v_axis < u32(3i))) { break; }
                    v_direction[v_axis] = gpu_divide_f32(v_direction[v_axis], v_distance);
                    continuing {
                      v_axis += u32(1);
                    }
                  }
                }
                var v_attenuation: f32 = 1.0f;
                if ((v_lightPosition[3i] != 0.0f)) {
                  let gpu_argument_index_25 = (v_l + u32(19i));
                  let gpu_argument_index_26 = (v_l + u32(20i));
                  let gpu_argument_index_27 = (v_l + u32(21i));
                  v_attenuation = gpu_divide_f32(1.0f, max(1e-12f, ((bitcast<f32>(b_descriptors[gpu_argument_index_25]) + (bitcast<f32>(b_descriptors[gpu_argument_index_26]) * v_distance)) + ((bitcast<f32>(b_descriptors[gpu_argument_index_27]) * v_distance) * v_distance))));
                }
                let gpu_argument_index_28 = (v_l + u32(23i));
                var v_cutoff: f32 = bitcast<f32>(b_descriptors[gpu_argument_index_28]);
                if ((v_cutoff != 180.0f)) {
                  f_gpu_buffer_helper_0(&v_spot, gpu_thread, gpu_block, gpu_grid);
                  var v_cosine: f32 = 0.0f;
                  {
                    var v_axis: u32 = u32(0i);
                    loop {
                      if (!(v_axis < u32(3i))) { break; }
                      v_cosine = (v_cosine - (v_direction[v_axis] * v_spot[v_axis]));
                      continuing {
                        v_axis += u32(1);
                      }
                    }
                  }
                  if ((v_cosine < cos((v_cutoff * 0.017453292519943295f)))) {
                    v_attenuation = 0.0f;
                  } else {
                    let gpu_argument_index_29 = (v_l + u32(22i));
                    var v_exponent: f32 = bitcast<f32>(b_descriptors[gpu_argument_index_29]);
                    var gpu_tmp_30: f32;
                    if ((v_exponent == 0.0f)) {
                      gpu_tmp_30 = 1.0f;
                    } else {
                      gpu_tmp_30 = gpu_pow_f32(max(v_cosine, 0.0f), v_exponent);
                    }
                    v_attenuation = (v_attenuation * gpu_tmp_30);
                  }
                }
                var v_halfVector: array<f32, 3>;
                var v_lambert: f32 = 0.0f;
                var v_spec: f32 = 0.0f;
                {
                  var v_axis: u32 = u32(0i);
                  loop {
                    if (!(v_axis < u32(3i))) { break; }
                    var gpu_tmp_31: f32;
                    if ((v_side == u32(1i))) {
                      gpu_tmp_31 = (-1.0f);
                    } else {
                      gpu_tmp_31 = 1.0f;
                    }
                    v_lambert = (v_lambert + ((v_normal[v_axis] * v_direction[v_axis]) * gpu_tmp_31));
                    v_halfVector[v_axis] = (v_direction[v_axis] + v_viewer[v_axis]);
                    continuing {
                      v_axis += u32(1);
                    }
                  }
                }
                f_gpu_buffer_helper_0(&v_halfVector, gpu_thread, gpu_block, gpu_grid);
                if ((v_lambert > 0.0f)) {
                  {
                    var v_axis: u32 = u32(0i);
                    loop {
                      if (!(v_axis < u32(3i))) { break; }
                      var gpu_tmp_32: f32;
                      if ((v_side == u32(1i))) {
                        gpu_tmp_32 = (-1.0f);
                      } else {
                        gpu_tmp_32 = 1.0f;
                      }
                      v_spec = (v_spec + ((v_normal[v_axis] * v_halfVector[v_axis]) * gpu_tmp_32));
                      continuing {
                        v_axis += u32(1);
                      }
                    }
                  }
                  let gpu_argument_index_33 = (v_material + u32(16i));
                  var v_shininess: f32 = bitcast<f32>(b_descriptors[gpu_argument_index_33]);
                  var gpu_tmp_34: f32;
                  if ((v_shininess == 0.0f)) {
                    gpu_tmp_34 = 1.0f;
                  } else {
                    gpu_tmp_34 = gpu_pow_f32(max(v_spec, 0.0f), v_shininess);
                  }
                  v_spec = gpu_tmp_34;
                }
                {
                  var v_axis: u32 = u32(0i);
                  loop {
                    if (!(v_axis < u32(3i))) { break; }
                    let gpu_argument_index_35 = ((v_l + u32(4i)) + v_axis);
                    let gpu_argument_index_36 = ((v_l + u32(8i)) + v_axis);
                    v_primary[v_axis] = (v_primary[v_axis] + (((v_ambient[v_axis] * bitcast<f32>(b_descriptors[gpu_argument_index_35])) + ((v_diffuse[v_axis] * bitcast<f32>(b_descriptors[gpu_argument_index_36])) * max(v_lambert, 0.0f))) * v_attenuation));
                    let gpu_argument_index_37 = ((v_l + u32(12i)) + v_axis);
                    var v_shine: f32 = (((v_specular[v_axis] * bitcast<f32>(b_descriptors[gpu_argument_index_37])) * v_spec) * v_attenuation);
                    if (((v_flags & u32(4i)) != u32(0i))) {
                      v_secondary[v_axis] = (v_secondary[v_axis] + v_shine);
                    } else {
                      v_primary[v_axis] = (v_primary[v_axis] + v_shine);
                    }
                    continuing {
                      v_axis += u32(1);
                    }
                  }
                }
              }
              continuing {
                v_light += u32(1);
              }
            }
          }
          {
            var v_axis: u32 = u32(0i);
            loop {
              if (!(v_axis < u32(3i))) { break; }
              let gpu_argument_index_38 = v_axis;
              b_output[(v_destination + v_axis)] = f_fixed_unit(v_primary[gpu_argument_index_38], gpu_thread, gpu_block, gpu_grid);
              let gpu_argument_index_39 = v_axis;
              b_output[((v_destination + u32(4i)) + v_axis)] = f_fixed_unit(v_secondary[gpu_argument_index_39], gpu_thread, gpu_block, gpu_grid);
              continuing {
                v_axis += u32(1);
              }
            }
          }
          let gpu_argument_index_40 = 3i;
          b_output[(v_destination + u32(3i))] = f_fixed_unit(v_diffuse[gpu_argument_index_40], gpu_thread, gpu_block, gpu_grid);
          b_output[(v_destination + u32(7i))] = 1.0f;
          continuing {
            v_face += u32(1);
          }
        }
      }
      if (((v_line != u32(0i)) && (gpu_params.p_capture_endpoints != u32(0i)))) {
        {
          var v_channel: u32 = u32(0i);
          loop {
            if (!(v_channel < u32(16i))) { break; }
            b_endpoints[(((v_vertex * u32(32i)) + (v_endpoint * u32(16i))) + v_channel)] = b_output[((v_vertex * u32(16i)) + v_channel)];
            continuing {
              v_channel += u32(1);
            }
          }
        }
      }
      continuing {
        v_endpoint += u32(1);
      }
    }
  }
}
