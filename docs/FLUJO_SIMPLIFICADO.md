# Flujo Simplificado: Planetas + Biomas

## Diagrama de Flujo Completo

```
┌─────────────────────────────────────────────────────────────┐
│  JUGADOR EN ESPACIO                                         │
│  • Nave espacial 3D                                         │
│  • Planetas = modelos esféricos (LOD)                       │
│  • No hay voxels                                            │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼  Te acercas a Planeta X
┌─────────────────────────────────────────────────────────────┐
│  ENTRADA ATMOSFÉRICA (FORZADA)                              │
│  • No puedes abortar una vez iniciada                       │
│  • La nave entra en caída libre controlada                  │
│  • Física de reentrada: calor, vibración, sonido            │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  TRANSICIÓN (sin pantalla de carga)                         │
│  1. Precargar chunks cercanos al punto de entrada           │
│  2. Fade out del modelo 3D del planeta                      │
│  3. Fade in de chunks voxel                                 │
│  4. Efectos: nubes, atmósfera, paracaídas/nave            │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  JUGADOR EN SUPERFICIE                                      │
│                                                             │
│  Para cada chunk nuevo que se necesita:                     │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  1. ¿Chunk ya existe en disco?                      │   │
│  │     → Sí: Cargar desde disco                       │   │
│  │     → No: Generar proceduralmente                  │   │
│  └──────────────────────────┬──────────────────────────┘   │
│                             │                               │
│                             ▼ Si no existe
│  ┌─────────────────────────────────────────────────────┐   │
│  │  2. GENERAR CHUNK (procedural)                      │   │
│  │                                                     │   │
│  │  a) ¿Qué biomas hay aquí?                          │   │
│  │     → Voronoi + warping → lista de biomas          │   │
│  │                                                     │   │
│  │  b) ¿Cuánto pesa cada bioma?                       │   │
│  │     → Calcular pesos (ej: 60% Crystal, 40% Acid)   │   │
│  │                                                     │   │
│  │  c) Generar terreno para cada columna (x,z):       │   │
│  │     • Crystal Forest: altura = 80 ± 20 (picos)     │   │
│  │     • Acid Lakes: altura = 40 ± 5 (depresiones)    │   │
│  │     • Altura final = blend ponderado               │   │
│  │                                                     │   │
│  │  d) Rellenar voxels en la columna:                 │   │
│  │     • Y > altura → AIRE / GAS TÓXICO               │   │
│  │     • Y = altura → SUPERFICIE (cristal, biomasa)   │   │
│  │     • Y = altura-3 → SUBSUELO (roca, huesos)       │   │
│  │     • Y < altura-3 → PROFUNDO (núcleo, magma)      │   │
│  │                                                     │   │
│  │  e) Añadir features alienígenas:                   │   │
│  │     • Cristales flotantes, esporas, tentáculos     │   │
│  │     • Lagos de ácido, geisers, grietas             │   │
│  └──────────────────────────┬──────────────────────────┘   │
│                             │                               │
│                             ▼
│  ┌─────────────────────────────────────────────────────┐   │
│  │  3. GUARDAR EN DISCO (si es nuevo)                  │   │
│  │     → Comprimir (RLE/LZ4)                          │   │
│  │     → Guardar en: save/planet_X/chunks/cx_cy_cz    │   │
│  └──────────────────────────┬──────────────────────────┘   │
│                             │                               │
│                             ▼
│  ┌─────────────────────────────────────────────────────┐   │
│  │  4. CARGAR EN RAM                                   │   │
│  │     → Añadir a cache LRU                           │   │
│  │     → Generar mesh (greedy meshing)                │   │
│  │     → Crear colisiones                             │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  [El jugador camina → nuevos chunks se cargan]              │
│  [El jugador se aleja → chunks viejos se descargan]         │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼  Jugador decide despegar
┌─────────────────────────────────────────────────────────────┐
│  TRANSICIÓN INVERSA                                         │
│  1. Guardar chunks modificados                              │
│  2. Descargar chunks de RAM                                 │
│  3. Fade out de voxels                                      │
│  4. Fade in del modelo 3D del planeta                       │
│  5. Nave despega y sale de atmósfera                        │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  JUGADOR EN ESPACIO (de nuevo)                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Ejemplo Concreto: Generar un Chunk

### Input
- **Planeta:** Xylos-7 (seed: 99999)
- **Tipo:** Planeta alienígena, gravedad 0.6G, atmósfera tóxica verde
- **Chunk:** Posición (100, 2, -50)
- **Jugador:** Cerca de este chunk

### Paso 1: ¿Existe en disco?
```
Revisar: save/planet_0/chunks/100_2_-50.chunk
→ No existe (nunca explorado)
```

### Paso 2: Generar proceduralmente

**2a. Determinar biomas (Voronoi + warping)**
```
Posición en planeta: (100*32, -50*32) = (3200, -1600)

