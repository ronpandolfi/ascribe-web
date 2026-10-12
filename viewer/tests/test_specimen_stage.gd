extends GdUnitTestSuite

const FIXTURE := "res://tests/fixtures/tiny_bundle/"


func _load_fixture_volume() -> WebVolumetricData:
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE + "manifest.json"))
	var body := FileAccess.get_file_as_bytes(FIXTURE + manifest["specimens"][0]["data"])
	var parsed := BinaryEnvelope.parse(body)
	var vol := WebVolumetricData.new()
	vol.set_from_bytes(parsed["preamble"], body, parsed["offset"])
	return vol


func _count_mesh_children(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		if child is MeshInstance3D:
			count += 1
	return count


func test_stage_volume_sets_id_and_shader_params() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)

	var vol := _load_fixture_volume()
	stage.stage("specimen_0", vol, {"gamma": 1.5, "opacity": 0.8})

	assert_that(stage.current_id).is_equal("specimen_0")
	assert_that(_count_mesh_children(stage)).is_equal(1)

	var mesh_child: MeshInstance3D = null
	for child in stage.get_children():
		if child is MeshInstance3D:
			mesh_child = child
	assert_that(mesh_child).is_not_null()

	var mat: ShaderMaterial = mesh_child.get_surface_override_material(0)
	assert_that(mat).is_not_null()
	assert_that(float(mat.get_shader_parameter("gamma"))).is_equal(1.5)


func test_stage_second_specimen_replaces_first() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)

	var vol := _load_fixture_volume()
	stage.stage("specimen_0", vol, {"gamma": 1.0})
	var first_child: Node = stage.get_child(0)

	stage.stage("specimen_1", vol, {"gamma": 2.0})

	assert_that(stage.current_id).is_equal("specimen_1")
	assert_that(_count_mesh_children(stage)).is_equal(1)
	assert_that(is_instance_valid(first_child) and first_child.is_inside_tree()).is_false()


func test_stage_volume_sets_box_extents_from_staged_box() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)

	var vol := _load_fixture_volume()
	stage.stage("specimen_0", vol, {})

	var mesh_child: MeshInstance3D = null
	for child in stage.get_children():
		if child is MeshInstance3D:
			mesh_child = child
	assert_that(mesh_child).is_not_null()

	var box: BoxMesh = mesh_child.mesh
	var mat: ShaderMaterial = mesh_child.get_surface_override_material(0)
	var box_extents: Vector3 = mat.get_shader_parameter("box_extents")
	assert_that(box_extents).is_equal(box.size / 2.0)


func test_gradient_from_stops() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)

	var tex: GradientTexture1D = stage._gradient_from_stops([[0.0, "#00000000"], [1.0, "#ffffffff"]])
	assert_that(tex).is_not_null()
	assert_that(tex.gradient.get_point_count()).is_equal(2)


func test_preintegrated_lut_is_generated_and_reaches_shader() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)

	stage.stage("specimen_0", _load_fixture_volume(), {
		"gradient": [[0.0, "#00000000"], [1.0, "#ffffffff"]]
	})

	var mesh_child: MeshInstance3D = null
	for child in stage.get_children():
		if child is MeshInstance3D:
			mesh_child = child
	assert_that(mesh_child).is_not_null()

	var mat: ShaderMaterial = mesh_child.get_surface_override_material(0)
	assert_that(mat).is_not_null()
	var pre_tex = mat.get_shader_parameter("preintegrated_lut")
	assert_that(pre_tex).is_not_null()
	assert_bool(mat.get_shader_parameter("use_preintegrated_lut")).is_true()
	assert_that(pre_tex.get_width()).is_equal(128)
	assert_that(pre_tex.get_height()).is_equal(128)


# Regression: the shader's per-eye origin came from EYE_OFFSET, which cannot be named under
# Godot 4.6 / 4.7's Compatibility backend without breaking the mono variant. Dropping it compiled but
# left both eyes marching from the same origin -- no stereo at all in a headset. The offsets now
# arrive as a uniform array indexed by VIEW_INDEX, so they have to actually reach the material.
func test_set_eye_offsets_reaches_the_shader() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("specimen_0", _load_fixture_volume(), {})

	stage.set_eye_offsets(Vector3(-0.032, 0, 0), Vector3(0.032, 0, 0))

	var mesh_child: MeshInstance3D = null
	for child in stage.get_children():
		if child is MeshInstance3D:
			mesh_child = child
	var mat: ShaderMaterial = mesh_child.get_surface_override_material(0)
	var offsets = mat.get_shader_parameter("eye_offsets")
	assert_that(offsets).is_not_null()
	assert_float(offsets[0].x).is_equal_approx(-0.032, 0.0001)
	assert_float(offsets[1].x).is_equal_approx(0.032, 0.0001)


