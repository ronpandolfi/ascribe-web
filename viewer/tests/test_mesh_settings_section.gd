extends GdUnitTestSuite


func _make() -> MeshSettingsSection:
	var section: MeshSettingsSection = auto_free(MeshSettingsSection.new())
	add_child(section)
	return section


func test_defaults_match_the_material() -> void:
	var d := _make().get_display()
	assert_str(d["shader"]).is_equal("surface")
	assert_str(d["color"]).is_equal("#d4af37")
	assert_float(d["opacity"]).is_equal_approx(1.0, 0.001)
	assert_float(d["roughness"]).is_equal_approx(0.5, 0.001)
	assert_float(d["metallic"]).is_equal_approx(0.0, 0.001)
	assert_float(d["rim"]).is_equal_approx(0.3, 0.001)
	assert_bool(d["inner_surfaces"]).is_false()
	assert_int(d.size()).is_equal(7)


func test_set_display_round_trips_without_emitting() -> void:
	var section := _make()
	var seen := [0]
	section.changed.connect(func(): seen[0] += 1)
	var wanted := {"shader": "surface", "color": "#2a9d8f", "opacity": 0.4, "roughness": 0.8,
		"metallic": 0.6, "rim": 0.0, "inner_surfaces": true}
	section.set_display(wanted)
	var got := section.get_display()
	for key in wanted:
		if wanted[key] is float:
			assert_float(got[key]).is_equal_approx(wanted[key], 0.001)
		else:
			assert_that(got[key]).is_equal(wanted[key])
	assert_int(seen[0]).is_equal(0)


func test_moving_a_slider_emits_changed() -> void:
	var section := _make()
	var seen := [0]
	section.changed.connect(func(): seen[0] += 1)
	(section.get_node("Surface/Roughness") as HSlider).value = 0.9
	assert_int(seen[0]).is_equal(1)
	assert_float(section.get_display()["roughness"]).is_equal_approx(0.9, 0.001)


func test_legacy_shader_hides_the_surface_controls() -> void:
	var section := _make()
	section.set_display({"shader": "crystal"})
	assert_bool((section.get_node("Surface") as Control).visible).is_false()
	section.set_display({"shader": "surface"})
	assert_bool((section.get_node("Surface") as Control).visible).is_true()


func test_vr_swaps_the_picker_for_swatches() -> void:
	var section := _make()
	assert_bool((section.get_node("Surface/Color") as Control).visible).is_true()
	assert_bool((section.get_node("Surface/Swatches") as Control).visible).is_false()
	section.set_vr(true)
	assert_bool((section.get_node("Surface/Color") as Control).visible).is_false()
	assert_bool((section.get_node("Surface/Swatches") as Control).visible).is_true()


func test_pressing_a_swatch_sets_the_colour() -> void:
	var section := _make()
	section.set_vr(true)
	(section.get_node("Surface/Swatches/Swatch_c0392b") as Button).emit_signal("pressed")
	assert_str(section.get_display()["color"]).is_equal("#c0392b")


# A hand-edited manifest colour that matches no swatch must survive being shown in VR.
func test_unmatched_colour_selects_no_swatch_and_is_kept() -> void:
	var section := _make()
	section.set_vr(true)
	section.set_display({"color": "#123456"})
	for b in section.get_node("Surface/Swatches").get_children():
		assert_bool((b as Button).button_pressed).is_false()
	assert_str(section.get_display()["color"]).is_equal("#123456")
	section.set_display({"color": "#C0392B"})
	assert_bool((section.get_node("Surface/Swatches/Swatch_c0392b") as Button).button_pressed).is_true()


# Final review: a hand-edited invalid colour was shown and saved back verbatim, so edit mode's
# save failed schema validation even if only another slider was moved.
func test_invalid_colour_is_normalised_to_the_default() -> void:
	var section := _make()
	section.set_display({"color": "gold"})
	assert_str(section.get_display()["color"]).is_equal("#d4af37")
