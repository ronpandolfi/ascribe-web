extends GdUnitTestSuite

const SHADER_PATH := "res://shaders/volume_web.gdshader"


func _source() -> String:
	return FileAccess.get_file_as_string(SHADER_PATH)


# The volume texture is normalized per-axis by `box_extents`, not by upstream's scalar `zoom`.
# (The old scalar mapping is what rendered everything black: its default of 2 pushed every
# sample coordinate outside [0, 1], so the march broke on its first step.)
func test_texture_coordinates_are_normalized_by_box_extents() -> void:
	var src := _source()
	assert_str(src).contains("uniform vec3 box_extents")
	assert_str(src).contains("(ray_pos / (2.0 * box_extents)) + vec3(0.5)")
	assert_str(src).not_contains("uniform float zoom")


# Regression: Godot 4.6's Compatibility (GLES3) backend only declares `eye_offset` in the
# multiview shader variant, so referencing it fails to compile the mono variant ("undefined
# variable eye_offset") and the whole volume renders black in a non-XR browser tab.
func test_shader_does_not_reference_eye_offset() -> void:
	assert_str(_source()).not_contains("EYE_OFFSET)")


# Fixed-step raymarching makes every ray sample the same evenly spaced planes, which beats
# against the volume's structure as banding. Upstream's interleaved gradient noise offsets each
# ray individually.
func test_ray_start_is_jittered() -> void:
	var src := _source()
	assert_str(src).contains("float interleaved_gradient_noise(")
	assert_str(src).contains("float jitter = interleaved_gradient_noise(FRAGCOORD.xy)")
	assert_str(src).contains("t_near + jitter * march_step")


func test_empty_space_skipping_uses_mapped_opacity() -> void:
	var src := _source()
	assert_str(src).contains("float mapped_alpha = lut_sample.a * opacity;")
	assert_str(src).contains("if (ess_stride > 1.0 && mapped_alpha < ess_cutoff)")
	assert_str(src).contains("t += current_step * ess_stride;")


# Compositing must weight each sample by the remaining transmittance. Accumulating raw opacity
# (`total_opacity += sample_opacity`) saturates early and flattens the volume.
func test_compositing_weights_by_remaining_transmittance() -> void:
	assert_str(_source()).contains("total_opacity += sample_opacity * (1.0 - total_opacity);")


# The quality slider changes step_size, which would otherwise change how dense the volume looks.
# Correcting opacity against a reference step keeps appearance stable across quality tiers.
func test_opacity_is_corrected_for_step_size() -> void:
	var src := _source()
	assert_str(src).contains("REFERENCE_STEP")
	assert_str(src).contains("float step_ratio = current_step / REFERENCE_STEP;")


# The march is bounded by an exact ray/box interval rather than by max_steps * step_size, which
# is not guaranteed to span the box (a 1m volume's diagonal can exceed the desktop tier's reach).
func test_march_is_bounded_by_the_clipped_interval() -> void:
	var src := _source()
	assert_str(src).contains("void clip_to_box(")
	assert_str(src).contains("if (t > t_far)")


# The shader must load and instantiate as a material (catches syntax errors that would
# otherwise only surface as a silent black screen at runtime).
func test_shader_loads_as_a_material() -> void:
	var shader: Shader = load(SHADER_PATH)
	assert_that(shader).is_not_null()
	var mat := ShaderMaterial.new()
	mat.shader = shader
	assert_that(mat.shader).is_not_null()


# The march must span the clipped interval even when max_steps * step_size is shorter than it,
# and the opacity correction has to follow the step actually taken or density would shift on
# exactly those rays.
func test_march_step_widens_to_cover_the_interval() -> void:
	var src := _source()
	assert_str(src).contains("float march_step = max(step_size, span / float(max_steps));")
	assert_str(src).contains("float step_ratio = current_step / REFERENCE_STEP;")
	assert_str(src).contains("t_near + jitter * march_step")


# The per-eye origin must come from a uniform indexed by VIEW_INDEX. EYE_OFFSET cannot be named
# without breaking the mono variant under Godot 4.6's Compatibility backend, but simply dropping
# it made both eyes march from the same origin -- i.e. no stereo in a headset.
func test_per_eye_origin_uses_view_index() -> void:
	var src := _source()
	assert_str(src).contains("uniform vec3 eye_offsets[2];")
	assert_str(src).contains("vec4(eye_offsets[VIEW_INDEX], 1.0)")


