# ALEPH VOXEL ENGINE — Arquitectura de Bajo Nivel

**Documento:** `VOXEL_ENGINE_ARCHITECTURE.md`  
**Propósito:** Especificación técnica detallada con pseudocódigo. Basado en errores reales.  
**Audiencia:** Satan y futuros agentes que toquen este código.  
**Regla de oro:** Si no está en este documento, no se implementa.

---

## 0. LECCIONES APRENDIDAS (Errores que NO se repetirán)

| # | Error | Consecuencia | Solución |
|---|-------|--------------|----------|
| 1 | `StaticBody3D` + `CollisionShape3D` por chunk | Colisiones como plataforma gigante, 3-5× más lento que meshing | **AABB sweep custom** (ver §5) |
| 2 | Meshing naive sin winding check | Caras TOP/FRONT/RIGHT invisibles (horario vs antihorario) | **Siempre usar SurfaceTool con normales manuales** + test de debug |
| 3 | `generate_normals()` automático | Normales invertidas por orden de vértices horario | **Normales manuales por cara**, nunca confiar en auto-generación |
| 4 | Debug over-engineered (nuevos nodos, materials complejos) | Más código que arreglar, compile errors, memory leaks | **Wireframe toggle simple** (ver §7) |
| 5 | Two-pass world gen con `call_deferred` | Chunks vecinos no existían durante meshing de bordes | **Crear todos los chunks PRIMERO, luego meshing** en _process |
| 6 | `STATE_UNIFORM` cubo gigante sin culling | Z-fighting con chunks mixtos vecinos | **Todo chunk pasa por face-culling**, no hay atajos |
| 7 | Header compartido (`voxel_types.h`) con enums nuevos | Recompilación de TODO el motor (10+ min) | **Enums nuevos van en .cpp o headers privados** |
| 8 | Material nuevo por cada `update_chunk_mesh()` | Memory leaks + stuttering | **Cachear material en VoxelWorld** una sola vez |

---

## 1. ARQUITECTURA GENERAL

```
┌─────────────────────────────────────────────────────────────────┐
│                         MAIN THREAD                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ VoxelWorld   │  │ VoxelPlayer  │  │ EntityManager        │  │
│  │ (streaming)  │  │ (movement)   │  │ (AI, spawning)       │  │
│  └──────┬───────┘  └──────┬───────┘  └──────────────────────┘  │
│         │                 │                                     │
│  ┌──────▼─────────────────▼───────┐  ┌──────────────────────┐  │
│  │        CHUNK MANAGER           │  │   LIGHTING ENGINE    │  │
│  │  - Create/destroy chunks       │  │   (propagation)      │  │
│  │  - Queue mesh jobs             │  └──────────────────────┘  │
│  │  - Track dirty chunks          │                             │
│  └──────┬────────────────────────┘  ┌──────────────────────┐  │
│         │                           │   LIQUID SIMULATOR   │  │
│  ┌──────▼──────┐  ┌──────────────┐  │   (cellular auto)    │  │
│  │ GENERATOR   │  │ MESH BUILDER │  └──────────────────────┘  │
│  │ (threaded)  │  │ (threaded)   │                             │
│  └─────────────┘  └──────────────┘                             │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    RENDERING THREAD (Godot)                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ MeshInstance │  │ MultiMesh    │  │ Material (cached)    │  │
│  │ (per chunk)  │  │ (entities)   │  │ (vertex color)       │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
│                                                                 │
│  FUTURO: GPU-Driven Pipeline                                    │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ Compute      │  │ Visibility   │  │ Indirect Draw        │  │
│  │ (culling)    │  │ Buffer       │  │ (chunks + entities)  │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

**Regla crítica:** El sistema de colisiones NUNCA toca `PhysicsServer3D` para terreno voxel. Es un grid de AABB. Punto.

---

## 2. CHUNK SYSTEM

### 2.1 VoxelChunk (C++ — `voxel_chunk.h/cpp`)

Responsabilidad Única: Almacenar datos de voxels. Nada más. No sabe de meshing, no sabe de colisiones.

```cpp
// === INTERFAZ PÚBLICA ===
class VoxelChunk : public RefCounted {
public:
    static constexpr int SIZE = 32;
    static constexpr int SIZE_CUBED = SIZE * SIZE * SIZE;
    
    // Estados
    enum State { STATE_EMPTY, STATE_UNIFORM, STATE_MIXED };
    
    // Creación
    void create_empty();                          // Todo aire
    void create_uniform(VoxelID id);              // Todo mismo bloque
    void create_from_data(const Vector<VoxelID>& data); // Desde array
    
    // Acceso (COORDENADAS LOCALES 0-31)
    VoxelID get_voxel(int x, int y, int z) const;
    void set_voxel(int x, int y, int z, VoxelID id);
    
    // Acceso seguro (devuelve AIR si fuera de rango)
    VoxelID get_voxel_safe(int x, int y, int z) const;
    
    // Metadata
    State get_state() const { return state; }
    bool is_empty() const { return state == STATE_EMPTY; }
    Vector3i get_chunk_position() const { return chunk_position; }
    void set_chunk_position(Vector3i pos) { chunk_position = pos; }
    
    // Referencia al mundo (para lookups de vecinos en bordes)
    void set_world(VoxelWorld* w) { world = w; }
    
    // Acceso por coordenadas MUNDIALES (consulta chunks vecinos)
    VoxelID get_voxel_world(int world_x, int world_y, int world_z) const;
    
private:
    Vector3i chunk_position;        // Posición en espacio de chunks
    VoxelWorld* world = nullptr;    // Referencia para lookups de vecinos
    State state = STATE_EMPTY;
    Vector<VoxelID> voxel_data;     // Solo para STATE_MIXED
    VoxelID uniform_value = 0;      // Para STATE_UNIFORM
};
```

### 2.2 Decisiones de diseño

1. **No mesh RID en VoxelChunk:** El chunk no sabe de rendering. Los meshes viven en VoxelWorld.
2. **No collision data en VoxelChunk:** Las colisiones son responsabilidad del player mover.
3. **VoxelID = uint16_t:** 65,536 tipos de bloques es suficiente. uint8_t (256) es restrictivo para biomas complejos.

---

## 3. MESH BUILDER SYSTEM

### 3.1 Interfaz del Builder

```cpp
// === INTERFAZ PÚBLICA ===
class VoxelMeshBuilder {
public:
    // Genera mesh para un chunk. Devuelve nullptr si chunk está vacío.
    static Ref<Mesh> build_mesh(
        const VoxelChunk& chunk,
        const Vector<VoxelType>& block_types,
        bool debug_face_colors = false  // Colores por cara para debug
    );
    
private:
    // === GREEDY MESHING POR EJE ===
    static void build_axis_x(
        ArrayMesh& mesh,
        const VoxelChunk& chunk,
        const Vector<VoxelType>& types
    );
    static void build_axis_y(
        ArrayMesh& mesh,
        const VoxelChunk& chunk,
        const Vector<VoxelType>& types
    );
    static void build_axis_z(
        ArrayMesh& mesh,
        const VoxelChunk& chunk,
        const Vector<VoxelType>& types
    );
    
