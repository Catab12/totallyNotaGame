# ⚠️ INFORMACIÓN CRÍTICA PARA COMPILACIÓN (ALEPH ENGINE)

**Archivo:** `docs/CRITICAL_BUILD_INFO.md`  
**Última actualización:** 2026-04-28  
**Autor:** Satan  
**Regla de oro:** LEER ESTO ANTES DE CADA BUILD

---

## 🚨 PROBLEMAS CONOCIDOS

### 1. SCons crea procesos zombie
**Síntoma:** Build tarda "infinito", CPU al 0%, múltiples python.exe en tasklist  
**Causa:** SCons no mata procesos hijo correctamente en Windows  
**Solución:**
```powershell
taskkill /F /IM python.exe
taskkill /F /IM cl.exe
taskkill /F /IM link.exe
```

### 2. Tocar headers compartidos = recompilar TODO
**Síntoma:** Build tarda 10+ minutos cuando solo cambiaste un archivo  
**Causa:** `voxel_types.h` y otros headers son incluidos por TODO el engine  
**Solución:**
- NUNCA añadir enums nuevos a `voxel_types.h`
- NUNCA modificar structs en headers compartidos
- Usar headers privados (`*_impl.h`) o poner enums en `.cpp`

### 3. Godot binary bloqueado = link falla
**Síntoma:** "Acceso denegado" al final del build  
**Causa:** Godot.exe está corriendo mientras SCons intenta escribirlo  
**Solución:** Cerrar Godot ANTES de compilar (usar `--quit` en headless)

---

## 🔧 MÉTODO DE BUILD CORRECTO (IMPORTANTE)

### ⚠️ NO ejecutar SCons desde bash/PowerShell de este entorno
**Razón:** Este entorno mata procesos padre sin matar hijos → crea procesos zombie → builds futuros fallan.

### ✅ MÉTODO CORRECTO: Script .bat

1. **Abrir CMD manualmente** (Win+R → `cmd`)
2. **Navegar al engine:**
   ```cmd
   cd /d "D:\Mis Juegos\Aleph\Aleph-Files\engine"
   ```
3. **Ejecutar el script:**
   ```cmd
   build.bat
   ```

### 📄 O directamente en CMD:
```cmd
cd /d "D:\Mis Juegos\Aleph\Aleph-Files\engine"
set PATH=%PATH%;%CD%
set CCACHE_DIR=%CD%\.ccache
py -m SCons platform=windows target=editor -j4
```

---

## 📊 TIEMPOS ESPERADOS

| Escenario | Tiempo | Notas |
|-----------|--------|-------|
| Primera vez (sin ccache) | 8-12 min | Todo el engine |
| Con ccache lleno | 30-60 seg | Cache hit > 90% |
| Solo .cpp del módulo | 10-20 seg | Sin tocar headers |
| Tocar `voxel_types.h` | 8-12 min | Recompila TODO |
| Tocar `voxel_world.h` | 2-3 min | Recompila dependencias |

---

## ⚠️ HEADERS QUE INVALIDAN CACHÉ (NO TOCAR)

| Header | Impacto | Alternativa |
|--------|---------|-------------|
| `voxel_types.h` | **TOTAL** (10+ min) | Poner enums en `.cpp` privado |
| `voxel_chunk.h` | Alto (3-5 min) | Usar forward declarations |
| `voxel_world.h` | Medio (2-3 min) | Headers privados para impl |
| `voxel_generator.h` | Bajo (1 min) | Raramente cambia |

---

## 🎯 CHECKLIST PRE-BUILD

- [ ] **Usar CMD manualmente** (NO bash/PowerShell de este entorno)
- [ ] Godot.exe cerrado (no corriendo)
- [ ] Ejecutar `build.bat` desde `D:\Mis Juegos\Aleph\Aleph-Files\engine`
- [ ] No modifiqué `voxel_types.h` sin necesidad
- [ ] Tengo 10GB libres en disco (cache puede crecer)

## 📁 ARCHIVOS DE BUILD

| Archivo | Ubicación | Uso |
|---------|-----------|-----|
| `build.bat` | `engine\build.bat` | **Script principal** - Ejecutar desde CMD |
| `ccache.exe` | `engine\ccache.exe` | Cache de compilación |
| `.ccache/` | `engine\.ccache\` | Datos de cache (10GB max) |

---

## 🆘 SI EL BUILD FALLA

### ⚠️ NUNCA ejecutar SCons desde el entorno de bash de este agente
**Síntoma:** SCons se cuelga, múltiples python.exe en tasklist, build nunca termina  
**Causa:** Este entorno mata procesos padre sin matar hijos → zombies  
**Solución:** Usar CMD manualmente con `build.bat`

### Error: "Acceso denegado"
```cmd
:: Cerrar Godot y reintentar
taskkill /F /IM godot.windows.editor.dev.x86_64.exe
```

### Error: "No module named SCons"
```cmd
py -m pip install scons
```

### Build extremadamente lento (20+ min)
**Normal si es primera vez o se tocó un header compartido.**  
**Usar ccache:** La segunda vez será 5-10x más rápido.
```cmd
:: Verificar ccache funciona
ccache -s
:: Si cache size = 0, algo está mal con CCACHE_DIR
```

---

## 📁 ARCHIVOS RELACIONADOS

- `build_aleph.bat` — Script de build automatizado
- `.ccache/` — Cache de compilación (10GB max)
- `bin/godot.windows.editor.dev.x86_64.exe` — Binario del editor

---

*Este documento debe actualizarse cada vez que se descubra un nuevo problema de build.*
