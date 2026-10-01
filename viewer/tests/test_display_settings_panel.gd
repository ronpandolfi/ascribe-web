extends GdUnitTestSuite

const PANEL := preload("res://scenes/display_settings_panel.tscn")


func _make_panel() -> DisplaySettingsPanel:
	var panel: DisplaySettingsPanel = auto_free(PANEL.instantiate())
	add_child(panel)
	return panel


# Regression: the sliders live under a VBox, but the script used to address them as `$Gamma`,
# so _ready() failed with "Node not found" and the panel was inert -- moving a slider changed
# nothing and set_display() crashed on a null instance.
func test_ready_wires_sliders_and_reports_defaults() -> void:
	var panel := _make_panel()

	var display := panel.get_display()
	assert_that(display["gamma"]).is_equal(1.0)
	assert_that(display["opacity"]).is_equal(1.0)
	assert_that(display["max_steps"]).is_equal(Quality.DESKTOP_STEPS)
	assert_that(display["step_size"]).is_equal(Quality.step_size_for(Quality.DESKTOP_STEPS))


func test_moving_a_slider_emits_display_changed() -> void:
	var panel := _make_panel()
	var seen: Array[Dictionary] = []
	panel.display_changed.connect(func(d: Dictionary): seen.append(d))

	panel.get_node("VBox/Gamma").value = 2.0

	assert_that(seen.size()).is_equal(1)
	assert_that(seen[0]["gamma"]).is_equal(2.0)
	assert_that(panel.get_display()["gamma"]).is_equal(2.0)


func test_set_display_moves_sliders_without_emitting() -> void:
	var panel := _make_panel()
	var seen: Array[Dictionary] = []
	panel.display_changed.connect(func(d: Dictionary): seen.append(d))

	panel.set_display({"gamma": 1.7, "opacity": 0.4, "max_steps": 768})

	var display := panel.get_display()
	assert_float(display["gamma"]).is_equal_approx(1.7, 0.001)
	assert_float(display["opacity"]).is_equal_approx(0.4, 0.001)
	assert_that(display["max_steps"]).is_equal(768)
	assert_that(seen).is_empty()


# A "Saved" label must not linger over settings that have since been edited.
func test_changing_a_slider_restores_the_save_label() -> void:
	var panel := _make_panel()
	panel.set_save_status("Saved")

	panel.get_node("VBox/Gamma").value = 2.0

	assert_str(panel.get_node("VBox/Save").text).is_equal(DisplaySettingsPanel.SAVE_TEXT)


func test_save_label_survives_until_something_changes() -> void:
	var panel := _make_panel()
	panel.set_save_status("Saved")
	assert_str(panel.get_node("VBox/Save").text).is_equal("Saved")

func test_advanced_toggle_expands_and_collapses_scroll() -> void:
	var panel := _make_panel()
	var toggle: Button = panel.get_node("VBox/AdvancedToggle")
	var scroll: ScrollContainer = panel.get_node("VBox/AdvancedScroll")

	assert_that(scroll.visible).is_false()
	assert_str(toggle.text).contains("[+]")

	toggle.emit_signal("pressed")
	assert_that(scroll.visible).is_true()
	assert_str(toggle.text).contains("[-]")

	toggle.emit_signal("pressed")
	assert_that(scroll.visible).is_false()
	assert_str(toggle.text).contains("[+]")


func test_advanced_sliders_and_checks_emit_display_changed() -> void:
	var panel := _make_panel()
	var seen: Array[Dictionary] = []
	panel.display_changed.connect(func(d: Dictionary): seen.append(d))

	var shading_check: CheckBox = panel.get_node("VBox/AdvancedScroll/AdvancedVBox/ShadingEnabled")
	shading_check.button_pressed = true

	assert_that(seen.size()).is_equal(1)
	assert_that(seen[0]["shading_enabled"]).is_true()
	assert_that(panel.get_display()["shading_enabled"]).is_true()

	var ess_stride: HSlider = panel.get_node("VBox/AdvancedScroll/AdvancedVBox/ESSStride")
	ess_stride.value = 3.5

	assert_that(seen.size()).is_equal(2)
	assert_float(seen[1]["ess_stride"]).is_equal_approx(3.5, 0.01)


func test_set_display_sets_advanced_properties_without_emitting() -> void:
	var panel := _make_panel()
	var seen: Array[Dictionary] = []
	panel.display_changed.connect(func(d: Dictionary): seen.append(d))

	panel.set_display({
		"gamma": 1.2,
		"opacity": 0.9,
		"max_steps": 256,
		"step_size": 0.005,
		"shading_enabled": true,
		"saturation_cutoff": 0.92,
		"ess_enabled": true,
		"ess_stride": 3.0,
		"ess_cutoff": 0.004,
		"use_preintegrated_lut": false,
		"lut_substeps": 4,
		"jitter_amount": 0.5,
		"lateral_jitter": 2.0,
		"scaling_3d_scale": 0.75,
		"adaptive_steps": false,
		"adaptive_res_flat": false,
		"ffr_enabled": false,
		"ffr_level": 0.5,
		"motion_adaptive_steps": false,
		"motion_step_floor": 40,
		"motion_sensitivity": 35.0,
		"opacity_adaptive_stepping": true,
		"opacity_search_stride": 3.0,
		"use_coarse_grid": false,
		"coarse_leap_stride": 4.0,
		"use_precomputed_normals": true,
		"decoupled_volume_pass": true,
		"volume_render_scale": 0.65,
		"edge_aware_upscale": false,
	})

	var d := panel.get_display()
	assert_that(seen).is_empty()
	assert_that(d["max_steps"]).is_equal(256)
	assert_float(d["step_size"]).is_equal_approx(0.005, 0.0001)
	assert_that(d["shading_enabled"]).is_true()
	assert_float(d["saturation_cutoff"]).is_equal_approx(0.92, 0.001)
	assert_float(d["ess_stride"]).is_equal_approx(3.0, 0.01)
	assert_float(d["ess_cutoff"]).is_equal_approx(0.004, 0.0001)
	assert_that(d["use_preintegrated_lut"]).is_false()
	assert_that(d["lut_substeps"]).is_equal(4)
	assert_float(d["jitter_amount"]).is_equal_approx(0.5, 0.01)
	assert_float(d["lateral_jitter"]).is_equal_approx(2.0, 0.01)
	assert_float(d["scaling_3d_scale"]).is_equal_approx(0.75, 0.01)
	assert_that(d["adaptive_steps"]).is_false()
	assert_that(d["adaptive_res_flat"]).is_false()
	assert_that(d["ffr_enabled"]).is_false()
	assert_float(d["ffr_level"]).is_equal_approx(0.5, 0.01)
	assert_that(d["motion_adaptive_steps"]).is_false()
	assert_that(d["motion_step_floor"]).is_equal(40)
	assert_float(d["motion_sensitivity"]).is_equal_approx(35.0, 0.1)
	assert_that(d["opacity_adaptive_stepping"]).is_true()
	assert_float(d["opacity_search_stride"]).is_equal_approx(3.0, 0.01)
	assert_that(d["use_coarse_grid"]).is_false()
	assert_float(d["coarse_leap_stride"]).is_equal_approx(4.0, 0.01)
	assert_that(d["use_precomputed_normals"]).is_true()
	assert_that(d["decoupled_volume_pass"]).is_true()
	assert_float(d["volume_render_scale"]).is_equal_approx(0.65, 0.01)
	assert_that(d["edge_aware_upscale"]).is_false()