    // Helper: ¿Puedo mergear estas dos caras?
    static bool can_merge_faces(
        const VoxelChunk& chunk,
        int x1, int y1, int z1,
        int x2, int y2, int z2,
        VoxelFace face
    );
};
```

### 3.2 Pseudocódigo: Greedy Meshing (Eje Y - Caras TOP/BOTTOM)

```cpp
void build_axis_y(ArrayMesh& mesh, const VoxelChunk& chunk, const Vector<VoxelType>& types) {
    // Máscara de voxels ya procesados
    bool processed[CHUNK_SIZE][CHUNK_SIZE] = {false};
    
    for (int y = 0; y <= CHUNK_SIZE; y++) {  // y puede ser CHUNK_SIZE (borde superior)
        memset(processed, 0, sizeof(processed));
        
        for (int z = 0; z < CHUNK_SIZE; z++) {
            for (int x = 0; x < CHUNK_SIZE; ) {
                
                // ¿Hay cara aquí?
                // Cara TOP en Y significa: (x, y-1, z) es sólido Y (x, y, z) es aire
                VoxelID id_below = (y > 0) ? chunk.get_voxel(x, y-1, z) : AIR;
                VoxelID id_above = (y < CHUNK_SIZE) ? chunk.get_voxel(x, y, z) : AIR;
                
                if (id_below == AIR || id_above != AIR) {
                    x++;
                    continue;
                }
                
                const VoxelType& type = types[id_below];
                if (!type.is_opaque()) {
                    x++;
                    continue;
                }
                
                // === GREEDY EXTEND X ===
                int width = 1;
                while (x + width < CHUNK_SIZE) {
                    VoxelID next_below = chunk.get_voxel(x + width, y - 1, z);
                    VoxelID next_above = (y < CHUNK_SIZE) ? chunk.get_voxel(x + width, y, z) : AIR;
                    
                    if (next_below != id_below || next_above != AIR) break;
                    if (processed[z][x + width]) break;
                    
                    width++;
                }
                
                // === GREEDY EXTEND Z ===
                int height = 1;
                bool can_extend = true;
                while (z + height < CHUNK_SIZE && can_extend) {
                    for (int dx = 0; dx < width; dx++) {
                        VoxelID next_below = chunk.get_voxel(x + dx, y - 1, z + height);
                        VoxelID next_above = (y < CHUNK_SIZE) ? chunk.get_voxel(x + dx, y, z + height) : AIR;
                        
                        if (next_below != id_below || next_above != AIR) {
                            can_extend = false;
                            break;
                        }
                        if (processed[z + height][x + dx]) {
                            can_extend = false;
                            break;
                        }
                    }
                    if (can_extend) height++;
                }
                
                // === EMIT QUAD ===
                // TOP face: normal (0, 1, 0)
                // Orden antihorario mirando desde +Y
                Vector3 base(x, y, z);
                Color color = debug_face_colors ? DEBUG_COLOR_TOP : type.color;
                
                // Quad: (0,0) → (width,0) → (width,height) → (0,height)
                mesh.add_vertex(base + Vector3(0, 0, 0),        color, Vector3(0, 1, 0));
                mesh.add_vertex(base + Vector3(0, 0, height),   color, Vector3(0, 1, 0));
                mesh.add_vertex(base + Vector3(width, 0, height), color, Vector3(0, 1, 0));
                
                mesh.add_vertex(base + Vector3(0, 0, 0),        color, Vector3(0, 1, 0));
                mesh.add_vertex(base + Vector3(width, 0, height), color, Vector3(0, 1, 0));
                mesh.add_vertex(base + Vector3(width, 0, 0),    color, Vector3(0, 1, 0));
                
                // Mark processed
                for (int dz = 0; dz < height; dz++) {
                    for (int dx = 0; dx < width; dx++) {
                        processed[z + dz][x + dx] = true;
                    }
                }
                
                x += width;
            }
        }
    }
}
```

### 3.3 Reglas de Winding (NO NEGOCIABLE)

Para cada cara, el orden de vértices debe ser **antihorario** cuando miras desde fuera del bloque (desde la dirección de la normal):

| Cara | Normal | Orden de vértices | Mirando desde |
|------|--------|-------------------|---------------|
| TOP | (0, 1, 0) | (0,1,0) → (0,1,1) → (1,1,1) | Arriba (+Y) |
| BOTTOM | (0, -1, 0) | (0,0,1) → (1,0,1) → (1,0,0) | Abajo (-Y) |
| FRONT | (0, 0, 1) | (0,0,1) → (0,1,1) → (1,1,1) | Frente (+Z) |
| BACK | (0, 0, -1) | (1,0,0) → (0,0,0) → (0,1,0) | Atrás (-Z) |
| RIGHT | (1, 0, 0) | (1,0,0) → (1,1,0) → (1,1,1) | Derecha (+X) |
| LEFT | (-1, 0, 0) | (0,0,1) → (0,0,0) → (0,1,0) | Izquierda (-X) |

**Test de verificación:** Si alguna cara se ve negra desde fuera y visible desde dentro, el winding está invertido.

### 3.4 Boundary Face Culling

Cuando un voxel está en el borde del chunk (x=0, x=31, etc.), necesitamos saber si el chunk vecino tiene un bloque sólido.

```cpp
VoxelID get_neighbor_voxel(const VoxelChunk& chunk, int x, int y, int z, VoxelFace face) {
    switch (face) {
        case FACE_LEFT:  // -X
            if (x > 0) return chunk.get_voxel(x - 1, y, z);
            return chunk.get_voxel_world(
                chunk.chunk_position.x * 32 - 1,
                chunk.chunk_position.y * 32 + y,
                chunk.chunk_position.z * 32 + z
            );
        
        case FACE_RIGHT: // +X
            if (x < 31) return chunk.get_voxel(x + 1, y, z);
            return chunk.get_voxel_world(/* coordenadas del vecino */);
        
        // ... etc para cada cara
    }
}
```

**Regla:** Si `get_neighbor_voxel()` devuelve `VOXEL_AIR` o un bloque transparente, generamos la cara. Si devuelve un bloque opaco, no generamos cara.

---

## 4. WORLD STREAMING SYSTEM

### 4.1 VoxelWorld (C++ — `voxel_world.h/cpp`)

```cpp
class VoxelWorld : public Node3D {
public:
    // Configuración
    void set_view_distance(int chunks) { view_distance = chunks; }
    void set_vertical_range(int chunks) { vertical_range = chunks; }
    
    // Generador
    void set_generator(Ref<VoxelGenerator> gen);
    
    // Ciclo de vida
    void _ready() override;
    void _process(double delta) override;
    
    // API pública
    void set_voxel(Vector3i world_pos, VoxelID id);
    VoxelID get_voxel(Vector3i world_pos) const;
    Ref<VoxelChunk> get_chunk(Vector3i chunk_pos) const;
    
    // Debug
    void set_debug_wireframe(bool enabled);
    bool is_debug_wireframe() const { return debug_wireframe; }
    
private:
    // === POOL DE CHUNKS ===
    HashMap<Vector3i, Ref<VoxelChunk>> chunks;
    
    // === MESHES ===
    HashMap<Vector3i, MeshInstance3D*> mesh_instances;
    Ref<StandardMaterial3D> cached_material;
    Ref<StandardMaterial3D> debug_wireframe_material;
    
    // === CONFIGURACIÓN ===
    int view_distance = 8;
    int vertical_range = 4;
    float update_interval = 0.2f;  // Segundos entre updates
    
    // === ESTADO ===
    Vector3i last_player_chunk;
    float update_accumulator = 0.0f;
    bool debug_wireframe = false;
    
    // === THREADING (FUTURO) ===
    // WorkerThreadPool* mesh_thread_pool;
    
    // === MÉTODOS PRIVADOS ===
    void create_chunk(Vector3i chunk_pos);
    void remove_chunk(Vector3i chunk_pos);
    void update_chunk_mesh(Vector3i chunk_pos);
    void remove_chunk_mesh(Vector3i chunk_pos);
    void update_all_meshes();
    
    // Debug
    void update_debug_materials();
};
```

### 4.2 Algoritmo de Streaming (_process)

```cpp
void VoxelWorld::_process(double delta) {
    if (!generator.is_valid()) return;
    
    update_accumulator += delta;
    if (update_accumulator < update_interval) return;
    update_accumulator = 0.0f;
    
    // 1. Calcular chunk del jugador
    Vector3i player_chunk = world_to_chunk(player_position);
    if (player_chunk == last_player_chunk) return;
    last_player_chunk = player_chunk;
    
    // 2. Determinar chunks necesarios
    HashSet<Vector3i> needed_chunks;
    for (int y = -1; y <= vertical_range; y++) {
        for (int z = -view_distance; z <= view_distance; z++) {
            for (int x = -view_distance; x <= view_distance; x++) {
                needed_chunks.insert(player_chunk + Vector3i(x, y, z));
            }
        }
    }
    
    // 3. Crear chunks faltantes (SIN meshing)
    for (const Vector3i& pos : needed_chunks) {
        if (!chunks.has(pos)) {
            create_chunk(pos);
        }
    }
    
    // 4. Generar meshes para TODOS los chunks necesarios
    // (Ahora los vecinos existen, así que boundary culling funciona)
    for (const Vector3i& pos : needed_chunks) {
        update_chunk_mesh(pos);
    }
    
    // 5. Eliminar chunks lejanos
    int remove_radius = view_distance + 2;
    Vector<Vector3i> to_remove;
    for (const auto& kv : chunks) {
        Vector3i diff = kv.key - player_chunk;
        if (abs(diff.x) > remove_radius || abs(diff.y) > remove_radius || abs(diff.z) > remove_radius) {
            to_remove.push_back(kv.key);
        }
    }
    for (const Vector3i& pos : to_remove) {
        remove_chunk(pos);
    }
}
```

### 4.3 Creación de Chunk

```cpp
void VoxelWorld::create_chunk(Vector3i chunk_pos) {
    Ref<VoxelChunk> chunk;
    chunk.instantiate();
    chunk->set_chunk_position(chunk_pos);
    chunk->set_world(this);  // CRÍTICO: para boundary lookups
    
    if (generator.is_valid()) {
        generator->generate_chunk(chunk.ptr(), chunk_pos);
    } else {
        chunk->create_empty();
    }
    
    chunks.insert(chunk_pos, chunk);
}
```

**Nota:** El `set_world(this)` es crítico. Sin esto, los chunks en bordes no pueden consultar vecinos y generan caras falsas.

### 4.4 Actualización de Mesh

```cpp
void VoxelWorld::update_chunk_mesh(Vector3i chunk_pos) {
    Ref<VoxelChunk> chunk = get_chunk(chunk_pos);
    if (chunk.is_null() || chunk->is_empty()) {
        remove_chunk_mesh(chunk_pos);
        return;
    }
    
    // Generar mesh
    Ref<Mesh> mesh = VoxelMeshBuilder::build_mesh(
        *chunk, 
        voxel_types,
        debug_wireframe  // Si true, usa colores por cara
    );
    
    if (mesh.is_null()) {
        remove_chunk_mesh(chunk_pos);
        return;
    }
    
    // Crear o actualizar MeshInstance3D
    MeshInstance3D* mi = nullptr;
    if (mesh_instances.has(chunk_pos)) {
        mi = mesh_instances.get(chunk_pos);
    } else {
        mi = memnew(MeshInstance3D);
        add_child(mi);
        mesh_instances.insert(chunk_pos, mi);
    }
    
    mi->set_mesh(mesh);
    mi->set_position(Vector3(chunk_to_world(chunk_pos)));
    
    // Material
    if (debug_wireframe) {
        if (debug_wireframe_material.is_null()) {
            debug_wireframe_material.instantiate();
            debug_wireframe_material->set_shading_mode(
                StandardMaterial3D::SHADING_MODE_UNSHADED
            );
            debug_wireframe_material->set_flag(
                StandardMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true
            );
        }
        mi->set_material_override(debug_wireframe_material);
    } else {
        if (cached_material.is_null()) {
            cached_material.instantiate();
            cached_material->set_flag(
                StandardMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true
            );
            cached_material->set_shading_mode(
                StandardMaterial3D::SHADING_MODE_PER_PIXEL
            );
        }
        mi->set_material_override(cached_material);
    }
}
```

---

## 5. COLLISION SYSTEM (AABB SWEEP — NO PHYSICS SERVER)

### 5.1 Filosofía

**NO usamos Godot Physics para terreno voxel.** Razones:
- `StaticBody3D` + `CollisionShape3D` crean BVH/octree interno: **3-5× más lento que meshing**
- Godot no permite crear shapes desde threads (bloquea meshing en background)
- Un grid regular de AABB es trivial de resolver con sweep tests

### 5.2 VoxelBoxMover (GDScript o C++)

```gdscript
# === GDScript Version (para iteración rápida) ===
class_name VoxelBoxMover

