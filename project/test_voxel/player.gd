extends CharacterBody3D

@export var speed: float = 8.0
@export var jump_velocity: float = 12.0
@export var gravity: float = 25.0
@export var mouse_sensitivity: float = 0.003
@export var noclip_speed: float = 25.0

@onready var camera: Camera3D = $Camera3D

var rotation_x: float = 0.0
var noclip: bool = false

func _ready():
	# Capturar mouse
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	# Posicionar sobre el terreno (biomas pueden llegar hasta Y=100+)
	position = Vector3(0, 120, 0)
	
	# Mirar ligeramente hacia abajo para ver el terreno
	rotation_x = -0.15  # ~8.5 grados hacia abajo
	camera.rotation.x = rotation_x

func toggle_noclip() -> bool:
	noclip = !noclip
	return noclip

func set_noclip(active: bool):
	noclip = active

func get_movement_mode() -> String:
	if noclip:
		return "NOCLIP"
	else:
		return "WALK"

func _input(event):
	# Movimiento de cámara con mouse
	if event is InputEventMouseMotion:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			rotate_y(-event.relative.x * mouse_sensitivity)
			rotation_x -= event.relative.y * mouse_sensitivity
			rotation_x = clamp(rotation_x, -PI/2, PI/2)
			camera.rotation.x = rotation_x
	
	# Liberar mouse con ESC
	if event.is_action_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _physics_process(delta):
	if noclip:
		# Modo noclip: vuelo libre, sin gravedad, atraviesa todo
		velocity = Vector3.ZERO
		
		var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
		
		# Subir con ESPACIO, bajar con CONTROL
		var vertical: float = 0.0
		if Input.is_action_pressed("jump"):
			vertical += 1.0
		if Input.is_key_pressed(KEY_CTRL):
			vertical -= 1.0
		direction.y = vertical
		
		if direction:
			velocity = direction * noclip_speed
		
		# Mover sin colisión
		move_and_collide(velocity * delta)
	else:
		# Modo normal (caminar)
		# Gravedad
		if not is_on_floor():
			velocity.y -= gravity * delta
		
		# Salto
		if Input.is_action_just_pressed("jump") and is_on_floor():
			velocity.y = jump_velocity
		
		# Movimiento WASD
		var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
		
		if direction:
			velocity.x = direction.x * speed
			velocity.z = direction.z * speed
		else:
			velocity.x = move_toward(velocity.x, 0, speed)
			velocity.z = move_toward(velocity.z, 0, speed)
		
		move_and_slide()
