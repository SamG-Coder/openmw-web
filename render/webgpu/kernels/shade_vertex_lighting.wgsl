// SPDX-License-Identifier: GPL-3.0-or-later
// OpenMW WebGPU compute: shade_vertex_lighting.
// This WGSL is the source of truth; edit it directly.
// Initially ported from the previous renderer's checked-in WGSL.
@group(0) @binding(0) var<storage, read> b_vertices: array<f32>;
@group(0) @binding(1) var<storage, read> b_attributes: array<f32>;
@group(0) @binding(2) var<storage, read> b_triangles: array<u32>;
@group(0) @binding(3) var<storage, read> b_materials: array<u32>;
@group(0) @binding(4) var<storage, read> b_texels: array<u32>;
@group(0) @binding(5) var<storage, read> b_lighting_origins: array<u32>;
@group(0) @binding(6) var<storage, read_write> b_output: array<f32>;
struct KernelParams {
  p_triangle_count: u32,
  p_track_lighting: u32,
  p_cluster_offset: u32,
  p_track_world_particles: u32,
  p_world_particle_offset: u32,
  gpu_pad_20: u32,
  gpu_pad_24: u32,
  gpu_pad_28: u32,
}
@group(0) @binding(7) var<uniform> gpu_params: KernelParams;
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




