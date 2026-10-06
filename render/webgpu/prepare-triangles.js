// SPDX-License-Identifier: GPL-3.0-or-later
// Binding layout for the authored WGSL identity triangle preparation stage.
// There is one slot per input triangle; WebGPU performs homogeneous clipping.
export const prepareTrianglesArtifact = Object.freeze({
  name: 'prepare_triangles',
  entryPoint: 'main',
  metadata: {
    workgroupSize: [64, 1, 1],
    bindings: [
      {name: 'clip', binding: 0, elementType: 'f32', stride: 4, readOnly: true},
      {name: 'indices', binding: 1, elementType: 'u32', stride: 4, readOnly: true},
      {name: 'polygon_edges', binding: 2, elementType: 'u32', stride: 4, readOnly: true},
      {name: 'positions', binding: 3, elementType: 'f32', stride: 4, readOnly: false},
      {name: 'weights', binding: 4, elementType: 'f32', stride: 4, readOnly: false},
      {name: 'valid', binding: 5, elementType: 'u32', stride: 4, readOnly: false},
    ],
    scalars: [{name: 'triangle_count', type: 'u32', offset: 0}],
    uniformBinding: 6,
    uniformSize: 16,
  },
});
