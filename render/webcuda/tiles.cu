// SPDX-License-Identifier: GPL-3.0-or-later
// Conservative 16x16 screen-space bins. Inputs must already be clipped and have
// positive w. Each tile owns its list; ordering is stable without atomics.
// counts is the REQUIRED capacity, even on overflow. The host must grow/retry
// before presenting a frame if any count exceeds capacity. This initial binner
// scans triangles per tile; hierarchical/triangle-driven binning remains work.
__global__ void bin_triangles(const float* clip, const unsigned int* indices,
                             unsigned int* counts, unsigned int* candidates,
                             unsigned int width, unsigned int height,
                             unsigned int triangle_count, unsigned int capacity,
                             unsigned int vertex_stride, unsigned int triangle_stride) {
    unsigned int tile = (blockIdx.x + blockIdx.y * gridDim.x) * blockDim.x + threadIdx.x;
    unsigned int columns = (width + 15) / 16;
    unsigned int rows = (height + 15) / 16;
    if (tile >= columns * rows) return;
    float left = (float)((tile % columns) * 16);
    float top = (float)((tile / columns) * 16);
    float right = fminf(left + 16.0f, (float)width);
    float bottom = fminf(top + 16.0f, (float)height);
    unsigned int count = 0;
    for (unsigned int t = 0; t < triangle_count; t++) {
        float min_x = (float)width;
        float min_y = (float)height;
        float max_x = 0.0f;
        float max_y = 0.0f;
        unsigned int usable = 1;
        for (unsigned int v = 0; v < 3; v++) {
            unsigned int i = indices[t * triangle_stride + v] * vertex_stride;
            float w = clip[i + 3];
            if (w <= 0.0f) { usable = 0; break; }
            float x = (clip[i] / w * 0.5f + 0.5f) * (float)width;
            float y = (0.5f - clip[i + 1] / w * 0.5f) * (float)height;
            min_x = fminf(min_x, x); max_x = fmaxf(max_x, x);
            min_y = fminf(min_y, y); max_y = fmaxf(max_y, y);
        }
        if (usable == 0 || max_x < left + 0.5f || min_x > right - 0.5f
            || max_y < top + 0.5f || min_y > bottom - 0.5f) continue;
        if (count < capacity) candidates[tile * capacity + count] = t;
        count++;
    }
    counts[tile] = count;
}

