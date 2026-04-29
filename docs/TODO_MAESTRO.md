# PLAN MAESTRO — ALEPH VOXEL ENGINE

**Fecha:** 2026-04-29  
**Estado:** CRÍTICO — Múltiples sistemas rotos  
**Meta:** Motor voxel funcional: mundo infinito, renderizado correcto, interacción (romper/colocar), sistema de bloques data-driven.

---

## PROBLEMAS IDENTIFICADOS

### 🔴 CRÍTICO: Renderizado roto
- **Síntoma:** Bloques no se ven correctamente, caras faltantes, posibles normales invertidas
- **Causa:** Greedy meshing genera caras sin verificar opacidad de bloques vecinos
- **Impacto:** El mundo se ve mal o invisible

### 🔴 CRÍTICO: Mundo NO infinito  
- **Síntoma:** Terreno se repite cada ~63 bloques
- **Causa:** Generador usa `sin(x*0.1) * cos(z*0.1)` — funciones periódicas
- **Impacto:** No hay mundo infinito, es un bucle

### 🔴 CRÍTICO: Código hardcodeado
- **Síntoma:** 60 líneas de switch/case para colores, registro manual de 30 bloques
- **Causa:** Todo definido en C++ estático
- **Impacto:** Añadir un bloque = recompilar motor. Sin modding.

### 🟡 ALTO: Sin interacción (romper/colocar)
- **Síntoma:** Click no hace nada
- **Causa:** No hay raycasting contra el grid de voxels
- **Impacto:** No es un juego, es una demo visual

### 🟡 ALTO: Sin metadatos de bloques
- **Síntoma:** Todos los bloques son iguales (solo ID)
- **Causa:** No hay sistema de estados/rotación/propiedades
- **Impacto:** No hay puertas, escaleras, cofres, antorchas orientadas

### 🟢 MEDIO: Sin persistencia
- **Síntoma:** Chunks descargados se pierden
- **Causa:** No hay save/load de chunks modificados
- **Impacto:** Jugador pierde construcciones al alejarse

---

## FASES DE IMPLEMENTACIÓN

### FASE 1: Generador de Mundo Real (Infinito)
**Objetivo:** Reemplazar sin/cos por FastNoiseLite, mundo infinito funcional.

**Tareas:**
- [ ] Crear `VoxelGeneratorFastNoise` usando Godot's FastNoiseLite
- [ ] Implementar 8 biomas con distribución por ruido (temperatura, humedad)
- [ ] Verificar coordenadas negativas en `world_to_chunk()`
- [ ] Fix: `generate_world()` debe crear chunks bajo demanda, no radio fijo
- [ ] Test: Caminar 1000 bloques en X/Z, verificar terreno NO se repite

**Archivos a tocar:**
- `engine/modules/aleph_voxel/generators/voxel_generator_fast_noise.h` (nuevo)
- `engine/modules/aleph_voxel/generators/voxel_generator_fast_noise.cpp` (nuevo)
- `engine/modules/aleph_voxel/core/voxel_world.cpp` (_process streaming)
- `engine/modules/aleph_voxel/core/voxel_types.h` (world_to_chunk fix)

**Verificación:**
- [ ] Caminar 500 bloques norte → terreno diferente
- [ ] Caminar 500 bloques sur → terreno diferente
- [ ] Coordenadas negativas funcionan (chunk -1, -1, -1)

---

### FASE 2: Sistema de Bloques Data-Driven (JSON)
**Objetivo:** Eliminar todo hardcodeo de bloques, definir todo en JSON.

**Tareas:**
- [ ] Crear `project/data/blocks.json` con definición de TODOS los bloques
- [ ] Crear `project/data/biomes.json` con definición de 8 biomas
- [ ] Crear `VoxelBlockRegistry` C++ (singleton que carga JSON en _ready)
- [ ] Refactor `VoxelWorld::create_default_voxel_types()` → carga desde registry
- [ ] Eliminar `get_voxel_color()` switch/case → usa `VoxelType.color` del registry
- [ ] Crear `VoxelType` completo: nombre, flags, color, textura, dureza, emissive, etc.

