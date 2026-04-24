# ALEPH VOXEL ENGINE — Technical Design Document

**Branch:** `aleph-dev`  
**Target:** Godot 4.6.2 Custom Module (C++)  
**Game:** Space-themed Minecraft clone, first-person, VR-compatible  
**Platforms:** PC (primary), VR (Quest), Mobile, Consoles

---

## 1. PHILOSOPHY

**"Render only what matters. Compute everything else."**

The Aleph Voxel Engine is not a generic voxel solution. It is a **domain-specific renderer** optimized for a single use case: massive block-based worlds with uniform cube geometry, viewed from first-person perspective, potentially in VR.

This constraint is our superpower. We can make assumptions that general engines cannot:
- All visible geometry is axis-aligned cubes (or cube-derived: stairs, slabs, doors)
- The camera is always outside the voxel grid (first-person, never inside a block)
- World is mostly static (terrain changes are localized events, not continuous streams)
- VR requires consistent frame times (90 FPS = 11.1ms budget)

---

## 2. RENDERING PIPELINE

### 2.1 The Big Decision: Rasterization + Compute, NOT Pure Ray Tracing

After analyzing DeadlockCode's voxel_ray_traversal and other techniques, we use a **hybrid approach**:

```
PRIMARY PIPELINE (99% of frames):
┌─────────────────────────────────────────────────────────────┐
│  1. VISIBLE SET DETERMINATION (CPU + GPU Compute)           │
│     • Frustum cull chunks                                     │
│     • Occlusion cull using Hierarchical Z-Buffer (HZB)      │
│     • LOD select based on distance                            │
│                                                             │
│  2. MESH GENERATION (CPU Background Threads)                │
│     • Greedy meshing for solid surfaces                     │
│     • Transparents queued separately                        │
│                                                             │
│  3. RENDERING (GPU Rasterization)                           │
│     • Single draw call per chunk via MultiMesh              │
│     • GPU instancing with texture atlas lookup              │
│     • No individual MeshInstances (too heavy)               │
└─────────────────────────────────────────────────────────────┘

SECONDARY PIPELINE (distant terrain, fallback):
┌─────────────────────────────────────────────────────────────┐
│  4. FAR LOD (GPU Compute + Ray Marching)                    │
│     • Voxel ray traversal for horizon/chunks beyond mesh LOD│
│     • Render to low-res buffer, composite                   │
│     • Only activates beyond mesh LOD distance               │
└─────────────────────────────────────────────────────────────┘
```

**Why not pure ray tracing?**
- Ray traversal shines for sparse scenes and reflections. For dense voxel worlds, rasterization wins on current GPUs.
- Godot's Forward+ renderer is highly optimized. We leverage it, don't replace it.
- Ray marching distant chunks as LOD is the sweet spot (low resolution, few steps).

---

### 2.2 Occlusion Culling: Hierarchical Z-Buffer (HZB)

**This is non-negotiable for massive worlds.**

```cpp
// Conceptual pipeline
Frame N:   Render opaque chunks → Generate depth pyramid (mip chain)
Frame N+1: Before rendering, test chunk AABBs against HZB
           If chunk is occluded → skip entirely (no mesh gen, no draw)
```

Implementation:
- Use Godot's `RenderingDevice` to generate HZB from depth buffer
- Compute shader reduces depth buffer to 8-10 level mip pyramid
- CPU-side: Test chunk bounding boxes against coarse HZB levels
- GPU-side (optional): Indirect draw with occlusion predicate

**Expected win:** In a cave or valley, 60-90% of chunks are occluded. We skip them entirely.

---

### 2.3 Voxel Ray Traversal (Compute Shader LOD)

For chunks beyond the mesh LOD horizon (e.g., > 500 meters):

