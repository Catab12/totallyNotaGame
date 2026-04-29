extends Node3D

## Escena principal del test voxel.
## Ahora usa VoxelBlockRegistry (data-driven, JSON) para definir bloques y biomas.

@onready var world: Node3D = $World
@onready var player: Node3D = $Player
@onready var debug_panel: Node = $BiomeDebugPanel

var generator
var biome_dist

func _ready() -> void:
	print("=".repeat(50))
	print("ALEPH VOXEL ENGINE - Iniciando...")
	print("=".repeat(50))
	
	# Verificar que el registry cargó
	if not VoxelBlockRegistry.is_loaded():
		push_error("VoxelBlockRegistry no cargó. Verificar blocks.json y biomes.json")
		return
	
	print("Bloques cargados: %d" % VoxelBlockRegistry.get_block_count())
	print("Biomas cargados: %d" % VoxelBlockRegistry.get_biome_count())
	
	# Listar biomas disponibles
	print("\nBiomas disponibles:")
	for biome: Dictionary in VoxelBlockRegistry.get_biome_list():
		print("  - %s (surface: %s)" % [biome["name"], biome["surface_block"]])
	
	# Crear distribución de biomas
	biome_dist = BiomeDistribution.new()
	biome_dist.initialize_with_params(50, 0.3, 0.01, 12345)
	
	# Crear generador de biomas
	generator = VoxelGeneratorBiome.new()
	generator.set_planet_seed(12345)
	generator.set_biome_distribution(biome_dist)
	
	# Configurar shapers desde JSON (data-driven, no hardcodeo)
	_configure_shapers_from_json(generator)
	
	world.set_generator(generator)

func _configure_shapers_from_json(gen: VoxelGeneratorBiome) -> void:
	## Configura los TerrainShapers del generador usando datos del JSON
	var biome_map := {
		"crystal_forest": 0,
		"acid_lakes": 1,
		"fungal_swamp": 2,
		"magma_fields": 3,
		"void_cracks": 4,
		"bio_mechanical": 5,
		"gravity_wells": 6,
		"echo_plains": 7,
	}
	
	for biome_name: String in biome_map:
		var biome_id: int = biome_map[biome_name]
		var biome_data: Dictionary = VoxelBlockRegistry.get_biome(biome_name)
		if biome_data.is_empty():
			push_warning("Bioma '%s' no encontrado en JSON" % biome_name)
			continue
		
		var shaper := TerrainShaper.new()
		shaper.set_seed(12345 + biome_id * 1000)
		shaper.set_base_height(float(biome_data.get("terrain_height", 64.0)))
		shaper.set_height_variation(float(biome_data.get("height_variation", 8.0)))
		
		# Configurar bloques desde el registry
		var surface_id: int = VoxelBlockRegistry.get_block_id(biome_data.get("surface_block", "grass"))
		var soil_id: int = VoxelBlockRegistry.get_block_id(biome_data.get("soil_block", "dirt"))
		var deep_id: int = VoxelBlockRegistry.get_block_id(biome_data.get("deep_block", "stone"))
		
		shaper.set_surface_block(surface_id)
		shaper.set_subsurface_block(soil_id)
		shaper.set_deep_block(deep_id)
		shaper.set_subsurface_depth(3)
		
		gen.set_shaper(biome_id, shaper)
		print("  Configurado shaper para %s: surface=%d, soil=%d, deep=%d" % [
			biome_name, surface_id, soil_id, deep_id
		])
	
	print("\nControles:")
	print("  WASD       = Mover")
	print("  ESPACIO    = Saltar / Subir (noclip)")
	print("  CTRL       = Bajar (noclip)")
	print("  MOUSE      = Mirar")
	print("  ESC        = Liberar mouse")
	print("  CLICK IZQ  = Romper bloque")
	print("  CLICK DER  = Colocar bloque")
	print("  1-9        = Seleccionar bloque")
	print("=".repeat(50))

func get_generator():
	return generator

func get_biome_distribution():
	return biome_dist