var world: VoxelWorld
var box_size: Vector3 = Vector3(0.6, 1.8, 0.6)  # Tamaño del jugador
var skin_width: float = 0.01  # Margen para evitar atascos

func _init(p_world: VoxelWorld):
    world = p_world

# Intenta mover 'position' por 'velocity'. Devuelve nueva posición.
func move(position: Vector3, velocity: Vector3) -> Vector3:
    var result = position
    
    # Resolver eje Y primero (gravedad)
    result = move_axis(result, velocity, Vector3(0, 1, 0))
    
    # Resolver eje X
    result = move_axis(result, velocity, Vector3(1, 0, 0))
    
    # Resolver eje Z
    result = move_axis(result, velocity, Vector3(0, 0, 1))
    
    return result

func move_axis(pos: Vector3, velocity: Vector3, axis: Vector3) -> Vector3:
    var move_amount = velocity * axis
    if move_amount.length_squared() < 0.0001:
        return pos
    
    var direction = move_amount.normalized()
    var distance = move_amount.length()
    
    # Raycast contra el grid de voxels
    var hit = raycast_aabb(pos, direction, distance, axis)
    
    if hit.hit:
        # Colisionamos: posicionarnos justo antes del impacto
        return pos + direction * max(0, hit.distance - skin_width)
    else:
        # No colisionamos: mover completo
        return pos + move_amount

func raycast_aabb(origin: Vector3, direction: Vector3, max_dist: float, axis: Vector3) -> Dictionary:
    # Calcular AABB del jugador en posición origen
    var player_aabb = AABB(
        origin - box_size * 0.5,
        box_size
    )
    
    # Calcular AABB destino
    var dest_aabb = AABB(
        origin + direction * max_dist - box_size * 0.5,
        box_size
    )
    
    # Calcular bounds de voxels a testear
    var min_voxel = Vector3i(floor(min(player_aabb.position.x, dest_aabb.position.x)),
                              floor(min(player_aabb.position.y, dest_aabb.position.y)),
                              floor(min(player_aabb.position.z, dest_aabb.position.z)))
    var max_voxel = Vector3i(ceil(max(player_aabb.end.x, dest_aabb.end.x)),
                             ceil(max(player_aabb.end.y, dest_aabb.end.y)),
                             ceil(max(player_aabb.end.z, dest_aabb.end.z)))
    
    var closest_hit = INF
    var hit_normal = Vector3.ZERO
    
    # Testear cada voxel en el camino
    for x in range(min_voxel.x, max_voxel.x + 1):
        for y in range(min_voxel.y, max_voxel.y + 1):
            for z in range(min_voxel.z, max_voxel.z + 1):
                if world.get_voxel(Vector3i(x, y, z)) == 0:  # AIR
                    continue
                
                # AABB del voxel
                var voxel_aabb = AABB(Vector3(x, y, z), Vector3(1, 1, 1))
                
                # ¿El AABB expandido del jugador intersecta este voxel?
                var expanded = player_aabb
                expanded.position -= box_size * 0.5
                expanded.size += box_size
                
                if not expanded.intersects(voxel_aabb):
                    continue
                
                # Calcular distancia de impacto
                var hit_dist = calculate_hit_distance(origin, direction, voxel_aabb, axis)
                if hit_dist < closest_hit:
                    closest_hit = hit_dist
                    hit_normal = -axis  # Normal opuesta a la dirección
    
    return {
        "hit": closest_hit < INF,
        "distance": closest_hit,
        "normal": hit_normal
    }
```

### 5.3 Integración con CharacterBody3D

```gdscript
# === player_controller.gd ===
extends CharacterBody3D

@export var voxel_world: VoxelWorld
@export var speed: float = 5.0
@export var jump_velocity: float = 8.0
@export var gravity: float = 20.0

var box_mover: VoxelBoxMover
var is_noclip: bool = false

func _ready():
    box_mover = VoxelBoxMover.new(voxel_world)

func _physics_process(delta):
    if is_noclip:
        _process_noclip(delta)
        return
    
    # Input
    var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
    var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
    
    # Horizontal movement
    var velocity_xz = direction * speed
    
    # Gravity
    velocity.y -= gravity * delta
    
    # Jump
    if Input.is_action_just_pressed("jump") and is_on_ground():
        velocity.y = jump_velocity
    
    # Combine
    var target_velocity = Vector3(velocity_xz.x, velocity.y, velocity_xz.z)
    
    # Move with AABB sweep
    global_position = box_mover.move(global_position, target_velocity * delta)
    
    # Update velocity for next frame
    velocity = target_velocity

func is_on_ground() -> bool:
    # Raycast hacia abajo desde los pies
    var feet_pos = global_position - Vector3(0, box_mover.box_size.y * 0.5, 0)
    var hit = box_mover.raycast_aabb(feet_pos, Vector3(0, -1, 0), 0.1, Vector3(0, 1, 0))
    return hit.hit

func _process_noclip(delta):
    var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
    var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
    
    if Input.is_action_pressed("jump"):
        direction += Vector3.UP
    if Input.is_action_pressed("crouch"):
        direction += Vector3.DOWN
    
    global_position += direction * speed * delta * 2.0
