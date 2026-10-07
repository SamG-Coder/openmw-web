import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {specializeMaterialSource} from './shader-specialization.js';
import {HardwareRasterizer} from './rasterizer.js';

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

test('entry-point pruning removes unreachable helpers and their inline or preceding attributes', () => {
  const source=`fn shared() -> f32 { return 1.0; }
    @vertex fn vertex_main() -> @builtin(position) vec4<f32> { return vec4<f32>(shared()); }
    @fragment fn fragment_color() -> @location(0) f32 { return shared(); }
    @fragment
    fn fragment_normal() -> @location(0) f32 { return unused(); }
    @fragment fn fragment_query() -> @location(0) f32 { return unused(); }
    fn unused() -> f32 { return 9.0; }`;
  const result=specializeMaterialSource(source,{},'fragment_color');
  assert(result.includes('fn vertex_main('));assert(result.includes('fn fragment_color('));assert(result.includes('fn shared('));
  for(const removed of ['fragment_normal','fragment_query','unused'])assert(!result.includes(`fn ${removed}(`));
  assert.equal((result.match(/@fragment\b/g)??[]).length,1,'Removed entry points must not leave orphaned attributes');
  assert.equal((result.match(/@vertex\b/g)??[]).length,1);
  for(const retained of ['vertex_main','fragment_color','shared'])
    assert.equal((result.match(new RegExp(`\\bfn\\s+${retained}\\b`,'g'))??[]).length,1,'Never absorb an earlier declaration');

  const global='@group(0) @binding(0) var<uniform> parameters: vec4<f32>;';
  const withGlobal=specializeMaterialSource(`${global}\n@fragment\nfn fragment_depth() -> @builtin(frag_depth) f32 { return 0.0; }\n${source}`,{},'fragment_color');
  assert(withGlobal.includes(global),'Attributes on a resource declaration remain with that resource');
});

test('current material families keep dynamic feature branches and only the selected fragment entry point', async () => {
  const source = await readFile(new URL('./shaders/material.wgsl', import.meta.url), 'utf8');
  const entries=['fragment_color','fragment_normal','fragment_depth','fragment_query'];
  for(const entry of entries) {
    // Match HardwareRasterizer.materialFamily: feature bits stay in uniforms.
    // All four entries use shade_material, so material helpers must remain live.
    const family=specializeMaterialSource(source,{},entry);
    assert(family.includes('fn vertex_main('));assert(family.includes(`fn ${entry}(`));
    for(const other of entries)if(other!==entry)assert(!family.includes(`fn ${other}(`));
    assert.equal((family.match(/@fragment\b/g)??[]).length,1);
    for(const field of ['material_flags','material_features','material_layers','material_mode','sky_pass','has_shadows'])
      assert(family.includes(`params.${field}`),`${entry} lost dynamic ${field}`);
    for(const helper of ['shade_water','material_alpha','f_line_rectangle_coverage','environment_coordinate','sample_shadow_compare','cluster_light'])
      assert(family.includes(`fn ${helper}(`),`${entry} lost reachable helper ${helper}`);
    assert(!family.includes('override '));
    assert.equal(family,specializeMaterialSource(source,{},entry),'Pruning must be deterministic');
  }
});

test('material families reuse one shader module per entry point across concurrent and later requests', async () => {
  const source=await readFile(new URL('./shaders/material.wgsl',import.meta.url),'utf8'),modules=[];
  const runtime={device:{limits:{minUniformBufferOffsetAlignment:256},createShaderModule(descriptor){
    const module={...descriptor,getCompilationInfo:async()=>({messages:[]})};modules.push(module);return module;
  }}};
  const rasterizer=new HardwareRasterizer(runtime);rasterizer.materialSource=source;
  const [first,concurrent]=await Promise.all([
    rasterizer.materialFamily('fragment_color'),rasterizer.materialFamily('fragment_color')]);
  assert.equal(first,concurrent);assert.equal(modules.length,1);
  assert.equal(await rasterizer.materialFamily('fragment_color'),first);assert.equal(modules.length,1);
  const depth=await rasterizer.materialFamily('fragment_depth');
  assert.notEqual(depth,first);assert.equal(modules.length,2);
  assert(!first.code.includes('fn fragment_depth('));assert(!depth.code.includes('fn fragment_color('));
});
