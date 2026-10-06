// SDL may keep a GL context for platform setup. Rendering through it is forbidden
// in this fork: all framebuffer-producing work belongs to the WebGPU renderer.
const guarded=new WeakMap();
export function guardLegacyRendering(context,onViolation){
  if(guarded.has(context))return guarded.get(context);
  const stats={attempts:0,lastOperation:null};
  const block=(object,name)=>{
    if(typeof object[name]!=='function')return;
    Object.defineProperty(object,name,{configurable:true,writable:false,value(){
      stats.attempts++;stats.lastOperation=name;
      const error=Error(`Legacy WebGL rendering is forbidden: ${name}`);
      onViolation?.(error);
      throw error;
    }});
  };
  for(const name of ['drawArrays','drawElements','drawRangeElements','drawArraysInstanced',
    'drawElementsInstanced','clear','clearBufferfv','clearBufferiv','clearBufferuiv',
    'clearBufferfi','blitFramebuffer'])block(context,name);
  const originalGetExtension=context.getExtension;
  const extensions=new WeakSet();
  if(typeof originalGetExtension==='function')Object.defineProperty(context,'getExtension',{
    configurable:true,writable:false,value(name){
      const extension=originalGetExtension.call(context,name);
      if(extension&&!extensions.has(extension)){
        for(const method of ['drawArraysInstancedANGLE','drawElementsInstancedANGLE',
          'multiDrawArraysWEBGL','multiDrawElementsWEBGL','multiDrawArraysInstancedWEBGL',
          'multiDrawElementsInstancedWEBGL','drawArraysInstancedBaseInstanceWEBGL',
          'drawElementsInstancedBaseVertexBaseInstanceWEBGL',
          'multiDrawArraysInstancedBaseInstanceWEBGL',
          'multiDrawElementsInstancedBaseVertexBaseInstanceWEBGL'])block(extension,method);
        extensions.add(extension);
      }
      return extension;
    }
  });
  guarded.set(context,stats);return stats;
}