# The march accumulates colour already weighted by each sample's opacity, i.e. premultiplied.
# Writing that to ALBEDO under ordinary alpha blending multiplies by alpha a second time, which
# darkens every pixel in proportion to its own transparency and amplifies sampling variation
# into visible banding (measured: -27% face variation on the synthetic cube when fixed).
func test_output_uses_premultiplied_blending() -> void:
	var src := _source()
	assert_str(src).contains("blend_premul_alpha")
	assert_str(src).contains("ALBEDO = accumulated_color * color_scalar;")


# Diagnostic switches used to trace rendering artifacts; they must stay off by default so the
# shipped render is the cheap path.
func test_diagnostic_uniforms_default_off() -> void:
	var src := _source()
	assert_str(src).contains("uniform bool manual_filter = false;")
	assert_str(src).contains("uniform bool smooth_sampling = false;")
	assert_str(src).contains("uniform float jitter_amount = 1.0;")


# Scalar projection modes: mode 0 composites (standard volume rendering), 1 is maximum
# intensity projection and 2 is mean density -- both reduce the ray to one number before
# touching the transfer function, so neither can produce compositing artifacts.
func test_preintegrated_lut_uniforms_exist_and_default_enabled() -> void:
	var src := _source()
	assert_str(src).contains("uniform sampler2D preintegrated_lut")
	assert_str(src).contains("uniform bool use_preintegrated_lut = true;")
	assert_str(src).contains("texture(preintegrated_lut, vec2(lut_from, lut_to))")


func test_projection_modes_exist_and_default_to_compositing() -> void:
	var src := _source()
	assert_str(src).contains("uniform int projection_mode = 0;")
	assert_str(src).contains("float scalar = projection_mode == 1")
	# The scalar path must output premultiplied colour to match the blend mode.
	assert_str(src).contains("ALBEDO = mapped.rgb * a * color_scalar;")


# On a uniform solid, a ray can saturate while still inside the surface's density ramp, so the
# pixel takes its colour from the ramp instead of the material behind it -- and where that
# happens shifts with sub-voxel phase, which is banding. Stopping later, and integrating the
# transfer function between samples rather than point-sampling it, cut the banding residual on
# the synthetic cube from 3.43 to 1.60. The two interact: sub-stepping looks useless while the
# cutoff is still quantising where rays stop, which is why both must stay on.
func test_saturation_cutoff_and_lut_substepping_are_enabled() -> void:
	var src := _source()
	assert_str(src).contains("uniform int lut_substeps = 192;")
	assert_str(src).contains("const int MAX_LUT_SUBSTEPS = 64;")
	# Sub-steps are allocated by how far the sample moved along the transfer function, not by
	# how far the density moved: with a high gamma a small density change can still cross a
	# steep part of the LUT, and scaling on raw density measurably under-serves exactly the
	# samples that generate the banding.
	assert_str(src).contains("float lut_delta = abs(lut_to - lut_from);")
	assert_str(src).contains("int substeps = clamp(int(ceil(lut_delta * float(lut_substeps)))")
	assert_str(src).contains("uniform float saturation_cutoff = 0.995;")
	assert_str(src).contains("if (total_opacity >= saturation_cutoff)")


# Regression: the saturation early-exit must end the march, not just the sub-step loop, or the
# ray keeps stepping after it can no longer contribute anything.
func test_saturation_breaks_the_march_not_just_the_substep_loop() -> void:
	var src := _source()
	var marker := "// Saturated: everything behind this contributes nothing."
	assert_str(src).contains(marker)
	var tail := src.substr(src.find(marker))
	assert_str(tail).contains("if (total_opacity >= saturation_cutoff)")
	# ...and exactly once: an earlier restructure left the check duplicated.
	assert_int(src.count("if (total_opacity >= saturation_cutoff)")).is_equal(1)


# The lateral dither ships on: it removes the coherent moire outright rather than reducing it.
# A manifest can still set display.lateral_jitter to 0 where the grain is not worth it.
func test_lateral_dither_is_on_by_default() -> void:
	assert_str(_source()).contains("uniform float lateral_jitter = 4.0;")

func test_opacity_adaptive_stepping_uniforms_and_logic() -> void:
	var src := _source()
	assert_str(src).contains("uniform bool opacity_adaptive_stepping = false;")
	assert_str(src).contains("uniform float opacity_search_stride = 2.0;")
	assert_str(src).contains("if (opacity_adaptive_stepping)")
	assert_str(src).contains("current_step = march_step * opacity_search_stride;")
