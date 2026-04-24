# Sistema de Biomas — Aleph Voxel

## Filosofía

> **"El bioma es el autor del terreno, no su etiqueta."**

Basado en el enfoque **Biome-First** de Cube World (vs Terrain-First de Minecraft). El bioma se define primero, y luego el terreno se genera según las características de ese bioma.

**Ventajas:**
- Control total sobre el paisaje de cada bioma
- Montañas que se sienten como montañas, no como accidente del ruido
- Diseño intencional del mundo

---

## Arquitectura

```
PLANETA
└── BiomeDistribution
    ├── Voronoi con warping
    ├── Celdas de bioma
    └── Pesos de influencia
        │
        ▼
    TERRAINSHAPER (por bioma)
    ├── Altura base
    ├── Rugosidad
    ├── Features
    └── Composición de bloques
        │
        ▼
    VOXELCHUNK
    └── Voxels generados
```

---

## BiomeDistribution

### Voronoi con Warping

El sistema usa **Voronoi** para dividir el planeta en regiones, pero con **warping** para que los bordes no sean rectos.

```cpp
class BiomeDistribution {
public:
    // Generar para un planeta
    void initialize(uint64_t planet_seed, int num_biomes);
    
    // Para una posición en el planeta, obtener biomas que influyen
    Array<BiomeInfluence> get_influences(Vector2 world_xz);
    
private:
    Array<BiomeRegion> regions;
    
    // Warping: desplazar coordenadas con ruido antes de Voronoi
    Vector2 warp_coordinates(Vector2 pos) {
        float warp_x = simplex_noise(pos.x * 0.01, pos.y * 0.01);
        float warp_y = simplex_noise(pos.x * 0.01 + 100, pos.y * 0.01 + 100);
        return pos + Vector2(warp_x, warp_y) * warp_strength;
    }
};

struct BiomeRegion {
    Vector2 center;        // Centro en espacio 2D (X,Z)
    float radius;          // Radio de influencia
    BiomeID biome_type;    // Tipo de bioma
    float seed_offset;     // Variación única
};

struct BiomeInfluence {
    BiomeID biome;
    float weight;          // 0.0 - 1.0, suma de todos = 1.0
};
```

### Ejemplo Visual

```
Sin warping (Voronoi puro):
┌─────┬─────┬─────┐
│  A  │  B  │  C  │
├─────┼─────┼─────┤
│  D  │  E  │  F  │
├─────┼─────┼─────┤
│  G  │  H  │  I  │
└─────┴─────┴─────┘
Bordes rectos, artificial

Con warping:
┌──┬─────┬──┬────┐
│A │  B  │C │ D  │
├──┘     │  │    │
│   ┌────┘  └────┤
│ E │     F      │
└───┴────────────┘
Bordes orgánicos, naturales
```

---

## Blending Multi-Bioma

### El Problema

En los bordes entre biomas, ¿qué terreno generamos?

**Solución:** Hasta **4 biomas** pueden influir en un punto, con pesos que suman 1.0.

```cpp
float calculate_height(Vector2 world_pos) {
    auto influences = biome_dist.get_influences(world_pos);
    
    float height = 0;
    for (auto& inf : influences) {
        float biome_height = inf.biome->shaper.get_height(world_pos);
        height += biome_height * inf.weight;
    }
    
    return height;
}
```

### Ejemplo

```
Posición en borde entre Plains (70%) y Desert (30%):

Plains:  altura = 64,  variación = 8
Desert:  altura = 62,  variación = 15

Altura final = 0.7 * 64 + 0.3 * 62 = 63.4
Variación    = 0.7 * 8  + 0.3 * 15 = 10.1

Resultado: Terreno que se siente 70% plains, 30% desert
```

---

## TerrainShaper

### Definición por Bioma

Cada bioma tiene un shaper que define cómo se ve su terreno:

```json
{
    "biome_id": "plains",
    "shaper": {
        "base_height": 64,
        "height_variation": 8,
        "noise": {
            "type": "simplex",
            "octaves": 4,
            "persistence": 0.5,
            "lacunarity": 2.0,
            "scale": 0.01
        }
    },
    "blocks": {
        "surface": "grass",
        "subsurface_depth": 3,
        "subsurface": "dirt",
        "deep": "stone"
    },
    "features": [
        {
            "type": "lake",
            "probability": 0.05,
            "min_size": 5,
            "max_size": 20
        },
        {
            "type": "tree",
            "probability": 0.1,
            "types": ["oak", "birch"]
        }
    ]
}
```

### Parámetros Clave

| Parámetro | Descripción | Ejemplos |
|-----------|-------------|----------|
| `base_height` | Altura media del terreno | Ocean: 45, Plains: 64, Mountains: 80 |
| `height_variation` | Qué tan irregular es | Desert: 15, Mountains: 40 |
| `noise_octaves` | Detalle del ruido | 2-6 |
| `noise_scale` | Tamaño de las features | 0.005 (grandes) - 0.05 (pequeñas) |

---

## Generación de Chunk con Biomas

### Flujo Completo

```cpp
Ref<VoxelChunk> Planet::generate_chunk(Vector3i chunk_pos) {
    Ref<VoxelChunk> chunk;
    chunk.instantiate();
    
    // Para cada columna (x,z) en el chunk
    for (int x = 0; x < CHUNK_SIZE; x++) {
        for (int z = 0; z < CHUNK_SIZE; z++) {
            
            // 1. Posición en mundo
            Vector2 world_xz = Vector2(
                chunk_pos.x * CHUNK_SIZE + x,
                chunk_pos.z * CHUNK_SIZE + z
            );
            
            // 2. Obtener biomas que influyen
            auto influences = biome_dist.get_influences(world_xz);
            
            // 3. Calcular altura mezclando biomas
            float height = calculate_height(world_xz, influences);
            
            // 4. Generar columna de voxels
            for (int y = 0; y < CHUNK_SIZE; y++) {
                int world_y = chunk_pos.y * CHUNK_SIZE + y;
                VoxelID voxel = determine_voxel(world_y, height, influences);
                chunk->set_voxel(x, y, z, voxel);
            }
        }
    }
    
    return chunk;
}
```

### Determinar Voxel

```cpp
VoxelID determine_voxel(int world_y, float height, Array<BiomeInfluence>& influences) {
    // Encontrar bioma dominante (mayor peso)
    BiomeID dominant = get_dominant_biome(influences);
    auto& biome = biomes[dominant];
    
    if (world_y > height) {
        return VOXEL_AIR;
    } else if (world_y == (int)height) {
        return biome.blocks.surface;
    } else if (world_y > height - biome.blocks.subsurface_depth) {
        return biome.blocks.subsurface;
    } else {
        return biome.blocks.deep;
    }
}
```

---

## Biomas Base (Propuesta)

| Bioma | Altura | Variación | Características |
|-------|--------|-----------|----------------|
| **Ocean** | 45 | 3 | Agua profunda, arena |
| **Beach** | 48 | 2 | Arena, transición ocean-land |
| **Plains** | 64 | 8 | Hierba, árboles dispersos |
| **Forest** | 65 | 10 | Hierba, muchos árboles |
| **Desert** | 62 | 15 | Arena, cactus, dunas |
| **Mountains** | 80 | 40 | Piedra, nieve en cima, escarpado |
| **Snow** | 70 | 12 | Nieve, hielo, picos |
| **Swamp** | 58 | 5 | Agua poco profunda, árboles de manglar |

---

## Determinismo

### Seed por Planeta

```cpp
// Cada planeta tiene seed única derivada de su posición
uint64_t planet_seed = hash(solar_position.x, solar_position.y, solar_position.z);

// Biomas usan esta seed
biome_dist.initialize(planet_seed, num_biomes);

// Resultado: Mismo planeta = mismos biomas SIEMPRE
```

### Ventajas