**Formato JSON (blocks.json):**
```json
{
  "version": 1,
  "blocks": {
    "grass": {
      "id": 1,
      "name": "Grass",
      "color": [0.35, 0.65, 0.25],
      "flags": ["opaque", "solid"],
      "hardness": 1.0,
      "texture": "grass.png"
    },
    "crystal_cyan": {
      "id": 10,
      "name": "Crystal Cyan",
      "color": [0.20, 0.90, 0.90],
      "flags": ["opaque", "solid", "emissive"],
      "light_level": 8,
      "hardness": 2.5
    }
  }
}
```

**Formato JSON (biomes.json):**
```json
{
  "biomes": {
    "crystal_forest": {
      "id": 0,
      "surface_block": "crystal_cyan",
      "soil_block": "crystal_dark",
      "deep_block": "stone",
      "temperature_range": [-0.5, 0.0],
      "humidity_range": [0.3, 0.8]
    }
  }
}
```

**Archivos a tocar:**
- `project/data/blocks.json` (nuevo)
- `project/data/biomes.json` (nuevo)
- `engine/modules/aleph_voxel/core/voxel_types.h` (expandir VoxelType)
- `engine/modules/aleph_voxel/core/voxel_block_registry.h` (nuevo)
- `engine/modules/aleph_voxel/core/voxel_world.cpp` (usar registry)
- `engine/modules/aleph_voxel/core/voxel_chunk.cpp` (usar registry)

**Verificación:**
- [ ] Añadir bloque nuevo en JSON → aparece en juego sin recompilar
- [ ] Cambiar color en JSON → cambia en juego sin recompilar
- [ ] 8 biomas generan terreno distintivo

---

### FASE 3: Fix Renderizado (Greedy Meshing Correcto)
**Objetivo:** Todas las caras visibles se renderizan correctamente.

**Tareas:**
- [ ] Fix: Greedy meshing debe verificar `type.is_opaque()` antes de culling
- [ ] Fix: Bloques transparentes (cristal) deben generar caras internas
- [ ] Fix: Bloques emissive deben renderizarse siempre (no cullar si emite luz)
- [ ] Fix: Verificar winding order de TODAS las caras con debug_face_colors
- [ ] Fix: Boundary face culling debe consultar chunks vecinos correctamente
- [ ] Fix: get_local() lambda debe usar get_voxel_world() consistentemente
- [ ] Eliminar mesh_rid huérfano en VoxelChunk (no se usa, causa leak)

**Archivos a tocar:**
- `engine/modules/aleph_voxel/core/voxel_chunk.cpp` (greedy meshing)
- `engine/modules/aleph_voxel/core/voxel_chunk.h` (eliminar mesh_rid)

**Verificación:**
- [ ] Modo DEBUG_FACE_COLORS muestra 6 colores distintos, todos visibles desde fuera
- [ ] Bloque de cristal (transparente) se ve desde todos los ángulos
- [ ] No hay caras falsas en bordes de chunk

---

### FASE 4: Raycasting + Romper/Colocar
**Objetivo:** Click izquierdo rompe, click derecho coloca, scroll cambia bloque.

**Tareas:**
- [ ] Crear `VoxelRaycaster.gd` (Amanatides & Woo 3D DDA)
- [ ] Raycast desde cámara, alcance 5 bloques
- [ ] Click izq: detectar bloque → `world.set_voxel(pos, AIR)` → regenerar chunk
- [ ] Click der: detectar cara → `world.set_voxel(pos + normal, selected_block)` → regenerar chunk
- [ ] Regenerar mesh del chunk afectado (y vecinos si es borde)
- [ ] Hotbar visual (1-9) para seleccionar tipo de bloque
- [ ] Feedback visual (partículas de destrucción, sonido placeholder)

