extends Control
# Panel de debug para ajustar parámetros de biomas en tiempo real
# Crea su propia UI programáticamente

var world: Node3D
var player: Node3D
var generator
var biome_dist

# Controles UI
var seed_input: SpinBox
var cell_count_input: SpinBox
var warp_slider: HSlider
var warp_label: Label
var height_slider: HSlider
var height_label: Label
var variation_slider: HSlider
var variation_label: Label
var scale_slider: HSlider
var scale_label: Label
var octaves_input: SpinBox
var biome_selector: OptionButton
var noclip_btn: Button
var regenerate_btn: Button
var info_label: Label

const BIOME_NAMES = [
	"Crystal Forest", "Acid Lakes", "Fungal Swamp", "Magma Fields",
	"Void Cracks", "Bio-Mechanical", "Gravity Wells", "Echo Plains"
]

var current_biome_index = 0

func _ready():
	# Crear UI programáticamente
	_create_ui()
	
	# Buscar referencias
	world = get_node_or_null("../World")
	player = get_node_or_null("../Player")
	
	# Conectar señales
	noclip_btn.pressed.connect(_on_noclip_pressed)
	regenerate_btn.pressed.connect(_on_regenerate_pressed)
	seed_input.value_changed.connect(_on_value_changed)
	cell_count_input.value_changed.connect(_on_value_changed)
	warp_slider.value_changed.connect(_on_value_changed)
	height_slider.value_changed.connect(_on_value_changed)
	variation_slider.value_changed.connect(_on_value_changed)
	scale_slider.value_changed.connect(_on_value_changed)
	octaves_input.value_changed.connect(_on_value_changed)
	biome_selector.item_selected.connect(_on_biome_selected)
	
	# Sincronizar valores
	_sync_from_world()
	_update_labels()
	_update_info()

func _create_ui():
	# Panel principal
	custom_minimum_size = Vector2(280, 480)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)
	
	# Título
	var title = Label.new()
	title.text = "🌍 BIOME DEBUG"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)
	
	# Helpers para crear filas
	var sep1 = HSeparator.new()
	vbox.add_child(sep1)
	
	# Seed
	vbox.add_child(_create_row("Seed:", _create_spinbox(12345, 0, 999999, 1)))
	seed_input = vbox.get_child(-1).get_child(1) as SpinBox
	
	# Cell Count
	vbox.add_child(_create_row("Celdas:", _create_spinbox(50, 10, 200, 1)))
	cell_count_input = vbox.get_child(-1).get_child(1) as SpinBox
	
	# Warp
	var warp_row = _create_row("Warp:", _create_slider(0.3, 0, 1, 0.01))
	warp_slider = warp_row.get_child(1) as HSlider
	warp_label = Label.new()
	warp_label.custom_minimum_size = Vector2(40, 0)
	warp_row.add_child(warp_label)
	vbox.add_child(warp_row)
	
	var sep2 = HSeparator.new()
	vbox.add_child(sep2)
	
	# Altura
	var height_row = _create_row("Altura:", _create_slider(64, 0, 150, 1))
	height_slider = height_row.get_child(1) as HSlider
	height_label = Label.new()
	height_label.custom_minimum_size = Vector2(40, 0)
	height_row.add_child(height_label)
	vbox.add_child(height_row)
	
	# Variación
	var var_row = _create_row("Variación:", _create_slider(8, 0, 50, 1))
	variation_slider = var_row.get_child(1) as HSlider
	variation_label = Label.new()
	variation_label.custom_minimum_size = Vector2(40, 0)
	var_row.add_child(variation_label)
	vbox.add_child(var_row)
	
	# Escala
	var scale_row = _create_row("Escala:", _create_slider(0.01, 0.001, 0.1, 0.001))
	scale_slider = scale_row.get_child(1) as HSlider
	scale_label = Label.new()
	scale_label.custom_minimum_size = Vector2(40, 0)
	scale_row.add_child(scale_label)
	vbox.add_child(scale_row)
	
	# Octavas
	vbox.add_child(_create_row("Octavas:", _create_spinbox(4, 1, 8, 1)))
	octaves_input = vbox.get_child(-1).get_child(1) as SpinBox
	
	var sep3 = HSeparator.new()
	vbox.add_child(sep3)
	
	# Selector de bioma
	var biome_row = HBoxContainer.new()
	var biome_label = Label.new()
	biome_label.text = "Bioma:"
	biome_label.custom_minimum_size = Vector2(80, 0)
	biome_row.add_child(biome_label)
	biome_selector = OptionButton.new()
	biome_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in range(BIOME_NAMES.size()):
		biome_selector.add_item(BIOME_NAMES[i], i)
	biome_row.add_child(biome_selector)
	vbox.add_child(biome_row)
	
	# Botón de noclip
	var move_hbox = HBoxContainer.new()
	move_hbox.add_theme_constant_override("separation", 4)
	
	noclip_btn = Button.new()
	noclip_btn.text = "👻 NOCLIP: OFF"
	noclip_btn.toggle_mode = true
	noclip_btn.focus_mode = Control.FOCUS_NONE  # Evitar que Space/Enter togglee el botón
	noclip_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	move_hbox.add_child(noclip_btn)
	
	# Botón regenerar
	regenerate_btn = Button.new()
	regenerate_btn.text = "🔄 Regenerar"
	regenerate_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	move_hbox.add_child(regenerate_btn)
	
	vbox.add_child(move_hbox)
	
	# Info
	info_label = Label.new()
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(info_label)