Voronoi puro diría: estás en la celda #7
Con warping: la celda #7 está ligeramente deformada

Resultado: Estás en el borde entre:
- Crystal Forest (centro en 3000, -1500) → peso: 0.6
- Acid Lakes (centro en 3500, -1800) → peso: 0.4
```

**2b. Generar altura para cada columna**
```
Para la columna (x=5, z=10) dentro del chunk:
Posición mundo: (3200+5, -1600+10) = (3205, -1590)

Crystal Forest dice:
  - Altura base: 80 (picos de cristal)
  - Ruido: +12.5 (muy irregular)
  - Altura Crystal: 92.5

Acid Lakes dice:
  - Altura base: 40 (depresiones llenas de ácido)
  - Ruido: -2.3 (suave)
  - Altura Acid: 37.7

Altura final = 0.6 * 92.5 + 0.4 * 37.7 = 70.58
```

**2c. Rellenar voxels en la columna**
```
Y = 70 → CRISTAL BIOLUMINISCENTE (superficie, brilla en la oscuridad)
Y = 69 → CRISTAL OSCURO
Y = 68 → CRISTAL OSCURO
Y = 67 → ROCA EXÓTICA
Y = 66 → ROCA EXÓTICA
Y = 65 → ROCA EXÓTICA
... (hasta Y=40)
Y = 40 → ACIDO CORROSIVO (lago subterráneo)
Y = 39 → ROCA PROFUNDA
... (hasta Y=0)
Y = 0 → NÚCLEO CALIENTE
```

**2d. Añadir features alienígenas**
```
¿Cristal flotante aquí?
- Ruido determinístico en (3205, -1590) = 0.89
- Probabilidad en Crystal Forest = 0.15
- 0.89 > 0.15 → No hay cristal flotante

¿Esporas tóxicas aquí?
- Ruido determinístico = 0.03
- Probabilidad = 0.08
- 0.03 < 0.08 → ¡SÍ! Esporas flotantes en Y=71-73

¿Géiser de ácido aquí?
- Ruido determinístico = 0.97
- Probabilidad = 0.02
- 0.97 > 0.02 → No hay géiser

¿Tentáculos del subsuelo?
- Ruido determinístico = 0.41
- Probabilidad = 0.10
- 0.41 > 0.10 → No hay tentáculos
```

### Paso 3: Guardar en disco
```
Comprimir chunk:
- Antes: 32*32*32 = 32768 voxels = 32 KB
- Después (RLE): ~500 bytes (la mayoría es piedra/tierra/aire)

Guardar en: save/planet_0/chunks/100_2_-50.chunk
```

### Paso 4: Cargar en RAM
```
- Añadir a cache LRU
- Generar mesh (greedy meshing reduce vértices 50-90%)
- Crear colisiones (AABB por chunk)
- Renderizar
```

---

## Estados de un Chunk

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   NUNCA     │────▶│  GENERADO   │────▶│   EN RAM    │
│  VISITADO   │     │  (disco)    │     │  (activo)   │
└─────────────┘     └─────────────┘     └──────┬──────┘
      ▲                                        │
      │                                        │
      └────────────────────────────────────────┘
           (se aleja el jugador, se libera RAM)
```

