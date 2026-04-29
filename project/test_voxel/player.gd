extends CharacterBody3D

## Player controller usando VoxelBoxMover (AABB sweep custom).
## CharacterBody3D solo para que VoxelWorld nos detecte en _ready().
## NO usamos move_and_slide() ni Godot Physics para terreno.

@export var speed: float = 8.0
@export var jump_velocity: float = 12.0
@export var gravity: float = 25.0
@export var mouse_sensitivity: float = 0.003
@export var noclip_speed: float = 30.0

@export var voxel_world: Node3D  ## Asignar al nodo VoxelWorld en el editor

@onready var camera: Camera3D = $Camera3D

var rotation_x: float = 0.0
var noclip: bool = false

# Física custom — velocity es propiedad nativa de CharacterBody3D
var box_mover = null
var _on_ground := false

const VoxelBoxMoverScript = preload("res://test_voxel/voxel_box_mover.gd")

func _ready():
	# Capturar mouse
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	# Mirar ligeramente hacia abajo para ver el terreno
	rotation_x = -0.15
	camera.rotation.x = rotation_x
	
	# Inicializar VoxelBoxMover
	if voxel_world == null:
		# Buscar VoxelWorld en el parent
		var parent = get_parent()
		if parent:
			voxel_world = parent.get_node_or_null("World")
	
	if voxel_world == null:
		push_error("Player: No se encontró VoxelWorld. Asignar manualmente en el editor.")
		return
	
	box_mover = VoxelBoxMoverScript.new(voxel_world)
	
	# Spawn: encontrar altura del suelo desde arriba
	var spawn_x := global_position.x
	var spawn_z := global_position.z
	# Buscar desde Y=120 hacia abajo (por encima de cualquier terreno)
	var ground_y : float = box_mover.find_ground_height(spawn_x, spawn_z, 120.0)
	global_position.y = ground_y + box_mover.box_size.y * 0.5 + 0.1
	
	print("Player: Spawn en ", global_position)

func toggle_noclip() -> bool:
	noclip = !noclip
	velocity = Vector3.ZERO
	return noclip

func set_noclip(active: bool):
	noclip = active
	velocity = Vector3.ZERO

func get_movement_mode() -> String:
	return "NOCLIP" if noclip else "WALK"

func _input(event):
	# Movimiento de cámara con mouse
	if event is InputEventMouseMotion:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			rotate_y(-event.relative.x * mouse_sensitivity)
			rotation_x -= event.relative.y * mouse_sensitivity
			rotation_x = clampf(rotation_x, -PI/2, PI/2)
			camera.rotation.x = rotation_x
	
	# Liberar mouse con ESC
	if event.is_action_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _physics_process(delta):
	if box_mover == null:
		return  # Todavía no inicializado
	if noclip:
		_process_noclip(delta)
	else:
		_process_walk(delta)

func _process_walk(delta):
	# Gravedad
	velocity.y -= gravity * delta
	
	# Salto
	if Input.is_action_just_pressed("jump") and _on_ground:
		velocity.y = jump_velocity
		_on_ground = false
	
	# Movimiento WASD (input relativo a la cámara)
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if direction.length_squared() > 0.01:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		# Fricción: detener gradualmente
		velocity.x = move_toward(velocity.x, 0, speed * 5.0 * delta)
		velocity.z = move_toward(velocity.z, 0, speed * 5.0 * delta)
	
	# Aplicar movimiento con AABB sweep
	var target_velocity := velocity
	global_position = box_mover.move(global_position, target_velocity * delta)
	
	# Detectar si estamos en el suelo (después del movimiento)
	_on_ground = box_mover.is_on_ground(global_position)
	
	# Si estamos en el suelo y cayendo, resetear velocidad Y
	if _on_ground and velocity.y < 0:
		velocity.y = 0.0

func _process_noclip(delta):
	velocity = Vector3.ZERO
	
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	# Subir con ESPACIO, bajar con CONTROL
	var vertical: float = 0.0
	if Input.is_action_pressed("jump"):
		vertical += 1.0
	if Input.is_key_pressed(KEY_CTRL):
		vertical -= 1.0
	direction.y = vertical
	
	if direction.length_squared() > 0.01:
		velocity = direction.normalized() * noclip_speed
	
	global_position += velocity * delta

## Devuelve true si el jugador está en el suelo
func is_on_ground() -> bool:
	if noclip:
		return false
	return _on_ground