func _create_row(label_text: String, control: Control) -> HBoxContainer:
	var row = HBoxContainer.new()
	var label = Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(80, 0)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row

func _create_spinbox(value: float, min_val: float, max_val: float, step: float) -> SpinBox:
	var sb = SpinBox.new()
	sb.value = value
	sb.min_value = min_val
	sb.max_value = max_val
	sb.step = step
	return sb

func _create_slider(value: float, min_val: float, max_val: float, step: float) -> HSlider:
	var slider = HSlider.new()
	slider.value = value
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step
	return slider

func _sync_from_world():
	if world == null:
		return
	
	if world.has_method("get_generator"):
		generator = world.get_generator()
	
	if generator != null and generator.has_method("get_biome_distribution"):
		biome_dist = generator.get_biome_distribution()
	
	if biome_dist != null:
		if biome_dist.has_method("get_seed"):
			seed_input.value = biome_dist.get_seed()
		if biome_dist.has_method("get_cell_count"):
			cell_count_input.value = biome_dist.get_cell_count()
		if biome_dist.has_method("get_warp_strength"):
			warp_slider.value = biome_dist.get_warp_strength()
	
	_sync_shaper()

func _sync_shaper():
	if generator == null or !generator.has_method("get_shaper"):
		return
	
	var shaper = generator.get_shaper(current_biome_index)
	if shaper == null:
		return
	
	if shaper.has_method("get_base_height"):
		height_slider.value = shaper.get_base_height()
	if shaper.has_method("get_height_variation"):
		variation_slider.value = shaper.get_height_variation()
	if shaper.has_method("get_noise_scale"):
		scale_slider.value = shaper.get_noise_scale()
	if shaper.has_method("get_noise_octaves"):
		octaves_input.value = shaper.get_noise_octaves()

func _update_labels():
	warp_label.text = str(warp_slider.value)
	height_label.text = str(int(height_slider.value))
	variation_label.text = str(int(variation_slider.value))
	scale_label.text = str(scale_slider.value)

func _update_info():
	var mode_text = ""
	if player != null:
		if player.has_method("get_movement_mode"):
			mode_text = " | %s" % player.get_movement_mode()
	if world != null and world.has_method("get_chunk_count"):
		info_label.text = "Chunks: %d | %s%s" % [world.get_chunk_count(), BIOME_NAMES[current_biome_index], mode_text]
	else:
		info_label.text = "Bioma: %s%s" % [BIOME_NAMES[current_biome_index], mode_text]

func _on_noclip_pressed():
	if player == null:
		push_error("No hay Player conectado")
		return
	
	var active = player.toggle_noclip()
	noclip_btn.text = "👻 NOCLIP: %s" % ("ON" if active else "OFF")
	noclip_btn.button_pressed = active
	_update_info()

func _on_regenerate_pressed():
	if world == null:
		push_error("No hay World conectado")
		return
	
	print("🔄 Regenerando mundo con parámetros actuales...")
	
	# Actualizar seed de la distribución
	if biome_dist != null and biome_dist.has_method("set_seed"):
		biome_dist.set_seed(int(seed_input.value))
	
	# Regenerar regiones de biomas
	if biome_dist != null and biome_dist.has_method("_generate_regions"):
		biome_dist._generate_regions()
	
	# Limpiar y regenerar mundo
	world.clear_world()
	world.generate_world(Vector3i(0, 0, 0), world.view_distance)
	
	print("🔄 Mundo regenerado. Chunks: ", world.get_chunk_count())
	_update_info()

func _on_biome_selected(index):
	current_biome_index = index
	_sync_shaper()
	_update_info()
	_update_labels()

func _on_value_changed(_value):
	_update_labels()
	_apply_shaper_params()

func _apply_shaper_params():
	if generator == null or !generator.has_method("get_shaper"):
		return
	
	var shaper = generator.get_shaper(current_biome_index)
	if shaper == null:
		return
	
	shaper.set_base_height(height_slider.value)
	shaper.set_height_variation(variation_slider.value)
	shaper.set_noise_scale(scale_slider.value)
	shaper.set_noise_octaves(int(octaves_input.value))
	shaper.set_seed(int(seed_input.value))
	
	# Actualizar distribución de biomas
	if biome_dist != null and biome_dist.has_method("set_cell_count"):
		biome_dist.set_cell_count(int(cell_count_input.value))
	if biome_dist != null and biome_dist.has_method("set_warp_strength"):
		biome_dist.set_warp_strength(warp_slider.value)
