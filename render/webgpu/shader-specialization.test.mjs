import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {specializeMaterialSource} from './shader-specialization.js';

const constants = {MATERIAL_FLAGS: 12, MATERIAL_FEATURES: 0, MATERIAL_LAYERS: 0, MATERIAL_MODE: 0, SKY_PASS: 0, HAS_SHADOWS: 0};
const declarations = Object.keys(constants).map(name => `override ${name}: u32 = 0u;`).join('\n');
const shader = body => `${declarations}\nfn shade_material() -> f32 { ${body} }\n@fragment fn fragment_color() -> @location(0) f32 { return shade_material(); }`;

test('hexadecimal literals ending in f keep all digits and preserve unsigned comparisons', () => {
  const source = shader(`let v_flags = MATERIAL_FLAGS;
    if ((v_flags & 0xffffffff) == 0xdeadbeef) { return 11.0; } else { return 22.0; }`);
  const result = specializeMaterialSource(source, {...constants, MATERIAL_FLAGS: 0xdeadbeef});
  assert(result.includes('return 11.0;')); assert(!result.includes('return 22.0;'));
  const high = specializeMaterialSource(shader(`let v_flags = MATERIAL_FLAGS;
    if ((v_flags & 0x80000000u) == u32(2147483648u)) { return 31.0; } else { return 42.0; }`),
    {...constants, MATERIAL_FLAGS: 0x80000000});
  assert(high.includes('return 31.0;')); assert(!high.includes('return 42.0;'));
});

test('nested if/else folding preserves block scopes and removes unreachable helpers', () => {
  const source = shader(`let v_flags = MATERIAL_FLAGS;
    if ((v_flags & u32(2048i)) != 0u) { return unused(); }
    else if ((v_flags & 8u) != 0u) { let private_value = 7.0; return private_value; }
    else { return 99.0; }`) + '\nfn unused() -> f32 { return 83.0; }';
  const result = specializeMaterialSource(source, constants);
  assert(!result.includes('override ')); assert(!result.includes('fn unused'));
  assert(!result.includes('return 99.0;')); assert(result.includes('{ let private_value = 7.0; return private_value; }'));
});

test('unknown conditions and fog mode survive while known false conjunctions are removed', () => {
  const source = shader(`let v_flags = MATERIAL_FLAGS;
    var v_mode: u32 = 7u;
    if ((v_flags & 2048u) != 0u && varying.x > 0.0) { return 19.0; }
    if (v_mode == 7u) { return 23.0; }
    if (varying.x > 0.0) { return 29.0; } else if ((v_flags & 8u) == 0u) { return 37.0; }
    return 41.0;`);
  const result = specializeMaterialSource(source, constants);
  assert(!result.includes('return 19.0;')); assert(!result.includes('return 37.0;'));
  assert(result.includes('if (v_mode == 7u)')); assert(result.includes('if (varying.x > 0.0)'));
  assert(result.includes('else {}'));
});

test('independent texture helper flags and mutated material aliases are never assumed constant', () => {
  const source = shader(`let v_flags = MATERIAL_FLAGS; return texture_helper(2048u);`)
    + '\nfn texture_helper(flags: u32) -> f32 { var v_flags: u32 = flags; if ((v_flags & 2048u) != 0u) { return 17.0; } return 18.0; }';
  const result = specializeMaterialSource(source, constants);
  assert(result.includes('if ((v_flags & 2048u) != 0u)')); assert(result.includes('return 17.0;'));
  const mutated = specializeMaterialSource(shader(`var v_features: u32 = MATERIAL_FEATURES;
    v_features |= 2048u; if ((v_features & 2048u) != 0u) { return 51.0; } return 52.0;`), constants);
  assert(mutated.includes('if ((v_features & 2048u) != 0u)'));
  const edited = specializeMaterialSource(shader(`let v_flags = 0u;
    if ((v_flags & 8u) != 0u) { return 61.0; } return 62.0;`), constants);
  assert(edited.includes('if ((v_flags & 8u) != 0u)'));
});

test('comments cannot masquerade as braces or helper references', () => {
  const source = shader(`let v_flags = MATERIAL_FLAGS;
    /* { fn fake() { nested /* } */ } */
    // unused(); if (fake) {
    if ((v_flags & 8u) != 0u) { return 7.0; } else { return 9.0; }`)
    + '\nfn unused() -> f32 { return 5.0; }';
  const result = specializeMaterialSource(source, constants);
  assert(result.includes('return 7.0;')); assert(!result.includes('return 9.0;')); assert(!result.includes('fn unused()'));
});

test('ordinary material variants exclude inactive shading families and line polygon loops', async () => {
  const source = await readFile(new URL('./shaders/material.wgsl', import.meta.url), 'utf8');
  const basic = specializeMaterialSource(source, constants);
  assert(basic.length < source.length / 8, `Basic shader retained ${basic.length}/${source.length} bytes`);
  assert(!basic.includes('fn shade_water(')); assert(!basic.includes('fn material_alpha('));
  assert(!basic.includes('fn f_line_rectangle_coverage(')); assert(!basic.includes('fn environment_coordinate('));
  for (const root of ['vertex_main', 'fragment_color', 'fragment_normal', 'fragment_depth', 'fragment_query']) assert(basic.includes(`fn ${root}(`));
  const line = specializeMaterialSource(source, {...constants, MATERIAL_FLAGS: 12 | 4194304});
  assert(line.includes('fn f_line_rectangle_coverage('));
  const object = specializeMaterialSource(source, {...constants, MATERIAL_FLAGS: 12 | 2048,
    MATERIAL_FEATURES: 131072 | 16384});
  assert(!object.includes('override '));
  assert(!object.includes('fn sample_shadow_compare('));
  assert(!object.includes('fn cluster_light('));
  assert(object.length < source.length / 6, `Composite shader retained ${object.length}/${source.length} bytes`);
  const shadow = specializeMaterialSource(source, {...constants, MATERIAL_FLAGS: 12 | 2048,
    MATERIAL_FEATURES: 131072, HAS_SHADOWS: 1});
  assert(shadow.includes('fn sample_shadow_compare('));
  assert.equal(basic, specializeMaterialSource(source, constants), 'Specialization must be deterministic');
});