**Archivos a tocar:**
- `project/test_voxel/voxel_raycaster.gd` (nuevo)
- `project/test_voxel/player.gd` (integrar raycaster)
- `project/assets/gui/hotbar/hotbar.gd` (ya existe, conectar)
- `engine/modules/aleph_voxel/core/voxel_world.cpp` (exponer set_voxel a GDScript)

**Verificación:**
- [ ] Romper bloque → desaparece, se ve hueco
- [ ] Colocar bloque → aparece con color correcto
- [ ] Romper en borde de chunk → vecino se regenera correctamente

---

### FASE 5: Metadatos de Bloques (Estados)
**Objetivo:** Bloques con información compleja sin romper rendimiento.

**Tareas:**
- [ ] Crear `BlockState` struct (rotación, estado personalizado)
- [ ] Paleta por chunk: solo bloques con metadatos lo tienen
- [ ] Tabla global de extra data (inventarios, texto) con índices uint32
- [ ] Integrar en meshing: usar BlockState para UV rotation (futuro texturas)
- [ ] API GDScript: `world.set_block_state(pos, state)`, `world.get_block_state(pos)`

**Estructura de datos:**
```cpp
// Por chunk (sparse):
HashMap<int, BlockState> block_palette;  // key = index en voxel_data

// Global (para datos grandes):
HashMap<uint32_t, Dictionary> extra_data_table;

struct BlockState {
    uint8_t rotation : 3;    // 0-5 (6 direcciones)
    uint8_t state : 5;       // 0-31 (estados del bloque)
    uint32_t extra_index;    // 0 = sin extra data
};
```

**Archivos a tocar:**
- `engine/modules/aleph_voxel/core/voxel_chunk.h` (añadir paleta)
- `engine/modules/aleph_voxel/core/voxel_world.h` (añadir extra_data_table)
- `engine/modules/aleph_voxel/core/voxel_chunk.cpp` (integrar en set_voxel)

**Verificación:**
- [ ] Colocar escalera → tiene rotación diferente según dirección del jugador
- [ ] Romper escalera → metadatos se limpian
- [ ] Memoria: chunk sin metadatos usa 0 bytes extra

---

### FASE 6: Persistencia de Chunks
**Objetivo:** Mundo modificado se guarda y carga.

**Tareas:**
- [ ] Formato de región: archivos `r.X.Z.bin` (Minecraft-style)
- [ ] Compresión: RLE para chunks uniformes, paleta para mixtos
- [ ] Guardar: voxel_data + light_data + block_palette + extra_data
- [ ] Async save/load con WorkerThreadPool
- [ ] Directorio: `user://saves/world1/region/`

**Archivos a tocar:**
- `engine/modules/aleph_voxel/io/region_file.h` (nuevo)
- `engine/modules/aleph_voxel/io/chunk_serializer.h` (nuevo)
- `engine/modules/aleph_voxel/core/voxel_world.cpp` (save/load hooks)

**Verificación:**
- [ ] Romper 10 bloques → salir → entrar → bloques siguen rotos
- [ ] Construir torre → alejarse 500 bloques → volver → torre existe

---

## DEPENDENCIAS

```
FASE 1 (Generador Real)
    │
    ▼
FASE 2 (Sistema de Bloques) ──► FASE 3 (Fix Renderizado)
    │                                    │
    ▼                                    ▼
FASE 4 (Raycasting) ◄────────────────────┘
    │
    ▼
FASE 5 (Metadatos)
    │
    ▼
FASE 6 (Persistencia)
```

---

## CHECKLIST DE ÉXITO FINAL

- [ ] Caminar 10,000 bloques en cualquier dirección → terreno siempre nuevo
- [ ] Añadir bloque nuevo editando JSON → funciona sin recompilar
- [ ] Romper/colocar bloques → instantáneo, sin lag
- [ ] Construir estructura → guarda al salir, carga al entrar
- [ ] 60+ FPS con view_distance=8 chunks (32³ cada uno)
- [ ] VR: 90 FPS consistente

---

*Plan creado por Satan el 2026-04-29*
*Basado en análisis de código actual + documentación de referencia*
