## In-VR pointer for UI panels (display settings and story panels): casts rays from both
## right and left controllers, shows a laser dot where each hits the panel quad, forwards hover
## into the panel's SubViewport, and synthesizes continuous mouse drag / click events with either
## hand's trigger so sliders and buttons can be operated fluidly by either hand.
## In XR the panel is visible by default and toggled by the B/Y button on either controller.
extends Node3D

const TRIGGER_THRESHOLD := 0.7

@export var right_controller: XRController3D
@export var left_controller: XRController3D
@export var panel_quad: MeshInstance3D
@export var panel_viewport: SubViewport
@export var laser_dot: MeshInstance3D:
	set(val):
		laser_dot = val
		_ensure_laser_dot_left()
@export var laser_dot_left: MeshInstance3D

var _prev_by_pressed: bool = false
var _active_controller: XRController3D = null
var _prev_active_trigger: bool = false
var _last_uv := Vector2(0.5, 0.5)
var _was_xr: bool = false


func _ready() -> void:
	_ensure_laser_dot_left()


func _ensure_laser_dot_left() -> void:
	if laser_dot and laser_dot_left == null and laser_dot.get_parent():
		laser_dot_left = laser_dot.duplicate() as MeshInstance3D
		laser_dot.get_parent().add_child(laser_dot_left)
		laser_dot_left.visible = false


func _exit_tree() -> void:
	if laser_dot_left and is_instance_valid(laser_dot_left) and laser_dot_left.get_parent():
		laser_dot_left.queue_free()
		laser_dot_left = null


func _physics_process(_delta: float) -> void:
	if panel_quad == null or panel_viewport == null:
		return
	if right_controller == null and left_controller == null:
		return

	var is_xr: bool = get_viewport().use_xr
	if not is_xr:
		_was_xr = false
		panel_quad.visible = false
		if laser_dot:
			laser_dot.visible = false
		if laser_dot_left:
			laser_dot_left.visible = false
		return

	if not _was_xr:
		_was_xr = true
		panel_quad.visible = true

	_handle_toggle()

	if not panel_quad.visible:
		if laser_dot:
			laser_dot.visible = false
		if laser_dot_left:
			laser_dot_left.visible = false
		if _prev_active_trigger:
			_push_button(_last_uv, false)
			_prev_active_trigger = false
			_active_controller = null
		return

	if laser_dot and laser_dot_left == null:
		_ensure_laser_dot_left()

	var right_hit := _intersect_quad(right_controller.global_transform) if right_controller else {}
	var left_hit := _intersect_quad(left_controller.global_transform) if left_controller else {}

	var right_trigger: bool = right_controller.get_float("trigger") > TRIGGER_THRESHOLD if right_controller else false
	var left_trigger: bool = left_controller.get_float("trigger") > TRIGGER_THRESHOLD if left_controller else false

	if laser_dot:
		if not right_hit.is_empty():
			laser_dot.visible = true
			laser_dot.global_position = right_hit["point"]
		else:
			laser_dot.visible = false

	if laser_dot_left:
		if not left_hit.is_empty():
			laser_dot_left.visible = true
			laser_dot_left.global_position = left_hit["point"]
		else:
			laser_dot_left.visible = false

	var driving_controller: XRController3D = null
	var hit_dict: Dictionary = {}

	if _active_controller != null:
		driving_controller = _active_controller
		var is_right := (driving_controller == right_controller)
		hit_dict = right_hit if is_right else left_hit
	else:
		if right_trigger and not right_hit.is_empty():
			driving_controller = right_controller
			hit_dict = right_hit
		elif left_trigger and not left_hit.is_empty():
			driving_controller = left_controller
			hit_dict = left_hit
		elif not right_hit.is_empty():
			driving_controller = right_controller
			hit_dict = right_hit
		elif not left_hit.is_empty():
			driving_controller = left_controller
			hit_dict = left_hit

	if driving_controller == null or hit_dict.is_empty():
		if _prev_active_trigger:
			_push_button(_last_uv, false)
			_prev_active_trigger = false
		_active_controller = null
		return

	var uv: Vector2 = hit_dict["uv"]
	_last_uv = uv

	var trigger_pressed: bool = driving_controller.get_float("trigger") > TRIGGER_THRESHOLD
	if trigger_pressed and not _prev_active_trigger:
		_active_controller = driving_controller
		_push_button(uv, true)
	elif trigger_pressed and _prev_active_trigger:
		_push_motion(uv, true)
	elif not trigger_pressed and _prev_active_trigger:
		_push_button(uv, false)
		_active_controller = null
	else:
		_push_motion(uv, false)

	# Forward thumbstick vertical axis as mouse wheel scroll events
	var thumbstick_y: float = driving_controller.get_vector2("primary").y
	if absf(thumbstick_y) > 0.2:
		var pos := _uv_to_viewport_pos(uv)
		var wheel_event := InputEventMouseButton.new()
		wheel_event.position = pos
		wheel_event.global_position = pos
		wheel_event.button_index = MouseButton.MOUSE_BUTTON_WHEEL_UP if thumbstick_y > 0.0 else MouseButton.MOUSE_BUTTON_WHEEL_DOWN
		wheel_event.pressed = true
		wheel_event.factor = clampf(absf(thumbstick_y) * 2.0, 1.0, 5.0)
		panel_viewport.push_input(wheel_event)
		var wheel_release := wheel_event.duplicate() as InputEventMouseButton
		wheel_release.pressed = false
		panel_viewport.push_input(wheel_release)

	_prev_active_trigger = trigger_pressed


