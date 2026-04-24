# Sistema de Planetas — Aleph Voxel

## Visión General

El juego transcurre en un **sistema solar finito** donde el jugador pilotea una nave espacial entre planetas. Cada planeta es un mundo voxel explorable con biomas propios, gravedad, atmósfera y recursos únicos.

**Filosofía:** El espacio es un hub 3D donde los planetas aparecen como modelos esféricos. Al acercarse, el planeta se transforma seamlessmente en un mundo voxel jugable.

---

## Arquitectura de Coordenadas

```
SISTEMA SOLAR (espacio 3D)
├── Posición: Vector3 float (unidades arbitrarias)
├── Radio: ~1000 AU
└── Contiene: 5-10 planetas + asteroides

PLANETA (instancia separada)
├── ID: int (0-9)
├── Posición en sistema solar: Vector3
├── Radio: 30,000 chunks (~960km diámetro)
├── Seed única (uint64)
└── Atributos: gravedad, atmósfera, temperatura

CHUNK (dentro de planeta)
├── Coordenadas: (cx, cy, cz) int32
├── Rango: [-30000, 30000] por eje
└── Tamaño: 32³ voxels

VOXEL
└── ID: uint8 (0-255)
```

---

## Flujo de Juego: Espacio ↔ Planeta

### Fase 1: En el Espacio
- El jugador pilotea la nave en un sistema solar 3D
- Los planetas se ven como **modelos 3D esféricos** (LOD)
- Física newtoniana, órbitas, gravedad entre cuerpos
- No hay voxels en esta fase

### Fase 2: Aproximación
- Al acercarse a un planeta (< atmósfera), comienza transición
- Se cargan chunks cercanos al punto de entrada
- Modelo 3D del planeta comienza fade-out

### Fase 3: Superficie
- El jugador está en el mundo voxel del planeta
- Chunks se generan/streaming bajo demanda
- Física superficial, gravedad del planeta, colisiones voxel
- Puede explorar, minar, construir, despegar

### Fase 4: Despegue
- Inversa de Fase 2-3
- Chunks se guardan y descargan de RAM
- Modelo 3D del planeta aparece
- Vuelta al espacio

**Crítico:** Sin pantallas de carga. Todo es seamless.

---

## Clase Planet

```cpp
class Planet {
public:
    // Identificación
    int planet_id;
    String name;
    
    // Posición en sistema solar
    Vector3 solar_position;
    
    // Atributos físicos
    float gravity;           // 0.1 - 3.0 (multiplicador de G)
    bool has_atmosphere;
    float temperature_min;   // °C
    float temperature_max;
    
    // Generación
    uint64_t seed;
    int radius_chunks;       // 30000 por defecto
    
    // Biomas (ver PLANET_BIOME_SYSTEM.md)
    BiomeDistribution biome_dist;
    
    // Métodos
    Ref<VoxelChunk> generate_chunk(Vector3i chunk_pos);
    bool is_chunk_inside(Vector3i chunk_pos);  // Dentro del radio
    Vector3 get_entry_point(Vector3 approach_direction);
    
private:
    // Cache de chunks en RAM
    LRUCache<Vector3i, Ref<VoxelChunk>> chunk_cache;
};
```

---

## Persistencia por Planeta

### Estructura de Directorios

```
save/
├── system.data              # Estado del sistema solar
│   ├── Posiciones orbitales
│   ├── Estado de la nave
│   └── Descubrimientos
│
├── planet_0/                # Datos del planeta 0
│   ├── planet.meta          # Seed, atributos
│   ├── chunks/              # Chunks explorados
│   │   ├── cx_cy_cz.chunk
│   │   └── ...
│   └── modifications.dat    # Modificaciones del jugador
│
├── planet_1/
│   └── ...
│
└── player/
    ├── inventory.dat
    ├── ship.dat
    └── progression.dat
```

### Política de Guardado

| Tipo de Dato | ¿Se Guarda? | Formato |
|-------------|-------------|---------|
| Seed del planeta | ✅ Sí | uint64 en planet.meta |
| Chunks explorados | ✅ Sí | Comprimido (.chunk) |
| Modificaciones | ✅ Sí | Lista de (pos, voxel_id) |
| Biomas | ❌ No | Procedural (seed) |
| Terreno | ❌ No | Procedural (seed) |
| Jugador | ✅ Sí | player/ |

**Regla de oro:** Si se puede regenerar proceduralmente con la seed, NO se guarda.

---

## Transición Nave → Planeta (Sin Pantalla de Carga)