// Opaque rasterization visits only the current tile's candidate triangles.
__global__ void raster_tiled(const float* clip, const float* colors,
                                 const unsigned int* indices, const unsigned int* counts,
                                 const unsigned int* candidates, float* rgba,
                                 float* depth, unsigned int width,
                                 unsigned int height, unsigned int capacity) {
    unsigned int pixel = (blockIdx.x + blockIdx.y * gridDim.x) * blockDim.x + threadIdx.x;
    if (pixel >= width * height) return;
    unsigned int columns = (width + 15) / 16;
    unsigned int tile = (pixel / width / 16) * columns + (pixel % width / 16);
    unsigned int count = counts[tile];
    // Overflow must never silently render a truncated scene. Host retries the
    // binner before presenting; magenta is a diagnostic if that contract breaks.
    if (count > capacity) {
        rgba[pixel * 4] = 1.0f; rgba[pixel * 4 + 1] = 0.0f;
        rgba[pixel * 4 + 2] = 1.0f; rgba[pixel * 4 + 3] = 1.0f;
        depth[pixel] = 1.0f;
        return;
    }
    float px = (float)(pixel % width) + 0.5f;
    float py = (float)(pixel / width) + 0.5f;
    float best = 1.0f;
    float red = 0.0f;
    float green = 0.0f;
    float blue = 0.0f;
    for (unsigned int candidate = 0; candidate < count; candidate++) {
        unsigned int t = candidates[tile * capacity + candidate];
        unsigned int ia = indices[t * 3] * 4;
        unsigned int ib = indices[t * 3 + 1] * 4;
        unsigned int ic = indices[t * 3 + 2] * 4;
        float aw = clip[ia + 3];
        float bw = clip[ib + 3];
        float cw = clip[ic + 3];
        if (aw <= 0.0f || bw <= 0.0f || cw <= 0.0f) continue;
        float ax = (clip[ia] / aw * 0.5f + 0.5f) * (float)width;
        float ay = (0.5f - clip[ia + 1] / aw * 0.5f) * (float)height;
        float bx = (clip[ib] / bw * 0.5f + 0.5f) * (float)width;
        float by = (0.5f - clip[ib + 1] / bw * 0.5f) * (float)height;
        float cx = (clip[ic] / cw * 0.5f + 0.5f) * (float)width;
        float cy = (0.5f - clip[ic + 1] / cw * 0.5f) * (float)height;
        float area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
        if (fabsf(area) < 0.000001f) continue;
        float a = ((bx - px) * (cy - py) - (by - py) * (cx - px)) / area;
        float b = ((cx - px) * (ay - py) - (cy - py) * (ax - px)) / area;
        float c = 1.0f - a - b;
        if (a < 0.0f || b < 0.0f || c < 0.0f) continue;
        float z = (a * clip[ia + 2] / aw + b * clip[ib + 2] / bw + c * clip[ic + 2] / cw) * 0.5f + 0.5f;
        if (z < 0.0f || z >= best) continue;
        best = z;
        float recip = a / aw + b / bw + c / cw;
        a = a / aw / recip;
        b = b / bw / recip;
        c = c / cw / recip;
        red = a * colors[ia] + b * colors[ib] + c * colors[ic];
        green = a * colors[ia + 1] + b * colors[ib + 1] + c * colors[ic + 1];
        blue = a * colors[ia + 2] + b * colors[ib + 2] + c * colors[ic + 2];
    }
    depth[pixel] = best;
    rgba[pixel * 4] = red;
    rgba[pixel * 4 + 1] = green;
    rgba[pixel * 4 + 2] = blue;
    rgba[pixel * 4 + 3] = 1.0f;
}


