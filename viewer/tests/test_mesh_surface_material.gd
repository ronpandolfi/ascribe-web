extends GdUnitTestSuite


func test_defaults_are_a_two_sided_gold_with_a_depth_pass() -> void:
	var mat := MeshSurfaceMaterial.build({})
	assert_int(mat.cull_mode).is_equal(BaseMaterial3D.CULL_DISABLED)
	assert_int(mat.transparency).is_equal(BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS)
	assert_that(mat.next_pass is ShaderMaterial).is_true()
	assert_str("#" + mat.albedo_color.to_html(false)).is_equal("#d4af37")
	assert_float(mat.albedo_color.a).is_equal_approx(1.0, 0.001)
	assert_float(mat.roughness).is_equal_approx(0.5, 0.001)
	assert_float(mat.metallic).is_equal_approx(0.0, 0.001)
	assert_bool(mat.rim_enabled).is_true()
	assert_float(mat.rim).is_equal_approx(0.3, 0.001)


func test_translucent_nearest_surface_uses_depth_prepass() -> void:
	var mat := MeshSurfaceMaterial.build({"opacity": 0.4})
	assert_int(mat.transparency).is_equal(BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS)
	assert_float(mat.albedo_color.a).is_equal_approx(0.4, 0.001)


# Ron saw triangles wherever translucent layers overlapped: "over" blending depends on draw
# order, and triangles are drawn in index order, not depth order. Additive blending is
# commutative, so inner surfaces no longer depend on order at all.
func test_inner_surfaces_blend_additively_in_one_pass() -> void:
	var mat := MeshSurfaceMaterial.build({"opacity": 0.4, "inner_surfaces": true})
	assert_int(mat.blend_mode).is_equal(BaseMaterial3D.BLEND_MODE_ADD)
	assert_int(mat.transparency).is_equal(BaseMaterial3D.TRANSPARENCY_ALPHA)
	assert_int(mat.depth_draw_mode).is_equal(BaseMaterial3D.DEPTH_DRAW_DISABLED)
	assert_int(mat.cull_mode).is_equal(BaseMaterial3D.CULL_DISABLED)
	assert_that(mat.next_pass).is_null()


# Blending without depth writes at full opacity would draw far surfaces over near ones.
func test_inner_surfaces_at_full_opacity_keeps_nearest_surface_occlusion() -> void:
	var mat := MeshSurfaceMaterial.build({"opacity": 1.0, "inner_surfaces": true})
	assert_int(mat.transparency).is_equal(BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS)
	assert_that(mat.next_pass is ShaderMaterial).is_true()


func test_apply_updates_in_place() -> void:
	var mat := MeshSurfaceMaterial.build({})
	MeshSurfaceMaterial.apply(mat, {"color": "#2a9d8f", "roughness": 0.9, "rim": 0.0})
	assert_str("#" + mat.albedo_color.to_html(false)).is_equal("#2a9d8f")
	assert_float(mat.roughness).is_equal_approx(0.9, 0.001)
	assert_float(mat.rim).is_equal(0.0)


# Ron saw a stall whenever opacity crossed 1 (and rim would at 0): each changed the material's
# render configuration, and on the web a configuration change recompiles the shader. Sliders
# must only ever change uniforms.
func test_slider_changes_never_change_the_render_configuration() -> void:
	var mat := MeshSurfaceMaterial.build({})
	var depth_pass := mat.next_pass
	for d in [{"opacity": 0.3}, {"opacity": 1.0}, {"rim": 0.0}, {"rim": 0.6},
			{"opacity": 0.7, "metallic": 1.0, "roughness": 0.0}, {"opacity": 1.0}]:
		MeshSurfaceMaterial.apply(mat, d)
		assert_int(mat.transparency).is_equal(BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS)
		assert_int(mat.cull_mode).is_equal(BaseMaterial3D.CULL_DISABLED)
		assert_int(mat.blend_mode).is_equal(BaseMaterial3D.BLEND_MODE_MIX)
		assert_bool(mat.rim_enabled).is_true()
		assert_that(mat.next_pass).is_same(depth_pass)


# A story page moving from a volume to a mesh carries the volume's opacity (range 0-2) along.
func test_out_of_range_values_are_clamped() -> void:
	var s := MeshSurfaceMaterial.resolved({"opacity": 1.7, "roughness": -1.0, "rim": 3.0})
	assert_float(s["opacity"]).is_equal(1.0)
	assert_float(s["roughness"]).is_equal(0.0)
	assert_float(s["rim"]).is_equal(1.0)


func test_invalid_color_falls_back_to_default() -> void:
	var mat := MeshSurfaceMaterial.build({"color": "gold"})
	assert_str("#" + mat.albedo_color.to_html(false)).is_equal("#d4af37")


func test_shader_name_normalises_and_falls_back() -> void:
	assert_str(MeshSurfaceMaterial.shader_name({})).is_equal("surface")
	assert_str(MeshSurfaceMaterial.shader_name({"shader": " Crystal "})).is_equal("crystal")
	assert_str(MeshSurfaceMaterial.shader_name({"shader": "glass"})).is_equal("surface")


# The Compatibility (WebGL2) renderer ignores TRANSPARENCY_ALPHA_DEPTH_PRE_PASS, which made the
# nearest-surface mode render exactly like inner surfaces. A depth-only pass drawn first stands in.
func test_nearest_surface_has_a_depth_pass_drawn_first() -> void:
	var mat := MeshSurfaceMaterial.build({"opacity": 0.4})
	assert_that(mat.next_pass is ShaderMaterial).is_true()
	assert_int(mat.next_pass.render_priority).is_less(mat.render_priority)


func test_toggling_inner_surfaces_swaps_the_extra_pass() -> void:
	var mat := MeshSurfaceMaterial.build({"opacity": 0.4})
	MeshSurfaceMaterial.apply(mat, {"opacity": 0.4, "inner_surfaces": true})
	assert_that(mat.next_pass).is_null()
	MeshSurfaceMaterial.apply(mat, {"opacity": 0.4, "inner_surfaces": false})
	assert_that(mat.next_pass is ShaderMaterial).is_true()
	assert_int(mat.blend_mode).is_equal(BaseMaterial3D.BLEND_MODE_MIX)