```cpp
enum TransitionState {
    IN_SPACE,        // En espacio, planeta = modelo 3D
    APPROACHING,     // Acercándose, precargando chunks
    IN_ATMOSPHERE,   // Fade out modelo, fade in voxels
    ON_SURFACE,      // Jugando en superficie
    DEPARTING        // Despegando, transición inversa
};

class PlanetTransition {
    TransitionState state = IN_SPACE;
    Planet* target_planet = nullptr;
    
    void update(Vector3 ship_pos) {
        switch (state) {
            case IN_SPACE:
                if (detect_approach(ship_pos)) {
                    state = APPROACHING;
                    preload_chunks();
                }
                break;
                
            case APPROACHING:
                if (chunks_ready()) {
                    state = IN_ATMOSPHERE;
                    start_visual_transition();
                }
                break;
                
            case IN_ATMOSPHERE:
                if (transition_complete()) {
                    state = ON_SURFACE;
                    enable_player_control();
                }
                break;
                
            case ON_SURFACE:
                if (player_initiates_departure()) {
                    state = DEPARTING;
                    save_and_unload();
                }
                break;
                
            case DEPARTING:
                if (transition_complete()) {
                    state = IN_SPACE;
                    target_planet = nullptr;
                }
                break;
        }
    }
};
```

### Precarga Inteligente

Al detectar aproximación:
1. Calcular punto de entrada (dirección de la nave)
2. Generar chunks en radio 2 alrededor del punto
3. Mostrar pantalla de "Entrando a atmósfera" (no bloqueante)
4. Fade out del modelo 3D mientras cargan chunks

---

## Streaming de Chunks

### Jerarquía de Memoria

```
TIER 1: RAM (activo)
├── Chunks cercanos al jugador (radio 2-3)
├── Capacidad: ~500-1000 chunks
└── Política: LRU (Least Recently Used)

TIER 2: SSD (cache)
├── Chunks explorados recientemente
├── Capacidad: ilimitada (disco)
└── Formato: comprimido

TIER 3: Procedural (sin almacenar)
├── Chunks nunca visitados
└── Generados bajo demanda con seed
```

### Ciclo de Vida de un Chunk

```
[NUNCA VISITADO]
      │
      ▼ (jugador se acerca)
[GENERAR proceduralmente]
      │
      ▼
[CARGAR en RAM]
      │
      ▼ (jugador se aleja)
[GUARDAR en disco]
      │
      ▼
[LIBERAR de RAM]
      │
      ▼ (jugador vuelve)
[CARGAR desde disco]
      │
      ▼
[CARGAR en RAM]
```

---

## Multijugador (Múltiples Planetas)

### Escenarios

| Situación | Sincronización |
|-----------|---------------|
| Dos jugadores en **mismo planeta** | Sincronizar chunks cercanos |
| Dos jugadores en **planetas diferentes** | Solo posición orbital |
| Uno en **espacio**, otro en **planeta** | Solo posición del espacial |
| Dos jugadores en **espacio** | Sincronizar posiciones 3D |

### Optimización

```cpp
class MultiplayerManager {
    void sync_player(PlayerSession& session) {
        if (session.location == IN_SPACE) {
            // Solo posición 3D, muy ligero
            broadcast_position(session);
        } else {
            // En planeta: sincronizar chunks cercanos
            Planet* planet = get_planet(session.planet_id);
            sync_chunks_near(session.position, planet);
        }
    }
};
```

**Nota:** Si hay 100 jugadores en 10 planetas diferentes, solo se sincronizan las posiciones orbitales, no los voxels.

---

## Límites y Consideraciones

### Límite del Mundo

- **Radio:** 30,000 chunks (~960km desde centro)
- **Diámetro:** ~1,920km
- **Chunks totales (esfera):** ~113 billones
- **Chunks explorables (realista):** Millones (solo superficie)

**El jugador nunca verá el límite.** A 100km/h caminando, tardarías ~9 horas en llegar al borde.

### Memoria Estimada

| Escenario | Chunks en RAM | Memoria |
|-----------|--------------|---------|
| Jugador quieto | ~125 (5×5×5) | ~4MB |
| Jugador caminando | ~500 | ~16MB |
| Máximo (view=10) | ~9261 | ~300MB |

Con cache LRU de 10,000 chunks: ~320MB máximo.

---

## Integración con Biomas

Los biomas se definen a nivel de planeta. Cada planeta tiene su propia distribución de biomas basada en:
- Voronoi con warping (ver `PLANET_BIOME_SYSTEM.md`)
- Seed única del planeta
- Parámetros del planeta (gravedad, temperatura)

Al generar un chunk:
1. Planeta calcula qué biomas afectan la posición
2. Cada bioma genera su terreno con su TerrainShaper
3. Se mezclan usando pesos de influencia
4. Resultado: chunk con transiciones suaves entre biomas

---

## Referencias

- `PLANET_BIOME_SYSTEM.md` — Sistema de biomas
- `DESIGN.md` — Arquitectura general del motor
- `VOXEL_FORMAT.md` — Formato de chunks comprimidos (por crear)
