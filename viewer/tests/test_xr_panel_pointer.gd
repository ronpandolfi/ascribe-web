extends GdUnitTestSuite
@warning_ignore("unused_parameter")

const XRPanelPointerScript = preload("res://scripts/xr_panel_pointer.gd")


func _create_test_pointer() -> Dictionary:
	var parent := Node3D.new()
	add_child(parent)

	# Create quad mesh instance
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(1.0, 1.0)
	quad.mesh = mesh
	quad.position = Vector3(0, 0, -1.0) # 1 meter forward
	parent.add_child(quad)

	# Create viewport
	var vp := SubViewport.new()
	vp.size = Vector2i(500, 500)
	parent.add_child(vp)

	# Create right laser dot
	var dot_right := MeshInstance3D.new()
	dot_right.mesh = SphereMesh.new()
	parent.add_child(dot_right)

	# Create controllers
	var right_ctrl := XRController3D.new()
	var left_ctrl := XRController3D.new()
	parent.add_child(right_ctrl)
	parent.add_child(left_ctrl)

	var pointer: Node3D = XRPanelPointerScript.new()
	pointer.panel_quad = quad
	pointer.panel_viewport = vp
	pointer.laser_dot = dot_right
	pointer.right_controller = right_ctrl
	pointer.left_controller = left_ctrl
	parent.add_child(pointer)

	return {
		"parent": parent,
		"pointer": pointer,
		"quad": quad,
		"viewport": vp,
		"dot_right": dot_right,
		"right_ctrl": right_ctrl,
		"left_ctrl": left_ctrl,
	}


func test_ready_creates_left_laser_dot_automatically() -> void:
	var fixture := _create_test_pointer()
	var parent: Node3D = fixture["parent"]
	var pointer: Node3D = fixture["pointer"]
	var dot_right: MeshInstance3D = fixture["dot_right"]

	auto_free(parent)

	assert_that(pointer.laser_dot_left).is_not_null()
	assert_that(pointer.laser_dot_left).is_not_same(dot_right)
	assert_bool(pointer.laser_dot_left.visible).is_false()


func test_intersect_quad_returns_correct_uv_and_world_point() -> void:
	var fixture := _create_test_pointer()
	var parent: Node3D = fixture["parent"]
	var pointer: Node3D = fixture["pointer"]
	auto_free(parent)

	# Ray aimed directly at center of quad from (0, 0, 0) towards (0, 0, -1)
	var ray_tf := Transform3D(Basis(), Vector3(0, 0, 0))
	var hit: Dictionary = pointer._intersect_quad(ray_tf)

	assert_bool(hit.is_empty()).is_false()
	assert_float(hit["uv"].x).is_equal_approx(0.5, 0.001)
	assert_float(hit["uv"].y).is_equal_approx(0.5, 0.001)
	assert_float(hit["point"].z).is_equal_approx(-1.0, 0.001)


func test_intersect_quad_misses_when_aimed_away() -> void:
	var fixture := _create_test_pointer()
	var parent: Node3D = fixture["parent"]
	var pointer: Node3D = fixture["pointer"]
	auto_free(parent)

	# Ray pointing backwards (+Z) away from the quad (-Z)
	var ray_tf := Transform3D(Basis.looking_at(Vector3(0, 0, 1)), Vector3(0, 0, 0))
	var hit: Dictionary = pointer._intersect_quad(ray_tf)
	assert_bool(hit.is_empty()).is_true()


func test_handle_toggle_toggles_quad_visibility() -> void:
	var fixture := _create_test_pointer()
	var parent: Node3D = fixture["parent"]
	var pointer: Node3D = fixture["pointer"]
	var quad: MeshInstance3D = fixture["quad"]
	auto_free(parent)

	assert_bool(quad.visible).is_true()
	pointer._prev_by_pressed = false
	# Simulating by_pressed
	pointer.left_controller.set_meta("by_pressed", true)
	# When by_pressed transitions from false to true, it toggles visibility
	pointer._handle_toggle()
