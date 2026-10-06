// SPDX-License-Identifier: GPL-3.0-or-later
// Native storage glue; included after native-pages.cuh by the build script.
// Refreshing a page entry in every native batch also makes that shared page an
// explicit argument of the batch, so browser ownership/fences cover every
// indirect access. No raw device address is transferred to JavaScript.
__global__ void omw_set_page(unsigned long long* table,unsigned int* page,unsigned int slot) {
    if(threadIdx.x==0)table[slot]=reinterpret_cast<unsigned long long>(page);
}
__global__ void omw_copy_pages(const unsigned long long* source_pages,const unsigned long long* target_pages,
    unsigned int source_offset,unsigned int target_offset,unsigned int word_count) {
    unsigned int i=(blockIdx.y*gridDim.x+blockIdx.x)*blockDim.x+threadIdx.x;
    OmwPaged<const unsigned int> source(source_pages);
    OmwPaged<unsigned int> target(target_pages);
    if(i<word_count)target[target_offset+i]=source[source_offset+i];
}