1. **Reproducibilidad:** Si borras el save, el planeta es idéntico
2. **Exploración compartida:** Dos jugadores ven los mismos biomas en el mismo planeta
3. **Streaming:** Puedes regenerar cualquier chunk en cualquier momento
4. **Debugging:** Fácil reproducir bugs de generación

---

## Transiciones Suaves vs Bruscas

### Control por Distancia

```cpp
float get_blend_weight(Vector2 pos, BiomeRegion& region) {
    float distance = pos.distance_to(region.center);
    float normalized = distance / region.radius;
    
    // Zona interna: 100% este bioma
    if (normalized < 0.7) return 1.0;
    
    // Zona de transición: blend suave
    else if (normalized < 1.0) {
        return smoothstep(1.0, 0.7, normalized);
    }
    
    // Fuera del radio: 0%
    else return 0.0;
}
```

### Tipos de Transición

| Tipo | Descripción | Ejemplo |
|------|-------------|---------|
| **Suave** | Blend gradual entre biomas | Plains → Forest |
| **Brusca** | Cambio repentino | Plains → Cliff |
| **Costera** | Transición por altura | Beach → Ocean |

---

## Features Específicos por Bioma

### Generación de Features

```cpp
void generate_features(Vector2 world_pos, BiomeID biome) {
    auto& biome_data = biomes[biome];
    
    for (auto& feature : biome_data.features) {
        // Determinar si aparece usando ruido determinístico
        float noise = get_feature_noise(world_pos, feature.type);
        
        if (noise < feature.probability) {
            place_feature(world_pos, feature);
        }
    }
}
```

### Ejemplos de Features

| Feature | Biomas | Implementación |
|---------|--------|----------------|
| Árboles | Forest, Plains | Estructura procedural o prefab |
| Lagos | Plains, Forest | Depresión en terreno + agua |
| Cuevas | Todos | 3D noise (Perlin worms) |
| Cactus | Desert | Estructura simple procedural |
| Rocas | Mountains, Desert | Voxels sueltos en superficie |
| Cristales | Cuevas | Estructuras raras, valiosas |

---

## Optimizaciones

### Cache de Influencias

```cpp
// Los pesos de bioma por chunk se calculan una vez y se cachean
class BiomeCache {
    HashMap<Vector2i, Array<BiomeInfluence>> chunk_influences;
    
    Array<BiomeInfluence> get_influences(Vector2i chunk_xz) {
        if (chunk_influences.has(chunk_xz)) {
            return chunk_influences[chunk_xz];
        }
        
        auto influences = calculate_influences(chunk_xz);
        chunk_influences[chunk_xz] = influences;
        return influences;
    }
};
```

**Resultado:** De ~256 cálculos por chunk a 1.

### LOD de Biomas

```cpp
// Lejos del jugador: menos precisión en blending
if (distance_to_player > 1000) {
    // Solo bioma dominante, no blending
    return dominant_biome_only(chunk_pos);
} else {
    // Blending completo
    return full_blend(chunk_pos);
}
```

---

## Integración con Sistema de Planetas

Cada planeta define:
1. **Qué biomas existen** (subset de todos los biomas posibles)
2. **Distribución** (Voronoi + parámetros)
3. **Parámetros modificados** (gravedad afecta altura máxima, temperatura afecta presencia de hielo)

```json
{
    "planet_id": 0,
    "biomes": {
        "available": ["plains", "desert", "mountains", "ocean"],
        "distribution": {
            "type": "voronoi_warped",
            "cell_count": 50,
            "warp_strength": 0.3
        },
        "modifiers": {
            "low_gravity": {
                "mountains.height_multiplier": 1.5
            },
            "cold": {
                "plains.surface_block": "snow"
            }
        }
    }
}
```

---

## Referencias

- `PLANET_SYSTEM.md` — Sistema de planetas
- `DESIGN.md` — Arquitectura general
- Video de referencia: "Terrain-First vs Biome-First Generation"