// Production binner: one thread per clipped triangle, visiting only tiles in
// its screen bounding box. Atomic insertion order is corrected by a tile sort.
__global__ void clear_tile_counts(unsigned int* counts,unsigned int tile_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i<tile_count)counts[i]=0u;
}
__global__ void bin_triangle_bounds(const float* clip,const unsigned int* indices,
    unsigned int* counts,unsigned int* candidates,const unsigned int* offsets,const unsigned int* summary,
    const unsigned int* materials,const float* attributes,unsigned int width,unsigned int height,
    unsigned int triangle_count,unsigned int capacity,unsigned int scatter,unsigned int raster_offset,unsigned int sample_count) {
    unsigned int t=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(t>=triangle_count||(scatter!=0u&&summary[1]!=0u))return;
    float minx=(float)width,miny=(float)height,maxx=0.0f,maxy=0.0f;
    for(unsigned int corner=0;corner<3;corner++) {
        unsigned int i=indices[t*4u+corner]*10u;
        float w=clip[i+3u];if(w<=0.0f)return;
        float x=(clip[i]/w*0.5f+0.5f)*(float)width;
        float y=(0.5f-clip[i+1u]/w*0.5f)*(float)height;
        minx=fminf(minx,x);miny=fminf(miny,y);maxx=fmaxf(maxx,x);maxy=fmaxf(maxy,y);
    }
    unsigned int material=indices[t*4u+3u],m=material*12u;
    unsigned int control=materials[m+9u],raster=raster_offset+material*50u;
    unsigned int scissorX=materials[m+5u],scissorY=materials[m+6u];
    unsigned int scissorWidth=materials[m+7u],scissorHeight=materials[m+8u];
    // These tests reject every sample in raster_material. Apply them before
    // counting references, so invisible draws never reach tile sorting/raster.
    if(scissorX>=width||scissorY>=height||scissorWidth==0u||scissorHeight==0u)return;
    if((materials[m+3u]&128u)!=0u&&((control>>14u)&3u)==3u)return;
    if(sample_count>1u&&attributes[raster+27u]!=0.0f) {
        unsigned int sampleBits=(1u<<sample_count)-1u;
        if((((unsigned int)attributes[raster+26u])&sampleBits)==0u)return;
        if((attributes[raster+24u]==0.0f&&attributes[raster+25u]==0.0f)
            ||(attributes[raster+24u]==1.0f&&attributes[raster+25u]!=0.0f))return;
    }
    // Clamp before addition: the raster's subtraction-based scissor predicate
    // also accepts UINT_MAX extents without unsigned coordinate wraparound.
    unsigned int scissorEndX=width,scissorEndY=height;
    if(scissorWidth<width-scissorX)scissorEndX=scissorX+scissorWidth;
    if(scissorHeight<height-scissorY)scissorEndY=scissorY+scissorHeight;
    unsigned int frontMode=(control>>27u)&3u,backMode=(control>>29u)&3u;
    // A conservative union of both faces avoids duplicating facing/cull logic.
    // Line and point coverage may extend beyond the polygon's filled bounds.
    float padding=0.0f;
    if(frontMode==1u||backMode==1u) {
        float linePadding=attributes[raster+37u]*0.5f;
        if(sample_count==1u||attributes[raster+27u]==0.0f) {
            if((((unsigned int)attributes[raster+49u])&128u)!=0u)linePadding+=0.5f;
            else linePadding=fmaxf(1.0f,floorf(attributes[raster+37u]+0.5f))*0.5f;
        }
        padding=fmaxf(padding,linePadding);
    }
    if(frontMode==2u||backMode==2u) {
        float pointSize=0.0f;
        for(unsigned int corner=0u;corner<3u;corner++) {
            unsigned int vertex=indices[t*4u+corner]*34u;
            float distance2=0.0f;
            for(unsigned int axis=0u;axis<3u;axis++)distance2+=attributes[vertex+axis]*attributes[vertex+axis];
            float attenuation=attributes[raster+46u]+attributes[raster+47u]*sqrtf(distance2)+attributes[raster+48u]*distance2;
            float size=attributes[raster+38u]/sqrtf(fmaxf(0.000000000001f,attenuation));
            size=fminf(attributes[raster+44u],fmaxf(attributes[raster+43u],size));
            pointSize=fmaxf(pointSize,size);
        }
        if(sample_count>1u&&attributes[raster+27u]!=0.0f)pointSize=fmaxf(pointSize,attributes[raster+45u]);
        float pointPadding=pointSize*0.5f;
        if(sample_count==1u||attributes[raster+27u]==0.0f) {
            unsigned int pointFlags=(unsigned int)attributes[raster+49u];
            if((pointFlags&3u)==0u)pointPadding=fmaxf(1.0f,floorf(pointSize+0.5f))*0.5f+0.5f;
            else if((pointFlags&3u)==1u)pointPadding+=0.5f; // pixel-square intersection
        }
        padding=fmaxf(padding,pointPadding);
    }
    minx-=padding;miny-=padding;maxx+=padding;maxy+=padding;
    // Include every possible sample location, not only pixel centres. Otherwise
    // a narrow triangle near a tile edge can lose its multisample coverage.
    float sampleMin=0.5f,sampleMax=0.5f;
    if(sample_count>1u&&attributes[raster+27u]!=0.0f) {
        sampleMin=sample_count==2u?0.25f:(sample_count==8u?0.0625f:0.125f);
        sampleMax=1.0f-sampleMin;
    }
    float firstx=ceilf(minx-sampleMax),firsty=ceilf(miny-sampleMax);
    float lastx=floorf(maxx-sampleMin),lasty=floorf(maxy-sampleMin);
    firstx=fmaxf((float)scissorX,firstx);firsty=fmaxf((float)scissorY,firsty);
    lastx=fminf((float)(scissorEndX-1u),lastx);lasty=fminf((float)(scissorEndY-1u),lasty);
    if(firstx>lastx||firsty>lasty)return;
    unsigned int columns=(width+15u)/16u;
    unsigned int x0=(unsigned int)firstx/16u,x1=(unsigned int)lastx/16u;
    unsigned int y0=(unsigned int)firsty/16u,y1=(unsigned int)lasty/16u;
    for(unsigned int y=y0;y<=y1;y++)for(unsigned int x=x0;x<=x1;x++) {
        unsigned int tile=y*columns+x,slot=atomicAdd(&counts[tile],1u);
        if(capacity!=0u) {if(slot<capacity)candidates[tile*capacity+slot]=t;}
        else if(scatter!=0u)candidates[offsets[tile]+slot]=t;
    }
}
__global__ void summarize_tile_counts(const unsigned int* counts,unsigned int* summary,unsigned int tile_count) {
    unsigned int tile=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(tile>=tile_count)return;
    atomicMax(&summary[0],counts[tile]);
    if(tile==0u)summary[1]=counts[tile_count];
}
// In-place heap sort has bounded O(n log n) work without a quadratic insertion
// pass. Ascending original triangle IDs restore draw and blending order.
__global__ void sort_tile_candidates(const unsigned int* counts,unsigned int* candidates,
    unsigned int tile_count,unsigned int capacity) {
    unsigned int tile=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(tile>=tile_count)return;
    unsigned int n=counts[tile],base=capacity==0u?candidates[tile]:tile*capacity;
    if(n<2u||(capacity!=0u&&n>capacity))return;
    unsigned int start=n/2u,end=n;
    while(end>1u) {
        unsigned int root;
        if(start>0u){start--;root=start;}
        else {
            end--;
            unsigned int top=candidates[base];candidates[base]=candidates[base+end];candidates[base+end]=top;
            root=0u;
        }
        unsigned int value=candidates[base+root];
        while(root*2u+1u<end) {
            unsigned int child=root*2u+1u;
            if(child+1u<end&&candidates[base+child]<candidates[base+child+1u])child++;
            if(value>=candidates[base+child])break;
            candidates[base+root]=candidates[base+child];root=child;
        }
        candidates[base+root]=value;
    }
}

