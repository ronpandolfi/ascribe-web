extends GdUnitTestSuite

const MAIN := preload("res://scenes/main.tscn")


func _make_main() -> Node3D:
	var main: Node3D = auto_free(MAIN.instantiate())
	add_child(main)
	await get_tree().process_frame
	return main


# Regression: the quads' materials carry ViewportTexture sub-resources addressed by
# `viewport_path`, which does not reliably resolve at runtime -- the quad then falls back to the
# missing-texture material, which is the pink checkerboard the panels showed in the headset.
func test_panel_quads_use_their_viewport_texture() -> void:
	var main := await _make_main()

	for pair in [["PanelQuad", "PanelViewport"], ["StoryQuad", "StoryViewport"]]:
		var quad: MeshInstance3D = main.get_node("XROrigin3D/%s" % pair[0])
		var viewport: SubViewport = main.get_node("XROrigin3D/%s" % pair[1])
		var mat: StandardMaterial3D = quad.get_surface_override_material(0)
		assert_that(mat).is_not_null()
		assert_that(mat.albedo_texture).is_not_null()
		assert_that(mat.albedo_texture).is_same(viewport.get_texture())


# Regression: the specimen was staged at the world origin, which in a headset is the floor
# between the user's feet -- it spawned underneath them instead of in front.
func test_specimen_is_staged_ahead_at_roughly_eye_height() -> void:
	var main := await _make_main()
	var stage: Node3D = main.get_node("SpecimenStage")

	assert_float(stage.position.y).is_greater(1.0)   # off the floor
	assert_float(stage.position.z).is_less(-0.5)     # in front of the origin


# ...and the desktop camera has to orbit that same point, or moving the specimen off the origin
# would push it out of frame on desktop.
func test_desktop_camera_orbits_the_specimen() -> void:
	var main := await _make_main()
	var stage: Node3D = main.get_node("SpecimenStage")
	var cam: OrbitCamera = main.get_node("Camera3D")

	assert_vector(cam.target).is_equal(stage.position)


# A headset has no browser chrome to fall back on, and the system gesture is not obvious to a
# first-time user, so the in-VR panel needs its own way out. The desktop panel must not show it.
func test_only_the_vr_panel_offers_an_exit() -> void:
	var main := await _make_main()

	var vr_button: Button = main.get_node(
		"XROrigin3D/PanelViewport/DisplaySettingsPanel/VBox/ExitVR")
	var desktop_button: Button = main.get_node(
		"CanvasLayer/DisplaySettingsPanel/VBox/ExitVR")

	assert_bool(vr_button.visible).is_true()
	assert_bool(desktop_button.visible).is_false()


func test_exit_button_emits_exit_vr_requested() -> void:
	var main := await _make_main()
	var panel: DisplaySettingsPanel = main.get_node(
		"XROrigin3D/PanelViewport/DisplaySettingsPanel")
	var seen := [false]
	panel.exit_vr_requested.connect(func(): seen[0] = true)

	panel.get_node("VBox/ExitVR").pressed.emit()

	assert_bool(seen[0]).is_true()


# Regression: the panels used to stay at their slider defaults while the render used the
# manifest's gamma/opacity, so the panel misreported the current state -- and in edit mode
# saving wrote those defaults over a tuned manifest.
func test_panels_show_the_bundles_display_settings() -> void:
	var main := await _make_main()
	var panel: DisplaySettingsPanel = main.get_node("CanvasLayer/DisplaySettingsPanel")

	panel.set_display({"gamma": 1.3, "opacity": 0.7})

	var shown := panel.get_display()
	assert_float(shown["gamma"]).is_equal_approx(1.3, 0.001)
	assert_float(shown["opacity"]).is_equal_approx(0.7, 0.001)


# Edit mode must never be offered unless it was explicitly asked for: the Save button only
# works behind `ascribe-bundle serve --edit`, so showing it on a deployed bundle would mislead.
func test_edit_mode_is_off_by_default() -> void:
	var main := await _make_main()
	var save_button: Button = main.get_node(
		"CanvasLayer/DisplaySettingsPanel/VBox/Save")
	assert_bool(save_button.visible).is_false()


