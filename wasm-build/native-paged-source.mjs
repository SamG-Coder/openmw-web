// Change only the native storage ABI; math and control flow stay in the .cu
// source. Helpers can receive either paged global storage or dense local arrays.
// Reject an unfamiliar signature instead of silently compiling different code.
export function nativePagedSource(source,header) {
  let globals=0;
  const pattern=/\b(__global__|__device__)\s+(void|float|int|unsigned\s+int)\s+(\w+)\s*\(([^()]*)\)\s*\{/g;
  const rewritten=source.replace(pattern,(whole,kind,result,name,signature)=>{
    const locals=[];
    const parameters=signature.trim()?signature.split(',').map(parameter=>{
      if(!parameter.includes('*'))return parameter;
      const match=/^\s*(const\s+)?(float|int|unsigned\s+int)\s*\*\s*(\w+)\s*$/.exec(parameter);
      if(!match)throw Error(`Unsupported native paged parameter in ${name}: ${parameter}`);
      const type=(match[1]??'')+match[2],id=match[3];
      if(kind==='__device__')return `OmwPaged<${type}> ${id}`;
      locals.push(`OmwPaged<${type}> ${id}(omw_pages_${id});`);
      return `const unsigned long long* omw_pages_${id}`;
    }):[];
    if(kind==='__global__')globals++;
    return `${kind} ${result} ${name}(${parameters.join(',')}) {\n${locals.join('\n')}\n`;
  });
  if(!globals||globals!==[...source.matchAll(/\b__global__\b/g)].length)
    throw Error('Native paged lowering did not cover every kernel');
  if(/\b__device__\s+[^{;]+\([^)]*\*[^)]*\)/.test(rewritten))
    throw Error('Native paged lowering left an unsupported helper pointer');
  return header+'\n'+rewritten;
}
