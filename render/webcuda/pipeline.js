import { kernelManifest } from './kernel-manifest.js';
import { boundedBatch } from './bounded-batch.js';
import { gpuTimedBatch } from './gpu-timing.js';
// Host-only allocation, uploads, dispatch and presentation. Rendering arithmetic
// lives in the authored .cu kernels; generated WGSL is loaded without alteration.
import { dispatchGroups } from './dispatch.js';
import { atlasUploadRanges } from './atlas-upload.js';
import { TextureResidency, mergeWordRanges } from './texture-residency.js';
import { colorStorage, depthStorage } from './color-storage.js';
import { allFinite, validateVertexAttributes } from './packet-validation.js';
import { terrainBlendInputRange } from './terrain-blend-inputs.js';
function validSampler(sampler) {
  if(!Number.isInteger(sampler)||sampler<0||sampler>0xffffffff)return false;
  if(((sampler&0x40000000)&&((sampler>>>9)&3))||((sampler&0x80000000)&&((sampler>>>11)&3)))return false;
  if(!(sampler&0x10000000))return (sampler&0x0fff0000)===0;
  for(let channel=0;channel<4;channel++)if(((sampler>>>(16+channel*3))&7)>5)return false;
  return true;
}
function textureBase(texels, base, sampler,wordCount=texels.length) {
  if(!Number.isInteger(base)||base<0||base>=wordCount)throw RangeError('Invalid texture base');
  if(!(sampler&0x20000000))return base;
  if(base+10>texels.length||texels[base+5]>55||(texels[base+5]&15)>7)throw RangeError('Invalid border descriptor');
  const border=new Float32Array(texels.buffer,texels.byteOffset+(base+1)*4,4);
  if(border.some(value=>!Number.isFinite(value)))throw RangeError('Non-finite texture border');
  const lod=new Float32Array(texels.buffer,texels.byteOffset+(base+6)*4,4);
  if(lod.some(value=>!Number.isFinite(value))||lod[0]>lod[1]||lod[3]<1)throw RangeError('Invalid sampler LOD range');
  const image=texels[base];
  if(image>=wordCount)throw RangeError('Invalid border image base');
  return image;
}