| Estado | En RAM | En Disco | ¿Procedural? |
|--------|--------|----------|--------------|
| Nunca visitado | ❌ | ❌ | ✅ Sí |
| Visitado, lejos | ❌ | ✅ | ❌ No (cargar) |
| Visitado, cerca | ✅ | ✅ | ❌ No (cache) |
| Modificado | ✅ | ✅ (dirty) | ❌ No |

---

## Memoria en Tiempo Real

### Escenario: Jugador quieto en superficie

```
Chunks cargados: 5×5×5 = 125 chunks
- Cada chunk en RAM: ~32 KB (datos) + mesh variable
- Total mesh: ~2-4 MB (con greedy meshing)
- Total RAM: ~10-20 MB

En disco (todo el planeta explorado):
- 1000 chunks explorados
- Cada uno: ~500 bytes comprimido
- Total disco: ~500 KB
```

### Escenario: Jugador caminando

```
Chunks cargados: 7×7×7 = 343 chunks
- Total RAM: ~30-50 MB

Chunks nuevos por segundo (caminando a 5m/s):
- ~2 chunks/segundo
- Tiempo de generación: ~10ms por chunk
- Sin lag perceptible
```

---

## Transición Visual: Espacio → Superficie

```
Distancia al planeta: 1000 km
├─ Visual: Modelo 3D esférico (LOD alto)
├─ Física: Órbita/espacial
└─ Voxels: Ninguno

Distancia: 100 km
├─ Visual: Modelo 3D (LOD medio)
├─ Física: Entrada atmosférica
└─ Voxels: Precargando chunks de entrada

Distancia: 10 km
├─ Visual: Fade out modelo 3D (opacidad 50%)
├─ Física: Aerodinámica
└─ Voxels: Chunks cargados, fade in

Distancia: 1 km
├─ Visual: Solo voxels (modelo 3D opacidad 0%)
├─ Física: Superficial
└─ Voxels: Streaming activo
```

**Duración total de transición:** 2-5 segundos (depende de velocidad de nave)

---

## Biomas Alienígenas (Ejemplos)

| Bioma | Altura | Variación | Características | Peligros |
|-------|--------|-----------|-----------------|----------|
| **Crystal Forest** | 80 | 20 | Picos de cristal bioluminiscente, cristales flotantes | Cortante, radiación |
| **Acid Lakes** | 40 | 5 | Lagos de ácido corrosivo, burbujas tóxicas | Corrosión, gas |
| **Fungal Swamp** | 55 | 8 | Hongos gigantes, esporas flotantes, biomasa | Veneno, alucinaciones |
| **Magma Fields** | 70 | 15 | Río de magma, roca volcánica, géiseres | Quemaduras |
| **Void Cracks** | 30 | 25 | Grietas al vacío, gravedad baja, cristales del vacío | Caída, locura |
| **Bio-Mechanical** | 60 | 10 | Estructuras orgánicas+metal, tentáculos, ojos | Parásitos, trampas |
| **Gravity Wells** | 90 | 30 | Inversiones de gravedad, islas flotantes, vórtices | Desorientación |
| **Echo Plains** | 50 | 3 | Superficie reflectante, ecos, silencio absoluto | Locura sónica |

### Paleta de Colores (vs Tierra)

```
Tierra:          Alienígena:
🟩 Verde          🟪 Púrpura neón
🟫 Marrón         🔵 Azul eléctrico
🟦 Azul (agua)    🟢 Verde tóxico
⬜ Gris (piedra)   🟠 Naranja brillante
⬛ Negro           ⚪ Blanco brillante (cristal)
```

---

## Resumen en 5 Pasos

1. **Espacio:** Nave entre planetas (modelos 3D)
2. **Aproximar:** Entrada atmosférica FORZADA (caída libre)
3. **Entrar:** Fade a mundo voxel alienígena (biomas locos)
4. **Explorar:** Caminas, minas, construyes, sobrevives
5. **Salir:** Despegar, fade a espacio

**Todo determinístico:** Misma seed = mismo planeta siempre.
**Todo seamless:** Sin pantallas de carga.
**Todo alien:** Biomas que no existen en la Tierra.
