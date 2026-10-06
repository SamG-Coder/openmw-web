// SPDX-License-Identifier: GPL-3.0-or-later
// Homogeneous clipping precedes perspective division. Original-vertex weights
// travel with each intersection so material attributes can be interpolated later.
// Each input reserves seven triangles (a triangle clipped by six planes has at
// most nine vertices). positions/weights: 84 floats per input; valid: 7 uints.
// Each weight record has three interpolation weights and an outgoing-edge flag.
// The flag identifies the clipped triangle polygon boundary, not a fan diagonal.
// Original quad/polygon boundary bits arrive from the topology producer.
__global__ void clip_triangles(const float* clip, const unsigned int* indices, const unsigned int* materials,const unsigned int* polygon_edges,
                              float* positions, float* weights,
                              unsigned int* valid, unsigned int triangle_count,
                              unsigned int vertex_stride, unsigned int triangle_stride) {
    unsigned int tri = (blockIdx.x + blockIdx.y * gridDim.x) * blockDim.x + threadIdx.x;
    if (tri >= triangle_count) return;
    unsigned int flags=triangle_stride==4u?materials[indices[tri*triangle_stride+3u]*12u+3u]:0u;
    unsigned int depth_clamp=flags&262144u;
    unsigned int expanded_primitive=flags&4194304u;
    float polygon[40];
    float attributes[40];
    float next_polygon[40];
    float next_attributes[40];
    unsigned int count = 3;
    for (unsigned int i = 0; i < 7; i++) valid[tri * 7 + i] = 0;
    for (unsigned int i = 0; i < 3; i++) {
        unsigned int vertex = indices[tri * triangle_stride + i];
        for (unsigned int k = 0; k < 4; k++) {
            polygon[i * 4 + k] = clip[vertex * vertex_stride + k];
            attributes[i * 4 + k] = i == k ? 1.0f : 0.0f;
        }
        // During clipping component three is the incoming edge flag. It is
        // discrete topology data and must not use intersection interpolation.
        unsigned int previous=i==0u?2u:i-1u;
        attributes[i*4+3]=((polygon_edges[tri]>>previous)&1u)!=0u?1.0f:0.0f;
    }
    for (unsigned int plane = 0; plane < 6; plane++) {
        // Point/line centres already passed homogeneous clipping. Their wide
        // raster footprint may legally extend beyond the viewport side planes.
        if(plane<4u&&expanded_primitive!=0u)continue;
        if(plane>=4u&&depth_clamp!=0u)continue;
        if (count < 3) return;
        unsigned int axis = plane / 2;
        float sign = plane % 2 == 0 ? 1.0f : -1.0f;
        unsigned int output_count = 0;
        for (unsigned int i = 0; i < count; i++) {
            unsigned int previous = i == 0 ? count - 1 : i - 1;
            float d0 = polygon[previous * 4 + 3] + sign * polygon[previous * 4 + axis];
            float d1 = polygon[i * 4 + 3] + sign * polygon[i * 4 + axis];
            if(plane==4u&&(flags&8388608u)!=0u) {
                d0=polygon[previous*4+2];d1=polygon[i*4+2];
            }
            bool inside0 = d0 >= 0.0f;
            bool inside1 = d1 >= 0.0f;
            // An endpoint on the plane is emitted by its inside case. Emitting it
            // again as an intersection can grow a degenerate polygon past 9 vertices.
            if (inside0 != inside1 && d0 != 0.0f && d1 != 0.0f) {
                float t = d0 / (d0 - d1);
                for (unsigned int k = 0; k < 4; k++) {
                    next_polygon[output_count * 4 + k] = polygon[previous * 4 + k]
                        + t * (polygon[i * 4 + k] - polygon[previous * 4 + k]);
                    next_attributes[output_count * 4 + k] = attributes[previous * 4 + k]
                        + t * (attributes[i * 4 + k] - attributes[previous * 4 + k]);
                }
                // Exiting follows the original edge; entering starts a new
                // clipping-plane boundary, which is visible in polygon mode.
                next_attributes[output_count*4+3]=inside0?attributes[i*4+3]:1.0f;
                output_count++;
            }
            if (inside1) {
                for (unsigned int k = 0; k < 4; k++) {
                    next_polygon[output_count * 4 + k] = polygon[i * 4 + k];
                    next_attributes[output_count * 4 + k] = attributes[i * 4 + k];
                }
                // A vertex exactly on the entering plane replaces an explicit
                // intersection and therefore starts the clipping boundary too.
                if(!inside0&&d1==0.0f)next_attributes[output_count*4+3]=1.0f;
                output_count++;
            }
        }
        count = output_count;
        for (unsigned int i = 0; i < count * 4; i++) {
            polygon[i] = next_polygon[i];
            attributes[i] = next_attributes[i];
        }
    }
    if (count < 3) return;
    for (unsigned int fan = 0; fan < count - 2; fan++) {
        unsigned int slot = tri * 7 + fan;
        // The w=0 apex has no projectable area. Do not generate NaN coordinates.
        if (polygon[3] <= 0.0f || polygon[(fan + 1) * 4 + 3] <= 0.0f
            || polygon[(fan + 2) * 4 + 3] <= 0.0f) continue;
        valid[slot] = 1;
        for (unsigned int v = 0; v < 3; v++) {
            unsigned int from = v == 0 ? 0 : fan + v;
            for (unsigned int k = 0; k < 4; k++) {
                positions[slot * 12 + v * 4 + k] = polygon[from * 4 + k];
                weights[slot * 12 + v * 4 + k] = attributes[from * 4 + k];
            }
            // Fan corners are [0, fan+1, fan+2]. Only the first and last
            // spokes belong to the polygon boundary; the middle edge always does.
            // Store after clipping so this discrete flag is never interpolated.
            unsigned int next=from+1u==count?0u:from+1u;
            weights[slot * 12 + v * 4 + 3] =
                (v == 1 || (v == 0 && fan == 0) || (v == 2 && fan == count - 3))
                    ? attributes[next*4+3] : 0.0f;
        }
    }
}