```

### 5.4 Ventajas del AABB Sweep

| Métrica | Godot Physics | AABB Sweep Custom |
|---------|---------------|-------------------|
| Setup por chunk | `StaticBody3D` + `CollisionShape3D` | Nada (puramente query) |
| Costo de colisión | BVH traversal (O(log n)) | Grid lookup (O(1)) |
| Thread safety | NO (Godot Physics no permite threads) | Sí (solo lectura de voxel data) |
| Precisión | Depende de Godot | Perfecta (grid exacto) |
| VR frame time | Inconsistente | Consistente (sin allocation de physics) |

---

## 6. GENERATOR SYSTEM

### 6.1 Interfaz

```cpp
class VoxelGenerator : public RefCounted {
    GDCLASS(VoxelGenerator, RefCounted)
public:
    virtual void generate_chunk(VoxelChunk* chunk, Vector3i chunk_pos) = 0;
};
```

### 6.2 Generador de Biomas (pseudocódigo)

```cpp
class VoxelGeneratorBiome : public VoxelGenerator {
public:
    void generate_chunk(VoxelChunk* chunk, Vector3i chunk_pos) override {
        Vector<VoxelID> data;
        data.resize(CHUNK_SIZE_CUBED);
        
        Vector3i world_base = chunk_to_world(chunk_pos);
        
        for (int y = 0; y < CHUNK_SIZE; y++) {
            for (int z = 0; z < CHUNK_SIZE; z++) {
                for (int x = 0; x < CHUNK_SIZE; x++) {
                    int world_y = world_base.y + y;
                    float world_x = world_base.x + x;
                    float world_z = world_base.z + z;
                    
                    // Sample noise
                    float height_noise = noise_2d(world_x * 0.05f, world_z * 0.05f);
                    int terrain_height = ground_level + (int)(height_noise * 8.0f);
                    
                    // Determine biome
                    BiomeType biome = get_biome(world_x, world_z);
                    
                    VoxelID id = VOXEL_AIR;
                    
                    if (world_y < terrain_height - 3) {
                        id = get_deep_block(biome);      // Piedra / equivalente
                    } else if (world_y < terrain_height) {
                        id = get_soil_block(biome);      // Tierra / equivalente
                    } else if (world_y == terrain_height) {
                        id = get_surface_block(biome);   // Pasto / equivalente
                    }
                    
                    data[y * CHUNK_SIZE * CHUNK_SIZE + z * CHUNK_SIZE + x] = id;
                }
            }
        }
        
        chunk->create_from_data(data);
    }
};
```

---

## 7. DEBUG SYSTEM (Simplificado)

### 7.1 Regla: Debug = Wireframe Toggle

**NO creamos nuevos nodos de debug.** No `MeshInstance3D` extras, no `ImmediateMesh`, no sistemas complejos.

**Una sola propiedad:**
```cpp
bool debug_wireframe = false;
```

Cuando `true`:
- El material del chunk usa `SHADING_MODE_UNSHADED`
- Se pintan las caras con colores únicos por dirección (para detectar normales invertidas)

Cuando `false`:
- Material normal con `FLAG_ALBEDO_FROM_VERTEX_COLOR`

### 7.2 Colores de Debug por Cara

```cpp
static const Color DEBUG_FACE_COLORS[6] = {
    Color(1.0f, 1.0f, 0.0f),  // LEFT   - Amarillo
    Color(0.0f, 0.0f, 1.0f),  // RIGHT  - Azul
    Color(1.0f, 0.0f, 1.0f),  // BOTTOM - Magenta
    Color(0.0f, 1.0f, 1.0f),  // TOP    - Cyan
    Color(0.0f, 1.0f, 0.0f),  // BACK   - Verde
    Color(1.0f, 0.0f, 0.0f),  // FRONT  - Rojo
};
```

### 7.3 Cómo activar

En el Inspector de `VoxelWorld`, checkbox simple: `[ ] Debug Wireframe`

No hay más. Si necesitas ver normales, usa el modo "Face Colors" y revisa que cada cara tenga el color correcto desde la dirección esperada.

---

## 8. THREADING MODEL (Fase 2)

### 8.1 Estado Actual (Fase 1)

Todo en main thread. Esto es correcto para prototipado y hasta ~100 chunks.

### 8.2 Fase 2: WorkerThreadPool

```cpp
void VoxelWorld::_process(double delta) {
    // ... (streaming logic) ...
    
    // En vez de llamar update_chunk_mesh() directamente:
    // queue_mesh_job(chunk_pos);
}

void queue_mesh_job(Vector3i chunk_pos) {
    // Añadir a cola de trabajo
    pending_mesh_jobs.push_back(chunk_pos);
    
    // WorkerThreadPool ejecutará en background:
    WorkerThreadPool::TaskID task = WorkerThreadPool::get_singleton()->add_native_task(
        &VoxelWorld::_build_mesh_thread,
        this,
        chunk_pos,
        true,  // high priority
        "VoxelMeshBuild"
    );
}

// Esta función corre en background thread
void _build_mesh_thread(void* userdata) {
    Vector3i chunk_pos = *(Vector3i*)userdata;
    Ref<VoxelChunk> chunk = get_chunk(chunk_pos);
    
    // Generar mesh (thread-safe: solo lectura de chunk data)
    Ref<Mesh> mesh = VoxelMeshBuilder::build_mesh(*chunk, voxel_types);
    
    // Encolar resultado para main thread
    // (No podemos llamar add_child() desde thread)
    completed_meshes.push_back({chunk_pos, mesh});
}

// En _process(), consumir resultados:
void consume_completed_meshes() {
    for (const auto& result : completed_meshes) {
        apply_mesh_to_instance(result.chunk_pos, result.mesh);
    }
    completed_meshes.clear();
}
```

**Regla crítica de threading:**
- ✅ **Permitido en threads:** Lectura de voxel data, generación de arrays de vértices
- ❌ **NO permitido en threads:** Crear nodos (`MeshInstance3D`), asignar materiales, tocar `RenderingServer`

---

## 9. FLUJO DE DATOS

```
JUGADOR SE MUEVE
       │
       ▼
┌──────────────┐
│ VoxelWorld   │──► Calcula nuevos chunks necesarios
│ _process()   │
└──────┬───────┘
       │
       ▼
┌──────────────┐     ┌──────────────┐
│ Create Chunk │──►  │ Generator    │──► Rellena voxel_data[]
│ (si falta)   │     │ (noise)      │
└──────┬───────┘     └──────────────┘
       │
       ▼
┌──────────────┐     ┌──────────────┐
│ Mesh Builder │──►  │ Greedy       │──► Array de vértices
│ (C++ thread) │     │ Meshing      │    + índices + colores
└──────┬───────┘     └──────────────┘
       │
       ▼
┌──────────────┐
│ Main Thread  │──► Crea MeshInstance3D + assign mesh
│ Apply Mesh   │    (Godot RenderingServer call)
└──────┬───────┘
       │
       ▼
┌──────────────┐     ┌──────────────┐
│ Render Frame │──►  │ Godot        │──► Pantalla
│              │     │ Forward+     │
└──────────────┘     └──────────────┘

PARALELO:
┌──────────────┐
│ Player       │──► VoxelBoxMover.query(voxel_grid)
│ Controller   │    (NO toca PhysicsServer)
│ _physics_pr  │
└──────────────┘
```

---

## 10. CHECKLIST DE IMPLEMENTACIÓN

### Phase 1: Core (YA — funciona pero roto)
- [x] VoxelChunk data structure
- [x] VoxelWorld streaming
- [x] Basic generator (noise)
- [x] Naive meshing (CON BUGS)
- [ ] **FIX: Winding order correcto**
- [ ] **FIX: Boundary face culling con vecinos**
- [ ] **FIX: Eliminar colisiones de Godot Physics**

### Phase 1.5: Correcciones Críticas (SIGUIENTE)
- [ ] Implementar VoxelBoxMover (GDScript)
- [ ] Implementar greedy meshing correcto
- [ ] Test unitario de winding order
- [ ] Simplificar debug a wireframe toggle

### Phase 2: Optimización
- [ ] WorkerThreadPool para meshing
- [ ] Face culling completo (no solo internal)
- [ ] Frustum culling de chunks

### Phase 3: GPU Acceleration
- [ ] HZB occlusion culling
- [ ] Compute shader setup
- [ ] Indirect rendering

### Phase 4: Features de Mundo
- [ ] Block metadata system (estados, rotación)
- [ ] Texture atlas system
- [ ] Biome system completo (8 biomas alien)
- [ ] Ore/structure generation

### Phase 5: Entidades y Jugabilidad
- [ ] Entity Component System (ECS)
- [ ] Entity AI (pathfinding A* en grid)
- [ ] Entity spawning/despawning por chunks
- [ ] Inventory system
- [ ] Crafting system

### Phase 6: Lighting
- [ ] Chunk-based light propagation (BFS)
- [ ] Torch light (point lights)
- [ ] Sun light (directional + ambient)
- [ ] Lightmap baking para static

### Phase 7: Líquidos
- [ ] Cellular automata flow (water/lava)
- [ ] Liquid levels (0-7)
- [ ] Infinite water source rules

### Phase 8: Persistencia y Multiplayer
- [ ] Save/load chunks (formato binario comprimido)
- [ ] Region files (Minecraft-style)
- [ ] Networking: client-server architecture
- [ ] Entity sync
- [ ] Block update sync

---

## 11. DECISIONES DE DISEÑO (Justificadas)

| Decisión | Alternativa | Por qué elegimos esto |
|----------|-------------|----------------------|
| AABB sweep custom | Godot Physics | 3-5× más rápido, thread-safe, sin allocations |
| MeshInstance3D por chunk | MultiMesh | Más simple, Godot maneja culling interno. MultiMesh para Phase 3 |
| Greedy meshing | Naive / Transvoxel | Naive es lento. Transvoxel es para smooth terrain, no blocky |
| uint16_t voxel IDs | uint8_t | 256 tipos no alcanzan para 8 biomas × 3-4 bloques cada uno |
| 32³ chunks | 16³ / 64³ | 32 es el sweet spot para greedy meshing (suficientes caras para mergear) |
| Vertex colors | Texture atlas (ahora) | Vertex colors = 0 draw calls de texturas. Atlas = Phase 2 |
| No debug gizmos | Nodos de debug complejos | Menos código = menos bugs. Wireframe es suficiente |
| C++ module | GDExtension | Performance, acceso directo a Godot internals (RenderingDevice) |

---

## 12. TESTING

### 12.1 Test de Winding Order

1. Generar mundo plano (superficie a Y=16)
2. Colocar cámara en (0, 20, 0) mirando hacia abajo
3. **Esperado:** Se ve la superficie verde (pasto)
4. Si se ve negra o invisible: winding de TOP está invertido

### 12.2 Test de Colisiones

1. Desactivar noclip
2. Spawnear en (0, 50, 0)
3. **Esperado:** Jugador cae y aterriza en Y=16 (superficie del terreno)
4. Si atraviesa el terreno: VoxelBoxMover no está funcionando

### 12.3 Test de Boundary Culling

1. Generar mundo con view_distance=1 (solo 1 chunk alrededor)
2. Mirar los bordes del chunk
3. **Esperado:** No hay caras falsas en los bordes (no se ve "muro" de caras hacia afuera)
4. Si hay caras en bordes: boundary lookup de vecinos está roto

---

## 13. LIGHTING SYSTEM (Chunk-Based Light Propagation)

### 13.1 Filosofía

NO usamos Godot lights para iluminación de bloques. Razones:
- `OmniLight3D` por antorcha = muerte de performance con 1000+ luces
- Forward+ tiene límite de 256 luces por cluster
- Voxel lighting es **propagación de luz por grid** (BFS), no ray tracing

**Arquitectura:**
- Cada bloque almacena 2 valores de luz de 4 bits (0-15): `sun_light` y `torch_light`
- Sun light: propagación top-down con skylight
- Torch light: propagación omnidireccional desde fuentes (BFS)
- Light value final = max(sun, torch)
- Colores: sun = blanco-azulado, torch = naranja-amarillo

### 13.2 Chunk Light Storage

```cpp
// Agregar a VoxelChunk:
struct LightData {
    uint8_t sun : 4;    // 0-15, skylight
    uint8_t torch : 4;  // 0-15, point light
};

