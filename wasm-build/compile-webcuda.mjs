import { kernelManifest } from '../render/webcuda/kernel-manifest.js';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { nativePagedSource } from './native-paged-source.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const compilerRoot = process.env.WEBCUDA_ROOT;
if (!compilerRoot) throw new Error('Set WEBCUDA_ROOT to your cuda-webshader checkout.');
const { compile, serializableArtifact } = await import(pathToFileURL(join(resolve(compilerRoot), 'src/compiler/compiler.js')));
const output = join(root, 'render/webcuda/generated');
await mkdir(output, { recursive: true });
const nativePages=await readFile(join(root,'render/webcuda/native-pages.cuh'),'utf8');
for (const {file, entry} of kernelManifest) {
  let source = await readFile(join(root, 'render/webcuda', file), 'utf8');
  if(file==='material.cu')source=source.replace('#include "water.cu"',await readFile(join(root,'render/webcuda/water.cu'),'utf8'));
  if(source.includes('#include "cluster-lighting.cuh"'))source=source.replace('#include "cluster-lighting.cuh"',await readFile(join(root,'render/webcuda/cluster-lighting.cuh'),'utf8'));
  if(source.includes('#include "precision.cuh"'))source=source.replace('#include "precision.cuh"',await readFile(join(root,'render/webcuda/precision.cuh'),'utf8'));
  if(source.includes('#include "raster-pixel.cuh"'))source=source.replace('#include "raster-pixel.cuh"',await readFile(join(root,'render/webcuda/raster-pixel.cuh'),'utf8'));
  // Keep the same authored, header-expanded CUDA beside WGSL. ChromiumRTXCuda
  // feeds this source to NVRTC; it must never reconstruct CUDA from WGSL.
  if (/#|%:|\?\?|\\|__has_include/.test(source))
    throw new Error(`${entry}: native browser source must be self-contained`);
  const artifact = compile(source, { entry, workgroupSize: [64, 1, 1], includeNativeSource: true });
  await writeFile(join(output, `${entry}.wgsl`), artifact.wgsl);
  await writeFile(join(output, `${entry}.json`), JSON.stringify(serializableArtifact(artifact), null, 2) + '\n');
  // The native diagnostic need not download the generated WGSL. Retain the ABI
  // and its original source together so entry signatures cannot drift apart.
  await writeFile(join(output, `${entry}.native.json`), JSON.stringify({name:entry,native:artifact.native}, null, 2) + '\n');
  await writeFile(join(output, `${entry}.native-paged.json`), JSON.stringify({name:entry,metadata:artifact.metadata,
    native:{...artifact.native,storage:'openmw-paged-64m-v1',source:nativePagedSource(source,nativePages)}}, null, 2)+'\n');
  console.log(`${entry}: generated WGSL and original-CUDA artifacts`);
}
await writeFile(join(output, 'native-manifest.json'), JSON.stringify(kernelManifest.map(({entry,runtime})=>({entry,runtime,artifact:`${entry}.native.json`})), null, 2)+'\n');
const storageSource=nativePages+'\n'+await readFile(join(root,'render/webcuda/native-storage.cu'),'utf8');
for(const [entry,parameters,workgroupSize] of [
  ['omw_set_page',[{name:'table',type:'buffer'},{name:'page',type:'buffer'},{name:'slot',type:'u32'}],[1,1,1]],
  ['omw_copy_pages',[{name:'source_pages',type:'buffer'},{name:'target_pages',type:'buffer'},
    {name:'source_offset',type:'u32'},{name:'target_offset',type:'u32'},{name:'word_count',type:'u32'}],[64,1,1]],
])await writeFile(join(output,`${entry}.native.json`),JSON.stringify({native:{version:1,entry,source:storageSource,parameters,workgroupSize}},null,2)+'\n');
