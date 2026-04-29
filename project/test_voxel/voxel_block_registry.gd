extends Node
## VoxelBlockRegistry — Sistema de registro de bloques data-driven.
## Carga definiciones desde JSON. Cero hardcodeo.
## Uso: VoxelBlockRegistry.get_block("grass") o .get_block_by_id(1)

# ───────────────────────────────────────────
# Datos cargados
# ───────────────────────────────────────────
var _blocks_by_name: Dictionary = {}   # { "grass": { id, color, flags... } }
var _blocks_by_id: Dictionary = {}     # { 1: { name, color, flags... } }
var _biomes: Dictionary = {}           # { "crystal_forest": { ... } }
var _biome_list: Array = []            # Lista ordenada para lookup rápido

var _loaded := false

# ───────────────────────────────────────────
# Flags helpers (más rápido que buscar en array)
# ───────────────────────────────────────────
func is_opaque(block_data: Dictionary) -> bool:
	return block_data.get("flags", []).has("opaque")

func is_solid(block_data: Dictionary) -> bool:
	return block_data.get("flags", []).has("solid")

func is_transparent(block_data: Dictionary) -> bool:
	return block_data.get("flags", []).has("transparent")

func is_liquid(block_data: Dictionary) -> bool:
	return block_data.get("flags", []).has("liquid")

func is_emissive(block_data: Dictionary) -> bool:
	return block_data.get("flags", []).has("emissive")

# ───────────────────────────────────────────
# Carga inicial
# ───────────────────────────────────────────
func _ready() -> void:
	_load_blocks()
	_load_biomes()
	_loaded = true
	print("VoxelBlockRegistry: Cargados %d bloques, %d biomas" % [
		_blocks_by_id.size(), _biomes.size()
	])

func _load_blocks() -> void:
	var path := "res://data/blocks.json"
	if not FileAccess.file_exists(path):
		push_error("VoxelBlockRegistry: No se encontró %s" % path)
		return
	
	var file := FileAccess.open(path, FileAccess.READ)
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()
	
	if err != OK:
		push_error("VoxelBlockRegistry: Error parseando blocks.json: %s" % json.get_error_message())
		return
	
	var data: Dictionary = json.data
	if not data.has("blocks"):
		push_error("VoxelBlockRegistry: blocks.json no tiene campo 'blocks'")
		return
	
	var blocks: Dictionary = data["blocks"]
	for block_name: String in blocks:
		var block: Dictionary = blocks[block_name]
		block["name_key"] = block_name  # Guardar nombre interno
		
		var id: int = block.get("id", -1)
		if id < 0:
			push_error("VoxelBlockRegistry: Bloque '%s' sin ID válido" % block_name)
			continue
		
		# Convertir color array → Color de Godot
		if block.has("color"):
			var c: Array = block["color"]
			block["godot_color"] = Color(c[0], c[1], c[2])
		else:
			block["godot_color"] = Color.MAGENTA
		
		_blocks_by_name[block_name] = block
		_blocks_by_id[id] = block

func _load_biomes() -> void:
	var path := "res://data/biomes.json"
	if not FileAccess.file_exists(path):
		push_error("VoxelBlockRegistry: No se encontró %s" % path)
		return
	
	var file := FileAccess.open(path, FileAccess.READ)
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()
	
	if err != OK:
		push_error("VoxelBlockRegistry: Error parseando biomes.json: %s" % json.get_error_message())
		return
	
	var data: Dictionary = json.data
	if not data.has("biomes"):
		push_error("VoxelBlockRegistry: biomes.json no tiene campo 'biomes'")
		return
	
	_biomes = data["biomes"]
	for biome_name: String in _biomes:
		var biome: Dictionary = _biomes[biome_name]
		biome["name_key"] = biome_name
		_biome_list.append(biome)

# ───────────────────────────────────────────
# API Pública
# ───────────────────────────────────────────
func get_block(block_name: String) -> Dictionary:
	## Devuelve datos de un bloque por nombre. Dictionary vacío si no existe.
	return _blocks_by_name.get(block_name, {})

func get_block_by_id(block_id: int) -> Dictionary:
	## Devuelve datos de un bloque por ID. Dictionary vacío si no existe.
	return _blocks_by_id.get(block_id, {})

func get_block_name(block_id: int) -> String:
	var block: Dictionary = get_block_by_id(block_id)
	return block.get("name", "Unknown")

func get_block_color(block_id: int) -> Color:
	var block: Dictionary = get_block_by_id(block_id)
	return block.get("godot_color", Color.MAGENTA)

func get_block_id(block_name: String) -> int:
	var block: Dictionary = get_block(block_name)
	return block.get("id", 0)

func get_all_blocks() -> Dictionary:
	## { id: Dictionary } de TODOS los bloques
	return _blocks_by_id.duplicate()

func get_placeable_blocks() -> Array:
	## Array de Dictionaries de bloques que el jugador puede colocar
	var result: Array = []
	for block_id: int in _blocks_by_id:
		var block: Dictionary = _blocks_by_id[block_id]
		if block.get("id", 0) == 0:
			continue  # Skip air
		result.append(block)
	return result

# ───────────────────────────────────────────
# Biomas
# ───────────────────────────────────────────
func get_biome(biome_name: String) -> Dictionary:
	return _biomes.get(biome_name, {})

func get_biome_list() -> Array:
	return _biome_list.duplicate()

func get_biome_for_conditions(temperature: float, humidity: float) -> Dictionary:
	## Encuentra el bioma que coincide con temperatura y humedad
	var best_match: Dictionary = {}
	var best_score := 999.0
	
	for biome: Dictionary in _biome_list:
		var temp_range: Array = biome.get("temperature_range", [0, 0])
		var hum_range: Array = biome.get("humidity_range", [0, 0])
		
		if temperature >= temp_range[0] and temperature <= temp_range[1] and \
		   humidity >= hum_range[0] and humidity <= hum_range[1]:
			# Dentro del rango → calcular qué tan cerca del centro está
			var temp_center: float = (temp_range[0] + temp_range[1]) * 0.5
			var hum_center: float = (hum_range[0] + hum_range[1]) * 0.5
			var score: float = abs(temperature - temp_center) + abs(humidity - hum_center)
			
			if score < best_score:
				best_score = score
				best_match = biome
	
	# Fallback: echo_plains si no hay match
	if best_match.is_empty():
		best_match = get_biome("echo_plains")
	
	return best_match

# ───────────────────────────────────────────
# Lookup rápido para generador
# ───────────────────────────────────────────
func get_surface_block_id(biome_name: String) -> int:
	var biome: Dictionary = get_biome(biome_name)
	var block_name: String = biome.get("surface_block", "grass")
	return get_block_id(block_name)

func get_soil_block_id(biome_name: String) -> int:
	var biome: Dictionary = get_biome(biome_name)
	var block_name: String = biome.get("soil_block", "dirt")
	return get_block_id(block_name)

func get_deep_block_id(biome_name: String) -> int:
	var biome: Dictionary = get_biome(biome_name)
	var block_name: String = biome.get("deep_block", "stone")
	return get_block_id(block_name)

# ───────────────────────────────────────────
# Utilidades
# ───────────────────────────────────────────
func is_loaded() -> bool:
	return _loaded

func get_block_count() -> int:
	return _blocks_by_id.size()

func get_biome_count() -> int:
	return _biomes.size()