export class MaterialPipeline {
  static async create(runtime, onProgress=()=>{}) {
    const kernels = {};
    const total=kernelManifest.filter(entry=>entry.runtime).length;
    let completed=0;
    for (const {entry:name,runtime:load} of kernelManifest) {
      if(!load)continue;
      onProgress({name,completed,total});
      const response = await fetch(new URL(`generated/${name}${runtime.artifactSuffix??'.json'}`, import.meta.url));
      if (!response.ok) throw Error(`Missing kernel ${name}`);
      kernels[name] = await runtime.kernel(await response.json());
      completed++;
    }
    onProgress({name:null,completed,total});
    return new MaterialPipeline(runtime, kernels);
  }
  constructor(runtime, kernels) {
    this.runtime=runtime; this.kernels=kernels; this.buffers=new Map(); this.retired=new Set(); this.busy=false;
    this.textureResidency=new TextureResidency(runtime);
  }
  seedMultisample(source, samples, width, height, sampleCount) {
    this.validateMultisampleStorage(source,samples,width,height,sampleCount);
    this.runtime.batch().dispatch(this.kernels.seed_multisample.bind({source,samples},
      {pixel_count:width*height,sample_count:sampleCount}),dispatchGroups(width*height*sampleCount,this.runtime.device.limits)).submit();
  }
  resolveMultisample(samples, target, width, height, sampleCount, options={}) {
    this.validateMultisampleStorage(target,samples,width,height,sampleCount);
    const mask=options.mask??(16384|256|1024),depth_sample=options.depthSample??0;
    if(!Number.isInteger(mask)||mask<0||(mask&~(16384|256|1024))||!Number.isInteger(depth_sample)||depth_sample<0||depth_sample>=sampleCount)
      throw RangeError('Invalid multisample resolve selection');
    const {channels:color_channels,storage:color_storage}=colorStorage(options.colorFormat??0x8058);
    const depth_bits=depthStorage(options.depthFormat??0x81a6);
    const {channels:normal_channels,storage:normal_storage}=colorStorage(options.normalFormat??0x8058);
    this.runtime.batch().dispatch(this.kernels.resolve_multisample.bind({samples,target},
      {pixel_count:width*height,sample_count:sampleCount,mask,depth_sample,normal_enabled:options.normals?1:0,normal_channels,normal_storage,
       color_channels,color_storage,depth_bits,stencil_enabled:options.stencil?1:0}),
      dispatchGroups(width*height,this.runtime.device.limits)).submit();
  }
  validateMultisampleStorage(target,samples,width,height,sampleCount) {
    if(![width,height].every(value=>Number.isSafeInteger(value)&&value>0)||![1,2,4,8,16].includes(sampleCount))
      throw RangeError('Invalid multisample dimensions/count');
    const words=width*height*10*sampleCount,bytes=words*4;
    if(!Number.isSafeInteger(bytes)||words>0xffffffff||bytes>this.runtime.device.limits.maxStorageBufferBindingSize
      ||samples.byteLength<bytes||target.byteLength<width*height*40||samples===target||(samples.gpuBuffer&&samples.gpuBuffer===target.gpuBuffer))
      throw RangeError('Invalid multisample storage or feedback');
  }
  buffer(name, bytes, data) {
    const limit=Math.floor(Math.min(this.runtime.device.limits.maxStorageBufferBindingSize,
      this.runtime.device.limits.maxBufferSize)/4)*4;
    if(!Number.isSafeInteger(bytes)||bytes<0||bytes>limit||bytes%4)
      throw RangeError(`Invalid pipeline buffer size for ${name}`);
    if(data?.byteLength>bytes)throw RangeError(`Upload exceeds requested buffer size for ${name}`);
    const required=Math.max(4,bytes);
    let resource=this.buffers.get(name);
    if (!resource || resource.byteLength<required) {
      // Keep modest headroom for changing geometry/tile counts. The live data
      // length remains an explicit kernel/readback argument, not this capacity.
      const headroom=required>=4096?Math.ceil((required+Math.min(required/4,4*1024*1024))/256)*256:required;
      const capacity=Math.min(limit,headroom);
      // Native scratch growth retains shared prefix pages and a versioned
      // address table, avoiding a second complete atlas at the frame peak.
      // Reservation failure still leaves the existing resource owned and live.
      const options={label:`OpenMW ${name}`};
      const replacement=resource&&this.runtime.growBuffer
        ?this.runtime.growBuffer(resource,capacity,options):this.runtime.createBuffer(capacity,options);
      if (resource) this.retireBuffer(resource);
      resource=replacement;
      this.buffers.set(name,resource);
    }
    if (data?.byteLength) this.upload(resource,data);
    return resource;
  }
  upload(resource,data,offset=0) {
    const r=this.runtime;
    if(r.writeBorrowed&&typeof SharedArrayBuffer!=='undefined'&&data.buffer instanceof SharedArrayBuffer)
      r.writeBorrowed(resource,data,offset);
    else r.write(resource,data,offset);
  }
  releaseBuffer(name) {
    if(this.busy)throw Error('Cannot release an in-flight pipeline buffer');
    const resource=this.buffers.get(name);
    if(resource){this.retireBuffer(resource);this.buffers.delete(name);}
  }
  retireBuffer(resource) {
    if(resource)this.retired.add(resource);
  }
  // The caller must have completed the queue covering all retired resources.
  collectRetired() {
    for(const resource of this.retired)this.runtime.destroyBuffer(resource);
    this.retired.clear();
    this.textureResidency.collectRetired();
  }
  // Called by serialized pass submission. resourceKey separates camera/light
  // snapshots that must coexist until all consumers of the pass are queued.
  async prepareClusterLights(snapshot, resourceKey) {
    const r=this.runtime,k=this.kernels;
    if(typeof resourceKey!=='string'||!/^[A-Za-z0-9_.-]{1,64}$/.test(resourceKey))
      throw TypeError('Invalid cluster resource identity');
    const {projection,lights,gridSize,nearDistance,farDistance}=snapshot;
    if(!(projection instanceof Float32Array)||projection.length!==16||projection.some(v=>!Number.isFinite(v))
      ||projection[0]<=0||projection[5]<=0||Math.abs(projection[11]+1)>0.00001||Math.abs(projection[15])>0.00001)
      throw RangeError('Cluster lighting requires a finite perspective projection');
    if(!(lights instanceof Float32Array)||lights.length%20||lights.some(v=>!Number.isFinite(v)))
      throw RangeError('Invalid clustered PointLight records');
    for(let i=19;i<lights.length;i+=20)if(lights[i]<0)throw RangeError('Negative clustered light radius');
    if(!Array.isArray(gridSize)||gridSize.length!==3||!gridSize.every(v=>Number.isInteger(v)&&v>0)
      ||!Number.isFinite(nearDistance)||!Number.isFinite(farDistance)||nearDistance<=0||farDistance<=nearDistance)
      throw RangeError('Invalid logarithmic light grid');
    const clusterCount=gridSize[0]*gridSize[1]*gridSize[2],lightCount=lights.length/20;
    const maxBytes=Math.min(r.device.limits.maxBufferSize,r.device.limits.maxStorageBufferBindingSize);
    const fits=bytes=>Number.isSafeInteger(bytes)&&bytes>=0&&bytes<=maxBytes;
    if(!fits(clusterCount*32)||!fits(lights.byteLength)||clusterCount>0xffffffff||lightCount>0xffffffff)
      throw RangeError('Cluster lighting exceeds GPU buffer capacity');
    const prefix=`cluster.${resourceKey}.`;
    const projectionBuffer=this.buffer(prefix+'projection',64,projection);
    const lightBuffer=this.buffer(prefix+'lights',lights.byteLength,lights);
    const clusters=this.buffer(prefix+'bounds',clusterCount*32);
    const grid=this.buffer(prefix+'grid',clusterCount*8);
    const overflow=this.buffer(prefix+'overflow',clusterCount*4);
    const groups=dispatchGroups(clusterCount,r.device.limits);
    r.batch().dispatch(k.build_light_clusters.bind({projection:projectionBuffer,clusters},
      {grid_x:gridSize[0],grid_y:gridSize[1],grid_z:gridSize[2],near_distance:nearDistance,far_distance:farDistance}),groups).submit();
    let capacity=Math.max(1,Math.min(lightCount,64)),indices;
    for(;;) {
      if(clusterCount*capacity>0xffffffff||!fits(clusterCount*capacity*4))
        throw RangeError('Cluster light lists exceed GPU buffer capacity');
      indices=this.buffer(prefix+'indices',clusterCount*capacity*4);
      r.batch().dispatch(k.cull_cluster_lights.bind({clusters,lights:lightBuffer,grid,indices,overflow},
        {cluster_count:clusterCount,light_count:lightCount,capacity}),groups).submit();
      // The culler visits each source light exactly once. With room for the
      // whole snapshot, overflow is impossible and no sizing readback is needed.
      // Queue order still places the subsequent atlas copy after this dispatch.
      if(capacity>=lightCount)break;
      const required=await r.read(overflow,Uint32Array,clusterCount*4);
      let maximum=0;for(const count of required)maximum=Math.max(maximum,count);
      if(maximum===0)break;
      if(maximum<=capacity||maximum>lightCount)throw Error('Invalid cluster overflow count');
      capacity=maximum;
    }
    return {clusters,grid,indices,lights:lightBuffer,capacity,clusterCount,lightCount,
      gridSize:gridSize.slice(),nearDistance,farDistance};
  }
  async prepareClusterSnapshots(scene) {
    const records=scene.clusterRecords??new Uint32Array(),mapping=scene.clusterMaterials??new Uint32Array();
    const lights=scene.clusterLights??new Float32Array(),projections=scene.clusterProjections??new Float32Array();
    if(!(records instanceof Uint32Array)||records.length%10||!(mapping instanceof Uint32Array)||mapping.length%2
      ||!(lights instanceof Float32Array)||lights.length%20||!(projections instanceof Float32Array)||projections.length%16)
      throw RangeError('Invalid clustered snapshot transport');
    const values=new Float32Array(records.buffer,records.byteOffset,records.length);
    const snapshots=[];
    for(let i=0;i<records.length;i+=10) {
      const first=records[i],count=records[i+1],projection=records[i+7];
      if(first+count>lights.length/20||projection>=projections.length/16)
        throw RangeError('Clustered snapshot exceeds transported buffers');
      const screenSize=[values[i+8],values[i+9]];
      if(!screenSize.every(v=>Number.isFinite(v)&&v>0))throw RangeError('Invalid clustered screen size');
      snapshots.push({lights:lights.subarray(first*20,(first+count)*20),
        projection:projections.subarray(projection*16,(projection+1)*16),
        gridSize:[records[i+2],records[i+3],records[i+4]],nearDistance:values[i+5],farDistance:values[i+6],screenSize});
    }
    const materials=new Map(),prepared=new Map();
    // Validate every mapping before submitting GPU work.
    for(let i=0;i<mapping.length;i+=2) {
      const material=mapping[i],snapshot=mapping[i+1],m=material*12;
      if(m+12>scene.materials.length||snapshot>=snapshots.length||materials.has(material)
        ||!(scene.materials[m+3]&2048)||!(scene.texels[scene.materials[m]+4]&16777216))
        throw RangeError('Invalid material-to-cluster mapping');
      materials.set(material,snapshot);
    }
    for(let m=0;m<scene.materials.length;m+=12)
      if((scene.materials[m+3]&2048)&&(scene.texels[scene.materials[m]+4]&16777216)&&!materials.has(m/12))
        throw RangeError('Clustered material has no light snapshot');
    for(const [material,snapshot] of materials) {
      if(!prepared.has(snapshot)) {
        const resources=await this.prepareClusterLights(snapshots[snapshot],String(snapshot));
        prepared.set(snapshot,{...resources,screenSize:snapshots[snapshot].screenSize});
      }
      materials.set(material,prepared.get(snapshot));
    }
    return materials;
  }
  async uploadClusterAtlas(scene,texturePlan) {
    const resources=await this.prepareClusterSnapshots(scene),r=this.runtime;
    const texelWordCount=scene.texelWordCount??scene.texels.length;
    const upload=words=>{
      const ranges=atlasUploadRanges(scene.texels.length,scene.textureCopies,texelWordCount,texturePlan?.hitRanges);
      const texels=this.buffer('texels',words*4);
      for(const [first,last] of ranges)this.upload(texels,scene.texels.subarray(first,last),first*4);
      return texels;
    };
    if(resources.size===0)return {texels:upload(texelWordCount),cluster_offset:0};
    const cluster_offset=texelWordCount,table=new Uint32Array(scene.materials.length/12),layouts=new Map();
    let words=cluster_offset+table.length;
    for(const [material,resource] of resources) {
      if(!layouts.has(resource)) {
        const descriptor=words;words+=12;
        const grid=words;words+=resource.clusterCount*2;
        const indices=words;words+=resource.clusterCount*resource.capacity;
        const lights=words;words+=resource.lightCount*16;
        layouts.set(resource,{descriptor,grid,indices,lights});
      }
      table[material]=layouts.get(resource).descriptor;
    }
    if(!Number.isSafeInteger(words)||words>0xffffffff||words*4>Math.min(r.device.limits.maxBufferSize,r.device.limits.maxStorageBufferBindingSize))
      throw RangeError('Cluster atlas exceeds GPU buffer capacity');
    const texels=upload(words);
    r.write(texels,table,cluster_offset*4);
    const batch=boundedBatch(r);
    for(const [resource,layout] of layouts) {
      const descriptor=new Uint32Array(12),values=new Float32Array(descriptor.buffer);
      descriptor.set(resource.gridSize);values[3]=resource.nearDistance;values[4]=resource.farDistance;
      values[5]=resource.screenSize[0];values[6]=resource.screenSize[1];descriptor[7]=resource.lightCount;
      descriptor[8]=layout.grid;descriptor[9]=layout.indices;descriptor[10]=layout.lights;descriptor[11]=resource.capacity;
      r.write(texels,descriptor,layout.descriptor*4);
      batch.copy(resource.grid,texels,{targetOffset:layout.grid*4,byteLength:resource.clusterCount*8})
        .copy(resource.indices,texels,{targetOffset:layout.indices*4,byteLength:resource.clusterCount*resource.capacity*4});
      if(resource.lightCount)batch.dispatch(this.kernels.pack_cluster_lights.bind({source:resource.lights,target:texels},
        {light_count:resource.lightCount,destination:layout.lights}),dispatchGroups(resource.lightCount,r.device.limits));
    }
    batch.submit();return {texels,cluster_offset};
  }
  async render(scene, width, height, context=null, pass={}) {
    if (this.busy) return null; // Bounded submission: engine can drop a stale frame.
    this.busy=true;
    try {
      const r=this.runtime, k=this.kernels;
      const viewport=pass.viewport??[0,0,width,height];
      if(!Array.isArray(viewport)||viewport.length!==4||!viewport.every(Number.isSafeInteger)
        ||viewport[2]<=0||viewport[3]<=0||viewport.some(v=>Math.abs(v)>0x7fffffff))
        throw RangeError('Invalid camera viewport');
      const [viewport_x,viewport_y,viewport_width,viewport_height]=viewport;
      const viewportArgs={viewport_x,viewport_y,viewport_width,viewport_height};
      scene={...scene,compressedBlocks:scene.compressedBlocks??new Uint32Array(),textureDecodes:scene.textureDecodes??new Uint32Array()};
      if (![width,height].every(n=>Number.isInteger(n)&&n>0&&n<=r.device.limits.maxTextureDimension2D)) throw RangeError('Invalid target dimensions');
      const types={vertices:Float32Array,matrices:Float32Array,matrixIds:Uint32Array,triangles:Uint32Array,materials:Uint32Array,texels:Uint32Array,compressedBlocks:Uint32Array,textureDecodes:Uint32Array};
      for (const [name,Type] of Object.entries(types)) if (!(scene[name] instanceof Type)) throw TypeError(`Invalid ${name}`);
      scene.texelWordCount??=scene.texels.length;
      if(!Number.isSafeInteger(scene.texelWordCount)||scene.texelWordCount<scene.texels.length||scene.texelWordCount>0xffffffff)
        throw RangeError('Invalid GPU atlas extent');
      const baseOfTexture=(base,sampler)=>textureBase(scene.texels,base,sampler,scene.texelWordCount);
      const vertexCount=scene.vertices.length/10, triangleCount=scene.triangles.length/4;
      if (!Number.isInteger(vertexCount)||!Number.isInteger(triangleCount)||scene.matrices.length%32||scene.materials.length%12||scene.matrixIds.length!==vertexCount) throw RangeError('Invalid packet record sizes');
      scene.groundcoverRanges??=new Uint32Array();
      scene.groundcoverInstances??=new Float32Array();
      scene.groundcoverParams??=new Float32Array();
      if(!(scene.groundcoverRanges instanceof Uint32Array)||scene.groundcoverRanges.length%3
        ||!(scene.groundcoverInstances instanceof Float32Array)||scene.groundcoverInstances.length%7
        ||!(scene.groundcoverParams instanceof Float32Array)||scene.groundcoverParams.length%40
        ||!allFinite(scene.groundcoverInstances)||!allFinite(scene.groundcoverParams))
        throw RangeError('Invalid groundcover input');
      const groundcoverVertices=new Set();
      for(let i=0;i<scene.groundcoverRanges.length;i+=3) {
        const [vertex,instance,parameters]=scene.groundcoverRanges.subarray(i,i+3);
        if(vertex>=vertexCount||instance>=scene.groundcoverInstances.length/7||parameters>=scene.groundcoverParams.length/40
          ||groundcoverVertices.has(vertex))throw RangeError('Invalid groundcover range');
        groundcoverVertices.add(vertex);
      }
      for(let p=0;p<scene.groundcoverParams.length;p+=40) {
        const mode=scene.groundcoverParams[p+37],intensity=scene.groundcoverParams[p+38];
        if(![0,1,2].includes(mode)||![0,1,2].includes(intensity)||scene.groundcoverParams[p+39]<=0)
          throw RangeError('Invalid groundcover deformation settings');
      }
      scene.secondaryColors??=new Float32Array(vertexCount*3);
      if(!(scene.secondaryColors instanceof Float32Array)||scene.secondaryColors.length!==vertexCount*3
        ||!allFinite(scene.secondaryColors))throw RangeError('Invalid secondary color input');
      scene.textGradientRanges??=new Uint32Array();scene.textGradientColors??=new Float32Array();
      if(!(scene.textGradientRanges instanceof Uint32Array)||scene.textGradientRanges.length%3
        ||!(scene.textGradientColors instanceof Float32Array)||scene.textGradientColors.length%16||!allFinite(scene.textGradientColors))
        throw RangeError('Invalid text gradient data');
      let previousGradientEnd=0;
      for(let i=0;i<scene.textGradientRanges.length;i+=3) {
        const [first,count,color]=scene.textGradientRanges.subarray(i,i+3);
        if(first<previousGradientEnd||first+count>vertexCount||color>=scene.textGradientColors.length/16)throw RangeError('Invalid or overlapping text gradient range');
        previousGradientEnd=first+count;
      }
      scene.localTransforms??=new Float32Array(scene.matrices.length/32*35);
      if(!(scene.localTransforms instanceof Float32Array)||scene.localTransforms.length!==scene.matrices.length/32*35||!allFinite(scene.localTransforms))
        throw RangeError('Invalid drawable local transforms');
      for(let p=0;p<scene.localTransforms.length;p+=35) {
        const values=scene.localTransforms;
        if(![0,1,2].includes(values[p]))throw RangeError('Invalid local transform mode');
        if(values[p]===2) {
          const d=p+17;
          if(![0,1,2].includes(values[d])||![0,1].includes(values[d+1])||![0,1].includes(values[d+2])||values[d+4]===0||values[d+16]<=0||values[d+17]<=0)
            throw RangeError('Invalid camera-dependent text placement');
        }
      }
      scene.debugParams??=new Float32Array(scene.matrices.length/32*16);
      if(!(scene.debugParams instanceof Float32Array)||scene.debugParams.length!==scene.matrices.length/32*16||!allFinite(scene.debugParams))
        throw RangeError('Invalid debug shader parameters');
      for(let p=0;p<scene.debugParams.length;p+=16)if(![0,1,2,3,4].includes(scene.debugParams[p])||![0,1].includes(scene.debugParams[p+1]))
        throw RangeError('Invalid debug shader mode');
      scene.fixedLighting??=new Uint32Array(scene.matrices.length/32*368);
      if(!(scene.fixedLighting instanceof Uint32Array)||scene.fixedLighting.length!==scene.matrices.length/32*368)
        throw RangeError('Invalid fixed lighting descriptor count');
      let fixed_enabled=0;
      const fixedValues=new Float32Array(scene.fixedLighting.buffer,scene.fixedLighting.byteOffset,scene.fixedLighting.length);
      for(let d=0;d<scene.fixedLighting.length;d+=368) {
        if(scene.fixedLighting[d]>255||(scene.fixedLighting[d+1]&~191)||scene.fixedLighting[d+2]>5||scene.fixedLighting[d+3])
          throw RangeError('Invalid fixed lighting descriptor header');
        if(scene.fixedLighting[d+1]&160)fixed_enabled=1;
        for(let i=d+4;i<d+368;i++)if(!Number.isFinite(fixedValues[i]))throw RangeError('Non-finite fixed lighting state');
        for(const offset of [24,41])if(fixedValues[d+offset]<0||fixedValues[d+offset]>128)
          throw RangeError('Invalid fixed material shininess');
        for(let light=0;light<8;light++)if(scene.fixedLighting[d]&(1<<light)) {
          const l=d+48+light*40,cutoff=fixedValues[l+23],exponent=fixedValues[l+22];
          if(fixedValues[l+19]<0||fixedValues[l+20]<0||fixedValues[l+21]<0||exponent<0||exponent>128
            ||!((cutoff>=0&&cutoff<=90)||cutoff===180))throw RangeError('Invalid fixed light attenuation or spotlight');
        }
      }
      scene.polygonEdges??=new Uint32Array(triangleCount).fill(7);
      if(!(scene.polygonEdges instanceof Uint32Array)||scene.polygonEdges.length!==triangleCount
        ||scene.polygonEdges.some(mask=>mask>7))throw RangeError('Invalid polygon edge packet');
      scene.flatColors??=new Uint32Array(triangleCount).fill(0xffffffff);
      if(!(scene.flatColors instanceof Uint32Array)||scene.flatColors.length!==triangleCount
        ||scene.flatColors.some(vertex=>vertex!==0xffffffff&&vertex>=vertexCount))throw RangeError('Invalid provoking vertex packet');
      if (!allFinite(scene.vertices)||!allFinite(scene.matrices)) throw RangeError('Non-finite vertex or matrix');
      if (scene.matrixIds.some(v=>v>=scene.matrices.length/32)) throw RangeError('Invalid matrix index');
      if(scene.attributes==null) {
        scene.attributes=new Float32Array(vertexCount*34);
        for(let vertex=0;vertex<vertexCount;vertex++) {
          scene.attributes[vertex*34+16]=scene.vertices[vertex*10+8];
          scene.attributes[vertex*34+17]=scene.vertices[vertex*10+9];
          for(let unit=0;unit<4;unit++)scene.attributes[vertex*34+27+unit*2]=1;
        }
      }
      scene.texgen??=new Uint32Array(scene.matrices.length/32*144);
      if(!(scene.texgen instanceof Uint32Array)||scene.texgen.length!==scene.matrices.length/32*144)
        throw RangeError('Invalid texture generation packet');
      const texgenFloats=new Float32Array(scene.texgen.buffer,scene.texgen.byteOffset,scene.texgen.length);
      let hasTexgen=false;
      for(let offset=0;offset<scene.texgen.length;offset+=36) {
        const [mask,mode,flags,reserved]=scene.texgen.subarray(offset,offset+4);
        if(mask>15||mode>5||flags>3||reserved!==0||(mask&&!mode)||(mode===2&&(mask&12))||((mode===3||mode===4)&&(mask&8))
          ||!allFinite(texgenFloats,offset+4,offset+36))throw RangeError('Invalid texture generation descriptor');
        hasTexgen||=mask!==0;
      }
      scene.morphRanges??=new Uint32Array();scene.morphOffsets??=new Float32Array();
      if(!(scene.morphRanges instanceof Uint32Array)||scene.morphRanges.length%3||!(scene.morphOffsets instanceof Float32Array)
        ||scene.morphOffsets.length%4||!allFinite(scene.morphOffsets))throw RangeError('Invalid morph packet');
      const morphedVertices=new Set();
      scene.skinRanges??=new Uint32Array();scene.skinWeights??=new Uint32Array();scene.skinBones??=new Float32Array();scene.skinTransforms??=new Float32Array();
      for(const [name,Type,stride] of [['skinRanges',Uint32Array,4],['skinWeights',Uint32Array,2],['skinBones',Float32Array,32],['skinTransforms',Float32Array,32]])
        if(!(scene[name] instanceof Type)||scene[name].length%stride||!allFinite(scene[name]))throw RangeError(`Invalid ${name}`);
      const skinWeightFloats=new Float32Array(scene.skinWeights.buffer,scene.skinWeights.byteOffset,scene.skinWeights.length),skinnedVertices=new Set();
      for(let i=0;i<scene.skinWeights.length;i+=2)if(scene.skinWeights[i]>=scene.skinBones.length/32||!Number.isFinite(skinWeightFloats[i+1]))throw RangeError('Invalid skin influence');
      for(let i=0;i<scene.skinRanges.length;i+=4) {
        const [vertex,first,count,transform]=scene.skinRanges.subarray(i,i+4);
        if(vertex>=vertexCount||first+count>scene.skinWeights.length/2||transform>=scene.skinTransforms.length/32||skinnedVertices.has(vertex))throw RangeError('Invalid skin range');
        skinnedVertices.add(vertex);
      }
      for(let i=0;i<scene.morphRanges.length;i+=3) {
        const [vertex,first,count]=scene.morphRanges.subarray(i,i+3);
        if(vertex>=vertexCount||first+count>scene.morphOffsets.length/4||morphedVertices.has(vertex))throw RangeError('Invalid or overlapping morph range');
        morphedVertices.add(vertex);
      }
      const attributeFlags=validateVertexAttributes(scene.attributes,vertexCount);
      if(!scene.rasterParams) {
        scene.rasterParams=new Float32Array(scene.materials.length/12*50);
        for(let i=0;i<scene.rasterParams.length;i+=50) {
          scene.rasterParams[i+3]=1;
          scene.rasterParams[i+37]=1;scene.rasterParams[i+38]=1;
          scene.rasterParams.set([0,64,1,1,0,0],i+43);
          scene.rasterParams[i+24]=1;
          scene.rasterParams[i+26]=65535;
          scene.rasterParams[i+27]=1;
          for(const face of [8,15])scene.rasterParams.set([7,0,255,255,0,0,0],i+face);
        }
      }
      // Word 23 is an opaque uint atlas address, not a floating-point value.
      // Validate its range below through the integer view when fog is enabled.
      if(!(scene.rasterParams instanceof Float32Array)||scene.rasterParams.length!==scene.materials.length/12*50||scene.rasterParams.some((v,index)=>index%50!==23&&!Number.isFinite(v)))
        throw RangeError('Invalid raster parameters');
      if(scene.uvMatrices && (!(scene.uvMatrices instanceof Float32Array)||scene.uvMatrices.length!==scene.matrices.length/2||!allFinite(scene.uvMatrices)))
        throw RangeError('Invalid UV matrices');
      for (let t=0;t<triangleCount;t++) {
        for (let c=0;c<3;c++) if (scene.triangles[t*4+c]>=vertexCount) throw RangeError('Invalid vertex index');
        if (scene.triangles[t*4+3]>=scene.materials.length/12) throw RangeError('Invalid material index');
      }
      for (let m=0;m<scene.materials.length;m+=12) {
        const a=scene.materials;
        if(scene.rasterParams[m/12*50+37]<=0||scene.rasterParams[m/12*50+38]<=0)throw RangeError('Invalid polygon size');
        const pointBase=m/12*50;
        const pointFlags=scene.rasterParams[pointBase+49];
        if(!Number.isInteger(pointFlags)||pointFlags<0||pointFlags>255||((pointFlags&2)===0&&(pointFlags&124)!==0))throw RangeError('Invalid polygon point flags');
        if(scene.rasterParams.subarray(pointBase+43,pointBase+49).some(value=>value<0)
          ||scene.rasterParams[pointBase+44]<scene.rasterParams[pointBase+43])throw RangeError('Invalid polygon point parameters');
        const sampleMask=scene.rasterParams[m/12*50+26],multisample=scene.rasterParams[m/12*50+27];
        if(!Number.isInteger(sampleMask)||sampleMask<0||sampleMask>65535||(multisample!==0&&multisample!==1))throw RangeError('Invalid multisample controls');
        const coverage=scene.rasterParams[m/12*50+24],invertCoverage=scene.rasterParams[m/12*50+25];
        if(coverage<0||coverage>1||(invertCoverage!==0&&invertCoverage!==1))throw RangeError('Invalid sample coverage parameters');
        const normalMask=scene.rasterParams[m/12*50+22];
        if(a[m+3]&32768) {
          const pointer=new Uint32Array(scene.rasterParams.buffer,scene.rasterParams.byteOffset,scene.rasterParams.length)[m/12*50+23];
          if(pointer+8>scene.texels.length||scene.texels[pointer]>30||(scene.texels[pointer]&3)>2||(a[m+3]&7168))
            throw RangeError('Invalid fixed-function fog descriptor');
          if(scene.texels[pointer]&16) {
            if(!(scene.texels[pointer]&8)||pointer+9>scene.texels.length)throw RangeError('Invalid constant fog descriptor');
            const coordinate=new Float32Array(scene.texels.buffer,scene.texels.byteOffset+(pointer+8)*4,1)[0];
            if(!Number.isFinite(coordinate))throw RangeError('Invalid constant fog coordinate');
          }
          const values=new Float32Array(scene.texels.buffer,scene.texels.byteOffset+(pointer+1)*4,7);
          if(values.some(value=>!Number.isFinite(value))||values[0]<0||values.subarray(3).some(value=>value<0||value>1))
            throw RangeError('Invalid fixed-function fog parameters');
        }
        if(!Number.isInteger(normalMask)||normalMask<0||normalMask>15)throw RangeError('Invalid normal attachment mask');
        if(a[m+3]&8192)for(const face of [8,15]) {
          const base=m/12*50+face;
          for(let field=0;field<7;field++) {
            const value=scene.rasterParams[base+field],maximum=field===0||field>=4?7:255;
            if(!Number.isInteger(value)||value<0||value>maximum)throw RangeError('Invalid stencil material parameters');
          }
        }
        const sky=Boolean(a[m+3]&1024);
        const object=Boolean(a[m+3]&2048);
        const shadow=Boolean(a[m+3]&4096);
        const environment=Boolean(a[m+3]&16384);
        if(Number(sky)+Number(object)+Number(shadow)+Number(environment)>1)throw RangeError('Conflicting material domains');
        if(environment) {
          if(!(a[m+3]&1)||!(a[m+3]&512)||!a[m])throw RangeError('Invalid texture environment flags');
          const stages=[];let data=a[m],previousUnit=-1,enabled=0;
          while(data) {
            if(stages.length===4||data+44>scene.texels.length||scene.texels[data+1]>5||scene.texels[data+2]>3)
              throw RangeError('Invalid texture environment chain');
            const unit=scene.texels[data+27],sampler=scene.texels[data+26];
            let w=scene.texels[data+24],h=scene.texels[data+25],size=0;
            if(unit>3||unit<=previousUnit||!w||!h||!validSampler(sampler)||((sampler>>5)&7)>5||(sampler&31)>15)
              throw RangeError('Invalid fixed-function texture stage');
            const base=baseOfTexture(scene.texels[data],sampler);
            for(let level=0;level<=(sampler&31);level++){size+=w*h*((sampler&32768)?4:1);w=Math.max(1,w>>1);h=Math.max(1,h>>1);}
            if(base+size>scene.texelWordCount)throw RangeError('Fixed-function texture exceeds atlas');
            if(stages.length===0&&(a[m+1]!==scene.texels[data+24]||a[m+2]!==scene.texels[data+25]||a[m+11]!==sampler))
              throw RangeError('First texture stage does not match material');
            const constants=new Float32Array(scene.texels.buffer,scene.texels.byteOffset+(data+4)*4,4);
            const matrix=new Float32Array(scene.texels.buffer,scene.texels.byteOffset+(data+28)*4,16);
            if(constants.some(value=>!Number.isFinite(value)||value<0||value>1)||matrix.some(value=>!Number.isFinite(value)))
              throw RangeError('Invalid texture environment color or matrix');
            stages.push(data);enabled|=1<<unit;previousUnit=unit;data=scene.texels[data+3];
          }
          for(const data of stages)if(scene.texels[data+1]===5) {
            if(scene.texels[data+8]>7||scene.texels[data+9]>5||![1,2,4].includes(scene.texels[data+10])||![1,2,4].includes(scene.texels[data+11]))
              throw RangeError('Invalid texture combine operation or scale');
            for(let arg=0;arg<3;arg++) {
              for(const source of [scene.texels[data+12+arg],scene.texels[data+18+arg]])
                if(source>7||(source>=4&&!(enabled&(1<<(source-4)))))throw RangeError('Texture combiner references an unavailable unit');
              if(scene.texels[data+15+arg]>3||scene.texels[data+21+arg]<2||scene.texels[data+21+arg]>3)
                throw RangeError('Invalid texture combine operand');
            }
          }
        }
        if(shadow&&(a[m]+10>scene.texels.length||scene.texels[a[m]+8]>7))throw RangeError('Invalid shadow material');
        if(sky&&(a[m]+30>scene.texels.length||![0,1,2,3,4,5,6].includes(scene.texels[a[m]+8])))throw RangeError('Invalid sky material');
        if(sky&&scene.texels[a[m]+8]===5&&!scene.texels[a[m]+9])throw RangeError('Missing sky query identity');
        if(object) {
          const data=a[m];
          if(data+352>scene.texels.length||scene.texels[data+6]>1024||scene.texels[data+7]!==352||data+352+scene.texels[data+6]*16>scene.texels.length||scene.texels[data+5]>5||scene.texels[data+51]>7)
            throw RangeError('Invalid object lighting payload');
          if((scene.texels[data+4]&8388608)&&((scene.texels[data+4]&(2097152|16384|8192))||(scene.texels[data+72]&48)))
            throw RangeError('Vertex lighting conflicts with per-pixel or unlit material features');
          if(scene.texels[data+4]&1073741824) {
            if(!(scene.texels[data+4]&536870912))throw RangeError('Tree alpha requires Bethesda material');
          }
          if(scene.texels[data+4]&536870912) {
            if((scene.texels[data+4]&(268435456|8388608|67108864|2097152|16384))
              ||(scene.texels[data+72]&~(8|16|64)))throw RangeError('Conflicting Bethesda material features');
          }
          if(scene.texels[data+4]&268435456) {
            // The unlit family reserves the disabled dark-map descriptor for falloff.
            const values=new Float32Array(scene.texels.buffer,scene.texels.byteOffset,scene.texels.length);
            if(scene.texels[data+80]>1||(scene.texels[data+72]&1)
              ||[81,82,83,84].some(offset=>!Number.isFinite(values[data+offset])))
              throw RangeError('Invalid unlit falloff payload');
          }
          if(scene.texels[data+4]&67108864) {
            const values=new Float32Array(scene.texels.buffer,scene.texels.byteOffset,scene.texels.length);
            if(!Number.isFinite(values[data+320])||!Number.isFinite(values[data+321])
              ||values[data+320]<0||values[data+321]<=values[data+320])throw RangeError('Invalid groundcover fade');
          }
          const cascadeCount=scene.texels[data+324],cascadeStart=scene.texels[data+325];
          if(scene.texels[data+4]&2097152) {
            const water=data+scene.texels[data+321];
            const expected=352+scene.texels[data+6]*16+cascadeCount*40+((scene.texels[data+4]&6029312)?48:0);
            if(scene.texels[data+321]!==expected||water+96>scene.texels.length||scene.texels[water+24]>15||scene.texels[water+28]>2)throw RangeError('Invalid water payload');
            for(const offset of [0,4,16,...(scene.texels[water+24]&1?[8,12]:[])]) {
              const t=water+offset,sampler=scene.texels[t+3],base=baseOfTexture(scene.texels[t],sampler);let w=scene.texels[t+1],h=scene.texels[t+2],size=0;
              if(!w||!h||!validSampler(sampler)||((sampler>>5)&7)>5||(sampler&31)>15||(offset===12&&!(sampler&8192)))throw RangeError('Invalid water texture');
              for(let level=0;level<=(sampler&31);level++){size+=w*h*((sampler&32768)?4:1);w=Math.max(1,w>>1);h=Math.max(1,h>>1);}
              if(base+size>scene.texelWordCount)throw RangeError('Water texture exceeds atlas');
            }
          }
          const particleFlags=scene.texels[data+4]&6029312;
          if(particleFlags) {
            const particle=data+scene.texels[data+79];
            if(scene.texels[data+79]!==352+scene.texels[data+6]*16+cascadeCount*40||particle+48>scene.texels.length)throw RangeError('Invalid screen effect payload');
            for(const offset of [...(particleFlags&262144?[0]:[]),...(particleFlags&524288?[12]:[]),...(particleFlags&1048576?[32]:[]),...(particleFlags&4194304?[40]:[])]) {
              const t=particle+offset,w=scene.texels[t+1],h=scene.texels[t+2],sampler=scene.texels[t+3],base=baseOfTexture(scene.texels[t],sampler);
              if(!w||!h||base+w*h*((sampler&32768)?4:1)>scene.texelWordCount||!validSampler(sampler)||((sampler>>5)&7)>5||((offset<32||offset===40)&&!(sampler&8192)))throw RangeError('Invalid screen effect texture');
            }
          }
          if(cascadeCount>32||(cascadeCount&&(cascadeStart!==352+scene.texels[data+6]*16||data+cascadeStart+cascadeCount*40>scene.texels.length)))
            throw RangeError('Invalid shadow cascade payload');
          for(let cascade=0;cascade<cascadeCount;cascade++) {
            const s=data+cascadeStart+cascade*40,w=scene.texels[s+1],h=scene.texels[s+2],sampler=scene.texels[s+3],base=baseOfTexture(scene.texels[s],sampler);
            if(!w||!h||!(sampler&8192)||(sampler&32768)||!validSampler(sampler)||(sampler&31)>15||((sampler>>5)&7)>5
              ||scene.texels[s+4]>7||scene.texels[s+5]>15||scene.texels[s+7]>2)throw RangeError('Invalid shadow cascade texture');
            let depthWords=0,mipWidth=w,mipHeight=h;
            for(let level=0;level<=(sampler&31);level++){depthWords+=mipWidth*mipHeight;mipWidth=Math.max(1,mipWidth>>1);mipHeight=Math.max(1,mipHeight>>1);}
            if(base+depthWords>scene.texelWordCount)throw RangeError('Shadow mip chain exceeds atlas');
          }
          if(scene.texels[data+72]>2047)throw RangeError('Invalid object layer flags');
          for(let layer=0;layer<11;layer++)if(scene.texels[data+72]&(1<<layer)) {
            const offset=data+(layer===10?328:80+layer*24),sampler=scene.texels[offset+3],base=baseOfTexture(scene.texels[offset],sampler);
            let w=scene.texels[offset+1],h=scene.texels[offset+2],size=0;
            if(!w||!h||scene.texels[offset+4]>3||!validSampler(sampler)||(sampler&31)>15||((sampler>>5)&7)>5)
              throw RangeError('Invalid object layer descriptor');
            for(let level=0;level<=(sampler&31);level++){size+=w*h*((sampler&32768)?4:1);w=Math.max(1,w>>1);h=Math.max(1,h>>1);}
            if(base+size>scene.texelWordCount)throw RangeError('Invalid object layer mip range');
          }
        }
        const rawBase=sky||object||shadow||environment?scene.texels[a[m]]:a[m];
        const base=(a[m+3]&1)?baseOfTexture(rawBase,a[m+11]):rawBase;
        if ((a[m+3]&1) && (!a[m+1]||!a[m+2]||base+a[m+1]*a[m+2]>scene.texelWordCount)) throw RangeError('Invalid texture atlas range');
        if (a[m+3]&~16777215) throw RangeError('Unsupported material flags');
        if(a[m+3]&524288) {
          const r=m/12*50,shadow=scene.rasterParams[r+30];
          if(![0,1,2].includes(shadow)||scene.rasterParams[r+28]<=0||scene.rasterParams[r+29]<=0)throw RangeError('Invalid glyph backdrop parameters');
        }
        if((a[m+3]&2097152)&&(!(a[m+3]&524288)||scene.rasterParams[m/12*50+28]<=0||scene.rasterParams[m/12*50+29]<=0))throw RangeError('Invalid distance-field glyph parameters');
        if((a[m+3]&1048576)&&!(a[m+3]&524288))throw RangeError('Glyph channel without glyph material');
        if((a[m+3]&524288)&&(!(a[m+3]&1)||(a[m+3]&23552)))throw RangeError('Invalid glyph material domain');
        if(a[m+3]&512) {
          const sampler=a[m+11],last=sampler&31;
          if(!validSampler(sampler)||((sampler>>5)&7)>5||last>15)
            throw RangeError('Unsupported sampler descriptor');
          let size=0,w=a[m+1],h=a[m+2];
          for(let level=0;level<=last;level++){size+=w*h*((sampler&32768)?4:1);w=Math.max(1,w>>1);h=Math.max(1,h>>1);}
          if(base+size>scene.texelWordCount)throw RangeError('Invalid texture mip chain');
        }
        if(sky&&scene.texels[a[m]+8]===3) {
          const data=a[m],sampler=scene.texels[data+7],maskBase=baseOfTexture(scene.texels[data+4],sampler);
          let w=scene.texels[data+5],h=scene.texels[data+6],size=0;
          if(!w||!h||!validSampler(sampler)||(sampler&31)>15)throw RangeError('Invalid moon mask');
          for(let level=0;level<=(sampler&31);level++){size+=w*h*((sampler&32768)?4:1);w=Math.max(1,w>>1);h=Math.max(1,h>>1);}
          if(maskBase+size>scene.texelWordCount)throw RangeError('Invalid moon mask mip range');
        }
        if (a[m+3]&128) {
          const control=a[m+9], factors=a[m+10];
          if ((control&15)>7||((control>>4)&15)>7||((control>>8)&7)>4||((control>>11)&7)>4||control>2147483647||((control>>>27)&3)>2||((control>>>29)&3)>2||factors>65535)
            throw RangeError('Invalid material comparison or blend equation');
          for(let shift=0;shift<16;shift+=4)if(((factors>>shift)&15)>14)throw RangeError('Invalid blend factor');
        }
      }
      const upload=name=>this.buffer(name,scene[name].byteLength,scene[name]);
      if(scene.textureDecodes.length%5)throw RangeError('Invalid texture decode records');
      const texturePlan=this.textureResidency.plan(scene.textureResources??new Uint32Array(),scene.texels.length);
      const decodePlans=[];
      const validatedMapInputs=new Map();
      const validatedTerrainInputs=new Map();
      for(let i=0;i<scene.textureDecodes.length;i+=5) {
        const [offset,destination,w,h,packedFormat]=scene.textureDecodes.subarray(i,i+5);
        const recordDecode=(words,pixels)=>decodePlans.push({offset,words,cached:texturePlan.isResident(destination,pixels)});
        if(packedFormat===259) {
          if(destination+w*h>scene.texels.length)throw RangeError('Invalid terrain blend destination');
          const range=terrainBlendInputRange(scene.compressedBlocks,offset,w,h,validatedTerrainInputs);
          decodePlans.push({...range,cached:texturePlan.isResident(destination,w*h)});
          continue;
        }
        if(packedFormat===258) {
          const count=scene.compressedBlocks[offset],end=offset+1+w*h+count*3;
          if(!w||!h||!Number.isSafeInteger(end)||end>scene.compressedBlocks.length||destination+w*h>scene.texels.length)throw RangeError('Invalid fog texture inputs');
          const brushes=new Float32Array(scene.compressedBlocks.buffer,scene.compressedBlocks.byteOffset+(offset+1+w*h)*4,count*3);
          if(brushes.some((value,index)=>!Number.isFinite(value)||(index%3===2&&value<=0)))throw RangeError('Invalid fog brush');
          recordDecode(end-offset,w*h);
          continue;
        }
        if(packedFormat===256||packedFormat===257) {
          const [cx,cy,cell]=scene.compressedBlocks.subarray(offset,offset+3);
          if(!cx||!cy||!cell||cx*cell!==w||cy*cell!==h||offset+1027+cx*cy*81>scene.compressedBlocks.length||destination+w*h>scene.texels.length)
            throw RangeError('Invalid map generation inputs');
          const signature=`${cx}:${cy}:${cell}`;
          if(validatedMapInputs.has(offset)&&validatedMapInputs.get(offset)!==signature)throw RangeError('Inconsistent map inputs');
          if(!validatedMapInputs.has(offset)) {
            const palette=new Float32Array(scene.compressedBlocks.buffer,scene.compressedBlocks.byteOffset+(offset+3)*4,1024);
            if(palette.some(value=>!Number.isFinite(value)))throw RangeError('Non-finite map palette');
            if(scene.compressedBlocks.subarray(offset+1027,offset+1027+cx*cy*81).some(value=>value>255))throw RangeError('Invalid map land sample');
            validatedMapInputs.set(offset,signature);
          }
          recordDecode(1027+cx*cy*81,w*h);
          continue;
        }
        const format=packedFormat&255,converted=Boolean(packedFormat&65536),destinationKind=(packedFormat>>>8)&15,storage=(packedFormat>>>12)&7;
        if((packedFormat&~0x17fff)!==0||(converted&&(destinationKind<1||destinationKind>9||storage>6||(destinationKind===9&&storage>2)||(storage===3&&![3,4].includes(destinationKind))))||(!converted&&packedFormat!==format))
          throw RangeError('Invalid image storage conversion');
        const family=Math.floor(format/16),kind=format%16;
        const floating=family<=15&&kind>=6&&kind<=14;
        const depthImage=converted&&destinationKind===9;
        if(depthImage&&(!floating||kind!==9||family>=8))throw RangeError('Invalid depth image source');
        if(family>=8&&((family<=9&&![7,14].includes(kind))||(family>=10&&![6,13].includes(kind))))
          throw RangeError('Packed image type does not match pixel layout');
        if(converted&&!floating&&(![1,2,3,5].includes(format)||storage!==3||destinationKind!==(format===2?3:4)))
          throw RangeError('Invalid compressed sRGB conversion');
        const channels=[6,13].includes(kind)?4:[7,14].includes(kind)?3:[8,11].includes(kind)?2:1;
        const words=floating?Math.ceil(w*h*(family>=8?(family<14?2:4):channels*[4,2,1,2,1,2,4,4][family])/4):Math.ceil(w/4)*Math.ceil(h/4)*(format<=2?2:4);
        if(!w||!h||(!floating&&![1,2,3,5].includes(format))||offset+words>scene.compressedBlocks.length||destination+w*h*((floating||converted)&&!depthImage?4:1)>scene.texels.length)
          throw RangeError('Invalid compressed texture range');
        recordDecode(words,w*h*((floating||converted)&&!depthImage?4:1));
      }
      const source=upload('vertices'), matrices=upload('matrices'), matrix_ids=upload('matrixIds');
      const triangles=upload('triangles'), materials=upload('materials'), flat_colors=upload('flatColors'), polygon_edges=upload('polygonEdges');
      const {texels,cluster_offset}=await this.uploadClusterAtlas(scene,texturePlan);
      this.textureResidency.restore(texturePlan,texels);
      const slots=triangleCount*7, tiles=Math.ceil(width/16)*Math.ceil(height/16), row_pixels=Math.ceil(width/64)*64;
      const transformed=this.buffer('transformed',vertexCount*40);
      const sourceAttributes=upload('attributes');
      let hasVertexLighting=false;
      for(let m=0;m<scene.materials.length;m+=12)
        if((scene.materials[m+3]&2048)&&(scene.texels[scene.materials[m]+4]&8388608))hasVertexLighting=true;
      let hasUnlit=false;
      for(let m=0;m<scene.materials.length;m+=12)if((scene.materials[m+3]&2048)&&(scene.texels[scene.materials[m]+4]&(268435456|536870912)))hasUnlit=true;
      const track_world_particles=(hasVertexLighting||hasUnlit)&&((scene.ribbonRanges?.length??0)>0
        ||attributeFlags.projectedParticles)?1:0;
      const world_particle_offset=vertexCount*34;
      const source_point_fade_offset=world_particle_offset+(track_world_particles?vertexCount*24:0);
      const transformedAttributes=this.buffer('transformedAttributes',(source_point_fade_offset+vertexCount*12)*4);
      const track_lighting=(hasVertexLighting||hasUnlit)&&scene.screenPrimitives.length?1:0;
      const lightingOrigins=this.buffer('lightingOrigins',track_lighting?vertexCount*12:4);
      const lighting_offset=slots*3*34;
      const fixed_offset=lighting_offset+(hasVertexLighting?slots*3*12:0);
      const falloff_offset=fixed_offset+(fixed_enabled?slots*3*16:0);
      const boundary_offset=falloff_offset+(hasUnlit?slots*3*4:0);
      const point_fade_offset=boundary_offset+slots*3;
      const raster_offset=point_fade_offset+slots*36;
      const fixedLighting=this.buffer('fixedLightingValues',fixed_enabled?vertexCount*64:4);
      const capture_endpoints=fixed_enabled&&((scene.ribbonRanges?.length??0)>0||attributeFlags.lineParticles)?1:0;
      const fixedEndpoints=this.buffer('fixedLightingEndpoints',capture_endpoints?vertexCount*128:4);
      const clippedAttributes=this.buffer('clippedAttributes',raster_offset*4+scene.rasterParams.byteLength);
      this.upload(clippedAttributes,scene.rasterParams,raster_offset*4);
      const positions=this.buffer('positions',slots*48), weights=this.buffer('weights',slots*48), valid=this.buffer('valid',slots*4);
      const vertices=this.buffer('clippedVertices',slots*120), output_triangles=this.buffer('clippedTriangles',slots*16);
      const targetBytes=width*height*(pass.compactDepth?4:40);
      if(pass.compactDepth&&((pass.sampleCount??1)!==1||pass.normalTargetId||pass.stencilTargetId||(pass.stencilBits??0)||[0x88f0,0x8cad].includes(pass.depthFormat)||!pass.deferCompletion||context))throw Error('Invalid compact depth camera');
      const counts=this.buffer('counts',(tiles+1+scene.materials.length/12)*4,new Uint32Array(tiles+1+scene.materials.length/12)), target=pass.target??this.buffer('target',targetBytes);
      const pixels=(!pass.deferCompletion||context)?this.buffer('pixels',row_pixels*height*4):null;
      if(target.byteLength<targetBytes)throw RangeError('Camera target buffer is too small');
      const sample_count=pass.sampleCount??1;
      if(![1,2,4,8,16].includes(sample_count))throw RangeError('Invalid raster sample count');
      const rasterTarget=sample_count===1?target:pass.sampleTarget;
      if(sample_count!==1) {
        if(!rasterTarget)throw RangeError('Multisample pass has no persistent sample target');
        this.validateMultisampleStorage(target,rasterTarget,width,height,sample_count);
      }
      const groups=n=>dispatchGroups(n,r.device.limits);
      const blocks=this.buffer('compressedBlocks',scene.compressedBlocks.byteLength);
      for(const [first,last] of mergeWordRanges(decodePlans.filter(plan=>!plan.cached).map(plan=>[plan.offset,plan.offset+plan.words]),scene.compressedBlocks.length))
        this.upload(blocks,scene.compressedBlocks.subarray(first,last),first*4);
      const decodeBatch=boundedBatch(r),floatMipOffsets=new Set(),floatMipStorage=new Map(),depthMipStorage=new Map();
      for(let i=0;i<scene.textureDecodes.length;i+=5) {
        const [block_offset,pixel_offset,w,h,format]=scene.textureDecodes.subarray(i,i+5);
        if(format===259) {
          if(!decodePlans[i/5].cached)decodeBatch.dispatch(k.generate_terrain_blendmap.bind({blocks,pixels:texels},
            {width:w,height:h,block_offset,pixel_offset}),groups(w*h));
          continue;
        }
        if(format===258) {
          if(!decodePlans[i/5].cached)decodeBatch.dispatch(k.generate_fog_map.bind({blocks,pixels:texels},{width:w,height:h,block_offset,pixel_offset}),groups(w*h));
          continue;
        }
        if(format===256||format===257) {
          if(!decodePlans[i/5].cached)decodeBatch.dispatch(k.generate_map.bind({blocks,pixels:texels},{width:w,height:h,block_offset,pixel_offset,alpha_only:format===257?1:0}),groups(w*h));
          continue;
        }
        const floating=(format&255)>=6;
        if((format&65536)&&((format>>>8)&15)===9) {
          const storage=(format>>>12)&7;
          depthMipStorage.set(pixel_offset,storage===1?16:storage===2?24:0);
        } else if(floating||(format&65536)) {
          floatMipOffsets.add(pixel_offset);
          floatMipStorage.set(pixel_offset,format&65536?{channels:Math.min(4,(format>>>8)&15),storage:(format>>>12)&7}:{channels:4,storage:2});
        }
        if(!decodePlans[i/5].cached)decodeBatch.dispatch((floating?k.decode_float_image:k.decode_dxt).bind({blocks,pixels:texels},
          {width:w,height:h,format,block_offset,pixel_offset}),groups(floating?w*h:Math.ceil(w/4)*Math.ceil(h/4)));
      }
      decodeBatch.submit();
      r.batch().dispatch(k.resolve_camera.bind({texels,materials,status:counts},
        {material_count:scene.materials.length/12,status_index:tiles}),groups(scene.materials.length/12)).submit();
      const copies=scene.textureCopies??new Uint32Array();
      if(!(copies instanceof Uint32Array)||copies.length%4)throw RangeError('Invalid render texture references');
      const depthSources=scene.depthMipSources??new Uint32Array();
      if(!(depthSources instanceof Uint32Array)||depthSources.length%2)throw RangeError('Invalid depth mip metadata');
      for(let i=0;i<depthSources.length;i+=2) {
        const offset=depthSources[i],bits=depthSources[i+1];
        if(![0,16,24].includes(bits)||depthMipStorage.has(offset))throw RangeError('Invalid depth mip storage');
        let matched=false;
        for(let c=0;c<copies.length;c+=4)if(copies[c+1]===offset&&(copies[c]&0x80000000)){matched=true;break;}
        if(!matched)throw RangeError('Depth mip source has no depth attachment copy');
        depthMipStorage.set(offset,bits);
      }
      for(let i=0;i<copies.length;i+=4) {
        const [id,offset,w,h]=copies.subarray(i,i+4), attachment=pass.targets?.get(id);
        const floatColor=(id&0x20000000)!==0;
        if((id&0x80000000)&&(!depthMipStorage.has(offset)||floatColor))throw RangeError("Missing or conflicting depth texture storage metadata");
        if(floatColor){floatMipOffsets.add(offset);floatMipStorage.set(offset,colorStorage(((id&0x40000000)!==0?attachment?.normalFormat:attachment?.colorFormat)??0x8814));}
        if(!attachment||attachment.width!==w||attachment.height!==h||offset+w*h*(floatColor?4:1)>scene.texelWordCount)
          throw Error(`Unavailable render texture ${id}`);
        if(attachment.buffer===target)throw Error('Camera reads its own attachment');
        r.batch().dispatch(((id&0x80000000)!==0?(attachment.compactDepth?k.compact_depth_to_texture:k.depth_to_texture):(id&0x40000000)!==0?(floatColor?k.float_normals_to_texture:k.normals_to_texture):floatColor?k.float_target_to_texture:k.target_to_texture).bind({target:attachment.buffer,texels},
          {width:w,height:h,offset}),groups(w*h)).submit();
      }
      const mips=scene.mipGenerations??new Uint32Array();
      if(!(mips instanceof Uint32Array)||mips.length%4)throw RangeError('Invalid mip generation records');
      for(let i=0;i<mips.length;i+=4) {
        const [source,destination,w,h]=mips.subarray(i,i+4),dw=Math.max(1,Math.floor(w/2)),dh=Math.max(1,Math.floor(h/2));
        const stride=floatMipOffsets.has(source)?4:1;
        if(!w||!h||source+w*h*stride>scene.texelWordCount||destination+dw*dh*stride>scene.texelWordCount||destination<source+w*h*stride)
          throw RangeError('Invalid mip generation range');
        const cached=texturePlan.isResident(destination,dw*dh*stride);
        if(cached!==texturePlan.isResident(source,w*h*stride))throw RangeError('Mip chain crosses resident image boundary');
        if(depthMipStorage.has(source)) {
          if(stride!==1)throw RangeError('Conflicting depth/color mip storage');
          const depth_bits=depthMipStorage.get(source);depthMipStorage.set(destination,depth_bits);
          if(!cached)r.batch().dispatch(k.generate_depth_mip.bind({texels},{source,destination,width:w,height:h,depth_bits}),groups(dw*dh)).submit();
        } else if(stride===4) {
          const storage=floatMipStorage.get(source)??{channels:4,storage:2};
          floatMipOffsets.add(destination);floatMipStorage.set(destination,storage);
          if(!cached)r.batch().dispatch(k.generate_float_mip.bind({texels},{source,destination,width:w,height:h,
            color_channels:storage.channels,color_storage:storage.storage}),groups(dw*dh)).submit();
        } else if(!cached)r.batch().dispatch(k.generate_mip.bind({texels},{source,destination,width:w,height:h}),groups(dw*dh)).submit();
      }
      this.textureResidency.capture(texturePlan,texels);
      scene.ribbonRanges??=new Uint32Array();scene.ribbonParticles??=new Float32Array();
      if(!(scene.ribbonRanges instanceof Uint32Array)||scene.ribbonRanges.length%13
        ||!(scene.ribbonParticles instanceof Float32Array)||scene.ribbonParticles.length%10||!allFinite(scene.ribbonParticles))
        throw RangeError('Invalid ribbon packet');
      const ribbonVertices=new Set(),ribbonTriangles=new Set();
      for(let offset=0;offset<scene.ribbonRanges.length;offset+=13) {
        const range=scene.ribbonRanges.subarray(offset,offset+13);
        const [first,count,base,triangle,matrix,max_skip,material,line_material]=range;
        const values=new Float32Array(range.slice(8,12).buffer),flat_color=range[12]&1,point_flags=((range[12]>>>1)&1)|((range[12]&4)?16:0);
        if(count<2||first+count>scene.ribbonParticles.length/10||base+(count-1)*4>vertexCount
          ||triangle+(count-1)*2>triangleCount||matrix>=scene.matrices.length/32
          ||material>=scene.materials.length/12||line_material>=scene.materials.length/12
          ||!values.every(Number.isFinite)||values[0]<=0||range[12]>7)throw RangeError('Invalid ribbon range');
        for(let v=base;v<base+(count-1)*4;v++) {
          if(ribbonVertices.has(v)||morphedVertices.has(v)||skinnedVertices.has(v)||scene.matrixIds[v]!==matrix)
            throw RangeError('Overlapping ribbon/deformation vertices or matrix mismatch');
          ribbonVertices.add(v);
        }
        for(let t=triangle;t<triangle+(count-1)*2;t++) {
          if(ribbonTriangles.has(t))throw RangeError('Overlapping ribbon triangles');ribbonTriangles.add(t);
        }
        const particles=this.buffer('ribbonInput',count*40,scene.ribbonParticles.subarray(first*10,(first+count)*10));
        const ribbonMatrix=this.buffer('ribbonMatrix',128,scene.matrices.subarray(matrix*32,matrix*32+32));
        const prepared=this.buffer('ribbonPrepared',count*80),summary=this.buffer('ribbonSummary',12);
        r.batch().dispatch(k.prepare_ribbon.bind({particles,matrices:ribbonMatrix,vertices:prepared,summary},
          {particle_count:count,max_skip,width:viewport_width,height:viewport_height}),[1,1,1])
          .dispatch(k.assemble_ribbon.bind({prepared,summary,vertices:source,attributes:sourceAttributes,triangles,status:counts,flat_colors},
            {segment_count:count-1,vertex_base:base,triangle_base:triangle,material,line_material,line_width:values[0],
              normal_x:values[1],normal_y:values[2],normal_z:values[3],status_index:tiles,flat_color,point_flags}),groups(count-1)).submit();
      }
      scene.screenPrimitives??=new Uint32Array();
      if(!(scene.screenPrimitives instanceof Uint32Array)||scene.screenPrimitives.length%12)
        throw RangeError('Invalid screen primitive records');
      const screenOutputs=new Set(),screenSources=new Set();
      const screenValues=new Float32Array(scene.screenPrimitives.buffer,scene.screenPrimitives.byteOffset,scene.screenPrimitives.length);
      for(let i=0;i<scene.screenPrimitives.length;i+=12) {
        const [a,b,destination,point]=scene.screenPrimitives.subarray(i,i+4);
        if(a>=vertexCount||b>=vertexCount||destination+4>vertexCount||point>1||(point&&a!==b)
          ||scene.screenPrimitives[i+11]>1023||(!point&&(scene.screenPrimitives[i+11]&31)!==0))
          throw RangeError('Invalid screen primitive indices');
        for(let k=4;k<11;k++)if(!Number.isFinite(screenValues[i+k]))throw RangeError('Non-finite screen primitive state');
        if(screenValues[i+4]<=0||screenValues[i+5]<0||screenValues[i+6]<screenValues[i+5]||screenValues[i+7]<0
          ||screenValues[i+8]<0||screenValues[i+9]<0||screenValues[i+10]<0)
          throw RangeError('Invalid point or line size state');
        screenSources.add(a);screenSources.add(b);
        for(let v=destination;v<destination+4;v++) {
          if(screenOutputs.has(v)||ribbonVertices.has(v)||morphedVertices.has(v)||skinnedVertices.has(v))
            throw RangeError('Overlapping screen primitive output');
          screenOutputs.add(v);
        }
      }
      for(const v of screenSources)if(screenOutputs.has(v)||ribbonVertices.has(v))
        throw RangeError('Screen primitive input aliases generated output');
      if(scene.morphRanges.length)r.batch().dispatch(k.morph_vertices.bind({vertices:source,ranges:upload('morphRanges'),offsets:upload('morphOffsets')},
        {range_count:scene.morphRanges.length/3}),groups(scene.morphRanges.length/3)).submit();
      if(scene.skinRanges.length)r.batch().dispatch(k.skin_vertices.bind({vertices:source,attributes:sourceAttributes,ranges:upload('skinRanges'),weights:upload('skinWeights'),bones:upload('skinBones'),transforms:upload('skinTransforms')},
        {range_count:scene.skinRanges.length/4}),groups(scene.skinRanges.length/4)).submit();
      if(scene.groundcoverRanges.length)r.batch().dispatch(k.deform_groundcover.bind({vertices:source,attributes:sourceAttributes,
        records:upload('groundcoverRanges'),instances:upload('groundcoverInstances'),params:upload('groundcoverParams'),matrices,matrix_ids},
        {record_count:scene.groundcoverRanges.length/3}),groups(scene.groundcoverRanges.length/3)).submit();
      if(scene.debugParams.some((value,index)=>index%16===0&&value!==0))r.batch().dispatch(k.shade_debug_vertices.bind({vertices:source,attributes:sourceAttributes,matrix_ids,params:upload('debugParams')},
        {vertex_count:vertexCount}),groups(vertexCount)).submit();
      if(scene.textGradientRanges.length)r.batch().dispatch(k.shade_text_gradient.bind({vertices:source,ranges:upload('textGradientRanges'),colors:upload('textGradientColors')},
        {range_count:scene.textGradientRanges.length/3}),groups(scene.textGradientRanges.length/3)).submit();
      if(scene.localTransforms.some((value,index)=>index%35===0&&value!==0))r.batch().dispatch(k.transform_local_vertices.bind({vertices:source,matrix_ids,matrices,transforms:upload('localTransforms')},
        {vertex_count:vertexCount}),groups(vertexCount)).submit();
      r.batch().dispatch(k.expand_particles.bind({source,attributes:sourceAttributes,matrices,matrix_ids},{vertex_count:vertexCount}),groups(vertexCount)).submit();
      if(fixed_enabled)r.batch().dispatch(k.shade_fixed_vertices.bind({vertices:source,attributes:sourceAttributes,matrices,matrix_ids,
        descriptors:upload('fixedLighting'),secondary_colors:upload('secondaryColors'),output:fixedLighting,endpoints:fixedEndpoints},{vertex_count:vertexCount,capture_endpoints}),groups(vertexCount)).submit();
      r.batch()
        .dispatch(k.transform_attributes.bind({source,attributes:sourceAttributes,matrices,matrix_ids,output:transformedAttributes,lighting_origins:lightingOrigins},{vertex_count:vertexCount,track_lighting,source_point_fade_offset}),groups(vertexCount))
        .dispatch(k.transform_material.bind({source,matrices,matrix_ids,vertices:transformed},{vertex_count:vertexCount}),groups(vertexCount))
        .dispatch(k.project_particles.bind({source,attributes:sourceAttributes,matrices,matrix_ids,vertices:transformed,varyings:transformedAttributes,fixed_lighting:fixedLighting,fixed_endpoints:fixedEndpoints},
          {vertex_count:vertexCount,width:viewport_width,height:viewport_height,fixed_enabled,track_world_particles,world_particle_offset,source_point_fade_offset,sample_count}),groups(vertexCount)).submit();
      if(hasTexgen)r.batch().dispatch(k.generate_texture_coordinates.bind({source,source_attributes:sourceAttributes,matrices,matrix_ids,
        descriptors:upload('texgen'),attributes:transformedAttributes},{vertex_count:vertexCount}),groups(vertexCount)).submit();
      if(scene.uvMatrices)r.batch().dispatch(k.transform_uv.bind({vertices:transformed,uv_matrices:upload('uvMatrices'),matrix_ids},
        {vertex_count:vertexCount}),groups(vertexCount)).submit();
      if(scene.screenPrimitives.length)r.batch().dispatch(k.expand_screen_primitives.bind({vertices:transformed,attributes:transformedAttributes,records:upload('screenPrimitives'),lighting_origins:lightingOrigins,fixed_lighting:fixedLighting},
        {primitive_count:scene.screenPrimitives.length/12,width:viewport_width,height:viewport_height,track_lighting,fixed_enabled,sample_count,source_point_fade_offset}),groups(scene.screenPrimitives.length/12)).submit();
      const unlitFalloff=hasUnlit?this.buffer('unlitFalloff',triangleCount*3*4*4):null;
      if(hasUnlit) {
        const endpoints=this.buffer('bethesdaEndpoints',vertexCount*6*4);
        r.batch().dispatch(k.prepare_bethesda_vertices.bind({vertices:source,attributes:sourceAttributes,matrices,matrix_ids,varyings:transformedAttributes,output:endpoints},
          {vertex_count:vertexCount,track_world_particles,world_particle_offset}),groups(vertexCount))
          .dispatch(k.shade_unlit_falloff.bind({endpoints,origins:lightingOrigins,triangles,materials,texels,output:unlitFalloff},
            {triangle_count:triangleCount,track_origins:track_lighting}),groups(triangleCount*3)).submit();
      }
      const vertexLighting=hasVertexLighting?this.buffer('vertexLighting',triangleCount*3*12*4):null;
      if(hasVertexLighting)r.batch().dispatch(k.shade_vertex_lighting.bind({vertices:transformed,attributes:transformedAttributes,
        triangles,materials,texels,lighting_origins:lightingOrigins,output:vertexLighting},{triangle_count:triangleCount,track_lighting,cluster_offset,track_world_particles,world_particle_offset}),groups(triangleCount*3)).submit();
      r.batch()
        .dispatch(k.clip_triangles.bind({clip:transformed,indices:triangles,materials,polygon_edges,positions,weights,valid},{triangle_count:triangleCount,vertex_stride:10,triangle_stride:4}),groups(triangleCount))
        .dispatch(k.assemble_material.bind({source:transformed,triangles,positions,weights,valid,vertices,output_triangles,flat_colors},{slot_count:slots}),groups(slots))
        .dispatch(k.assemble_attributes.bind({source:transformedAttributes,triangles,weights,valid,output:clippedAttributes},{slot_count:slots,boundary_offset,point_fade_offset,source_point_fade_offset}),groups(slots)).submit();
      if(hasUnlit)r.batch().dispatch(k.assemble_unlit_falloff.bind({source:unlitFalloff,weights,valid,attributes:clippedAttributes},
        {slot_count:slots,falloff_offset}),groups(slots)).submit();
      if(hasVertexLighting)r.batch().dispatch(k.assemble_vertex_lighting.bind({source:vertexLighting,weights,valid,attributes:clippedAttributes},
        {slot_count:slots,lighting_offset}),groups(slots)).submit();
      if(fixed_enabled)r.batch().dispatch(k.assemble_fixed_lighting.bind({source:fixedLighting,triangles,
        flat_colors,weights,valid,output:clippedAttributes},{slot_count:slots,fixed_offset}),groups(slots)).submit();
      r.batch().dispatch(k.map_viewport.bind({vertices,attributes:clippedAttributes},
        {vertex_count:slots*3,width,height,point_fade_offset,...viewportArgs}),groups(slots*3)).submit();
      // Count triangle references, prefix compact offsets on the GPU, then
      // scatter and sort. Storage scales with actual references, not the
      // busiest tile multiplied by the entire screen's tile count.
      const capacity=0, offsets=this.buffer('tileOffsets',(tiles+1)*4);
      const placeholder=this.buffer('emptyCandidates',4);
      const prefixBlocks=this.buffer('tilePrefixBlocks',Math.ceil(tiles/256)*4);
      const summary=this.buffer('tileSummary',8,new Uint32Array(2));
      const max_words=Math.min(0xffffffff,Math.floor(Math.min(r.device.limits.maxStorageBufferBindingSize,r.device.limits.maxBufferSize)/4));
      r.batch()
        .dispatch(k.clear_tile_counts.bind({counts},{tile_count:tiles}),groups(tiles))
        .dispatch(k.bin_triangle_bounds.bind({clip:vertices,indices:output_triangles,counts,candidates:placeholder,offsets,summary,materials,attributes:clippedAttributes},
          {width,height,triangle_count:slots,capacity,scatter:0,raster_offset,sample_count}),groups(slots))
        .dispatch(k.prefix_tile_blocks.bind({counts,offsets,blocks:prefixBlocks},{tile_count:tiles,max_words}),groups(Math.ceil(tiles/256)))
        .dispatch(k.prefix_tile_block_totals.bind({counts,blocks:prefixBlocks,summary},{tile_count:tiles,max_words}),[1,1,1])
        .dispatch(k.finish_tile_prefix.bind({offsets,blocks:prefixBlocks,summary},{tile_count:tiles}),groups(tiles+1)).submit();
      // Each clipped triangle can appear at most once per tile. A bound that
      // fits a small allocation or retained storage can defer status readback
      // to the frame boundary; other passes retain exact compact sizing.
      const bound=tiles+1+slots*tiles;
      const retainedWords=(this.buffers.get('candidates')?.byteLength??0)/4;
      const bounded=Number.isSafeInteger(bound)&&bound<=Math.min(max_words,Math.max(1024*1024,retainedWords));
      // Only proven allocation bounds can defer the size check. Reusing last
      // frame's measured size alone is unsafe when the camera or scene changes.
      const frameRead=pass.deferCompletion&&typeof pass.readback==='function'?pass.readback:(...args)=>r.read(...args);
      const validateSizes=sizes=>{
        if(sizes[1]===2)throw RangeError('Compact triangle lists exceed GPU buffer capacity');
        if(sizes[1]!==0)throw Error('Camera view matrix is singular');
        if(sizes[0]<tiles+1||sizes[0]>(bounded?bound:max_words))throw RangeError('Invalid compact triangle allocation');
        return sizes[0];
      };
      // Attach rejection handling immediately; later passes may still be queued.
      const sizingRead=bounded?frameRead(summary,Uint32Array,8):r.read(summary,Uint32Array,8);
      const sizingCompletion=sizingRead.then(sizes=>{
        try{return {words:validateSizes(sizes)};}catch(error){return {error};}
      },error=>({error}));
      let candidateWords=bound;
      if(!bounded) {
        const sized=await sizingCompletion;
        if(sized.error)throw sized.error;
        candidateWords=sized.words;
      }
      const candidates=this.buffer('candidates',candidateWords*4);
      r.batch()
        .dispatch(k.copy_tile_offsets.bind({offsets,candidates},{tile_count:tiles}),groups(tiles+1))
        .dispatch(k.clear_tile_counts.bind({counts},{tile_count:tiles}),groups(tiles))
        .dispatch(k.bin_triangle_bounds.bind({clip:vertices,indices:output_triangles,counts,candidates,offsets,summary,materials,attributes:clippedAttributes},
          {width,height,triangle_count:slots,capacity,scatter:1,raster_offset,sample_count}),groups(slots))
        .dispatch(k.sort_tile_candidates.bind({counts,candidates},{tile_count:tiles,capacity}),groups(tiles)).submit();
      const clear=pass.clearColor??[0,0,0,1], clearMask=pass.clearMask??16640, depth=pass.clearDepth??1;
      const normal_enabled=pass.normalTargetId?1:0;
      const {channels:normal_channels,storage:normal_storage}=colorStorage(pass.normalFormat??0x8058);
      const {channels:storedChannels,storage:color_storage}=colorStorage(pass.colorFormat??0x8058);
      const color_channels=pass.compactDepth?0:storedChannels;
      if(color_storage===5||color_storage===6||(normal_enabled&&(normal_storage===5||normal_storage===6)))for(let m=0;m<scene.materials.length;m+=12)
        if((scene.materials[m+3]&128)&&(scene.materials[m+9]&0x2000000))
          throw Error('Signed normalized framebuffer logic operations require integer storage');
      const depth_bits=depthStorage(pass.depthFormat??0x81a6);
      const stencilBits=pass.stencilBits??([0x88f0,0x8cad].includes(pass.depthFormat)?8:0);
      if(stencilBits!==0&&stencilBits!==8)throw RangeError('Unsupported stencil bit depth');
      const stencil_enabled=stencilBits?1:0;
      const stencil_clear=(pass.clearStencil??0)&255;
      const clear_color_mask=pass.clearColorMask??15;
      if(!Number.isInteger(clear_color_mask)||clear_color_mask<0||clear_color_mask>15)
        throw RangeError('Invalid camera clear color mask');
      if(clear.length!==4||!clear.every(Number.isFinite)||!Number.isFinite(depth)||!Number.isInteger(clearMask)||(clearMask&~17664))
        throw RangeError('Unsupported camera clear state');
      const rasterTimer=gpuTimedBatch(r,pass.profileGpu===true,'OpenMW clear and raster');
      let rasterTiming;
      try { rasterTimer.batch
        .dispatch(k.clear_attachment.bind({target:rasterTarget},{pixel_count:width*height,mask:clearMask,red:clear[0],green:clear[1],blue:clear[2],alpha:clear[3],depth,normal_enabled,normal_channels,normal_storage,color_channels,color_storage,depth_bits,stencil_enabled,stencil_clear,clear_color_mask,width,height,...viewportArgs,sample_count}),groups(width*height*sample_count))
        .dispatch(k.raster_material.bind({vertices,triangles:output_triangles,counts,candidates,materials,texels,target:rasterTarget,attributes:clippedAttributes},{width,height,capacity,raster_offset,boundary_offset,point_fade_offset,lighting_offset,cluster_offset,fixed_offset,falloff_offset,fixed_enabled,normal_enabled,normal_channels,normal_storage,color_channels,color_storage,depth_bits,stencil_enabled,sample_count}),groups(width*height*sample_count));
        rasterTiming=rasterTimer.submit();
      } catch(error){rasterTimer.dispose();throw error;}
      if(sample_count!==1)this.resolveMultisample(rasterTarget,target,width,height,sample_count,
        {mask:16384|256|1024,colorFormat:pass.colorFormat,depthFormat:pass.depthFormat,normalFormat:pass.normalFormat,normals:normal_enabled!==0,stencil:stencil_enabled!==0});
      if(!pass.deferCompletion||context)r.batch().dispatch(k.pack_target.bind({target,pixels},{width,height,row_pixels}),groups(width*height)).submit();
      const queryEntries=[];
      for(let m=0;m<scene.materials.length;m+=12) {
        const data=scene.materials[m];
        if((scene.materials[m+3]&1024)&&scene.texels[data+8]===5) {
          const id=scene.texels[data+9];
          if(!id)throw RangeError('Missing sky query identity');
          queryEntries.push([id,m/12]);
        }
      }
      // Snapshot before another pass reuses counts. The game host collects
      // these results on the GPU and reads them together at the frame boundary.
      const queryReadback=queryEntries.length?frameRead(counts,Uint32Array,scene.materials.length/12*4,(tiles+1)*4).then(samples=>{
        const queryResults=new Map();
        for(const [id,index] of queryEntries)queryResults.set(id,(queryResults.get(id)??0)+samples[index]);
        return {queryResults};
      },error=>({error})):Promise.resolve({queryResults:new Map()});
      const queryCompletion=Promise.all([sizingCompletion,queryReadback,rasterTiming]).then(([sized,queries,timing])=>
        sized.error?{error:sized.error}:timing.error?{error:timing.error}:{...queries,diagnostic:{triangleCount:triangleCount,tileReferences:sized.words-tiles-1,clearAndRasterGpuMs:timing.gpuMs,
          textureDecodeCount:decodePlans.filter(plan=>!plan.cached).length,textureCacheHits:texturePlan.hits.length,textureCacheMisses:texturePlan.misses.length}});
      if(pass.deferCompletion)return {pixels:null,target,width,height,row_pixels,capacity,queryCompletion};
      const completed=await queryCompletion;
      if(completed.error) {
        await r.idle();this.collectRetired();
        throw completed.error;
      }
      if (context) {
        if(r.presentBuffer)await r.presentBuffer(pixels,context,width,height,row_pixels);
        else {
        const encoder=r.device.createCommandEncoder();
        encoder.copyBufferToTexture({buffer:pixels.gpuBuffer,bytesPerRow:row_pixels*4,rowsPerImage:height},{texture:context.getCurrentTexture()},[width,height,1]);
        r.device.queue.submit([encoder.finish()]);
        }
      }
      await r.idle();
      this.collectRetired();
      const queryResults=completed.queryResults;
      return {pixels,target,width,height,row_pixels,capacity,queryResults};
    } finally { this.busy=false; }
  }
  dispose() {
    if (this.busy) throw Error('Cannot dispose an in-flight pipeline');
    for (const resource of this.buffers.values()) this.runtime.destroyBuffer(resource);
    this.buffers.clear();
    this.collectRetired();
    this.textureResidency.dispose();
  }
}