Vector<LightData> light_data;  // SIZE_CUBED elementos, inicializado en 0
```

### 13.3 Sun Light Propagation (Top-Down)

```cpp
void propagate_sunlight(VoxelChunk* chunk) {
    // Para cada columna X,Z:
    for (int z = 0; z < SIZE; z++) {
        for (int x = 0; x < SIZE; x++) {
            int light = 15;  // Máxima luz solar arriba
            
            // De arriba hacia abajo
            for (int y = SIZE - 1; y >= 0; y--) {
                int idx = y * SIZE * SIZE + z * SIZE + x;
                VoxelID id = chunk->get_voxel(x, y, z);
                
                if (is_opaque(id)) {
                    light = 0;  // Bloque opaco bloquea luz
                } else {
                    chunk->light_data[idx].sun = light;
                    if (light > 0) light--;  // Decay por distancia
                }
            }
        }
    }
}
```

### 13.4 Torch Light Propagation (BFS)

```cpp
void propagate_torchlight(VoxelWorld* world, Vector3i source_pos, int intensity) {
    // Queue: {position, light_level}
    Queue<Pair<Vector3i, int>> queue;
    queue.push({source_pos, intensity});
    
    HashSet<Vector3i> visited;
    visited.insert(source_pos);
    
    while (!queue.is_empty()) {
        auto [pos, light] = queue.pop();
        
        // Set light
        world->set_torch_light(pos, light);
        
        if (light <= 1) continue;
        
        // Propagar a 6 vecinos
        for (Vector3i dir : {Vector3i(1,0,0), Vector3i(-1,0,0), 
                             Vector3i(0,1,0), Vector3i(0,-1,0),
                             Vector3i(0,0,1), Vector3i(0,0,-1)}) {
            Vector3i neighbor = pos + dir;
            if (visited.has(neighbor)) continue;
            if (is_opaque(world->get_voxel(neighbor))) continue;
            
            visited.insert(neighbor);
            queue.push({neighbor, light - 1});
        }
    }
}
```

### 13.5 Integración con Mesh Builder

```cpp
// En VoxelMeshBuilder::build_mesh, al emitir vértices:
Color base_color = type.color;
float light_level = chunk->get_light(x, y, z) / 15.0f;
Color final_color = base_color * light_level;

// Aplicar tinte de luz
if (chunk->get_sun_light(x,y,z) > chunk->get_torch_light(x,y,z)) {
    final_color = final_color.lerp(Color(0.7, 0.8, 1.0), 0.3);  // Tint azul día
} else {
    final_color = final_color.lerp(Color(1.0, 0.6, 0.3), 0.5);  // Tint naranja antorcha
}

mesh.add_vertex(pos, final_color, normal);
```

### 13.6 Performance

| Escenario | Costo | Solución |
|-----------|-------|----------|
| Place torch | O(r³) BFS | Solo recalcular chunks afectados |
| Break block | O(r³) BFS | Recalcular luz que pasaba por ese bloque |
| Day/night cycle | O(chunks × SIZE²) | Cachear sunlight, solo actualizar ambient |
| 1000 torches | 1000 BFS | Spread updates over frames, no instantáneo |

**Regla:** Nunca recalcular TODA la luz del mundo. Solo chunks dirty + vecinos.

---

## 14. LIQUID SYSTEM (Cellular Automata)

### 14.1 Filosofía

Líquidos = bloques especiales con nivel (0-7) y reglas de flujo. NO usamos Godot physics ni particles para el flujo base.

**Tipos de líquido:**
- Water: flujo infinito si hay source, level 7 max
- Lava: flujo lento (ticks cada 300ms), destruye items
- Alien goo: viscoso, flujo lento, daña jugador

### 14.2 Block States para Líquidos

```cpp
// VoxelType flags:
bool is_liquid;           // Es líquido
bool is_liquid_source;    // Source block (level 7, genera más)
int liquid_viscosity;     // Ticks entre updates (water=1, lava=3)

// En voxel data (usar bits altos de VoxelID o array separado):
struct LiquidState {
    uint8_t level : 3;    // 0-7 (0 = vacío, 7 = source)
    uint8_t source : 1;   // 1 = infinite source
    uint8_t flowing : 1;  // 1 = está fluyendo (para animación)
};
```

### 14.3 Reglas de Flujo (por tick)

```cpp
void update_liquid(VoxelWorld* world, Vector3i pos) {
    VoxelID id = world->get_voxel(pos);
    if (!is_liquid(id)) return;
    
    int level = world->get_liquid_level(pos);
    if (level == 0) return;
    
    // 1. Caer hacia abajo (siempre prioridad)
    Vector3i below = pos + Vector3i(0, -1, 0);
    if (world->get_voxel(below) == AIR) {
        world->set_voxel(below, id);
        world->set_liquid_level(below, 7);  // Caída = source temporal
        world->set_liquid_level(pos, 0);
        world->mark_chunk_dirty(pos);
        return;
    }
    
    // 2. Expandir horizontalmente
    if (level > 1) {
        for (Vector3i dir : {Vector3i(1,0,0), Vector3i(-1,0,0), 
                             Vector3i(0,0,1), Vector3i(0,0,-1)}) {
            Vector3i neighbor = pos + dir;
            if (world->get_voxel(neighbor) == AIR) {
                world->set_voxel(neighbor, id);
                world->set_liquid_level(neighbor, level - 1);
                world->mark_chunk_dirty(pos);
            }
        }
    }
    
    // 3. Source regeneration
    if (is_source(id) && level < 7) {
        world->set_liquid_level(pos, 7);
    }
}
```

### 14.4 Update Scheduling

```cpp
// NO actualizar todos los líquidos cada frame
// Usar cola con prioridad por viscosidad

struct LiquidUpdate {
    Vector3i position;
    uint64_t tick_time;  // Cuándo ejecutar
};

PriorityQueue<LiquidUpdate> liquid_queue;

void schedule_liquid_update(Vector3i pos, int viscosity) {
    liquid_queue.push({
        pos, 
        current_tick + viscosity
    });
}

void process_liquid_updates() {
    while (!liquid_queue.is_empty() && liquid_queue.top().tick_time <= current_tick) {
        auto update = liquid_queue.pop();
        update_liquid(world, update.position);
    }
}
```

### 14.5 Visualización

- Mesh: Usar greedy meshing normal, pero con `alpha < 1.0`
- Animación: UV offset por `flowing` flag (scroll texture)
- Particles: Godot `GPUParticles3D` en surface (splash, lava bubbles) — solo cerca del jugador

---

## 15. ENTITY SYSTEM (Component-Based)

### 15.1 Filosofía

NO usamos nodos Godot para cada entidad. Razones:
- `CharacterBody3D` por entidad = overhead de Godot physics
- 500 entidades = 500 nodos = lag en scene tree
- Necesitamos control total sobre update scheduling

**Arquitectura:** ECS (Entity Component System) ligero
- Entity = ID (uint32_t)
- Component = struct plano (position, velocity, health, etc.)
- System = función que procesa entidades con ciertos componentes

### 15.2 Entity Manager

```cpp
class EntityManager {
public:
    uint32_t spawn_entity(EntityType type, Vector3 position);
    void destroy_entity(uint32_t id);
    void update(double delta);
    
    // Component access
    TransformComponent* get_transform(uint32_t id);
    HealthComponent* get_health(uint32_t id);
    AIComponent* get_ai(uint32_t id);
    
private:
    // Sparse sets para O(1) lookup
    HashMap<uint32_t, TransformComponent> transforms;
    HashMap<uint32_t, HealthComponent> healths;
    HashMap<uint32_t, AIComponent> ais;
    