func _handle_toggle() -> void:
	var by_pressed: bool = false
	if left_controller and left_controller.is_button_pressed("by_button"):
		by_pressed = true
	elif right_controller and right_controller.is_button_pressed("by_button"):
		by_pressed = true
	if by_pressed and not _prev_by_pressed:
		panel_quad.visible = not panel_quad.visible
	_prev_by_pressed = by_pressed


func _intersect_quad(ray_transform: Transform3D) -> Dictionary:
	var mesh := panel_quad.mesh as QuadMesh
	if mesh == null:
		return {}
	var quad_size: Vector2 = mesh.size

	var inv := panel_quad.global_transform.affine_inverse()
	var local_origin: Vector3 = inv * ray_transform.origin
	var local_dir: Vector3 = (inv.basis * (-ray_transform.basis.z)).normalized()

	if absf(local_dir.z) < 0.0001:
		return {}
	var t := -local_origin.z / local_dir.z
	if t < 0.0:
		return {}

	var local_hit: Vector3 = local_origin + local_dir * t
	var half := quad_size * 0.5
	if absf(local_hit.x) > half.x or absf(local_hit.y) > half.y:
		return {}

	var uv := Vector2(
		(local_hit.x / quad_size.x) + 0.5,
		0.5 - (local_hit.y / quad_size.y)
	)
	return {"point": panel_quad.to_global(local_hit), "uv": uv}


func _push_motion(uv: Vector2, held: bool) -> void:
	var pos := _uv_to_viewport_pos(uv)
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.global_position = pos
	if held:
		event.button_mask = MOUSE_BUTTON_MASK_LEFT
	panel_viewport.push_input(event)


func _push_button(uv: Vector2, pressed: bool) -> void:
	var pos := _uv_to_viewport_pos(uv)
	var btn := InputEventMouseButton.new()
	btn.position = pos
	btn.global_position = pos
	btn.button_index = MOUSE_BUTTON_LEFT
	btn.pressed = pressed
	if pressed:
		btn.button_mask = MOUSE_BUTTON_MASK_LEFT
	panel_viewport.push_input(btn)


func _uv_to_viewport_pos(uv: Vector2) -> Vector2:
	var size := Vector2(panel_viewport.size)
	return Vector2(uv.x * size.x, uv.y * size.y)
