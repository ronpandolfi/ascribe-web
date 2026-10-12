## The mesh half of the display settings panel: a shader picker and, for the tunable `surface`
## shader, colour, opacity, roughness, metallic, rim and the inner-surfaces toggle. Built in code
## and owned by DisplaySettingsPanel, which shows either this or the volume controls.
class_name MeshSettingsSection
extends VBoxContainer

signal changed

const SHADER_LABELS := {"surface": "Surface", "pearl": "Pearl", "crystal": "Crystal",
	"hologram": "Hologram"}
## Colour presets for the in-VR panel, where a colour picker is fiddly to drive with a laser
## pointer. Gold first: it is the default.
const SWATCHES := ["#d4af37", "#c8d2e6", "#e3dac9", "#b87333", "#2a9d8f", "#c0392b", "#8e44ad",
	"#5d6d7e"]
const SLIDERS := [
	["opacity", "Opacity: %.2f"],
	["roughness", "Roughness: %.2f"],
	["metallic", "Metallic: %.2f"],
	["rim", "Rim light: %.2f"],
]

var _shader_option: OptionButton
var _surface_box: VBoxContainer
var _color_picker: ColorPickerButton
var _swatch_row: HBoxContainer
var _inner_check: CheckBox
var _sliders := {}  # key -> HSlider
var _labels := {}   # key -> [Label, format]
var _color: String = MeshSurfaceMaterial.DEFAULT_COLOR


func _init() -> void:
	name = "MeshSection"

	_shader_option = OptionButton.new()
	_shader_option.name = "Shader"
	for key in MeshSurfaceMaterial.SHADERS:
		_shader_option.add_item(SHADER_LABELS[key])
	_shader_option.item_selected.connect(func(_i: int) -> void:
		_sync_surface_visibility()
		changed.emit()
	)
	add_child(_shader_option)

	_surface_box = VBoxContainer.new()
	_surface_box.name = "Surface"
	add_child(_surface_box)

	_color_picker = ColorPickerButton.new()
	_color_picker.name = "Color"
	_color_picker.custom_minimum_size = Vector2(0, 28)
	_color_picker.edit_alpha = false
	_color_picker.color_changed.connect(func(c: Color) -> void:
		_color = "#" + c.to_html(false)
		_sync_swatches()
		changed.emit()
	)
	_surface_box.add_child(_color_picker)

	_swatch_row = HBoxContainer.new()
	_swatch_row.name = "Swatches"
	_swatch_row.visible = false
	for hex in SWATCHES:
		_swatch_row.add_child(_make_swatch(hex))
	_surface_box.add_child(_swatch_row)

	for spec in SLIDERS:
		_add_slider(spec[0], spec[1])

	_inner_check = CheckBox.new()
	_inner_check.name = "InnerSurfaces"
	_inner_check.text = "Show inner surfaces"
	_inner_check.toggled.connect(func(_p: bool) -> void: changed.emit())
	_surface_box.add_child(_inner_check)

	var defaults := MeshSurfaceMaterial.resolved({})
	defaults["shader"] = "surface"
	set_display(defaults)


## The mesh look as a display dict: always exactly these seven keys.
func get_display() -> Dictionary:
	var d := {
		"shader": MeshSurfaceMaterial.SHADERS[_shader_option.selected],
		"color": _color,
		"inner_surfaces": _inner_check.button_pressed,
	}
	for key in _sliders:
		d[key] = (_sliders[key] as HSlider).value
	return d


## Shows the keys present in `display` without emitting `changed`; absent keys keep their value.
func set_display(display: Dictionary) -> void:
	if display.has("shader"):
		_shader_option.select(MeshSurfaceMaterial.SHADERS.find(
			MeshSurfaceMaterial.shader_name(display)))
	if display.has("color"):
		# Through resolved() so an invalid hand-edited colour shows and saves as the default the
		# mesh actually renders, rather than failing schema validation on save.
		_color = MeshSurfaceMaterial.resolved(display)["color"]
		_color_picker.color = Color.from_string(_color, _color_picker.color)
	var s := MeshSurfaceMaterial.resolved(display)
	for key in _sliders:
		if display.has(key):
			(_sliders[key] as HSlider).set_value_no_signal(s[key])
			_refresh_label(key)
	if display.has("inner_surfaces"):
		_inner_check.set_pressed_no_signal(s["inner_surfaces"])
	_sync_surface_visibility()
	_sync_swatches()


## In a headset, offers preset swatches in place of the colour picker.
func set_vr(vr: bool) -> void:
	_color_picker.visible = not vr
	_swatch_row.visible = vr


func _add_slider(key: String, fmt: String) -> void:
	var label := Label.new()
	label.name = key.capitalize() + "Label"
	var slider := HSlider.new()
	slider.name = key.capitalize()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	_sliders[key] = slider
	_labels[key] = [label, fmt]
	slider.value_changed.connect(func(_v: float) -> void:
		_refresh_label(key)
		changed.emit()
	)
	_surface_box.add_child(label)
	_surface_box.add_child(slider)


func _refresh_label(key: String) -> void:
	var entry: Array = _labels[key]
	(entry[0] as Label).text = (entry[1] as String) % (_sliders[key] as HSlider).value


func _make_swatch(hex: String) -> Button:
	var b := Button.new()
	b.name = "Swatch_" + hex.substr(1)
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(44, 44)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color.from_string(hex, Color.WHITE)
	var selected := normal.duplicate() as StyleBoxFlat
	selected.set_border_width_all(3)
	selected.border_color = Color.WHITE
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", normal)
	b.add_theme_stylebox_override("pressed", selected)
	b.add_theme_stylebox_override("hover_pressed", selected)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(func() -> void:
		_color = hex
		_color_picker.color = Color.from_string(hex, _color_picker.color)
		_sync_swatches()
		changed.emit()
	)
	return b


func _sync_surface_visibility() -> void:
	_surface_box.visible = _shader_option.selected == 0


## Marks the swatch matching the current colour, if any. A colour that matches none is kept as is.
func _sync_swatches() -> void:
	for b in _swatch_row.get_children():
		(b as Button).set_pressed_no_signal(b.name == "Swatch_" + _color.substr(1))