# A bundle that specifies a quality meant it -- edit mode saves exactly that -- so the automatic
# tier must not quietly overwrite it on load.
func test_authored_quality_survives_the_startup_tier() -> void:
	var main := await _make_main()
	main._authored_quality = {"max_steps": 2048, "step_size": Quality.step_size_for(2048)}
	main._apply_quality_tier()

	var panel: DisplaySettingsPanel = main.get_node("CanvasLayer/DisplaySettingsPanel")
	assert_that(panel.get_display()["max_steps"]).is_equal(2048)


# ...but it must never push a headset above what its tier can afford: rendering slowly on a
# desktop is a nuisance, dropping frames in VR is not.
func test_authored_quality_is_capped_in_xr() -> void:
	var main := await _make_main()
	main._authored_quality = {"max_steps": 2048, "step_size": Quality.step_size_for(2048)}
	main.get_viewport().use_xr = true
	main._apply_quality_tier()
	main.get_viewport().use_xr = false

	var panel: DisplaySettingsPanel = main.get_node("CanvasLayer/DisplaySettingsPanel")
	assert_that(panel.get_display()["max_steps"]).is_equal(Quality.XR_STEPS)

func test_fullscreen_button_exists_and_defaults_to_fullscreen_text() -> void:
	var main := await _make_main()
	var btn: Button = main.get_node("CanvasLayer/Fullscreen")
	assert_that(btn).is_not_null()
	assert_that(btn.text).is_equal("Fullscreen")
	assert_bool(btn.visible).is_true()


func test_fullscreen_button_toggles_mode_and_updates_text() -> void:
	var main := await _make_main()
	var btn: Button = main.get_node("CanvasLayer/Fullscreen")

	main._toggle_fullscreen()
	assert_bool(main._is_fullscreen()).is_true()
	assert_that(btn.text).is_equal("Exit Fullscreen")

	main._toggle_fullscreen()
	assert_bool(main._is_fullscreen()).is_false()
	assert_that(btn.text).is_equal("Fullscreen")


func test_fullscreen_button_hidden_in_xr() -> void:
	var main := await _make_main()
	var btn: Button = main.get_node("CanvasLayer/Fullscreen")

	main._on_session_started()
	assert_bool(btn.visible).is_false()

	main._on_session_ended()
	assert_bool(btn.visible).is_true()


func test_fullscreen_button_layout_adapts_to_story_panel() -> void:
	var main := await _make_main()
	var btn: Button = main.get_node("CanvasLayer/Fullscreen")
	var story: StoryPanel = main.get_node("CanvasLayer/StoryPanel")

	story.visible = false
	main._update_fullscreen_button_layout()
	assert_float(btn.offset_right).is_equal_approx(-16.0, 0.1)

	story.visible = true
	main._update_fullscreen_button_layout()
	assert_float(btn.offset_right).is_equal_approx(-336.0, 0.1)

func test_xr_session_toggles_scaling_and_cameras() -> void:
	var main := await _make_main()
	var vp := main.get_viewport()
	var cam_desktop: Camera3D = main.get_node("Camera3D")
	var cam_xr: XRCamera3D = main.get_node("XROrigin3D/XRCamera3D")
	var panel_vp: SubViewport = main.get_node("XROrigin3D/PanelViewport")
	var story_vp: SubViewport = main.get_node("XROrigin3D/StoryViewport")

	# Initial desktop state (adaptive scaling starts near 1.0)
	assert_float(vp.scaling_3d_scale).is_greater(0.8)
	assert_bool(cam_desktop.current).is_true()
	assert_bool(cam_xr.current).is_false()
	assert_that(panel_vp.render_target_update_mode).is_equal(SubViewport.UPDATE_DISABLED)
	assert_that(story_vp.render_target_update_mode).is_equal(SubViewport.UPDATE_DISABLED)

	# Enter XR session
	main._on_session_started()
	assert_float(vp.scaling_3d_scale).is_equal_approx(main.XR_SCALING_3D_SCALE, 0.001)
	assert_bool(cam_desktop.current).is_false()
	assert_bool(cam_xr.current).is_true()
	assert_that(panel_vp.render_target_update_mode).is_equal(SubViewport.UPDATE_ALWAYS)
	assert_that(story_vp.render_target_update_mode).is_equal(SubViewport.UPDATE_ALWAYS)

	# End XR session
	main._on_session_ended()
	assert_float(vp.scaling_3d_scale).is_greater(0.8)
	assert_bool(cam_desktop.current).is_true()
	assert_bool(cam_xr.current).is_false()
	assert_that(panel_vp.render_target_update_mode).is_equal(SubViewport.UPDATE_DISABLED)
	assert_that(story_vp.render_target_update_mode).is_equal(SubViewport.UPDATE_DISABLED)

