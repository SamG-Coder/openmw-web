// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: bloom_combine.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_source: array<f32>;
@group(0) @binding(1) var<storage, read> b_bloom: array<f32>;
@group(0) @binding(2) var<storage, read_write> b_target: array<f32>;
struct KernelParams {
  p_width: u32,
  p_height: u32,
  p_source_width: u32,
  p_source_height: u32,
  p_bloom_width: u32,
  p_bloom_height: u32,
  p_gamma: f32,
  p_clamp_value: f32,
  p_strength: f32,
  p_time: f32,
  gpu_pad_40: u32,
  gpu_pad_44: u32,
}
@group(0) @binding(3) var<uniform> gpu_params: KernelParams;
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












fn f_bloom_scramble(gpu_arg_x: f32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var v_x: f32 = gpu_arg_x;
  v_x = (v_x - floor(v_x));
  v_x = (v_x + 4.0f);
  v_x = (v_x * v_x);
  v_x = (v_x * v_x);
  return (v_x - floor(v_x));
}
fn f_gpu_buffer_helper_0(gpu_buffer_arg_0: i32, gpu_arg_width: u32, gpu_arg_height: u32, gpu_arg_u: f32, gpu_arg_v: f32, gpu_arg_channel: u32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var gpu_buffer_offset_0: i32 = gpu_buffer_arg_0;
  var v_width: u32 = gpu_arg_width;
  var v_height: u32 = gpu_arg_height;
  var v_u: f32 = gpu_arg_u;
  var v_v: f32 = gpu_arg_v;
  var v_channel: u32 = gpu_arg_channel;
  var v_x: f32 = ((min(1.0f, max(0.0f, v_u)) * f32(v_width)) - 0.5f);
  var v_y: f32 = (((1.0f - min(1.0f, max(0.0f, v_v))) * f32(v_height)) - 0.5f);
  var v_ix: i32 = i32(floor(v_x));
  var v_iy: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - floor(v_x));
  var v_fy: f32 = (v_y - floor(v_y));
  var v_value: f32 = 0.0f;
  {
    var v_dy: i32 = 0i;
    loop {
      if (!(v_dy < 2i)) { break; }
      {
        var v_dx: i32 = 0i;
        loop {
          if (!(v_dx < 2i)) { break; }
          var v_sx: i32 = (v_ix + v_dx);
          var v_sy: i32 = (v_iy + v_dy);
          var gpu_tmp_12: i32;
          if ((v_sx < 0i)) {
            gpu_tmp_12 = 0i;
          } else {
            var gpu_tmp_11: i32;
            if ((v_sx >= i32(v_width))) {
              gpu_tmp_11 = (i32(v_width) - 1i);
            } else {
              gpu_tmp_11 = v_sx;
            }
            gpu_tmp_12 = gpu_tmp_11;
          }
          v_sx = gpu_tmp_12;
          var gpu_tmp_14: i32;
          if ((v_sy < 0i)) {
            gpu_tmp_14 = 0i;
          } else {
            var gpu_tmp_13: i32;
            if ((v_sy >= i32(v_height))) {
              gpu_tmp_13 = (i32(v_height) - 1i);
            } else {
              gpu_tmp_13 = v_sy;
            }
            gpu_tmp_14 = gpu_tmp_13;
          }
          v_sy = gpu_tmp_14;
          var gpu_tmp_15: f32;
          if ((v_dx == 0i)) {
            gpu_tmp_15 = (1.0f - v_fx);
          } else {
            gpu_tmp_15 = v_fx;
          }
          var gpu_tmp_16: f32;
          if ((v_dy == 0i)) {
            gpu_tmp_16 = (1.0f - v_fy);
          } else {
            gpu_tmp_16 = v_fy;
          }
          v_value = (v_value + ((b_bloom[(gpu_buffer_offset_0 + i32(((((u32(v_sy) * v_width) + u32(v_sx)) * u32(9i)) + v_channel)))] * gpu_tmp_15) * gpu_tmp_16));
          continuing {
            v_dx += i32(1);
          }
        }
      }
      continuing {
        v_dy += i32(1);
      }
    }
  }
  return v_value;
}
fn f_gpu_buffer_helper_1(gpu_buffer_arg_0: i32, gpu_arg_width: u32, gpu_arg_height: u32, gpu_arg_u: f32, gpu_arg_v: f32, gpu_arg_channel: u32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var gpu_buffer_offset_0: i32 = gpu_buffer_arg_0;
  var v_width: u32 = gpu_arg_width;
  var v_height: u32 = gpu_arg_height;
  var v_u: f32 = gpu_arg_u;
  var v_v: f32 = gpu_arg_v;
  var v_channel: u32 = gpu_arg_channel;
  var v_x: f32 = ((min(1.0f, max(0.0f, v_u)) * f32(v_width)) - 0.5f);
  var v_y: f32 = (((1.0f - min(1.0f, max(0.0f, v_v))) * f32(v_height)) - 0.5f);
  var v_ix: i32 = i32(floor(v_x));
  var v_iy: i32 = i32(floor(v_y));
  var v_fx: f32 = (v_x - floor(v_x));
  var v_fy: f32 = (v_y - floor(v_y));
  var v_value: f32 = 0.0f;
  {
    var v_dy: i32 = 0i;
    loop {
      if (!(v_dy < 2i)) { break; }
      {
        var v_dx: i32 = 0i;
        loop {
          if (!(v_dx < 2i)) { break; }
          var v_sx: i32 = (v_ix + v_dx);
          var v_sy: i32 = (v_iy + v_dy);
          var gpu_tmp_18: i32;
          if ((v_sx < 0i)) {
            gpu_tmp_18 = 0i;
          } else {
            var gpu_tmp_17: i32;
            if ((v_sx >= i32(v_width))) {
              gpu_tmp_17 = (i32(v_width) - 1i);
            } else {
              gpu_tmp_17 = v_sx;
            }
            gpu_tmp_18 = gpu_tmp_17;
          }
          v_sx = gpu_tmp_18;
          var gpu_tmp_20: i32;
          if ((v_sy < 0i)) {
            gpu_tmp_20 = 0i;
          } else {
            var gpu_tmp_19: i32;
            if ((v_sy >= i32(v_height))) {
              gpu_tmp_19 = (i32(v_height) - 1i);
            } else {
              gpu_tmp_19 = v_sy;
            }
            gpu_tmp_20 = gpu_tmp_19;
          }
          v_sy = gpu_tmp_20;
          var gpu_tmp_21: f32;
          if ((v_dx == 0i)) {
            gpu_tmp_21 = (1.0f - v_fx);
          } else {
            gpu_tmp_21 = v_fx;
          }
          var gpu_tmp_22: f32;
          if ((v_dy == 0i)) {
            gpu_tmp_22 = (1.0f - v_fy);
          } else {
            gpu_tmp_22 = v_fy;
          }
          v_value = (v_value + ((b_source[(gpu_buffer_offset_0 + i32(((((u32(v_sy) * v_width) + u32(v_sx)) * u32(9i)) + v_channel)))] * gpu_tmp_21) * gpu_tmp_22));
          continuing {
            v_dx += i32(1);
          }
        }
      }
      continuing {
        v_dy += i32(1);
      }
    }
  }
  return v_value;
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
  var v_i: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_i >= (gpu_params.p_width * gpu_params.p_height))) {
    return;
  }
  var v_u: f32 = gpu_divide_f32((f32((v_i % gpu_params.p_width)) + 0.5f), f32(gpu_params.p_width));
  var v_v: f32 = (1.0f - gpu_divide_f32((f32((v_i / gpu_params.p_width)) + 0.5f), f32(gpu_params.p_height)));
  var v_phase: f32 = (gpu_params.p_time - floor(gpu_params.p_time));
  var v_x: f32 = (v_u * 61.12f);
  var v_y: f32 = (v_v * 61.12f);
  var v_first: f32 = f_bloom_scramble((((v_x * 0.6491f) + (v_y * 0.029f)) + v_phase), gpu_thread, gpu_block, gpu_grid);
  var v_seed: f32 = (v_phase * (v_x - floor(v_x)));
  v_seed = (v_seed - floor(v_seed));
  var v_second: f32 = f_bloom_scramble(((((v_x * 0.6491f) + (v_y * 0.029f)) + v_seed) + 0.18943f), gpu_thread, gpu_block, gpu_grid);
  var v_color: array<f32, 3>;
  var v_mean: f32 = 0.0f;
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(3i))) { break; }
      var v_value: f32 = gpu_pow_f32(max(0.0f, f_gpu_buffer_helper_0(0i, gpu_params.p_bloom_width, gpu_params.p_bloom_height, v_u, v_v, v_c, gpu_thread, gpu_block, gpu_grid)), gpu_divide_f32(1.0f, gpu_params.p_gamma));
      var gpu_tmp_8: f32;
      if ((v_c == 1u)) {
        gpu_tmp_8 = v_second;
      } else {
        gpu_tmp_8 = v_first;
      }
      var v_noise: f32 = gpu_tmp_8;
      v_color[v_c] = max(0.0f, (v_value - (v_noise * gpu_divide_f32(2.0f, 255.0f))));
      v_mean = (v_mean + gpu_divide_f32(v_color[v_c], 3.0f));
      continuing {
        v_c += u32(1);
      }
    }
  }
  var gpu_tmp_10: f32;
  if ((gpu_params.p_clamp_value == 0.0f)) {
    gpu_tmp_10 = 0.0f;
  } else {
    var gpu_tmp_9: f32;
    if ((v_mean > gpu_params.p_clamp_value)) {
      gpu_tmp_9 = gpu_divide_f32(gpu_params.p_clamp_value, v_mean);
    } else {
      gpu_tmp_9 = 1.0f;
    }
    gpu_tmp_10 = gpu_tmp_9;
  }
  var v_scale: f32 = gpu_tmp_10;
  {
    var v_c: u32 = u32(0i);
    loop {
      if (!(v_c < u32(3i))) { break; }
      var v_base: f32 = gpu_pow_f32(max(0.0f, f_gpu_buffer_helper_1(0i, gpu_params.p_source_width, gpu_params.p_source_height, v_u, v_v, v_c, gpu_thread, gpu_block, gpu_grid)), gpu_params.p_gamma);
      var v_addition: f32 = ((gpu_pow_f32((v_color[v_c] * v_scale), gpu_params.p_gamma) * gpu_params.p_strength) * 0.5f);
      b_target[((v_i * 9u) + v_c)] = gpu_pow_f32((v_base + v_addition), gpu_divide_f32(1.0f, gpu_params.p_gamma));
      continuing {
        v_c += u32(1);
      }
    }
  }
  b_target[((v_i * 9u) + 3u)] = 1.0f;
}
