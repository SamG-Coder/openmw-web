// SPDX-License-Identifier: GPL-3.0-or-later
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, rm, readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';

const root=fileURLToPath(new URL('../',import.meta.url));

test('staging installs an immutable standalone renderer beside an existing engine',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'openmw-stage-webgpu-'));
  try {
    const engine=join(directory,'e','test-engine');await mkdir(engine,{recursive:true});
    for(const name of ['openmw.js','openmw.wasm','openmw.data'])await writeFile(join(engine,name),`fixture ${name}`);
    execFileSync('python3',['wasm-build/stage-webgpu-page.py','test-engine','--destination',directory],{cwd:root});
    const page=await readFile(join(directory,'index.html'),'utf8');
    assert(page.includes('var __ENGINE_VER = "test-engine"'));
    const [,version]=page.match(/const rendererDirectory = '\.\/webgpu\/([0-9a-f]{16})\/';/)??[];
    assert(version,'Page names the exact staged renderer version');
    const bundle=join(directory,'webgpu',version);
    const host=await readFile(join(bundle,'game-host.js'),'utf8');
    assert(host.includes("import { WebGPURuntime } from './runtime.js'"));
    assert(!host.includes('webcuda-sdk'));
    assert((await readdir(join(bundle,'kernels'))).every(name=>name.endsWith('.wgsl')));
    assert((await readFile(join(bundle,'shaders','prepare-triangles.wgsl'),'utf8')).includes('@compute'));
    assert.equal(await readFile(join(engine,'openmw.wasm'),'utf8'),'fixture openmw.wasm');
    execFileSync('python3',['wasm-build/stage-webcuda-page.py','test-engine','--destination',directory],{cwd:root});
    assert.equal(await readFile(join(directory,'index.html'),'utf8'),page,'Legacy staging command uses the same native bundle');
    assert.throws(()=>execFileSync('python3',['wasm-build/stage-webgpu-page.py','missing','--destination',directory],{cwd:root,stdio:'pipe'}));
    assert.equal(await readFile(join(directory,'index.html'),'utf8'),page,'Missing engine cannot replace the working page');
  } finally {await rm(directory,{recursive:true,force:true});}
});

test('shader changes produce new engine URLs and move all referenced startup assets',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'openmw-version-webgpu-'));
  try {
    async function bundle(name,shader) {
      const play=join(directory,name);await mkdir(join(play,'webgpu','shaders'),{recursive:true});
      for(const file of ['openmw.js','openmw.wasm','openmw.data','streamfs.js','frame-pump.js'])
        await writeFile(join(play,file),`same ${file}`);
      await writeFile(join(play,'webgpu','game-host.js'),'export const native = true;');
      await writeFile(join(play,'webgpu','shaders','material.wgsl'),shader);
      await writeFile(join(play,'index.html'),'<script src="frame-pump.js"></script><script src="streamfs.js"></script>__ENGINE_VERSION__');
      execFileSync('sh',['wasm-build/version-engine.sh'],{cwd:root,env:{...process.env,PLAY:play}});
      const version=await readFile(join(play,'engine-version.txt'),'utf8');
      const html=await readFile(join(play,'index.html'),'utf8');
      for(const file of ['streamfs.js','frame-pump.js'])assert(html.includes(`src="e/${version}/${file}"`));
      assert.equal(await readFile(join(play,'e',version,'webgpu','shaders','material.wgsl'),'utf8'),shader);
      return version;
    }
    assert.notEqual(await bundle('first','// first shader'),await bundle('second','// shader changed'));
  } finally {await rm(directory,{recursive:true,force:true});}
});