func test_adaptive_resolution_scales_with_camera_distance() -> void:
	var main := await _make_main()
	var vp := main.get_viewport()
	var cam: Camera3D = main.get_node("Camera3D")
	var stage: Node3D = main.get_node("SpecimenStage")

	# Put camera far away (e.g. stage pos + 3.0m back)
	cam.global_position = stage.global_position + Vector3(0, 0, 3.0)
	for i in range(5):
		main._update_adaptive_resolution(0.5)
	var far_scale := vp.scaling_3d_scale
	assert_float(far_scale).is_greater(0.9)

	# Put camera right inside the volume at the stage position
	cam.global_position = stage.global_position
	for i in range(15):
		main._update_adaptive_resolution(0.5)
	var inside_scale := vp.scaling_3d_scale
	assert_float(inside_scale).is_less(far_scale)
	assert_float(inside_scale).is_less_equal(0.55)

func test_adaptive_step_budget_in_xr() -> void:
	var main := await _make_main()
	var vp := main.get_viewport()
	var stage: Node3D = main.get_node("SpecimenStage")
	var xr_cam: XRCamera3D = main.get_node("XROrigin3D/XRCamera3D")

	main._on_session_started()
	vp.use_xr = true
	assert_float(vp.scaling_3d_scale).is_equal_approx(1.0, 0.001)

	# XR camera far away (>= 1.5m)
	xr_cam.global_position = stage.global_position + Vector3(0, 0, 3.0)
	main._update_adaptive_resolution(0.5)
	assert_that(main._current_xr_adaptive_steps).is_equal(Quality.XR_STEPS)
	assert_float(vp.scaling_3d_scale).is_equal_approx(1.0, 0.001)

	# XR camera inside the volume
	xr_cam.global_position = stage.global_position
	main._update_adaptive_resolution(0.5)
	assert_that(main._current_xr_adaptive_steps).is_less(Quality.XR_STEPS)
	assert_that(main._current_xr_adaptive_steps).is_greater_equal(48)
	assert_float(vp.scaling_3d_scale).is_equal_approx(1.0, 0.001)

	main._on_session_ended()
	vp.use_xr = false

func test_fixed_foveation_applied_on_session_start_and_panel_change() -> void:
	var main := await _make_main()
	var panel: DisplaySettingsPanel = main.get_node("CanvasLayer/DisplaySettingsPanel")

	main._on_session_started()
	# Can call safely without crash even outside web environment
	main._apply_webxr_fixed_foveation(true, 1.0)
	main._apply_webxr_fixed_foveation(false, 0.0)

	panel.set_display({"ffr_enabled": false, "ffr_level": 0.5})
	assert_that(panel.get_display()["ffr_enabled"]).is_false()
	assert_float(panel.get_display()["ffr_level"]).is_equal_approx(0.5, 0.01)

	main._on_session_ended()

func test_motion_adaptive_step_throttling_in_xr() -> void:
	var main := await _make_main()
	var vp := main.get_viewport()
	var stage: Node3D = main.get_node("SpecimenStage")
	var xr_cam: XRCamera3D = main.get_node("XROrigin3D/XRCamera3D")

	main._on_session_started()
	vp.use_xr = true

	# Stationary far away: full XR steps
	xr_cam.global_position = stage.global_position + Vector3(0, 0, 3.0)
	xr_cam.global_basis = Basis.IDENTITY
	main._last_xr_cam_rot = Basis.IDENTITY
	main._smoothed_angular_speed = 0.0
	main._update_adaptive_resolution(0.016)
	assert_that(main._current_xr_adaptive_steps).is_equal(Quality.XR_STEPS)

	# Sudden rapid rotation (e.g. 90 degrees in 16ms = ~5600 deg/s)
	xr_cam.global_basis = Basis(Vector3.UP, deg_to_rad(90.0))
	main._update_adaptive_resolution(0.016)

	# Steps should throttle down to motion floor (48)
	assert_that(main._current_xr_adaptive_steps).is_less_equal(48)

	main._on_session_ended()
	vp.use_xr = false