fn f_gpu_buffer_helper_0(gpu_buffer_arg_0: i32, gpu_arg_descriptor: u32, gpu_arg_screen_x: f32, gpu_arg_screen_y: f32, gpu_arg_view_z: f32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> u32 {
  var gpu_buffer_offset_0: i32 = gpu_buffer_arg_0;
  var v_descriptor: u32 = gpu_arg_descriptor;
  var v_screen_x: f32 = gpu_arg_screen_x;
  var v_screen_y: f32 = gpu_arg_screen_y;
  var v_view_z: f32 = gpu_arg_view_z;
  if ((v_descriptor == u32(0i))) {
    return 4294967295u;
  }
  let gpu_argument_index_43 = (gpu_buffer_offset_0 + i32((v_descriptor + u32(3i))));
  var v_near: f32 = bitcast<f32>(b_texels[gpu_argument_index_43]);
  let gpu_argument_index_44 = (gpu_buffer_offset_0 + i32((v_descriptor + u32(4i))));
  var v_far: f32 = bitcast<f32>(b_texels[gpu_argument_index_44]);
  var v_z: f32 = max(abs(v_view_z), 1e-12f);
  let gpu_argument_index_45 = (gpu_buffer_offset_0 + i32((v_descriptor + u32(5i))));
  var v_tx: f32 = (gpu_divide_f32(v_screen_x, bitcast<f32>(b_texels[gpu_argument_index_45])) * f32(b_texels[(gpu_buffer_offset_0 + i32(v_descriptor))]));
  let gpu_argument_index_46 = (gpu_buffer_offset_0 + i32((v_descriptor + u32(6i))));
  var v_ty: f32 = (gpu_divide_f32(v_screen_y, bitcast<f32>(b_texels[gpu_argument_index_46])) * f32(b_texels[(gpu_buffer_offset_0 + i32((v_descriptor + u32(1i))))]));
  var v_tz: f32 = (gpu_divide_f32(log2(gpu_divide_f32(v_z, v_near)), log2(gpu_divide_f32(v_far, v_near))) * f32(b_texels[(gpu_buffer_offset_0 + i32((v_descriptor + u32(2i))))]));
  if (((((((v_tx < 0.0f) || (v_ty < 0.0f)) || (v_tz < 0.0f)) || (v_tx >= f32(b_texels[(gpu_buffer_offset_0 + i32(v_descriptor))]))) || (v_ty >= f32(b_texels[(gpu_buffer_offset_0 + i32((v_descriptor + u32(1i))))]))) || (v_tz >= f32(b_texels[(gpu_buffer_offset_0 + i32((v_descriptor + u32(2i))))])))) {
    return 4294967295u;
  }
  return ((u32(v_tx) + (u32(v_ty) * b_texels[(gpu_buffer_offset_0 + i32(v_descriptor))])) + ((u32(v_tz) * b_texels[(gpu_buffer_offset_0 + i32(v_descriptor))]) * b_texels[(gpu_buffer_offset_0 + i32((v_descriptor + u32(1i))))]));
}
fn f_gpu_buffer_helper_1(gpu_buffer_arg_0: i32, gpu_arg_descriptor: u32, gpu_arg_cell: u32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> u32 {
  var gpu_buffer_offset_0: i32 = gpu_buffer_arg_0;
  var v_descriptor: u32 = gpu_arg_descriptor;
  var v_cell: u32 = gpu_arg_cell;
  var gpu_tmp_47: u32;
  if ((v_cell == 4294967295u)) {
    gpu_tmp_47 = 0u;
  } else {
    gpu_tmp_47 = b_texels[(gpu_buffer_offset_0 + i32(((b_texels[(gpu_buffer_offset_0 + i32((v_descriptor + u32(8i))))] + (v_cell * u32(2i))) + u32(1i))))];
  }
  return gpu_tmp_47;
}
fn f_gpu_buffer_helper_2(gpu_buffer_arg_0: i32, gpu_arg_descriptor: u32, gpu_arg_cell: u32, gpu_arg_ordinal: u32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> u32 {
  var gpu_buffer_offset_0: i32 = gpu_buffer_arg_0;
  var v_descriptor: u32 = gpu_arg_descriptor;
  var v_cell: u32 = gpu_arg_cell;
  var v_ordinal: u32 = gpu_arg_ordinal;
  var v_first: u32 = b_texels[(gpu_buffer_offset_0 + i32((b_texels[(gpu_buffer_offset_0 + i32((v_descriptor + u32(8i))))] + (v_cell * u32(2i)))))];
  var v_index: u32 = b_texels[(gpu_buffer_offset_0 + i32(((b_texels[(gpu_buffer_offset_0 + i32((v_descriptor + u32(9i))))] + v_first) + v_ordinal)))];
  return (b_texels[(gpu_buffer_offset_0 + i32((v_descriptor + u32(10i))))] + (v_index * u32(16i)));
}
fn f_gpu_buffer_helper_3(gpu_buffer_arg_0: i32, gpu_arg_descriptor: u32, gpu_arg_view_z: f32, gpu_arg_radius: f32, gpu_thread: vec3<u32>, gpu_block: vec3<u32>, gpu_grid: vec3<u32>) -> f32 {
  var gpu_buffer_offset_0: i32 = gpu_buffer_arg_0;
  var v_descriptor: u32 = gpu_arg_descriptor;
  var v_view_z: f32 = gpu_arg_view_z;
  var v_radius: f32 = gpu_arg_radius;
  let gpu_argument_index_48 = (gpu_buffer_offset_0 + i32((v_descriptor + u32(4i))));
  var v_far: f32 = bitcast<f32>(b_texels[gpu_argument_index_48]);
  var v_t: f32 = min(1.0f, max(0.0f, gpu_divide_f32(((-v_view_z) - (v_far - v_radius)), max(v_radius, 1e-12f))));
  var v_fade: f32 = (1.0f - (v_t * v_t));
  return (v_fade * v_fade);
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
  var v_corner: u32 = (((gpu_block.x + (gpu_block.y * gpu_grid.x)) * gpu_block_size.x) + gpu_thread.x);
  if ((v_corner >= (gpu_params.p_triangle_count * u32(3i)))) {
    return;
  }
  var v_triangle: u32 = (v_corner / u32(3i));
  var v_inputVertex: u32 = b_triangles[((v_triangle * u32(4i)) + (v_corner % u32(3i)))];
  var v_material: u32 = (b_triangles[((v_triangle * u32(4i)) + u32(3i))] * u32(12i));
  var v_destination: u32 = (v_corner * u32(12i));
  {
    var v_k: u32 = u32(0i);
    loop {
      if (!(v_k < u32(12i))) { break; }
      b_output[(v_destination + v_k)] = 0.0f;
      continuing {
        v_k += u32(1);
      }
    }
  }
  if (((b_materials[(v_material + u32(3i))] & u32(2048i)) == u32(0i))) {
    return;
  }
  var v_data: u32 = b_materials[v_material];
  var v_features: u32 = b_texels[(v_data + u32(4i))];
  var v_mode: u32 = b_texels[(v_data + u32(5i))];
  if (((v_features & u32(8388608i)) == u32(0i))) {
    return;
  }
  var gpu_tmp_0: u32;
  if (((v_features & u32(16777216i)) != u32(0i))) {
    gpu_tmp_0 = b_texels[(gpu_params.p_cluster_offset + (v_material / u32(12i)))];
  } else {
    gpu_tmp_0 = u32(0i);
  }
  var v_cluster: u32 = gpu_tmp_0;
  var gpu_tmp_1: u32;
  if ((gpu_params.p_track_lighting != u32(0i))) {
    gpu_tmp_1 = b_lighting_origins[(v_inputVertex * u32(3i))];
  } else {
    gpu_tmp_1 = v_inputVertex;
  }
  var v_first: u32 = gpu_tmp_1;
  var gpu_tmp_2: u32;
  if ((gpu_params.p_track_lighting != u32(0i))) {
    gpu_tmp_2 = b_lighting_origins[((v_inputVertex * u32(3i)) + u32(1i))];
  } else {
    gpu_tmp_2 = v_inputVertex;
  }
  var v_last: u32 = gpu_tmp_2;
  var gpu_tmp_4: f32;
  if ((gpu_params.p_track_lighting != u32(0i))) {
    let gpu_argument_index_3 = ((v_inputVertex * u32(3i)) + u32(2i));
    gpu_tmp_4 = bitcast<f32>(b_lighting_origins[gpu_argument_index_3]);
  } else {
    gpu_tmp_4 = 0.0f;
  }
  var v_fraction: f32 = gpu_tmp_4;
  var v_particle: u32 = (gpu_params.p_world_particle_offset + (v_inputVertex * u32(24i)));
  var v_projected: u32 = select(u32(0), u32(1), ((gpu_params.p_track_world_particles != u32(0i)) && (b_attributes[v_particle] > 0.5f)));
  var gpu_tmp_5: u32;
  if ((v_first == v_last)) {
    gpu_tmp_5 = 1u;
  } else {
    gpu_tmp_5 = 2u;
  }
  var v_endpoints: u32 = gpu_tmp_5;
  if ((v_projected != u32(0i))) {
    v_first = v_inputVertex;
    v_last = v_inputVertex;
    var gpu_tmp_6: u32;
    if ((b_attributes[v_particle] > 1.5f)) {
      gpu_tmp_6 = 2u;
    } else {
      gpu_tmp_6 = 1u;
    }
    v_endpoints = gpu_tmp_6;
    v_fraction = b_attributes[(v_particle + u32(1i))];
  }
  {
    var v_endpoint: u32 = u32(0i);
    loop {
      if (!(v_endpoint < v_endpoints)) { break; }
      var gpu_tmp_7: u32;
      if ((v_endpoint == u32(0i))) {
        gpu_tmp_7 = v_first;
      } else {
        gpu_tmp_7 = v_last;
      }
      var v_vertex: u32 = gpu_tmp_7;
      var gpu_tmp_9: f32;
      if ((v_endpoints == 1u)) {
        gpu_tmp_9 = 1.0f;
      } else {
        var gpu_tmp_8: f32;
        if ((v_endpoint == u32(0i))) {
          gpu_tmp_8 = (1.0f - v_fraction);
        } else {
          gpu_tmp_8 = v_fraction;
        }
        gpu_tmp_9 = gpu_tmp_8;
      }
      var v_weight: f32 = gpu_tmp_9;
      var v_position: array<f32, 3>;
      var v_normal: array<f32, 3>;
      var v_eye: array<f32, 3>;
      var v_diffuse: array<f32, 3>;
      var v_ambient: array<f32, 3>;
      var v_specular: array<f32, 3>;
      var v_emission: array<f32, 3>;
      var v_shaded: array<f32, 3>;
      var v_shadeSpec: array<f32, 3>;
      var v_sunDiffuse: array<f32, 3>;
      var v_sunSpec: array<f32, 3>;
      var v_eyeLength: f32 = 0.0f;
      var v_normalLength: f32 = 0.0f;
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          var gpu_tmp_10: f32;
          if ((v_projected != u32(0i))) {
            gpu_tmp_10 = b_attributes[(((v_particle + u32(2i)) + (v_endpoint * u32(3i))) + v_k)];
          } else {
            gpu_tmp_10 = b_attributes[((v_vertex * u32(34i)) + v_k)];
          }
          v_position[v_k] = gpu_tmp_10;
          v_normal[v_k] = b_attributes[(((v_vertex * u32(34i)) + u32(23i)) + v_k)];
          v_eyeLength = (v_eyeLength + (v_position[v_k] * v_position[v_k]));
          v_normalLength = (v_normalLength + (v_normal[v_k] * v_normal[v_k]));
          var gpu_tmp_11: f32;
          if ((v_projected != u32(0i))) {
            gpu_tmp_11 = b_attributes[(((v_particle + u32(14i)) + (v_endpoint * u32(4i))) + v_k)];
          } else {
            gpu_tmp_11 = b_vertices[(((v_vertex * u32(10i)) + u32(4i)) + v_k)];
          }
          var v_color: f32 = gpu_tmp_11;
          var gpu_tmp_13: f32;
          if (((v_mode == u32(2i)) || (v_mode == u32(4i)))) {
            gpu_tmp_13 = v_color;
          } else {
            let gpu_argument_index_12 = ((v_data + u32(12i)) + v_k);
            gpu_tmp_13 = bitcast<f32>(b_texels[gpu_argument_index_12]);
          }
          v_diffuse[v_k] = gpu_tmp_13;
          var gpu_tmp_15: f32;
          if (((v_mode == u32(2i)) || (v_mode == u32(3i)))) {
            gpu_tmp_15 = v_color;
          } else {
            let gpu_argument_index_14 = ((v_data + u32(8i)) + v_k);
            gpu_tmp_15 = bitcast<f32>(b_texels[gpu_argument_index_14]);
          }
          v_ambient[v_k] = gpu_tmp_15;
          var gpu_tmp_17: f32;
          if ((v_mode == u32(5i))) {
            gpu_tmp_17 = v_color;
          } else {
            let gpu_argument_index_16 = ((v_data + u32(16i)) + v_k);
            gpu_tmp_17 = bitcast<f32>(b_texels[gpu_argument_index_16]);
          }
          v_specular[v_k] = gpu_tmp_17;
          var gpu_tmp_19: f32;
          if ((v_mode == u32(1i))) {
            gpu_tmp_19 = v_color;
          } else {
            let gpu_argument_index_18 = ((v_data + u32(20i)) + v_k);
            gpu_tmp_19 = bitcast<f32>(b_texels[gpu_argument_index_18]);
          }
          let gpu_argument_index_20 = (v_data + u32(47i));
          v_emission[v_k] = (gpu_tmp_19 * bitcast<f32>(b_texels[gpu_argument_index_20]));
          v_shaded[v_k] = v_emission[v_k];
          v_shadeSpec[v_k] = 0.0f;
          v_sunDiffuse[v_k] = 0.0f;
          v_sunSpec[v_k] = 0.0f;
          continuing {
            v_k += u32(1);
          }
        }
      }
      v_eyeLength = sqrt(max(v_eyeLength, 1e-12f));
      v_normalLength = sqrt(max(v_normalLength, 1e-12f));
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          v_eye[v_k] = gpu_divide_f32(v_position[v_k], v_eyeLength);
          v_normal[v_k] = gpu_divide_f32(v_normal[v_k], v_normalLength);
          continuing {
            v_k += u32(1);
          }
        }
      }
      let gpu_argument_index_21 = (v_data + u32(46i));
      var v_shininess: f32 = max(0.0001f, bitcast<f32>(b_texels[gpu_argument_index_21]));
      let gpu_argument_index_22 = (v_data + u32(48i));
      var v_strength: f32 = bitcast<f32>(b_texels[gpu_argument_index_22]);
      var v_cell: u32 = 4294967295u;
      var v_pointCount: u32 = b_texels[(v_data + u32(6i))];
      if ((v_cluster != u32(0i))) {
        let gpu_argument_index_23 = (v_cluster + u32(5i));
        var v_sw: f32 = bitcast<f32>(b_texels[gpu_argument_index_23]);
        let gpu_argument_index_24 = (v_cluster + u32(6i));
        var v_sh: f32 = bitcast<f32>(b_texels[gpu_argument_index_24]);
        var gpu_tmp_25: f32;
        if ((v_projected != u32(0i))) {
          gpu_tmp_25 = b_attributes[((v_particle + u32(8i)) + (v_endpoint * u32(3i)))];
        } else {
          gpu_tmp_25 = b_vertices[(v_vertex * u32(10i))];
        }
        var v_clipX: f32 = gpu_tmp_25;
        var gpu_tmp_26: f32;
        if ((v_projected != u32(0i))) {
          gpu_tmp_26 = b_attributes[((v_particle + u32(9i)) + (v_endpoint * u32(3i)))];
        } else {
          gpu_tmp_26 = b_vertices[((v_vertex * u32(10i)) + u32(1i))];
        }
        var v_clipY: f32 = gpu_tmp_26;
        var gpu_tmp_27: f32;
        if ((v_projected != u32(0i))) {
          gpu_tmp_27 = b_attributes[((v_particle + u32(10i)) + (v_endpoint * u32(3i)))];
        } else {
          gpu_tmp_27 = b_vertices[((v_vertex * u32(10i)) + u32(3i))];
        }
        var v_w: f32 = gpu_tmp_27;
        if ((abs(v_w) > 1e-12f)) {
          var v_sx: f32 = min((v_sw - 1.0f), max(0.0f, (((gpu_divide_f32(v_clipX, v_w) * 0.5f) + 0.5f) * v_sw)));
          var v_sy: f32 = min((v_sh - 1.0f), max(0.0f, (((gpu_divide_f32(v_clipY, v_w) * 0.5f) + 0.5f) * v_sh)));
          let gpu_argument_index_28 = 2i;
          v_cell = f_gpu_buffer_helper_0(0i, v_cluster, v_sx, v_sy, v_position[gpu_argument_index_28], gpu_thread, gpu_block, gpu_grid);
        }
        var gpu_tmp_29: u32;
        if (((v_features & u32(33554432i)) != u32(0i))) {
          gpu_tmp_29 = 0u;
        } else {
          gpu_tmp_29 = f_gpu_buffer_helper_1(0i, v_cluster, v_cell, gpu_thread, gpu_block, gpu_grid);
        }
        v_pointCount = gpu_tmp_29;
      }
      {
        var v_light: u32 = u32(0i);
        loop {
          if (!(v_light <= v_pointCount)) { break; }
          var gpu_tmp_31: u32;
          if ((v_light == u32(0i))) {
            gpu_tmp_31 = (v_data + u32(24i));
          } else {
            var gpu_tmp_30: u32;
            if ((v_cluster != u32(0i))) {
              gpu_tmp_30 = f_gpu_buffer_helper_2(0i, v_cluster, v_cell, (v_light - u32(1i)), gpu_thread, gpu_block, gpu_grid);
            } else {
              gpu_tmp_30 = ((v_data + b_texels[(v_data + u32(7i))]) + ((v_light - u32(1i)) * u32(16i)));
            }
            gpu_tmp_31 = gpu_tmp_30;
          }
          var v_record: u32 = gpu_tmp_31;
          var v_direction: array<f32, 3>;
          var v_distance: f32 = 0.0f;
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              let gpu_argument_index_32 = (v_record + v_k);
              var gpu_tmp_33: f32;
              if ((v_light == u32(0i))) {
                gpu_tmp_33 = 0.0f;
              } else {
                gpu_tmp_33 = v_position[v_k];
              }
              v_direction[v_k] = (bitcast<f32>(b_texels[gpu_argument_index_32]) - gpu_tmp_33);
              v_distance = (v_distance + (v_direction[v_k] * v_direction[v_k]));
              continuing {
                v_k += u32(1);
              }
            }
          }
          v_distance = sqrt(max(v_distance, 1e-12f));
          var v_attenuation: f32 = 1.0f;
          if ((v_light != u32(0i))) {
            let gpu_argument_index_34 = (v_record + u32(15i));
            var v_radius: f32 = bitcast<f32>(b_texels[gpu_argument_index_34]);
            if (((((v_features & u32(1i)) == u32(0i)) || (v_cluster != u32(0i))) && (v_distance > v_radius))) {
              continue;
            }
            if ((v_cluster != u32(0i))) {
              let gpu_argument_index_35 = 2i;
              v_attenuation = (v_attenuation * f_gpu_buffer_helper_3(0i, v_cluster, v_position[gpu_argument_index_35], v_radius, gpu_thread, gpu_block, gpu_grid));
            }
            let gpu_argument_index_36 = (v_record + u32(3i));
            let gpu_argument_index_37 = (v_record + u32(7i));
            let gpu_argument_index_38 = (v_record + u32(11i));
            var v_denominator: f32 = ((bitcast<f32>(b_texels[gpu_argument_index_36]) + (bitcast<f32>(b_texels[gpu_argument_index_37]) * v_distance)) + ((bitcast<f32>(b_texels[gpu_argument_index_38]) * v_distance) * v_distance));
            v_attenuation = gpu_divide_f32(v_attenuation, max(v_denominator, 1e-12f));
            if ((((v_features & u32(1i)) == u32(0i)) || (v_cluster != u32(0i)))) {
              var v_fade: f32 = min(1.0f, max(0.0f, gpu_divide_f32((gpu_divide_f32(v_distance, max(v_radius, 0.000001f)) - 0.75f), 0.25f)));
              v_fade = (1.0f - (v_fade * v_fade));
              v_attenuation = (v_attenuation * (v_fade * v_fade));
            }
          }
          var v_lambert: f32 = 0.0f;
          var v_halfLength: f32 = 0.0f;
          var v_halfVector: array<f32, 3>;
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              v_direction[v_k] = gpu_divide_f32(v_direction[v_k], v_distance);
              v_lambert = (v_lambert + (v_normal[v_k] * v_direction[v_k]));
              v_halfVector[v_k] = (v_direction[v_k] - v_eye[v_k]);
              v_halfLength = (v_halfLength + (v_halfVector[v_k] * v_halfVector[v_k]));
              continuing {
                v_k += u32(1);
              }
            }
          }
          if (((v_features & u32(67108864i)) != u32(0i))) {
            var v_eyeCosine: f32 = 0.0f;
            {
              var v_axis: u32 = u32(0i);
              loop {
                if (!(v_axis < u32(3i))) { break; }
                v_eyeCosine = (v_eyeCosine + (v_normal[v_axis] * v_eye[v_axis]));
                continuing {
                  v_axis += u32(1);
                }
              }
            }
            if ((v_lambert < 0.0f)) {
              v_lambert = (-v_lambert);
              v_eyeCosine = (-v_eyeCosine);
            }
            v_lambert = (v_lambert * min(1.0f, max(0.3f, (1.0f - (5.6f * v_eyeCosine)))));
          }
          v_halfLength = sqrt(max(v_halfLength, 1e-12f));
          var v_spec: f32 = 0.0f;
          if ((v_lambert > 0.0f)) {
            {
              var v_k: u32 = u32(0i);
              loop {
                if (!(v_k < u32(3i))) { break; }
                v_spec = (v_spec + gpu_divide_f32((v_normal[v_k] * v_halfVector[v_k]), v_halfLength));
                continuing {
                  v_k += u32(1);
                }
              }
            }
            v_spec = gpu_pow_f32(max(v_spec, 0.0f), v_shininess);
          }
          {
            var v_k: u32 = u32(0i);
            loop {
              if (!(v_k < u32(3i))) { break; }
              let gpu_argument_index_39 = ((v_record + u32(8i)) + v_k);
              var v_d: f32 = (((v_diffuse[v_k] * bitcast<f32>(b_texels[gpu_argument_index_39])) * max(v_lambert, 0.0f)) * v_attenuation);
              let gpu_argument_index_40 = ((v_record + u32(4i)) + v_k);
              var v_a: f32 = ((v_ambient[v_k] * bitcast<f32>(b_texels[gpu_argument_index_40])) * v_attenuation);
              let gpu_argument_index_41 = ((v_record + u32(12i)) + v_k);
              var v_s: f32 = ((((v_specular[v_k] * bitcast<f32>(b_texels[gpu_argument_index_41])) * v_spec) * v_attenuation) * v_strength);
              v_shaded[v_k] = (v_shaded[v_k] + v_a);
              if ((v_light == u32(0i))) {
                v_sunDiffuse[v_k] = v_d;
                v_sunSpec[v_k] = v_s;
              } else {
                v_shaded[v_k] = (v_shaded[v_k] + v_d);
                v_shadeSpec[v_k] = (v_shadeSpec[v_k] + v_s);
              }
              continuing {
                v_k += u32(1);
              }
            }
          }
          continuing {
            v_light += u32(1);
          }
        }
      }
      {
        var v_k: u32 = u32(0i);
        loop {
          if (!(v_k < u32(3i))) { break; }
          var v_lit: f32 = max(0.0f, (v_shaded[v_k] + v_sunDiffuse[v_k]));
          let gpu_argument_index_42 = v_k;
          var v_shade: f32 = max(0.0f, v_shaded[gpu_argument_index_42]);
          if (((v_features & u32(2i)) != u32(0i))) {
            v_lit = min(1.0f, v_lit);
            v_shade = min(1.0f, v_shade);
          }
          b_output[(v_destination + v_k)] = (b_output[(v_destination + v_k)] + (v_weight * v_shade));
          b_output[((v_destination + u32(3i)) + v_k)] = (b_output[((v_destination + u32(3i)) + v_k)] + (v_weight * v_shadeSpec[v_k]));
          b_output[((v_destination + u32(6i)) + v_k)] = (b_output[((v_destination + u32(6i)) + v_k)] + (v_weight * v_lit));
          b_output[((v_destination + u32(9i)) + v_k)] = (b_output[((v_destination + u32(9i)) + v_k)] + (v_weight * (v_shadeSpec[v_k] + v_sunSpec[v_k])));
          continuing {
            v_k += u32(1);
          }
        }
      }
      continuing {
        v_endpoint += u32(1);
      }
    }
  }
}