func test_eye_offset_is_measured_in_head_space() -> void:
	# Head turned 90 degrees and standing away from the origin: an eye 32mm to the head's right
	# must still report +0.032 on x, not its world displacement.
	var head := Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(3, 1.6, -2))
	var eye := Transform3D(head.basis, head * Vector3(0.032, 0, 0))

	var offset := SpecimenStage.eye_offset_in_view_space(head, eye)

	assert_float(offset.x).is_equal_approx(0.032, 0.0001)
	assert_float(offset.y).is_equal_approx(0.0, 0.0001)
	assert_float(offset.z).is_equal_approx(0.0, 0.0001)


# Lateral dither is manifest-driven so it can be compared in a headset without a rebuild.
func test_lateral_jitter_reaches_the_shader() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("specimen_0", _load_fixture_volume(), {"lateral_jitter": 4.0})

	var mesh_child: MeshInstance3D = null
	for child in stage.get_children():
		if child is MeshInstance3D:
			mesh_child = child
	var mat: ShaderMaterial = mesh_child.get_surface_override_material(0)
	assert_float(mat.get_shader_parameter("lateral_jitter")).is_equal_approx(4.0, 0.001)


# A manifest that says nothing about the dither leaves the shader's own default in force (it is
# on), rather than the stage forcing a value -- so the default can be changed in one place.
func test_absent_lateral_jitter_leaves_the_shader_default() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("specimen_0", _load_fixture_volume(), {})

	var mesh_child: MeshInstance3D = null
	for child in stage.get_children():
		if child is MeshInstance3D:
			mesh_child = child
	var mat: ShaderMaterial = mesh_child.get_surface_override_material(0)
	assert_that(mat.get_shader_parameter("lateral_jitter")).is_null()


# ...and a manifest can still turn it off explicitly, for content where grain is not worth it.
func test_lateral_jitter_can_be_disabled_by_the_manifest() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("specimen_0", _load_fixture_volume(), {"lateral_jitter": 0.0})

	var mesh_child: MeshInstance3D = null
	for child in stage.get_children():
		if child is MeshInstance3D:
			mesh_child = child
	var mat: ShaderMaterial = mesh_child.get_surface_override_material(0)
	assert_float(mat.get_shader_parameter("lateral_jitter")).is_equal_approx(0.0, 0.001)


func _build_test_mesh_data() -> WebMeshData:
	var md := WebMeshData.new()
	md.vertices = PackedFloat32Array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0])
	md.indices = PackedInt32Array([0, 1, 2])
	md.normals = PackedFloat32Array([0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0])
	return md


func _staged_mesh(stage: SpecimenStage) -> MeshInstance3D:
	for child in stage.get_children():
		if child is MeshInstance3D:
			return child
	return null


func test_stage_mesh_uses_the_surface_material_by_default() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("mesh_specimen_0", _build_test_mesh_data(), {})

	assert_that(stage.current_id).is_equal("mesh_specimen_0")
	assert_that(_count_mesh_children(stage)).is_equal(1)
	var mat: Material = _staged_mesh(stage).get_surface_override_material(0)
	assert_that(mat is StandardMaterial3D).is_true()
	assert_str("#" + (mat as StandardMaterial3D).albedo_color.to_html(false)).is_equal("#d4af37")


func test_stage_mesh_applies_a_legacy_shader() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("mesh_specimen_crystal", _build_test_mesh_data(), {"shader": "crystal"})

	var mat: Material = _staged_mesh(stage).get_surface_override_material(0)
	assert_that(mat is ShaderMaterial).is_true()
	assert_that((mat as ShaderMaterial).shader.resource_path).is_equal("res://shaders/crystal.gdshader")


func test_retired_shader_names_render_with_surface() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("old", _build_test_mesh_data(), {"shader": "glass"})
	assert_that(_staged_mesh(stage).get_surface_override_material(0) is StandardMaterial3D).is_true()


