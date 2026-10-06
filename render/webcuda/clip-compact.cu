// SPDX-License-Identifier: GPL-3.0-or-later
// Stable compaction of the seven reserved clipping slots per source triangle.
// Keep positions/weights in their original slots; assembly follows this map
// before allocating the much larger interpolated attribute streams. The high
// bit distinguishes a mapped source slot (including slot zero) from the legacy
// 0/1 validity array used by small passes without a sizing readback.
__global__ void prefix_clip_blocks(const unsigned int* valid,unsigned int* offsets,
    unsigned int* blocks,unsigned int slot_count) {
    unsigned int block=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    unsigned int first=block*256u;
    if(first>=slot_count)return;
    unsigned int total=0u;
    for(unsigned int i=first;i<slot_count&&i<first+256u;i++) {
        offsets[i]=total;
        if(valid[i]!=0u)total++;
    }
    blocks[block]=total;
}

__global__ void prefix_clip_totals(unsigned int* blocks,unsigned int* summary,
    unsigned int block_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i!=0u)return;
    unsigned int total=0u;
    for(unsigned int block=0u;block<block_count;block++) {
        unsigned int count=blocks[block];blocks[block]=total;total+=count;
    }
    summary[0]=total;
}

__global__ void scatter_clip_slots(const unsigned int* valid,const unsigned int* offsets,
    const unsigned int* blocks,unsigned int* compact_valid,unsigned int slot_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i>=slot_count||valid[i]==0u)return;
    compact_valid[blocks[i/256u]+offsets[i]]=0x80000000u|i;
}