```glsl
// traverse.comp — Simplified Amanatides & Woo
layout(local_size_x = 8, local_size_y = 8) in;

uniform sampler3D voxel_data;      // Sparse voxel texture
uniform sampler2D depth_pyramid;   // HZB for early termination
uniform vec3 camera_pos;
uniform mat4 inv_view_proj;

void main() {
    vec2 uv = gl_GlobalInvocationID.xy / imageSize(output_img);
    
    // Reconstruct world ray
    vec4 clip = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
    vec4 world = inv_view_proj * clip;
    vec3 ray_dir = normalize(world.xyz / world.w - camera_pos);
    
    // Amanatides & Woo traversal
    ivec3 map_pos = ivec3(floor(camera_pos));
    vec3 delta = abs(1.0 / ray_dir);
    ivec3 step_dir = ivec3(sign(ray_dir));
    vec3 side = (sign(ray_dir) * (vec3(map_pos) - camera_pos) + 
                 sign(ray_dir) * 0.5 + 0.5) * delta;
    
    // Traverse until hit or max distance
    for (int i = 0; i < MAX_STEPS; i++) {
        // Early out: check HZB
        float depth = textureLod(depth_pyramid, uv, coarse_level).r;
        if (distance > depth * far_plane) break;
        
        ivec3 mask = ivec3(
            side.x < side.y && side.x < side.z,
            side.x >= side.y && side.y < side.z,
            side.x >= side.z && side.y >= side.z
        );
        
        map_pos += step_dir * mask;
        side += delta * vec3(mask);
        
        uint voxel = texelFetch(voxel_data, map_pos, 0).r;
        if (voxel != 0) {
            // Hit! Write color + depth
            imageStore(output_img, ivec2(gl_GlobalInvocationID.xy), 
                      lookup_color(voxel));
            return;
        }
    }
    
    // Miss — write sky
    imageStore(output_img, ivec2(gl_GlobalInvocationID.xy), sky_color);
}
```

**Key optimizations:**
- Render at 1/4 or 1/8 resolution, upscale with bilateral filter
- Use sparse voxel octree (SVO) or brick maps for distant data
- Only run for pixels where HZB shows no mesh occlusion

---

### 2.4 Unified Block System

**ONE mesh to rule them all.**

```cpp
// VoxelLibrary — Block type definitions
enum VoxelShape {
    SHAPE_CUBE,           // Standard 1x1x1
    SHAPE_SLAB_BOTTOM,    // 1x0.5x1
    SHAPE_SLAB_TOP,
    SHAPE_STAIRS,         // Special: rotation matters
    SHAPE_DOOR,           // Special: animated, two blocks tall
    SHAPE_PLANT,          // Crossed planes (like flowers)
    SHAPE_LIQUID,         // Special: animated, translucent
};

struct VoxelType {
    uint16_t id;
    VoxelShape shape;
    uint32_t texture_indices[6];  // One per face, into atlas
    uint32_t flags;               // OPAQUE, TRANSPARENT, EMISSIVE, etc.
    uint8_t light_level;          // 0-15, for emissive blocks
};
```

**Rendering strategy:**
- All cubes share the **same vertex buffer** (24 verts, 36 indices)
- Per-instance data: `transform (mat4) + texture_id (uint) + flags (uint)`
- Use `MultiMesh` or compute-driven indirect rendering
- Non-cube shapes (stairs, doors) use **pre-baked variant meshes** in the same buffer

**Texture Atlas:**
- Single 4096x4096 atlas = 256x256 textures × 16x16 grid
- Or 512x512 × 8x8 for higher res
- All block faces index into this atlas via UV offsets

---

### 2.5 LOD System: Chunk Pyramid

```cpp
// Chunk LOD levels
enum ChunkLOD {
    LOD_0 = 0,   // 32×32×32 voxels, full detail
    LOD_1 = 1,   // 16×16×16 (2× downsample)
    LOD_2 = 2,   // 8×8×8 (4× downsample)
    LOD_3 = 3,   // 4×4×4 (8× downsample)
    LOD_4 = 4,   // 2×2×2 (16× downsample) — single cube if any voxel present
    LOD_RAY = 5, // Switch to ray marching
};

// Distance thresholds (configurable)
const float LOD_DISTANCES[] = {
    64.0f,   // LOD 0: 0-64m
    128.0f,  // LOD 1: 64-128m
    256.0f,  // LOD 2: 128-256m
    512.0f,  // LOD 3: 256-512m
    1024.0f, // LOD 4: 512-1024m
    FLT_MAX, // LOD_RAY: 1024m+
};
```