    // Rendering
    HashMap<uint32_t, MeshInstance3D*> renderers;  // Solo visuales
    
    uint32_t next_id = 1;
};
```

### 15.3 Componentes Principales

```cpp
struct TransformComponent {
    Vector3 position;
    Vector3 velocity;
    Vector3 rotation;
    AABB bounding_box;
};

struct HealthComponent {
    int max_health;
    int current_health;
    float regen_rate;
};

struct AIComponent {
    enum State { IDLE, WANDER, CHASE, ATTACK, FLEE };
    State state = IDLE;
    Vector3 target_position;
    float detection_radius = 16.0f;
    float attack_range = 2.0f;
    float speed = 3.0f;
};

struct RendererComponent {
    Mesh* mesh;
    Material* material;
    Vector3 scale = Vector3(1, 1, 1);
    bool visible = true;
};
```

### 15.4 Pathfinding (A* en Voxel Grid)

```cpp
// A* optimizado para voxels
// No buscamos en 3D completo, solo 2.5D (X,Z + saltos Y)

Vector<Vector3i> find_path(Vector3i start, Vector3i end, VoxelWorld* world) {
    // Heuristic: Manhattan distance
    auto heuristic = [](Vector3i a, Vector3i b) {
        return abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z);
    };
    
    PriorityQueue<Node> open;
    HashSet<Vector3i> closed;
    
    open.push({start, 0, heuristic(start, end), nullptr});
    
    while (!open.is_empty()) {
        Node current = open.pop();
        
        if (current.pos == end) {
            return reconstruct_path(current);
        }
        
        if (closed.has(current.pos)) continue;
        closed.insert(current.pos);
        
        // Generar vecinos: walk, jump up, fall down
        for (auto [offset, cost] : get_valid_moves(current.pos, world)) {
            Vector3i neighbor = current.pos + offset;
            if (closed.has(neighbor)) continue;
            
            float g = current.g + cost;
            float h = heuristic(neighbor, end);
            open.push({neighbor, g, h, &current});
        }
    }
    
    return {};  // No path found
}
```

### 15.5 Entity Spawning por Chunks

```cpp
// Solo spawnear entidades en chunks cargados
// Despawnear cuando chunk se descarga

void on_chunk_loaded(Vector3i chunk_pos) {
    // Spawn mobs según biome
    BiomeType biome = get_biome(chunk_pos);
    int mob_count = get_mob_density(biome);
    
    for (int i = 0; i < mob_count; i++) {
        Vector3 pos = random_position_in_chunk(chunk_pos);
        if (is_valid_spawn_point(pos)) {
            entity_manager.spawn_entity(get_random_mob(biome), pos);
        }
    }
}

void on_chunk_unloaded(Vector3i chunk_pos) {
    // Despawn entidades en este chunk (o persistir si es importante)
    for (uint32_t id : entities_in_chunk(chunk_pos)) {
        entity_manager.destroy_entity(id);
    }
}
```

### 15.6 Rendering de Entidades

```cpp
// Opción A: MeshInstance3D por entidad (ahora, < 200 entidades)
// Opción B: MultiMesh (futuro, 1000+ entidades)

void render_entities() {
    // Agrupar por mesh para minimizar draw calls
    HashMap<Mesh*, Vector<Transform>> batches;
    
    for (auto& [id, renderer] : renderers) {
        if (!renderer.visible) continue;
        auto* transform = get_transform(id);
        batches[renderer.mesh].push_back(
            Transform3D(Basis(), transform->position).scaled(renderer.scale)
        );
    }
    
    // Render batches
    for (auto& [mesh, transforms] : batches) {
        RenderingServer::get_singleton()->multimesh_create();
        // ... set transforms ...
    }
}
```

---

## 16. BLOCK METADATA SYSTEM

### 16.1 Necesidad

No todos los bloques son iguales. Necesitamos:
- Rotación (escaleras, troncos, dispensers)
- Estado (puerta abierta/cerrada, redstone power level)
- Custom data (nombre de chest, contenido de sign)

### 16.2 Paleta por Chunk

```cpp
// En vez de guardar metadata por voxel (32KB extra por chunk),
// usamos paleta: solo bloques con metadata lo tienen

struct BlockState {
    VoxelID id;
    uint8_t rotation : 3;  // 0-5 (6 direcciones)
    uint8_t state : 5;     // 0-31 (estados del bloque)
    // Para datos grandes (inventarios, texto):
    uint32_t extra_data_index;  // Índice a tabla global
};

// Paleta por chunk (sparse)
HashMap<int, BlockState> block_palette;  // key = index en voxel_data

// Tabla global de extra data (inventarios, etc.)
HashMap<uint32_t, Variant> extra_data_table;
```

### 16.3 Registro de Block Types

```cpp
struct VoxelType {
    String name;
    bool is_opaque;
    bool is_solid;
    bool is_liquid;
    bool is_flammable;
    float hardness;  // Segundos para minar
    Color color;     // Vertex color (ahora)
    Rect2 uv_rect;   // Texture atlas (futuro)
    
    // Behaviors
    bool emits_light;
    int light_level;
    bool can_rotate;
    int max_state_values;
    
    // Callbacks (GDScript o C++)
    Callable on_placed;
    Callable on_broken;
    Callable on_neighbor_changed;
};
```

---

## 17. PERSISTENCE SYSTEM

### 17.1 Formato de Región (Minecraft-style)

```
world/
  region/
    r.0.0.bin      # Chunks (0,0) a (31,31)
    r.0.1.bin      # Chunks (0,32) a (31,63)
    r.-1.0.bin     # Chunks (-32,0) a (-1,31)
  player.dat       # Inventario, posición, stats
  level.dat        # Seed, tiempo, reglas
```

### 17.2 Estructura de Región File

```cpp
struct RegionHeader {
    uint32_t magic = 'ALPH';  // 'A','L','P','H'
    uint32_t version = 1;
    uint32_t chunk_count;
    uint32_t padding[5];  // Reservado
};

struct ChunkEntry {
    uint32_t offset;   // Offset en archivo
    uint32_t size;     // Tamaño comprimido
    uint32_t checksum; // CRC32
    uint8_t compression;  // 0=none, 1=zstd, 2=lz4
};

// Chunk data (comprimido):
// - voxel_data (RLE o paleta)
// - light_data
// - block_states (paleta)
// - entities (serialized)
// - tile_entities (chests, etc.)
```

### 17.3 Compresión de Chunk Data

```cpp
// Opción A: RLE (Run Length Encoding) para chunks uniformes
// Opción B: Paleta de bloques (más común en mundo real)

Vector<uint8_t> compress_chunk(const VoxelChunk* chunk) {
    // 1. Contar frecuencias
    HashMap<VoxelID, int> frequencies;
    for (VoxelID id : chunk->voxel_data) {
        frequencies[id]++;
    }
    
    // 2. Si hay pocos tipos diferentes (< 16): usar 4 bits por voxel
    //    Si hay muchos: usar paleta de 16 bits
    
    // 3. Comprimir con zstd
    return zstd_compress(serialized_data);
}
```

### 17.4 Async Save/Load

```cpp
// Guardar en thread para no bloquear main thread
void save_chunk_async(Vector3i chunk_pos) {
    Ref<VoxelChunk> chunk = get_chunk(chunk_pos);
    
    WorkerThreadPool::get_singleton()->add_native_task(
        &save_chunk_thread,
        chunk.ptr(),
        chunk_pos,
        false,  // low priority
        "ChunkSave"
    );
}
```

---

## 18. LOD & DISTANT RENDERING

### 18.1 Problema

View distance = 16 chunks = 16 × 32 = 512 bloques.
- Meshing 16³ chunks = 4096 chunks
- Cada chunk ~1000 vértices = 4M vértices
- Demasiado para 90 FPS en VR

### 18.2 Niveles de LOD

| Distancia | Chunk Size | Detalle |
|-----------|-----------|---------|
| 0-2 chunks | 32³ | Full mesh, greedy |
| 3-6 chunks | 32³ | Simplified (solo bloques opacos) |
| 7-12 chunks | 64³ (merge 2×2×2) | Blocks de 2×2×2 |
| 13-20 chunks | 128³ (merge 4×4×4) | Blocks de 4×4×4 |
| 20+ chunks | 256³ o más | Ray marching / impostor |

### 18.3 LOD Mesh Generation

```cpp
Ref<Mesh> build_lod_mesh(const VoxelChunk* chunk, int lod_level) {
    int step = 1 << lod_level;  // 1, 2, 4, 8
    
    // Sample cada 'step' voxels
    for (int y = 0; y < SIZE; y += step) {
        for (int z = 0; z < SIZE; z += step) {
            for (int x = 0; x < SIZE; x += step) {
                // Si ALGÚN voxel en el rango [x,x+step) es sólido, considerar bloque
                bool solid = false;
                for (int dy = 0; dy < step && !solid; dy++) {
                    for (int dz = 0; dz < step && !solid; dz++) {
                        for (int dx = 0; dx < step && !solid; dx++) {
                            if (is_opaque(chunk->get_voxel(x+dx, y+dy, z+dz))) {
                                solid = true;
                            }
                        }
                    }
                }
                
                if (solid) {
                    // Emitir bloque de tamaño 'step'
                    emit_cube(x, y, z, step);
                }
            }
        }
    }
}
```

### 18.4 Ray Marching para Lejano (Fase 3)

Para chunks muy lejanos (20+), en vez de mesh:
- Renderizar como volumen ray-marched
- Usar SVDAG o Sparse 64-Tree para compresión
- Shader compute para traversal

Ver `docs/Meta/Docs/AgentsMemory/2026-04-22-voxel-research.md`

---

## 19. TEXTURE ATLAS SYSTEM

### 19.1 Motivación

Vertex colors son simples pero limitados:
- No texturas detalladas
- No animaciones de bloques
- No variaciones por bioma

### 19.2 Atlas Layout

```
┌─────────────────────────────────────┐
│  Grass  │  Dirt   │  Stone  │  ...  │  Row 0
├─────────────────────────────────────┤
│  Sand   │  Water  │  Lava   │  ...  │  Row 1
├─────────────────────────────────────┤
│  ...    │  ...    │  ...    │  ...  │
└─────────────────────────────────────┘

