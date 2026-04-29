extends RefCounted

## Sistema de colisiones AABB sweep para voxels.
## NO usa Godot Physics. Consulta directamente el grid de voxels.
## Basado en la arquitectura de VOXEL_ENGINE_ARCHITECTURE.md §5

var world: Node3D  ## Referencia al VoxelWorld (tiene método get_voxel(Vector3i) -> int)
var box_size: Vector3 = Vector3(0.6, 1.8, 0.6)  ## Tamaño del jugador (ancho, alto, profundo)
var skin_width: float = 0.001  ## Margen para evitar atascos en esquinas

var _half_size: Vector3

func _init(p_world: Node3D):
	world = p_world
	_half_size = box_size * 0.5

## Intenta mover 'position' por 'velocity'. Devuelve la nueva posición.
func move(position: Vector3, velocity: Vector3) -> Vector3:
	var result := position
	
	# Resolver eje Y primero (gravedad/salto)
	if velocity.y != 0.0:
		result = _move_axis(result, velocity.y, Vector3(0, 1, 0))
	
	# Resolver eje X
	if velocity.x != 0.0:
		result = _move_axis(result, velocity.x, Vector3(1, 0, 0))
	
	# Resolver eje Z
	if velocity.z != 0.0:
		result = _move_axis(result, velocity.z, Vector3(0, 0, 1))
	
	return result

## Mueve a lo largo de un solo eje. Returns nueva posición.
func _move_axis(pos: Vector3, move_amount: float, axis: Vector3) -> Vector3:
	if abs(move_amount) < 0.0001:
		return pos
	
	var direction : Vector3 = axis * sign(move_amount)
	var distance : float = abs(move_amount)
	
	# Raycast AABB contra grid de voxels
	var hit : Dictionary = _sweep_aabb(pos, direction, distance)
	
	if hit.hit:
		# Colisionamos: posicionarnos justo antes del impacto
		var move_dist := maxf(0.0, hit.distance - skin_width)
		return pos + direction * move_dist
	else:
		# No colisionamos: mover completo
		return pos + axis * move_amount

## Sweep AABB del jugador contra el grid de voxels.
## Devuelve Dictionary con: hit (bool), distance (float), normal (Vector3)
func _sweep_aabb(origin: Vector3, direction: Vector3, max_dist: float) -> Dictionary:
	# AABB del jugador en posición origen
	var player_aabb := AABB(origin - _half_size, box_size)
	
	# AABB en posición destino
	var dest_aabb := AABB(
		origin + direction * max_dist - _half_size,
		box_size
	)
	
	# Bounds de voxels a testear (expandir por skin para capturar bordes)
	var min_voxel := Vector3i(
		floori(min(player_aabb.position.x, dest_aabb.position.x)) - 1,
		floori(min(player_aabb.position.y, dest_aabb.position.y)) - 1,
		floori(min(player_aabb.position.z, dest_aabb.position.z)) - 1
	)
	var max_voxel := Vector3i(
		ceili(max(player_aabb.end.x, dest_aabb.end.x)) + 1,
		ceili(max(player_aabb.end.y, dest_aabb.end.y)) + 1,
		ceili(max(player_aabb.end.z, dest_aabb.end.z)) + 1
	)
	
	var closest_hit := INF
	var hit_normal := Vector3.ZERO
	
	# Testear cada voxel en el camino
	for x in range(min_voxel.x, max_voxel.x + 1):
		for y in range(min_voxel.y, max_voxel.y + 1):
			for z in range(min_voxel.z, max_voxel.z + 1):
				if _is_voxel_air(x, y, z):
					continue
				
				# AABB del voxel (1×1×1)
				var voxel_aabb := AABB(Vector3(x, y, z), Vector3(1, 1, 1))
				
				# Expandir AABB del voxel por el tamaño del jugador (Minkowski sum)
				# En vez de mover el jugador, "crecemos" el voxel
				var expanded_aabb := AABB(
					voxel_aabb.position - _half_size,
					voxel_aabb.size + box_size
				)
				
				# Raycast contra el AABB expandido
				var hit := _raycast_aabb(origin, direction, max_dist, expanded_aabb)
				if hit.hit and hit.distance < closest_hit:
					closest_hit = hit.distance
					hit_normal = hit.normal
	
	return {
		"hit": closest_hit < INF,
		"distance": closest_hit,
		"normal": hit_normal
	}

## Raycast contra un AABB. Devuelve hit, distance, normal.
func _raycast_aabb(origin: Vector3, direction: Vector3, max_dist: float, aabb: AABB) -> Dictionary:
	var tmin := 0.0
	var tmax := max_dist
	var normal := Vector3.ZERO
	
	# Para cada eje
	for i in 3:
		if direction[i] == 0.0:
			# Rayo paralelo al eje: ¿está dentro del slab?
			if origin[i] < aabb.position[i] or origin[i] > aabb.end[i]:
				return {"hit": false, "distance": 0.0, "normal": Vector3.ZERO}
		else:
			var inv_d := 1.0 / direction[i]
			var t1 := (aabb.position[i] - origin[i]) * inv_d
			var t2 := (aabb.end[i] - origin[i]) * inv_d
			
			var t_enter := minf(t1, t2)
			var t_exit := maxf(t1, t2)
			
			if t_enter > tmin:
				tmin = t_enter
				# Determinar normal (dirección de la cara impactada)
				normal = Vector3.ZERO
				normal[i] = 1.0 if t1 > t2 else -1.0
				# Ajustar según dirección del rayo
				if direction[i] < 0.0:
					normal[i] = -normal[i]
			
			if t_exit < tmax:
				tmax = t_exit
			
			if tmin > tmax:
				return {"hit": false, "distance": 0.0, "normal": Vector3.ZERO}
	
	if tmin > max_dist:
		return {"hit": false, "distance": 0.0, "normal": Vector3.ZERO}
	
	return {"hit": true, "distance": tmin, "normal": normal}

## Consulta si un voxel es aire (ID = 0)
func _is_voxel_air(x: int, y: int, z: int) -> bool:
	if world == null:
		push_error("VoxelBoxMover: world es null")
		return true
	var id : int = world.get_voxel(Vector3i(x, y, z))
	return id == 0

## Verifica si el jugador está en el suelo.
## Lanza un sweep corto hacia abajo desde los pies.
func is_on_ground(position: Vector3) -> bool:
	var feet_pos := position - Vector3(0, _half_size.y, 0)
	var hit := _sweep_aabb(feet_pos, Vector3(0, -1, 0), 0.05)
	return hit.hit

## Verifica si hay espacio libre en una posición (útil para spawning)
func is_position_free(position: Vector3) -> bool:
	var player_aabb := AABB(position - _half_size, box_size)
	var min_voxel := Vector3i(floori(player_aabb.position.x), floori(player_aabb.position.y), floori(player_aabb.position.z))
	var max_voxel := Vector3i(ceili(player_aabb.end.x), ceili(player_aabb.end.y), ceili(player_aabb.end.z))
	
	for x in range(min_voxel.x, max_voxel.x + 1):
		for y in range(min_voxel.y, max_voxel.y + 1):
			for z in range(min_voxel.z, max_voxel.z + 1):
				if not _is_voxel_air(x, y, z):
					return false
	return true

## Encuentra la altura del suelo debajo de una posición (para spawning)
func find_ground_height(x: float, z: float, start_y: float, max_search: int = 200) -> float:
	var y := start_y
	for i in range(max_search):
		if not _is_voxel_air(floori(x), floori(y), floori(z)):
			return y + 1.0  # Situar justo encima del bloque
		y -= 1.0
	return start_y  # No se encontró suelo
