import { GpuRuntime } from '/webcuda-sdk/src/runtime/runtime.js';

export async function nativeRendererRequested(Module) {
  if(new URLSearchParams(location.search).get('backend')!=='native')return false;
  if(!await GpuRuntime.SupportsNativeCuda())throw Error('Native CUDA requires ChromiumRTXCuda. Open this URL there, or remove backend=native to use WebGPU.');
  if(await navigator.cuda.queryPermission()==='granted')return true;
  Module.setStatus?.('Native CUDA requires browser permission');
  return new Promise((resolve,reject)=>{
    const panel=document.createElement('div');
    Object.assign(panel.style,{position:'fixed',inset:'0',display:'grid',placeContent:'center',gap:'16px',padding:'32px',
      background:'#141b24',color:'#e5eef8',font:'18px system-ui',zIndex:'100000'});
    const text=document.createElement('p');text.textContent='Allow this OpenMW page to render with native CUDA?';
    const enable=document.createElement('button');enable.textContent='Enable native CUDA';
    const fallback=document.createElement('button');fallback.textContent='Use WebGPU';
    for(const button of [enable,fallback])Object.assign(button.style,{font:'inherit',padding:'12px',cursor:'pointer'});
    const finish=value=>{panel.remove();resolve(value);};
    enable.addEventListener('click',async()=>{
      enable.disabled=true;fallback.disabled=true;
      try {
        const permission=await GpuRuntime.requestPermission();
        if(permission==='granted')finish(true);
        else {text.textContent='Native GPU access was not granted. You can use WebGPU or try again.';enable.disabled=false;fallback.disabled=false;}
      } catch(error){panel.remove();reject(error);}
    });
    fallback.addEventListener('click',()=>{
      const url=new URL(location.href);url.searchParams.delete('backend');history.replaceState(null,'',url);finish(false);
    });
    panel.append(text,enable,fallback);document.body.appendChild(panel);
  });
}
