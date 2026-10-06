// SPDX-License-Identifier: GPL-3.0-or-later
// Visit each 16x16 candidate list together instead of interleaving neighboring
// tiles within a warp. Partial edge tiles contain only their real pixels, so
// the host still dispatches exactly width*height invocations per sample.
__device__ unsigned int raster_pixel_index(unsigned int invocation,unsigned int width,unsigned int height) {
    unsigned int yBase=(invocation/(width*16u))*16u;
    unsigned int tileHeight=height-yBase<16u?height-yBase:16u;
    unsigned int inRow=invocation-yBase*width;
    unsigned int column=inRow/(tileHeight*16u);
    unsigned int xBase=column*16u;
    unsigned int tileWidth=width-xBase<16u?width-xBase:16u;
    unsigned int within=inRow-column*tileHeight*16u;
    unsigned int x=xBase+within%tileWidth;
    unsigned int y=yBase+within/tileWidth;
    return y*width+x;
}