Atlas size: 2048×2048 (soporta 256 bloques de 128×128)
```

### 19.3 UV Mapping por Bloque

```cpp
struct VoxelType {
    // ... color, flags ...
    
    // UV en atlas (0.0 - 1.0)
    Rect2 uv_top;
    Rect2 uv_bottom;
    Rect2 uv_side;
    
    // Animación (water, lava, fire)
    bool animated;
    int animation_frames;
    float animation_speed;
};

// En mesh builder:
Vector2 uv = type.uv_top.position + Vector2(
    (float)dx / atlas_width,
    (float)dz / atlas_height
);
```

### 19.4 Material con Atlas

```cpp
Ref<StandardMaterial3D> atlas_material;
atlas_material->set_texture(StandardMaterial3D::TEXTURE_ALBEDO, atlas_texture);
atlas_material->set_flag(StandardMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, false);
```

---

## 20. NETWORKING ARCHITECTURE

### 20.1 Modelo: Client-Server Authoritative

```
┌──────────┐      UDP (compressed)      ┌──────────┐
│ Client 1 │◄──────────────────────────►│ Server   │
│ (render) │  - Block updates           │ (world)  │
│ (input)  │  - Entity positions        │ (physics)│
│ (predict)│  - Player actions          │ (save)   │
└──────────┘                            └──────────┘
     ▲                                       ▲
     └───────────────────────────────────────┘
                    Client 2, 3, 4...
```

### 20.2 Protocolo de Red

```cpp
enum PacketType {
    PACKET_BLOCK_CHANGE,     // x,y,z + new_block_id (3 bytes + 2)
    PACKET_CHUNK_DATA,       // chunk_pos + compressed_data
    PACKET_ENTITY_UPDATE,    // entity_id + position + rotation
    PACKET_PLAYER_INPUT,     // input_state + camera_rotation
    PACKET_ENTITY_SPAWN,     // entity_type + position
    PACKET_ENTITY_DESPAWN,   // entity_id
    PACKET_CHAT,             // message
};

// Block changes: solo enviar diffs, no chunk completo
struct BlockChangePacket {
    int16_t x, y, z;  // Relativo a chunk, o absoluto
    uint16_t block_id;
    uint8_t block_state;  // rotation, etc.
};
```

### 20.3 Client-Side Prediction

```cpp
// Client predice su movimiento localmente
// Server corrige si hay discrepancia

void client_move(Vector3 input) {
    predicted_pos = local_physics_step(predicted_pos, input);
    send_to_server(input);
    
    // Render en predicted_pos (0 latency visual)
}

void on_server_correction(Vector3 server_pos) {
    float error = (predicted_pos - server_pos).length();
    if (error > 0.1f) {
        // Reconciliar: teleportar o interpolar rápido
        predicted_pos = server_pos;
    }
}
```

### 20.4 Entity Interpolation

```cpp
// Para entidades de otros jugadores/NPCs:
// No predecir, interpolar entre posiciones recibidas

struct EntitySnapshot {
    Vector3 position;
    Vector3 rotation;
    uint64_t timestamp;
};

Queue<EntitySnapshot> snapshot_buffer;

void interpolate_entity(double render_time) {
    // Buscar 2 snapshots alrededor de render_time
    // Interpolar linealmente
    // Delay de 100ms para suavidad
}
```

---

## 21. MEMORY MANAGEMENT

### 21.1 Presupuestos de Memoria

| Componente | Budget | Estrategia |
|------------|--------|------------|
| Chunk data (voxels) | 200 MB | uint16_t, 32³ chunks, max 10k chunks |
| Chunk meshes | 300 MB | Vertex + index arrays, LRU cache |
| Texturas | 100 MB | Atlas 2048² × 4 canales |
| Entities | 50 MB | Sparse sets, pool allocation |
| Lights | 20 MB | 4 bits por voxel, propagación on-demand |
| **Total** | **~670 MB** | Target para 8GB VRAM |

### 21.2 Chunk Pooling

```cpp
// NO allocar/deallocar chunks constantemente
// Usar object pool

class ChunkPool {
public:
    Ref<VoxelChunk> acquire();
    void release(Ref<VoxelChunk> chunk);
    
private:
    Vector<Ref<VoxelChunk>> available;
    HashSet<Ref<VoxelChunk>> in_use;
};
```

### 21.3 Mesh LRU Cache

```cpp
// Si un chunk se descarga pero está cerca del borde,
// mantener mesh en cache por 30 segundos

struct CachedMesh {
    Ref<Mesh> mesh;
    double last_accessed;
};

HashMap<Vector3i, CachedMesh> mesh_cache;

void cleanup_mesh_cache() {
    double now = Time::get_singleton()->get_ticks_msec() / 1000.0;
    for (auto it = mesh_cache.begin(); it != mesh_cache.end();) {
        if (now - it->value.last_accessed > 30.0) {
            it = mesh_cache.erase(it);
        } else {
            ++it;
        }
    }
}
```

---

## 22. PERFORMANCE BUDGETS (VR Target: 90 FPS = 11.1ms)

### 22.1 Frame Budget

| Fase | Budget | Notas |
|------|--------|-------|
| Input + Game Logic | 1.0 ms | Player, entities, AI |
| Chunk Streaming | 2.0 ms | Create chunks, queue meshes |
| Mesh Application | 1.5 ms | Main thread: apply meshes from workers |
| Physics (AABB) | 0.5 ms | Player + entity collision queries |
| Liquid Updates | 0.5 ms | Max 100 updates por frame |
| Light Propagation | 0.5 ms | Deferred, spread over frames |
| Entity Updates | 1.0 ms | AI, pathfinding, animations |
| Render (Godot) | 4.0 ms | Culling, draw calls, GPU |
| **Total** | **~11.0 ms** | **Target 90 FPS** |

### 22.2 Optimizaciones Críticas

1. **Nunca allocar en hot path:** Pre-allocar arrays de vértices, reutilizar
2. **Nunca tocar PhysicsServer3D:** AABB sweep solo
3. **Nunca recalcular toda la luz:** Solo chunks dirty
4. **Nunca meshing en main thread (Phase 2+):** WorkerThreadPool
5. **Nunca cargar más chunks de los necesarios:** View distance dinámico según FPS
6. **Nunca usar CollisionShape3D para terreno:** Grid lookup O(1)

---

## 23. WORLD GENERATION PIPELINE

### 23.1 Pipeline de 4 Etapas

```cpp
void generate_chunk(VoxelChunk* chunk, Vector3i pos) {
    // Stage 1: Terrain shape (heightmap + 3D noise)
    generate_terrain_shape(chunk, pos);
    
    // Stage 2: Biome assignment (temperature + humidity noise)
    assign_biomes(chunk, pos);
    
    // Stage 3: Features (caves, ravines, ore veins)
    generate_features(chunk, pos);
    
    // Stage 4: Structures (ruins, dungeons, trees)
    generate_structures(chunk, pos);
    
    // Stage 5: Decoration (grass, flowers, surface details)
    decorate_surface(chunk, pos);
}
```

### 23.2 Biome System (8 Aliens)

```cpp
enum BiomeType {
    BIOME_CRATER,        // Depresiones, roca obsidiana
    BIOME_CRYSTAL,       // Formaciones cristalinas, suelo brillante
    BIOME_ACID,          // Lagos de ácido, vegetación resistente
    BIOME_DUST,          // Planicie polvorienta, poca vegetación
    BIOME_FUNGAL,        // Bosque de hongos gigantes, bioluminiscencia
    BIOME_MAGMA,         // Ríos de magma, roca ígnea
    BIOME_VOID,          // Vacío parcial, islas flotantes
    BIOME_TECH,          // Ruinas alienígenas, metal oxidado
};

