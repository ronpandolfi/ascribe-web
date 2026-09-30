## In-VR pointer for the display settings panel: casts a ray from the right controller, shows a
## laser dot where it hits the panel quad, forwards hover as mouse motion into the panel's
## SubViewport, and synthesizes continuous mouse drag / click events with the trigger so sliders
## can be dragged fluidly.
## The panel is hidden outside XR; in XR it is visible by default and toggled by the left
## controller's "by" button when that input is available (headsets without it just leave it on).
extends Node3D

const TRIGGER_THRESHOLD := 0.7

@export var right_controller: XRController3D
@export var left_controller: XRController3D
@export var panel_quad: MeshInstance3D
@export var panel_viewport: SubViewport
@export var laser_dot: MeshInstance3D

var _prev_by_pressed: bool = false
var _prev_trigger_pressed: bool = false
var _last_uv := Vector2(0.5, 0.5)


func _physics_process(_delta: float) -> void:
	if panel_quad == null or right_controller == null or panel_viewport == null:
		return

	if not get_viewport().use_xr:
		panel_quad.visible = false
		if laser_dot:
			laser_dot.visible = false
		return

	_handle_toggle()

	if not panel_quad.visible:
		if laser_dot:
			laser_dot.visible = false
		if _prev_trigger_pressed:
			_push_button(_last_uv, false)
			_prev_trigger_pressed = false
		return

	var hit := _intersect_quad(right_controller.global_transform)
	if hit.is_empty():
		if laser_dot:
			laser_dot.visible = false
		if _prev_trigger_pressed:
			_push_button(_last_uv, false)
			_prev_trigger_pressed = false
		return

	if laser_dot:
		laser_dot.visible = true
		laser_dot.global_position = hit["point"]

	var uv: Vector2 = hit["uv"]
	_last_uv = uv

	var trigger_pressed: bool = right_controller.get_float("trigger") > TRIGGER_THRESHOLD
	if trigger_pressed and not _prev_trigger_pressed:
		_push_button(uv, true)
	elif trigger_pressed and _prev_trigger_pressed:
		_push_motion(uv, true)
	elif not trigger_pressed and _prev_trigger_pressed:
		_push_button(uv, false)
	else:
		_push_motion(uv, false)

	_prev_trigger_pressed = trigger_pressed


func _handle_toggle() -> void:
	if left_controller == null:
		return
	var by_pressed: bool = left_controller.is_button_pressed("by_button")
	if by_pressed and not _prev_by_pressed:
		panel_quad.visible = not panel_quad.visible
	_prev_by_pressed = by_pressed


## Ray-vs-plane intersection between the controller's forward ray (-Z in its local space) and the
## panel quad's plane, in the quad's own coordinate frame. Returns `{}` when the ray points away
## from the plane or misses the quad's bounds; otherwise `{"point": Vector3, "uv": Vector2}` where
## `uv` is in `[0,1]x[0,1]` with the origin at the quad's top-left (viewport pixel convention).
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
