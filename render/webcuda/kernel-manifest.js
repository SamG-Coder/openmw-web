// SPDX-License-Identifier: GPL-3.0-or-later
// Shared source inventory for shader generation and browser loading.
// runtime:false entries are diagnostic kernels, still generated from .cu.
export const kernelManifest = Object.freeze([
  {"file":"cluster-lighting.cu","entry":"prepare_cluster_lights","runtime":true},
  {"file":"positioned-state.cu","entry":"prepare_fixed_matrices","runtime":true},
  {"file":"positioned-state.cu","entry":"prepare_texgen_matrices","runtime":true},
  {"file":"vertex-input.cu","entry":"unpack_vertex_inputs","runtime":true},
  {"file":"compact-depth.cu","entry":"clear_compact_depth","runtime":true},
  {"file":"compact-depth.cu","entry":"copy_depth_layout","runtime":true},
  {"file":"compact-depth.cu","entry":"compact_depth_to_texture","runtime":true},
  {"file":"material.cu","entry":"float_normals_to_texture","runtime":true},
  {"file":"text-gradient.cu","entry":"shade_text_gradient","runtime":true},
  {"file":"local-transform.cu","entry":"transform_local_vertices","runtime":true},
  {"file":"unlit-falloff.cu","entry":"prepare_bethesda_vertices","runtime":true},
  {"file":"unlit-falloff.cu","entry":"shade_unlit_falloff","runtime":true},
  {"file":"unlit-falloff.cu","entry":"assemble_unlit_falloff","runtime":true},
  {"file":"fog-map.cu","entry":"generate_fog_map","runtime":true},
  {"file":"map.cu","entry":"generate_map","runtime":true},
  {"file":"terrain-blend.cu","entry":"generate_terrain_blendmap","runtime":true},
  {"file":"snapshot.cu","entry":"snapshot_frame","runtime":true},
  {"file":"readback.cu","entry":"capture_image","runtime":true},
  {"file":"debug.cu","entry":"shade_debug_vertices","runtime":true},
  {"file":"multisample.cu","entry":"copy_resolved_attachment","runtime":true},
  {"file":"multisample.cu","entry":"broadcast_multisample_color","runtime":true},
  {"file":"multisample.cu","entry":"copy_multisample_plane","runtime":true},
  {"file":"multisample.cu","entry":"clear_multisample_depth","runtime":true},
  {"file":"multisample.cu","entry":"seed_multisample","runtime":true},
  {"file":"multisample.cu","entry":"resolve_multisample","runtime":true},
  {"file":"groundcover.cu","entry":"deform_groundcover","runtime":true},
  {
    "file": "fixed-lighting.cu",
    "entry": "shade_fixed_vertices",
    "runtime": true
  },
  {
    "file": "fixed-lighting.cu",
    "entry": "assemble_fixed_lighting",
    "runtime": true
  },
  {
    "file": "cluster-lighting.cu",
    "entry": "pack_cluster_lights",
    "runtime": true
  },
  {
    "file": "cluster-lighting.cu",
    "entry": "build_light_clusters",
    "runtime": true
  },
  {
    "file": "cluster-lighting.cu",
    "entry": "cull_cluster_lights",
    "runtime": true
  },
  {
    "file": "vertex-lighting.cu",
    "entry": "shade_vertex_lighting",
    "runtime": true
  },
  {
    "file": "vertex-lighting.cu",
    "entry": "assemble_vertex_lighting",
    "runtime": true
  },
  {
    "file": "material.cu",
    "entry": "generate_depth_mip",
    "runtime": true
  },
  {
    "file": "texgen.cu",
    "entry": "generate_texture_coordinates",
    "runtime": true
  },
  {
    "file": "screen-primitives.cu",
    "entry": "expand_screen_primitives",
    "runtime": true
  },
  {
    "file": "ribbons.cu",
    "entry": "assemble_ribbon",
    "runtime": true
  },
  {
    "file": "ribbons.cu",
    "entry": "prepare_ribbon",
    "runtime": true
  },
  {
    "file": "postprocess.cu",
    "entry": "debug_scene",
    "runtime": true
  },
  {
    "file": "postprocess.cu",
    "entry": "place_postprocess",
    "runtime": true
  },
  {
    "file": "assemble.cu",
    "entry": "map_viewport",
    "runtime": true
  },
  {
    "file": "material.cu",
    "entry": "copy_stencil",
    "runtime": true
  },
  {
    "file": "postprocess.cu",
    "entry": "store_postprocess_color",
    "runtime": true
  },
  {
    "file": "postprocess.cu",
    "entry": "bloom_extract",
    "runtime": true
  },
  {
    "file": "postprocess.cu",
    "entry": "bloom_blur",
    "runtime": true
  },
  {
    "file": "postprocess.cu",
    "entry": "bloom_combine",
    "runtime": true
  },
  {
    "file": "postprocess.cu",
    "entry": "scene_log_luminance",
    "runtime": true
  },
  {
    "file": "postprocess.cu",
    "entry": "reduce_luminance",
    "runtime": true
  },
  {
    "file": "postprocess.cu",
    "entry": "adapt_luminance",
    "runtime": true
  },
  {
    "file": "postprocess.cu",
    "entry": "adjust_scene",
    "runtime": true
  },
  {
    "file": "tiles.cu",
    "entry": "prefix_tile_blocks",
    "runtime": true
  },
  {
    "file": "tiles.cu",
    "entry": "prefix_tile_block_totals",
    "runtime": true
  },
  {
    "file": "tiles.cu",
    "entry": "finish_tile_prefix",
    "runtime": true
  },
  {
    "file": "tiles.cu",
    "entry": "copy_tile_offsets",
    "runtime": true
  },
  {
    "file": "tiles.cu",
    "entry": "clear_tile_counts",
    "runtime": true
  },
  {
    "file": "tiles.cu",
    "entry": "bin_triangle_bounds",
    "runtime": true
  },
  {
    "file": "tiles.cu",
    "entry": "summarize_tile_counts",
    "runtime": true
  },
  {
    "file": "tiles.cu",
    "entry": "sort_tile_candidates",
    "runtime": true
  },
  {
    "file": "float-image.cu",
    "entry": "decode_float_image",
    "runtime": true
  },
  {
    "file": "particles.cu",
    "entry": "project_particles",
    "runtime": true
  },
  {
    "file": "postprocess.cu",
    "entry": "resolve_scene",
    "runtime": true
  },
  {
    "file": "deformation.cu",
    "entry": "skin_vertices",
    "runtime": true
  },
  {
    "file": "deformation.cu",
    "entry": "morph_vertices",
    "runtime": true
  },
  {
    "file": "material.cu",
    "entry": "clear_depth",
    "runtime": true
  },
  {
    "file": "ripples.cu",
    "entry": "ripple_blob",
    "runtime": true
  },
  {
    "file": "ripples.cu",
    "entry": "ripple_simulate",
    "runtime": true
  },
  {
    "file": "material.cu",
    "entry": "generate_float_mip",
    "runtime": true
  },
  {
    "file": "material.cu",
    "entry": "float_target_to_texture",
    "runtime": true
  },
  {
    "file": "particles.cu",
    "entry": "expand_particles",
    "runtime": true
  },
  {
    "file": "camera.cu",
    "entry": "resolve_camera",
    "runtime": true
  },
  {
    "file": "geometry.cu",
    "entry": "transform_vertices",
    "runtime": false
  },
  {
    "file": "geometry.cu",
    "entry": "raster_reference",
    "runtime": false
  },
  {"file":"clip-compact.cu","entry":"prefix_clip_blocks","runtime":true},
  {"file":"clip-compact.cu","entry":"prefix_clip_totals","runtime":true},
  {"file":"clip-compact.cu","entry":"scatter_clip_slots","runtime":true},
  {
    "file": "clip.cu",
    "entry": "clip_triangles",
    "runtime": true
  },
  {
    "file": "present.cu",
    "entry": "pack_present",
    "runtime": false
  },
  {
    "file": "tiles.cu",
    "entry": "bin_triangles",
    "runtime": true
  },
  {
    "file": "tiles.cu",
    "entry": "raster_tiled",
    "runtime": false
  },
  {
    "file": "material.cu",
    "entry": "clear_target",
    "runtime": true
  },
  {
    "file": "material.cu",
    "entry": "clear_attachment",
    "runtime": true
  },
  {
    "file": "material.cu",
    "entry": "generate_mip",
    "runtime": true
  },
  {
    "file": "material.cu",
    "entry": "raster_material",
    "runtime": true
  },
  {
    "file": "material.cu",
    "entry": "pack_target",
    "runtime": true
  },
  {
    "file": "material.cu",
    "entry": "target_to_texture",
    "runtime": true
  },
  {
    "file": "material.cu",
    "entry": "depth_to_texture",
    "runtime": true
  },
  {
    "file": "material.cu",
    "entry": "copy_depth",
    "runtime": true
  },
  {
    "file": "material.cu",
    "entry": "copy_normals",
    "runtime": true
  },
  {
    "file": "material.cu",
    "entry": "normals_to_texture",
    "runtime": true
  },
  {
    "file": "attributes.cu",
    "entry": "transform_attributes",
    "runtime": true
  },
  {
    "file": "attributes.cu",
    "entry": "assemble_attributes",
    "runtime": true
  },
  {
    "file": "assemble.cu",
    "entry": "transform_material",
    "runtime": true
  },
  {
    "file": "assemble.cu",
    "entry": "transform_uv",
    "runtime": true
  },
  {
    "file": "assemble.cu",
    "entry": "assemble_material",
    "runtime": true
  },
  {
    "file": "dxt.cu",
    "entry": "decode_dxt",
    "runtime": true
  }
].map(entry => Object.freeze(entry)));
