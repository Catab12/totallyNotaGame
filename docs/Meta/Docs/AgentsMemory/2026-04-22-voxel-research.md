# Agent Memory: Voxel Engine Research Decisions

**Date:** 2026-04-22  
**Agent:** Satan  
**Topic:** Advanced voxel rendering techniques research

---

## Key Decisions Made

### 1. Hybrid Pipeline Confirmed
**Decision:** Rasterization for near chunks + Ray marching for far LOD  
**Rationale:** Pure ray tracing loses to rasterization in dense scenes. Ray marching as LOD is the sweet spot.

### 2. SVDAG Integration (Aokana 2025)
**Decision:** Implement Sparse Voxel DAG for far chunk compression  
**Key metrics:**
- 9× memory reduction vs raw voxels
- 4.8× faster than HashDAG
- Only 5% of scene in VRAM at any time
- 6ms render time for 64K³ scene (10 billion voxels)

**Implementation approach:** Multiple shallow SVDAGs (one per chunk) instead of single giant tree

### 3. Sparse 64-Trees Alternative
**Decision:** Research parallel implementation alongside SVDAG  
**Advantages over octrees:**
- 3× less memory (0.19 vs 0.57 bytes/voxel)
- 64-bit child masks
- Float bit-hacking traversal (IEEE754 mantissa)
- Better cache efficiency

**Key optimizations:**
- Ancestor memoization (2× speedup)
- 2³ skip coalescing (21% speedup)
- Ray-octant mirroring (10% speedup)

### 4. Visibility Buffer Rendering
**Decision:** Use 64-bit visibility buffer instead of traditional G-buffer  
**Layout:**
- [63:40] depth (24 bits)
- [39:37] normal (3 bits)
- [36:24] chunk_id (13 bits)
- [23:0] voxel xyz (24 bits)

**Benefits:** Reduced bandwidth, InterlockedMax for depth, deferred shading

### 5. GPU-Driven Pipeline
**Decision:** Move culling and dispatch to GPU compute shaders  
**Pipeline:**
1. Chunk selection (frustum cull)
2. Tile selection (8×8 tiles, Hi-Z cull)
3. Indirect dispatch for ray marching
4. Visibility buffer resolve

### 6. NOT Using (for now)
- **Pure ray tracing:** Too slow for dense scenes
- **Mesh shaders:** Requires Vulkan 1.3+, limits hardware compatibility
- **Neural Radiance Fields:** Too experimental, high latency
- **Nanite-style virtual geometry:** Designed for triangles, not voxels

---

## Research Sources

1. **Aokana (2025)** — Fudan/Harvard, GPU-Driven Voxel Rendering
   - https://arxiv.org/html/2505.02017v1

2. **Sparse 64-Trees (2024)** — dubiousconst282
   - https://dubiousconst282.github.io/2024/10/03/voxel-ray-tracing/

3. **Voxel Ray Traversal** — DeadlockCode (Amanatides & Woo)
   - https://github.com/DeadlockCode/voxel_ray_traversal

4. **Efficient Sparse Voxel Octrees** — Laine & Karras (NVIDIA, 2010)
   - Classic reference for SVO ray casting

5. **GPU-Driven Rendering** — Ubisoft (2015)
   - Foundation for indirect rendering approach

---

## Next Actions

1. Implement Phase 1: Core chunk data structures
2. Test SVDAG vs 64-tree on sample data
3. Profile memory usage with RLE + SVDAG combination
4. Design compute shader integration with Godot's RenderingDevice

---

*This file is referenced by AGENTS.md and opencode.jsonc*
