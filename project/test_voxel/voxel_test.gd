extends Node3D

@onready var world = $World
@onready var player = $Player
@onready var debug_panel = $BiomeDebugPanel

var generator
var biome_dist

func _ready():
	print("Iniciando mundo voxel con BIOMAS ALIENÍGENAS...")
	print("Generación EN TIEMPO REAL - muévete para generar terreno")
	
	# Crear distribución de biomas
	biome_dist = BiomeDistribution.new()
	biome_dist.initialize_with_params(50, 0.3, 0.01, 12345)
	
	# Crear generador de biomas
	generator = VoxelGeneratorBiome.new()
	generator.set_planet_seed(12345)
	generator.set_biome_distribution(biome_dist)
	
	world.set_generator(generator)
	
	# NO generar mundo manualmente - la generación es en tiempo real
	# El VoxelWorld generará chunks automáticamente al detectar movimiento
	
	print("Controles: WASD = mover, ESPACIO = saltar/subir, MOUSE = mirar, ESC = liberar mouse")
	print("Panel debug: Esquina superior izquierda, ajusta parámetros en tiempo real")
	print("Modo: NOCLIP = volar libre (activar con botón del panel)")

func get_generator():
	return generator

func get_biome_distribution():
	return biome_dist