struct Biome {
    String name;
    float base_temperature;
    float base_humidity;
    Color ground_color;
    VoxelID surface_block;
    VoxelID subsurface_block;
    VoxelID deep_block;
    float tree_density;
    float ore_richness;
    Array<EntitySpawn> native_entities;
};
```

### 23.3 Noise Configuration

```cpp
// FastNoiseLite configuración recomendada:
// - Terrain height: OpenSimplex2, freq=0.005, octaves=4
// - Caves: Perlin, freq=0.02, octaves=3 (3D)
// - Biome selection: Cellular (Voronoi), freq=0.002
// - Ore veins: Perlin ridged, freq=0.05
```

---

## 24. AUDIO SYSTEM

### 24.1 Arquitectura

NO usar nodos `AudioStreamPlayer3D` por fuente. Overhead innecesario.

```cpp
class VoxelAudioManager {
public:
    void play_block_sound(VoxelID block, SoundType type, Vector3 pos);
    void play_ambient(BiomeType biome, Vector3 player_pos);
    void play_music(ZoneType zone);
    
private:
    // Audio streams cacheados
    HashMap<String, Ref<AudioStream>> sound_cache;
    
    // Pool de AudioStreamPlayer3D (reutilizar)
    Vector<AudioStreamPlayer3D*> player_pool;
    int next_player = 0;
};
```

### 24.2 Sonidos por Bloque

```cpp
struct BlockSounds {
    String place_sound;
    String break_sound;
    String step_sound;
    float step_interval;  // Segundos entre pasos
};

// Ejemplos:
// Stone: "stone_place.ogg", "stone_break.ogg", "stone_step.ogg"
// Grass: "grass_place.ogg", "grass_break.ogg", "grass_step.ogg"
// Metal: "metal_place.ogg", "metal_break.ogg", "metal_step.ogg"
```

---

## 25. MODDING / SCRIPTING API

### 25.1 GDScript API para Mods

```gdscript
# Ejemplo de API pública:

# Registrar bloque custom
VoxelAPI.register_block("my_mod:cool_block", {
    "opaque": true,
    "color": Color.RED,
    "hardness": 2.0,
    "on_placed": func(pos):
        print("Block placed at ", pos)
})

# Registrar generador custom
VoxelAPI.register_generator("my_mod:crystal_caves", func(chunk, pos):
    # Código de generación
    pass
)

# Eventos
VoxelAPI.on_block_broken.connect(func(pos, block_id, player):
    if block_id == "my_mod:cool_block":
        spawn_particles(pos)
)
```

### 25.2 C++ API para Modders Avanzados

```cpp
// Virtual class que mods pueden extender
class VoxelModAPI {
public:
    virtual void on_world_load(VoxelWorld* world) {}
    virtual void on_chunk_generate(VoxelChunk* chunk, Vector3i pos) {}
    virtual void on_block_placed(Vector3i pos, VoxelID id) {}
    virtual void on_block_broken(Vector3i pos, VoxelID id, Entity* player) {}
    virtual void on_entity_tick(Entity* entity, double delta) {}
};
```

---

## 26. FLUJO DE DATOS COMPLETO (Sistema Integrado)

```
INICIALIZACIÓN
       │
       ▼
┌──────────────────┐
│ Load world/seed  │──► Generar o cargar chunks iniciales
│ Init systems     │    (lighting, liquids, entities)
└────────┬─────────┘
         │
         ▼
GAME LOOP (cada frame)
         │
    ┌────┴────┐
    ▼         ▼
┌────────┐  ┌──────────────┐
│ Input  │  │ VoxelWorld   │──► Streaming de chunks
│ Process│  │ _process()   │    (create → mesh → apply)
└────────┘  └──────────────┘
    │              │
    ▼              ▼
┌────────┐  ┌──────────────┐
│ Player │  │ EntityManager│──► Update AI, pathfinding
│ Move   │  │ update()     │    Spawn/despawn
│ (AABB) │  └──────────────┘
└────────┘         │
    │              ▼
    │         ┌──────────────┐
    │         │ Liquid Sim   │──► Process queue (max 100/frame)
    │         └──────────────┘
    │              │
    ▼              ▼
┌──────────────────────────┐
│ Render Frame             │
│ - Chunks (MeshInstance)  │
│ - Entities (MultiMesh)   │
│ - Particles (GPU)        │
│ - Lights (vertex color)  │
└──────────────────────────┘

ASYNC (background threads):
┌──────────────────────────┐
│ WorkerThreadPool         │
│ - Mesh building          │
│ - Chunk generation       │
│ - Pathfinding (A*)       │
│ - Save/Load IO           │
└──────────────────────────┘
```

---

## 27. DECISIONES DE DISEÑO EXTENDIDAS

| Decisión | Alternativa | Por qué |
|----------|-------------|---------|
| Chunk-based lighting | Godot lights | 1000+ luces = muerte. Propagación BFS = O(chunks) |
| Cellular automata liquids | Particle systems | CA es determinista, reproducible, más barato |
| ECS para entidades | Nodos Godot | 500+ nodos = lag. ECS = cache-friendly, O(1) lookup |
| A* pathfinding | Godot Navigation | NavMesh no sirve para voxels. A* en grid es exacto |
| Region files | Un archivo por chunk | Menor overhead de filesystem, mejor compresión |
| zstd compression | gzip/lz4 | zstd = mejor ratio + velocidad. lz4 = más rápido, peor ratio |
| Pool allocation | new/delete | Evita fragmentación, reutiliza memoria, predecible |
| Client-side prediction | Input lag | 100ms de lag es inaceptable. Prediction = 0ms visual |
| Atlas de texturas | Texturas separadas | 1 draw call vs N. Atlas es obligatorio para performance |
| Biome noise Voronoi | Simplex | Voronoi da biomas con bordes nítidos, más naturales |
| Vertex color (ahora) | Texture atlas (ahora) | Vertex colors permiten prototipar rápido. Atlas = Phase 2 |

---

## 28. CHECKLIST COMPLETO DE IMPLEMENTACIÓN

### Phase 1: Core Engine
- [x] VoxelChunk data structure
- [x] VoxelWorld streaming
- [x] Basic generator (noise)
- [x] Naive meshing (CON BUGS)
- [ ] **FIX: Winding order correcto**
- [ ] **FIX: Boundary face culling con vecinos**
- [ ] **FIX: Eliminar colisiones de Godot Physics**
- [ ] Implementar VoxelBoxMover (GDScript)
- [ ] Implementar greedy meshing correcto
- [ ] Test unitario de winding order
- [ ] Simplificar debug a wireframe toggle

### Phase 2: Optimización Base
- [ ] WorkerThreadPool para meshing
- [ ] Face culling completo (internal + boundary)
- [ ] Frustum culling de chunks
- [ ] Chunk mesh LRU cache
- [ ] Object pooling para chunks

### Phase 3: Rendering Avanzado
- [ ] Texture atlas system
- [ ] HZB occlusion culling
- [ ] Compute shader setup
- [ ] Indirect rendering
- [ ] LOD system (4 niveles)
- [ ] Ray marching para lejano

### Phase 4: Mundo Vivo
- [ ] Block metadata system (rotation, states)
- [ ] Biome system completo (8 biomas)
- [ ] Ore/structure generation
- [ ] Tree/vegetation generation
- [ ] Cave generation (3D noise)

### Phase 5: Entidades y Jugabilidad
- [ ] Entity Component System (ECS)
- [ ] Entity AI (A* pathfinding)
- [ ] Entity spawning/despawning
- [ ] Inventory system
- [ ] Crafting system
- [ ] Block breaking/placing
- [ ] Item drops

### Phase 6: Lighting
- [ ] Chunk light storage (sun + torch)
- [ ] Sun light propagation (top-down)
- [ ] Torch light propagation (BFS)
- [ ] Light integration en mesh builder
- [ ] Day/night cycle
- [ ] Block light sources (torch, lava, glowstone)

### Phase 7: Líquidos
- [ ] Liquid block states (level 0-7)
- [ ] Water flow rules
- [ ] Lava flow rules
- [ ] Source block mechanics
- [ ] Liquid rendering (transparency + animation)
- [ ] Liquid particles (splash, bubbles)

### Phase 8: Persistencia
- [ ] Region file format
- [ ] Chunk compression (zstd)
- [ ] Async save/load
- [ ] Player data save
- [ ] World metadata (seed, time)

### Phase 9: Multiplayer
- [ ] Client-server architecture
- [ ] Block update sync
- [ ] Entity interpolation
- [ ] Client-side prediction
- [ ] Player authentication
- [ ] Anti-cheat (server authoritative)

### Phase 10: Polish
- [ ] Audio system (block sounds, ambient, music)
- [ ] Particle effects
- [ ] Screen effects (underwater, lava)
- [ ] UI/HUD (inventory, health, minimap)
- [ ] Settings/Options
- [ ] Modding API
- [ ] VR support (OpenXR)

---

*Documento version: 2.0*  
*Actualizado: 2026-04-28*  
*Autor: Satan*  
*Incluye: Lighting, Liquids, Entities, Persistence, Networking, LOD, Audio, Modding*