**LOD mesh generation:**
- For LOD > 0, downsample voxel data (OR operation for opacity)
- Greedy meshing on downsampled data = fewer, larger quads
- At LOD_4, entire chunk becomes one cube if non-empty
- Beyond LOD_4, switch to ray-marched impostor

**Seams between LODs:**
- Use "skirts" or transition zones (2-voxel overlap)
- Or accept minor gaps (Minecraft does, players don't notice)

---

### 2.6 Greedy Meshing

Standard optimization: merge adjacent same-texture faces into larger quads.

```cpp
// Pseudocode for greedy meshing on Y-plane
for (y = 0; y < CHUNK_SIZE; y++) {
    for (z = 0; z < CHUNK_SIZE; z++) {
        for (x = 0; x < CHUNK_SIZE; ) {
            VoxelType* voxel = get_voxel(x, y, z);
            if (!voxel->is_opaque() || is_culled(x, y, z, FACE_UP)) {
                x++;
                continue;
            }
            
            // Greedy extend in X
            int width = 1;
            while (x + width < CHUNK_SIZE && 
                   can_merge(x, y, z, x + width, y, z, FACE_UP)) {
                width++;
            }
            
            // Greedy extend in Z
            int height = 1;
            bool extended = true;
            while (extended && z + height < CHUNK_SIZE) {
                for (int dx = 0; dx < width; dx++) {
                    if (!can_merge(x + dx, y, z, x + dx, y, z + height, FACE_UP)) {
                        extended = false;
                        break;
                    }
                }
                if (extended) height++;
            }
            
            // Emit quad: (x, z) to (x + width, z + height)
            emit_quad(x, y, z, width, height, FACE_UP, voxel->texture);
            
            // Mark as processed
            for (int dz = 0; dz < height; dz++) {
                for (int dx = 0; dx < width; dx++) {
                    mark_processed(x + dx, y, z + dz, FACE_UP);
                }
            }
            
            x += width;
        }
    }
}
```

**Expected reduction:** 50-90% fewer faces vs naive per-block rendering.

---

## 3. DATA STRUCTURES

### 3.1 Chunk Storage

```cpp
// Chunk: 32×32×32 voxels = 32,768 voxels
// Stored as flat array for cache efficiency
class VoxelChunk : public RefCounted {
    GDCLASS(VoxelChunk, RefCounted)

public:
    static const int SIZE = 32;
    static const int SIZE_CUBED = SIZE * SIZE * SIZE;
    
    // Primary storage: Run-Length Encoding for empty space
    // Secondary: Dense array for active chunks
    enum StorageMode {
        STORAGE_UNIFORM,    // All voxels same type (e.g., air, solid stone)
        STORAGE_RLE,        // Run-length encoded (mostly empty chunks)
        STORAGE_DENSE,      // Full 32KB array (complex terrain)
        STORAGE_PALETTE,    // Sparse palette for builds (few block types)
    };
    
    StorageMode storage_mode;
    
    // Dense storage: direct index = (y * SIZE + z) * SIZE + x
    // Using uint16_t for voxel IDs (65,536 block types)
    Vector<uint16_t> voxel_data;
    
    // RLE storage for mostly-air chunks
    struct RLERun {
        uint16_t voxel_id;
        uint16_t length;  // Max 32,768 per chunk
    };
    Vector<RLERun> rle_data;
    
    // Metadata
    AABB world_bounds;
    bool is_dirty = true;        // Needs mesh regeneration
    bool is_empty = true;        // All air — skip everything
    bool is_full = false;        // All solid — cull faces
    
    // Mesh data (generated on background thread)
    RID mesh_rids[LOD_LEVELS];   // One per LOD
    RID multimesh_rid;
    
    // Neighbor pointers for face culling
    VoxelChunk* neighbors[6] = {nullptr};  // -X, +X, -Y, +Y, -Z, +Z
    
    void set_voxel(int x, int y, int z, uint16_t id);
    uint16_t get_voxel(int x, int y, int z) const;
    void mark_dirty();
    void generate_mesh(int lod);
    
    // Serialization
    PackedByteArray serialize() const;
    void deserialize(const PackedByteArray& data);
};
```

### 3.2 World Streaming

```cpp
class VoxelWorld : public Node3D {
    GDCLASS(VoxelWorld, Node3D)

public:
    // Chunk coordinate system
    // World pos (x,y,z) → Chunk: (x/32, y/32, z/32)
    // Local: (x%32, y%32, z%32)
    
    HashMap<Vector3i, Ref<VoxelChunk>> chunks;
    
    // Active region around camera
    int load_radius = 16;      // Chunks to keep loaded (512m radius)
    int render_radius = 12;    // Chunks to render meshes for
    int mesh_gen_radius = 14;  // Chunks to generate meshes for
    
    // Streaming
    Vector3i current_chunk_pos;
    ThreadPool thread_pool;
    
    // Generation
    Ref<VoxelGenerator> generator;
    
    // Rendering
    RID scenario;  // RenderingServer scenario
    
    void _process(double delta) override;
    void update_streaming();
    void queue_mesh_generation(Vector3i chunk_pos);
    void unload_distant_chunks();
    
    // Public API
    void set_voxel(Vector3i world_pos, uint16_t voxel_id);
    uint16_t get_voxel(Vector3i world_pos) const;
    Ref<VoxelChunk> get_chunk(Vector3i chunk_pos) const;
};
```

### 3.3 Sparse Voxel Octree (for Ray LOD)

```cpp
// For distant chunks rendered via ray marching
class VoxelOctree : public RefCounted {
    GDCLASS(VoxelOctree, RefCounted)

public:
    struct Node {
        union {
            uint32_t children[8];  // Indices to child nodes (0 = leaf/empty)
            uint32_t voxel_id;      // Leaf node: single voxel type
        };
        bool is_leaf;
        uint8_t occupancy;  // Bitmask of which children exist
    };
    
    Vector<Node> nodes;
    uint32_t root_index;
    
    // Build from chunk data
    void build_from_chunk(const VoxelChunk& chunk, int max_depth = 5);
    
    // Upload to GPU as SSBO
    RID buffer_rid;
    void upload_to_gpu();
};
```

---

## 4. THREADING MODEL

```
MAIN THREAD (Godot):
├── _process(): Update camera, queue streaming
├── _physics_process(): Player movement, collision
└── Render: Submit draw calls (Godot handles this)

BACKGROUND THREADS (WorkerThreadPool):
├── Chunk Generation: Procedural terrain
├── Mesh Generation: Greedy meshing + LOD
├── Serialization: Save/load chunks to disk
└── Octree Build: SVO construction for ray LOD

GPU (Compute Shaders):
├── HZB Generation: Depth pyramid
├── Occlusion Culling: Chunk visibility test
├── Ray Traversal: Distant chunk rendering
└── Post-Process: Upscale ray LOD, composite
```

**Critical rule:** Never block main thread. Mesh generation is async. Chunks appear when ready.

---

## 5. MEMORY BUDGET

| Component | Budget | Notes |
|-----------|--------|-------|
| Loaded chunks | 1024 chunks | 32³ each, ~32MB with RLE |
| Mesh data | 256MB | Vertex buffers, index buffers |
| Texture atlas | 64MB | 4096×4096 × RGBA8 |
| SVO (ray LOD) | 128MB | Sparse octree for distant chunks |
| HZB | 8MB | Depth pyramid (10 levels) |
| **Total** | **~500MB** | Fits in 2GB VRAM budget for Quest |

---

## 6. ADVANCED TECHNIQUES (Research Phase)

### 6.1 Sparse Voxel DAG (SVDAG) — AOKANA Method
**Source:** [Aokana: GPU-Driven Voxel Rendering Framework](https://arxiv.org/html/2505.02017v1) (2025)

Revolutionary approach from Fudan/Harvard researchers:
- **SVDAG Compression:** Merge isomorphic subtrees of SVO into DAG
- **9× memory reduction** vs raw voxels
- **4.8× faster rendering** than HashDAG at scale
- **LOD + Streaming:** Only 5% of scene data in VRAM at any time
- **GPU-Driven Pipeline:** Compute shaders for culling, ray marching, visibility buffer

**Key insight for Aleph:** Use multiple shallow SVDAGs (one per chunk) instead of one giant tree. Better cache locality, easier streaming.

```cpp
// SVDAG Node Structure (64-bit optimized)
struct SVDAGNode {
    uint32_t child_mask;      // 8 bits: which children exist
    uint32_t leaf_count;      // Subtree leaf count (for DFS color lookup)
    uint32_t child_ptr;       // Offset to child array
};

// For leaf nodes (deepest 4×4×4 sub-chunks):
// Use 64-bit bitmap instead of tree nodes
uint64_t leaf_bitmap;  // Each bit = one voxel exists
```

### 6.2 Sparse 64-Trees (Wide Trees)
**Source:** [dubiousconst282.github.io](https://dubiousconst282.github.io/2024/10/03/voxel-ray-tracing/) (2024)

Alternative to octrees: **4³ branching factor** instead of 2³:
- **3× less memory** than SVO (0.19 vs 0.57 bytes/voxel)
- **64-bit child masks** fit in one uint64_t
- **Better cache efficiency** via sequential memory access
- **Float bit-hacking traversal** using IEEE754 mantissa as tree index

```glsl
// Traversal using float mantissa as implicit tree index
// Range [1.0, 2.0) recursively subdivided by 1/4
uint GetNodeCellIndex(float3 pos, int scaleExp) {
    uint3 cellPos = asuint(pos) >> scaleExp & 3;
    return cellPos.x + cellPos.z * 4 + cellPos.y * 16;
}
```

**Optimization: Ancestor memoization**
- Keep stack of ancestor nodes during traversal
- Backtrack using XOR + firstbithigh (findMSB)
- **2× faster** than naive descent-from-root

**Optimization: 2³ skip coalescing**
- Test if 2×2×2 block is empty via bitmask
- Skip larger empty regions in single step
- **21% faster** traversal

### 6.3 Visibility Buffer Rendering
**Source:** Aokana / Unreal Nanite approach

Instead of traditional G-buffer:
- Render **64-bit visibility buffer**: depth (24b) + normal (3b) + chunk_id (13b) + voxel_coords (24b)
- **Deferred shading** in compute pass
- Reduces bandwidth vs full G-buffer
- Enables **InterlockedMax** for order-independent depth

```cpp
// Visibility Buffer Layout (64 bits):
// [63:40] depth (24 bits, reversed: near=2^24-1, far=0)
// [39:37] normal (3 bits, axis + sign)
// [36:24] chunk_id (13 bits)
// [23:0]  voxel xyz (8 bits each)
```

### 6.4 Indirect Rendering (GPU-Driven)
**Source:** GPU-Driven Rendering pipelines (Ubisoft, 2015)

Eliminate CPU draw call bottleneck:
1. **Chunk Culling Pass:** Compute shader frustum + occlusion culls chunks
2. **Tile Selection Pass:** 8×8 tiles, Hi-Z culling, generate tile-chunk pairs
3. **Indirect Dispatch:** Ray marching only for visible tile-chunk pairs
4. **Zero CPU involvement** in per-chunk decisions

### 6.5 Temporal Reprojection (for VR)
- Reuse last frame's color where possible
- Reduces ray marching cost by 50-70%
- Essential for consistent VR frame times

### 6.6 Virtual Texturing
- If texture atlas exceeds GPU memory
- Stream texture tiles based on distance/view
- Overkill for 4096×4096, but scalable

### 6.7 Indirect Lighting (cheap)
- Precomputed ambient occlusion per vertex
- Or: Screen-space GI (Godot already has this)
- No real-time GI needed for blocky aesthetic

### 6.8 Frustum Culling (obvious but critical)
- CPU: Test chunk AABB against camera frustum
- Reject chunks behind camera early
- Combined with HZB = massive win

### 6.9 Chunk Priority Queue
- Sort chunks by distance to camera
- Generate meshes for near chunks first
- Far chunks can wait (or use lower LOD)

### 6.10 Face Culling Optimization
- Don't generate faces between solid blocks
- Don't generate faces on chunk borders if neighbor is solid
- Track "is_full" and "is_empty" per chunk to skip entirely

---

## 7. IMPLEMENTATION ROADMAP

### Phase 1: Core Foundation (Week 1-2)
- [ ] VoxelChunk data structure with RLE/Palette/Dense storage
- [ ] VoxelWorld streaming system
- [ ] Basic procedural generator (noise-based terrain)
- [ ] Naive meshing (one quad per visible face)
- [ ] **Unified Block System** — Single mesh, texture atlas

### Phase 2: Optimization (Week 3-4)
- [ ] **Greedy meshing** — 50-90% face reduction
- [ ] **Frustum culling** — CPU-side chunk rejection
- [ ] **Face culling** — Neighbor-aware, skip internal faces
- [ ] **Chunk LOD system** — 5-level pyramid (32³ → 2³)
- [ ] **MultiMesh batching** — Single draw call per chunk

### Phase 3: GPU Acceleration (Week 5-6)
- [ ] **HZB Occlusion Culling** — Depth pyramid, skip occluded chunks
- [ ] **Compute shader setup** — Godot RenderingDevice integration
- [ ] **Indirect rendering** — GPU-driven chunk dispatch
- [ ] **Visibility Buffer** — 64-bit deferred shading

### Phase 4: Advanced Ray Techniques (Week 7-8)
- [ ] **Sparse Voxel DAG (SVDAG)** — Chunk compression for far LOD
- [ ] **Voxel ray traversal** — Amanatides & Woo compute shader
- [ ] **Sparse 64-Trees** — Alternative to octrees (3× memory savings)
- [ ] **Temporal reprojection** — VR frame time consistency

### Phase 5: Polish & Platform Optimization (Week 9-10)
- [ ] **VR optimization** — Foveated rendering, fixed foveated
- [ ] **Mobile optimization** — Tile-based rendering compatibility
- [ ] **Console ports** — Platform-specific optimizations
- [ ] **Memory profiling** — Stay within 500MB budget

### Phase 6: Experimental (Future)
- [ ] **Neural Radiance Fields** — Extreme LOD with NERF
- [ ] **Mesh Shaders** — If hardware supports (Vulkan 1.3+)
- [ ] **Virtual Geometry** — Nanite-style micro-polygons for non-voxel objects

---

## 8. COMPARISON WITH EXISTING SOLUTIONS

| Feature | Zylann VoxelTools | Minecraft + DH | Aokana (2025) | Aleph Voxel (Ours) |
|---------|-------------------|----------------|---------------|-------------------|
| Architecture | GDExtension | Vanilla + Mod | Unity plugin | Custom C++ module |
| Meshing | Transvoxel (smooth) | Greedy | SVDAG ray | Greedy + SVDAG |
| LOD | Transvoxel LOD | Mesh LOD | SVDAG LOD | Chunk pyramid + ray |
| Occlusion | None | None | Hi-Z + Frustum | HZB + GPU-driven |
| VR Focus | No | No | No | Yes (90 FPS target) |
| Block shapes | Limited | Limited | N/A | Unified system |
| Ray traversal | No | No | Yes (primary) | Yes (distant LOD) |
| Memory efficiency | Moderate | Low | **9× compression** | **SVDAG + RLE** |
| GPU-driven | No | No | Yes | Yes |

**Key differentiators for Aleph:**
- **Hybrid approach:** Rasterization for near, SVDAG ray for far (not pure ray)
- **VR-first:** Temporal reprojection, consistent frame times
- **Godot integration:** Leverages Forward+ renderer, not replacement
- **Modular design:** Can disable features for lower-end hardware

---

## 9. KEY FILES (Module Structure)

```
modules/aleph_voxel/
├── config.py
├── SCsub
├── register_types.h/cpp
├── core/
│   ├── voxel_types.h              # Enums, constants, flags
│   ├── voxel_chunk.h/cpp          # Chunk data (RLE/Dense/Palette)
│   ├── voxel_world.h/cpp          # World streaming & management
│   ├── voxel_library.h/cpp        # Block type definitions
│   └── voxel_storage.h/cpp        # Storage strategies (RLE, SVDAG)
├── generators/
│   ├── voxel_generator.h/cpp      # Base generator class
│   ├── voxel_generator_noise.h/cpp # Noise-based terrain
│   └── voxel_generator_flat.h.cpp # Flat world (testing)
├── rendering/
│   ├── voxel_mesh_builder.h/cpp   # Greedy meshing
│   ├── voxel_mesh_serializer.h/cpp # Mesh caching to disk
│   ├── voxel_lod_manager.h/cpp    # LOD selection & transitions
│   ├── voxel_occlusion.h/cpp      # HZB culling system
│   ├── voxel_ray_lod.h/cpp        # SVDAG ray traversal
│   ├── voxel_visibility_buffer.h.cpp # 64-bit deferred shading
│   └── voxel_indirect_draw.h.cpp  # GPU-driven rendering
├── svdag/
│   ├── svdag_builder.h.cpp        # SVDAG construction from chunks
│   ├── svdag_node.h               # Node structures (64-bit optimized)
│   └── svdag_traversal.h.cpp      # Ray traversal (Amanatides & Woo)
├── shaders/
│   ├── hzb_generate.comp          # Depth pyramid generation
│   ├── chunk_cull.comp            # Frustum + Hi-Z culling
│   ├── voxel_traverse.comp        # SVDAG ray marching
│   ├── voxel_traverse_64tree.comp # Sparse 64-tree variant
│   ├── visibility_resolve.comp    # Deferred shading from vis buffer
│   ├── temporal_reproject.comp    # VR frame reuse
│   └── voxel_vertex.glsl          # Vertex shader (atlas lookup)
└── doc_classes/
    └── [XML documentation]
```

---

## 10. PERFORMANCE TARGETS

| Metric | Target | Notes |
|--------|--------|-------|
| Render distance | 1024m | With LOD + ray fallback |
| Chunks rendered | 500-1000 | After HZB + frustum culling |
| Draw calls | < 100 | Via MultiMesh / indirect rendering |
| VR frame time | < 11.1ms | 90 FPS on Quest 3 |
| PC frame time | < 16.6ms | 60 FPS minimum |
| Chunk load time | < 50ms | From disk or generation |
| Mesh gen time | < 16ms | Per chunk, background thread |
| Memory usage | < 500MB | VRAM budget (Quest-compatible) |
| SVDAG compression | 9× | vs raw voxel data (Aokana baseline) |
| Ray traversal | < 6ms | For 64K³ scene (Aokana baseline) |

### Benchmarks from Research:
- **Aokana (2025):** 64K³ voxel scene (10 billion voxels) rendered in **6ms** on RTX 3060 Ti
- **Sparse 64-Trees:** ~0.19 bytes/voxel (3× better than SVO)
- **HZB Culling:** 60-90% of chunks culled in typical scenes
- **Temporal Reprojection:** 50-70% ray cost reduction for VR

---

*Document version: 1.1*  
*Author: Satan (Aleph Engine Team)*  
*Date: 2026-04-22*  
*Research Update: Added SVDAG (Aokana 2025), Sparse 64-Trees, Visibility Buffer, GPU-Driven Rendering*