func test_apply_display_switches_between_legacy_and_surface() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("m", _build_test_mesh_data(), {"shader": "crystal"})
	var mesh := _staged_mesh(stage)

	stage.apply_display({"shader": "hologram"})
	var holo: ShaderMaterial = mesh.get_surface_override_material(0)
	assert_that(holo.shader.resource_path).is_equal("res://shaders/hologram.gdshader")

	stage.apply_display({"shader": "surface", "color": "#2a9d8f"})
	var surf: StandardMaterial3D = mesh.get_surface_override_material(0)
	assert_str("#" + surf.albedo_color.to_html(false)).is_equal("#2a9d8f")


func test_surface_sliders_update_the_material_in_place() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("m", _build_test_mesh_data(), {})
	var mesh := _staged_mesh(stage)
	var before: Material = mesh.get_surface_override_material(0)

	stage.apply_display({"opacity": 0.4})
	var after: StandardMaterial3D = mesh.get_surface_override_material(0)
	assert_that(after).is_same(before)
	assert_int(after.transparency).is_equal(BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS)


# The motion-adaptive quality code sends a partial display every frame; on a mesh it must not
# reset anything a bundle or the panel set.
func test_partial_volume_display_leaves_the_mesh_look_alone() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("m", _build_test_mesh_data(), {"color": "#c0392b", "opacity": 0.5})

	stage.apply_display({"max_steps": 64, "step_size": 0.01, "lut_substeps": 1})
	var mat: StandardMaterial3D = _staged_mesh(stage).get_surface_override_material(0)
	assert_str("#" + mat.albedo_color.to_html(false)).is_equal("#c0392b")
	assert_float(mat.albedo_color.a).is_equal_approx(0.5, 0.001)

func test_advanced_display_parameters_reach_the_shader() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("specimen_0", _load_fixture_volume(), {
		"shading_enabled": true,
		"use_preintegrated_lut": false,
		"saturation_cutoff": 0.95,
		"jitter_amount": 0.5,
		"ess_cutoff": 0.005,
		"ess_stride": 3.0,
		"opacity_adaptive_stepping": true,
		"opacity_search_stride": 2.5,
		"use_coarse_grid": false,
		"coarse_leap_stride": 4.5,
		"use_precomputed_normals": true,
		"volume_render_scale": 0.75,
		"edge_aware_upscale": false,
	})

	var mesh_child: MeshInstance3D = null
	for child in stage.get_children():
		if child is MeshInstance3D:
			mesh_child = child
	var mat: ShaderMaterial = mesh_child.get_surface_override_material(0)
	assert_that(bool(mat.get_shader_parameter("shading_enabled"))).is_true()
	assert_that(bool(mat.get_shader_parameter("use_preintegrated_lut"))).is_false()
	assert_float(mat.get_shader_parameter("saturation_cutoff")).is_equal_approx(0.95, 0.001)
	assert_float(mat.get_shader_parameter("jitter_amount")).is_equal_approx(0.5, 0.001)
	assert_float(mat.get_shader_parameter("ess_cutoff")).is_equal_approx(0.005, 0.0001)
	assert_float(mat.get_shader_parameter("ess_stride")).is_equal_approx(3.0, 0.001)
	assert_that(bool(mat.get_shader_parameter("opacity_adaptive_stepping"))).is_true()
	assert_float(mat.get_shader_parameter("opacity_search_stride")).is_equal_approx(2.5, 0.001)
	assert_that(bool(mat.get_shader_parameter("use_coarse_grid"))).is_false()
	assert_float(mat.get_shader_parameter("coarse_leap_stride")).is_equal_approx(4.5, 0.001)
	assert_that(bool(mat.get_shader_parameter("use_precomputed_normals"))).is_true()
	assert_float(mat.get_shader_parameter("volume_render_scale")).is_equal_approx(0.75, 0.001)
	assert_that(bool(mat.get_shader_parameter("edge_aware_upscale"))).is_false()



# Regression: set_eye_offsets runs every frame in a headset and typed the staged material as a
# ShaderMaterial, so a mesh (now a StandardMaterial3D) raised a script error on every frame.
func test_set_eye_offsets_ignores_a_staged_mesh() -> void:
	var stage: SpecimenStage = auto_free(SpecimenStage.new())
	add_child(stage)
	stage.stage("m", _build_test_mesh_data(), {})

	stage.set_eye_offsets(Vector3(-0.032, 0, 0), Vector3(0.032, 0, 0))

	assert_that(_staged_mesh(stage).get_surface_override_material(0) is StandardMaterial3D).is_true()