// Scan independent blocks of 256 tile counts in parallel. Offsets are local
// until finish_tile_prefix adds each block's checked global base.
__global__ void prefix_tile_blocks(const unsigned int* counts,unsigned int* offsets,unsigned int* blocks,
    unsigned int tile_count,unsigned int max_words) {
    unsigned int block=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    unsigned int begin=block*256u;if(begin>=tile_count)return;
    unsigned int end=begin+256u;if(end>tile_count)end=tile_count;
    unsigned int sum=0u;
    for(unsigned int tile=begin;tile<end;tile++) {
        offsets[tile]=sum;
        unsigned int value=counts[tile];
        // Saturate to an invalid size without allowing unsigned wraparound.
        if(value>max_words-sum){blocks[block]=4294967295u;return;}
        sum+=value;
    }
    blocks[block]=sum;
}
// Only the block totals use a serial scan: one entry per 256 screen tiles.
__global__ void prefix_tile_block_totals(const unsigned int* counts,unsigned int* blocks,unsigned int* summary,
    unsigned int tile_count,unsigned int max_words) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i!=0u)return;
    unsigned int next=tile_count+1u;
    summary[0]=0u;summary[1]=counts[tile_count];
    if(next>max_words){summary[1]=2u;return;}
    unsigned int block_count=(tile_count+255u)/256u;
    for(unsigned int block=0;block<block_count;block++) {
        unsigned int count=blocks[block];
        if(count>max_words-next){summary[1]=2u;return;}
        blocks[block]=next;next+=count;
    }
    summary[0]=next;
}
__global__ void finish_tile_prefix(unsigned int* offsets,const unsigned int* blocks,const unsigned int* summary,
    unsigned int tile_count) {
    unsigned int tile=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(tile>tile_count)return;
    if(summary[1]!=0u){offsets[tile]=0u;return;}
    if(tile==tile_count)offsets[tile]=summary[0];
    else offsets[tile]+=blocks[tile/256u];
}
__global__ void copy_tile_offsets(const unsigned int* offsets,unsigned int* candidates,unsigned int tile_count) {
    unsigned int i=(blockIdx.x+blockIdx.y*gridDim.x)*blockDim.x+threadIdx.x;
    if(i<=tile_count)candidates[i]=offsets[i];
}
