// SPDX-License-Identifier: GPL-3.0-or-later
// A direct packet borrows ranges of a WASM-owned GPU buffer. Its CPU views
// remain authoritative for validation, material selection and cache identities.
import {DIRECT_GPU_NAMES} from './wasm-frame.js';
const names=new Set(DIRECT_GPU_NAMES);

export function importDirectPacket(runtime,packet) {
  const direct=packet.scene?.directGPU;
  if(!direct)return;
  if(!direct.buffer||!direct.ranges||typeof direct.ranges!=='object'||Array.isArray(direct.ranges)
    ||!Number.isSafeInteger(direct.byteLength)||direct.byteLength<=0||direct.byteLength>direct.buffer.size)
    throw RangeError('Invalid direct WASM GPU packet');
  const imported={},occupied=[];
  try {
    for(const [name,range] of Object.entries(direct.ranges)) {
      const source=packet.scene[name];
      if(!names.has(name)||!ArrayBuffer.isView(source)||!range
        ||!Number.isSafeInteger(range.offset)||!Number.isSafeInteger(range.bytes)
        ||range.offset<0||range.bytes<=0||range.bytes!==source.byteLength
        ||range.offset+range.bytes>direct.byteLength)
        throw RangeError(`Invalid direct WASM GPU packet range: ${name}`);
      for(const [start,end] of occupied)
        if(range.offset<end&&range.offset+range.bytes>start)
          throw RangeError('Direct WASM GPU packet ranges overlap');
      occupied.push([range.offset,range.offset+range.bytes]);
      imported[name]=runtime.importExternalBuffer(direct.buffer,range.bytes,
        {offset:range.offset,label:`OpenMW direct ${name}`});
    }
  } catch(error) {
    // An earlier import is still registered when a later range fails. Do not
    // destroy the shared GPU buffer; the C++ packet owner releases it.
    for(const resource of Object.values(imported))runtime.releaseExternalBuffer(resource);
    throw error;
  }
  packet.scene.directGpuResources=imported;
  const release=packet.release;
  let released=false;
  packet.release=()=>{
    if(released)return;released=true;
    try {
      for(const resource of Object.values(imported))runtime.releaseExternalBuffer(resource);
    } finally { release(); }
  };
}
