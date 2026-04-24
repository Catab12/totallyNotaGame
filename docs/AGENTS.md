# Aleph Engine — Agents Configuration

**Project:** Aleph Voxel Engine (Godot 4.6.2 Custom Module)  
**Repository:** `D:\Mis Juegos\Aleph\Aleph-Files`  
**Branch:** `aleph-dev`

---

## 📁 Documentation Structure

All project documentation lives in `docs/`:

| File | Purpose |
|------|---------|
| `docs/DESIGN.md` | **Technical Design Document** — Architecture, rendering pipeline, data structures, performance targets |
| `docs/Meta/Docs/AgentsMemory/*.md` | Agent memory files (runtime notes, decisions, context) |

---

## 🎯 Project Overview

Space-themed Minecraft clone with VR support. Custom C++ voxel module for Godot 4.6.2 targeting maximum performance through:

- **HZB Occlusion Culling** — Skip 60-90% of invisible chunks
- **Greedy Meshing** — 50-90% fewer faces
- **Chunk LOD Pyramid** — 5 levels + ray marching fallback
- **Unified Block System** — Single mesh, texture atlas
- **GPU Compute** — Ray traversal for distant terrain

---

## 🔗 Quick Links

- **Design Doc:** `docs/DESIGN.md`
- **Engine Source:** `engine/` (Godot 4.6.2 fork)
- **Game Project:** `project/` (Godot game files)
- **Module:** `engine/modules/aleph_voxel/`

---

## 👥 Team

- **Satan** (You) — Lead architect, C++ implementation
- **Gusano** — Code review
- **Topo** — Codebase exploration
- **Araña** — Documentation/API research

---

*Last updated: 2026-04-22*
