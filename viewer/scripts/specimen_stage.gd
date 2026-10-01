## Stages one specimen (volume or mesh) in the 3D scene, replacing any previously staged
## specimen. Volumes are shown as a unit BoxMesh with the raymarch shader material; meshes are
## shown as a MeshInstance3D normalized to fit a 1m cube.
class_name SpecimenStage
extends Node3D

const VOLUME_SHADER := preload("res://shaders/volume_web.gdshader")

var current_id: String = ""


## Stages `data` (a WebVolumetricData or WebMeshData) under `id`, applying `display` settings.
## Removes any previously staged specimen first.
func stage(id: String, data: RefCounted, display: Dictionary) -> void:
	clear()
	current_id = id

	if data is WebVolumetricData:
		_stage_volume(data as WebVolumetricData, display)
	elif data is WebMeshData:
		_stage_mesh(data as WebMeshData, display)
	else:
		push_error("SpecimenStage.stage: unsupported data type for '%s'" % [id])


## Removes the currently staged specimen, if any.
func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	current_id = ""


## Applies display settings to the currently staged specimen.
## For volumes: applies gamma/opacity/gradient/max_steps/step_size.
## For meshes: applies shader material if "shader" is specified in display.
func apply_display(display: Dictionary) -> void:
	var mesh_instance := _current_mesh_instance()
	if mesh_instance == null:
		return
	var mat: Material = mesh_instance.get_surface_override_material(0)
	if mat is ShaderMaterial and (mat as ShaderMaterial).shader == VOLUME_SHADER:
		_apply_display_to_material(mat as ShaderMaterial, display)
	elif display.has("shader"):
		var shader_name: String = str(display.get("shader", "glass"))
		var new_mat := _resolve_mesh_material(shader_name)
		if new_mat != null:
			mesh_instance.set_surface_override_material(0, new_mat)


func _current_mesh_instance() -> MeshInstance3D:
	for child in get_children():
		if child is MeshInstance3D:
			return child
	return null


func get_box_extents() -> Vector3:
	var mesh_instance := _current_mesh_instance()
	if mesh_instance != null and mesh_instance.mesh is BoxMesh:
		return (mesh_instance.mesh as BoxMesh).size / 2.0
	return Vector3.ONE * 0.5


func _stage_volume(vol: WebVolumetricData, display: Dictionary) -> void:
	var box := BoxMesh.new()
	var box_size := _normalized_box_size(vol.get_dimensions(), vol.get_spacing())
	box.size = box_size

	var mat := ShaderMaterial.new()
	mat.shader = VOLUME_SHADER
	mat.set_shader_parameter("texture_volume", vol.get_texture())
	var coarse_tex: Texture3D = vol.get_coarse_texture() if vol.has_method("get_coarse_texture") else null
	if coarse_tex == null:
		coarse_tex = _get_default_coarse_grid()
	mat.set_shader_parameter("coarse_occupancy_grid", coarse_tex)
	var norm_tex: Texture3D = vol.get_normal_texture() if vol.has_method("get_normal_texture") else null
	if norm_tex == null:
		norm_tex = _get_default_normal_texture()
	mat.set_shader_parameter("texture_normals", norm_tex)
	# Half-extents of the staged box; keeps the raymarch's ray-box intersection and texture
	# coordinate normalization matched to the actual (possibly non-cubic) box, not a unit cube.
	mat.set_shader_parameter("box_extents", box_size / 2.0)
	var default_grad := Gradient.new()
	default_grad.offsets = PackedFloat32Array([0.0, 1.0])
	default_grad.colors = [Color(0, 0, 0, 0), Color(1, 1, 1, 1)]
	mat.set_shader_parameter("preintegrated_lut", _preintegrated_from_gradient(default_grad))
	mat.set_shader_parameter("use_preintegrated_lut", true)
	_apply_display_to_material(mat, display)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = box
	mesh_instance.set_surface_override_material(0, mat)
	add_child(mesh_instance)


func _stage_mesh(mesh_data: WebMeshData, display: Dictionary) -> void:
	if display.get("flip_normals", false) != mesh_data.flip_normals:
		mesh_data.flip_normals = display.get("flip_normals", false)
		mesh_data.invalidate_mesh()

	var mesh := mesh_data.get_mesh()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh

	var shader_name: String = str(display.get("shader", "glass"))
	var mat := _resolve_mesh_material(shader_name)
	if mat != null:
		mesh_instance.set_surface_override_material(0, mat)

	add_child(mesh_instance)

	if mesh != null:
		var aabb := mesh.get_aabb()
		var largest := maxf(maxf(aabb.size.x, aabb.size.y), aabb.size.z)
		if largest > 0.0:
			var scale := 1.0 / largest
			mesh_instance.scale = Vector3(scale, scale, scale)
			mesh_instance.position = -aabb.get_center() * scale


## Computes a BoxMesh size (in meters) for a volume whose physical extent is
## `dimensions * spacing`, normalized so the largest axis is 1m.
func _normalized_box_size(dimensions: Vector3i, spacing: Vector3) -> Vector3:
	var extent := Vector3(dimensions) * spacing
	var largest := maxf(maxf(extent.x, extent.y), extent.z)
	if largest <= 0.0:
		return Vector3.ONE
	return extent / largest


func _apply_display_to_material(mat: ShaderMaterial, display: Dictionary) -> void:
	if display.has("gamma"):
		mat.set_shader_parameter("gamma", float(display["gamma"]))
	if display.has("opacity"):
		mat.set_shader_parameter("opacity", float(display["opacity"]))
	if display.has("gradient"):
		var grad_tex := _gradient_from_stops(display["gradient"])
		mat.set_shader_parameter("gradient", grad_tex)
		mat.set_shader_parameter("preintegrated_lut", _preintegrated_from_gradient(grad_tex.gradient))
		mat.set_shader_parameter("use_preintegrated_lut", true)
	if display.has("max_steps"):
		mat.set_shader_parameter("max_steps", int(display["max_steps"]))
	if display.has("step_size"):
		mat.set_shader_parameter("step_size", float(display["step_size"]))
	# Lateral (screen-plane) dither, in units of the march step. Breaks the coherent moire that
	# arises because neighbouring rays sample a surface at nearly the same phase, at the cost of
	# per-pixel grain. 0 disables it.
	if display.has("lateral_jitter"):
		mat.set_shader_parameter("lateral_jitter", float(display["lateral_jitter"]))
	# Transfer-function sub-step budget. Higher removes pixel-scale structure at the cost of
	# extra 1D LUT lookups on samples that cross a steep part of the LUT; lower it if a headset
	# cannot hold framerate.
	if display.has("lut_substeps"):
		mat.set_shader_parameter("lut_substeps", int(display["lut_substeps"]))
	if display.has("shading_enabled"):
		mat.set_shader_parameter("shading_enabled", bool(display["shading_enabled"]))
	if display.has("use_precomputed_normals"):
		mat.set_shader_parameter("use_precomputed_normals", bool(display["use_precomputed_normals"]))
	if display.has("use_preintegrated_lut"):
		mat.set_shader_parameter("use_preintegrated_lut", bool(display["use_preintegrated_lut"]))
	if display.has("saturation_cutoff"):
		mat.set_shader_parameter("saturation_cutoff", float(display["saturation_cutoff"]))
	if display.has("jitter_amount"):
		mat.set_shader_parameter("jitter_amount", float(display["jitter_amount"]))
	if display.has("ess_cutoff"):
		mat.set_shader_parameter("ess_cutoff", float(display["ess_cutoff"]))
	if display.has("ess_stride"):
		mat.set_shader_parameter("ess_stride", float(display["ess_stride"]))
	if display.has("opacity_adaptive_stepping"):
		mat.set_shader_parameter("opacity_adaptive_stepping", bool(display["opacity_adaptive_stepping"]))
	if display.has("opacity_search_stride"):
		mat.set_shader_parameter("opacity_search_stride", float(display["opacity_search_stride"]))
	if display.has("use_coarse_grid"):
		mat.set_shader_parameter("use_coarse_grid", bool(display["use_coarse_grid"]))
	if display.has("coarse_leap_stride"):
		mat.set_shader_parameter("coarse_leap_stride", float(display["coarse_leap_stride"]))


## Builds a GradientTexture1D from a list of `[offset: float, hex_color: String]` stops (the
## manifest's `display.gradient` shape). Invalid hex colors fall back to magenta so a bad
## manifest is visibly wrong rather than silently transparent.
func _gradient_from_stops(stops: Array) -> GradientTexture1D:
	var gradient := Gradient.new()
	var points := PackedFloat32Array()
	var colors: Array[Color] = []
	for stop in stops:
		var offset: float = float(stop[0])
		var color := Color.from_string(str(stop[1]), Color.MAGENTA)
		points.append(offset)
		colors.append(color)

	if points.size() >= 2:
		gradient.offsets = points
		gradient.colors = colors
	elif points.size() == 1:
		gradient.offsets = PackedFloat32Array([0.0, 1.0])
		gradient.colors = [colors[0], colors[0]]

	var tex := GradientTexture1D.new()
	tex.gradient = gradient
	return tex


## Pushes the per-eye view-space offsets to the staged volume's shader.
##
## The shader marches from a per-eye origin; with both offsets zero (the desktop default) the
## two eyes would render identical images, which reads as a flat picture in a headset rather
## than a solid object.
func set_eye_offsets(left: Vector3, right: Vector3) -> void:
	var mesh_instance := _current_mesh_instance()
	if mesh_instance == null:
		return
	var mat: ShaderMaterial = mesh_instance.get_surface_override_material(0)
	if mat == null or mat.shader != VOLUME_SHADER:
		return
	mat.set_shader_parameter("eye_offsets", PackedVector3Array([left, right]))


## The offset of one eye from the head, expressed in the head's own (view) space -- which is
## what the shader's `eye_offsets` expects. Pure math so it can be tested without a headset.
static func eye_offset_in_view_space(head: Transform3D, eye: Transform3D) -> Vector3:
	return head.affine_inverse() * eye.origin


func _resolve_mesh_material(shader_name: String) -> Material:
	var name_clean := shader_name.to_lower().strip_edges()
	if name_clean.is_empty():
		name_clean = "glass"

	var tres_path := "res://shaders/" + name_clean + ".tres"
	var shader_path := "res://shaders/" + name_clean + ".gdshader"

	if ResourceLoader.exists(tres_path):
		var res := load(tres_path)
		if res is Material:
			return (res as Material).duplicate()
	if ResourceLoader.exists(shader_path):
		var sh := load(shader_path)
		if sh is Shader:
			var sm := ShaderMaterial.new()
			sm.shader = sh
			return sm

	if name_clean != "glass":
		return _resolve_mesh_material("glass")

	push_error("SpecimenStage: failed to load default mesh shader (glass)")
	return null


## Generates a 2D pre-integrated transfer function LUT (Engel et al. 2001) using O(N)
## prefix sums. Eliminates the runtime numerical sub-stepping loop in the fragment shader.
func _preintegrated_from_gradient(gradient: Gradient, n: int = 128) -> ImageTexture:
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var data := PackedByteArray()
	data.resize(n * n * 4)

	var cum_a := PackedFloat32Array()
	var cum_r := PackedFloat32Array()
	var cum_g := PackedFloat32Array()
	var cum_b := PackedFloat32Array()
	cum_a.resize(n)
	cum_r.resize(n)
	cum_g.resize(n)
	cum_b.resize(n)

	var cur_a := 0.0
	var cur_r := 0.0
	var cur_g := 0.0
	var cur_b := 0.0
	var inv_n := 1.0 / float(n)

	for i in range(n):
		var s := float(i) / float(n - 1)
		var c := gradient.sample(s)
		cur_a += c.a * inv_n
		cur_r += c.r * c.a * inv_n
		cur_g += c.g * c.a * inv_n
		cur_b += c.b * c.a * inv_n
		cum_a[i] = cur_a
		cum_r[i] = cur_r
		cum_g[i] = cur_g
		cum_b[i] = cur_b

	var ptr := 0
	for y in range(n):
		var sf := float(y) / float(n - 1)
		for x in range(n):
			if x == y:
				var c := gradient.sample(sf)
				data[ptr + 0] = int(clampf(c.r * 255.0, 0.0, 255.0))
				data[ptr + 1] = int(clampf(c.g * 255.0, 0.0, 255.0))
				data[ptr + 2] = int(clampf(c.b * 255.0, 0.0, 255.0))
				data[ptr + 3] = int(clampf(c.a * 255.0, 0.0, 255.0))
			else:
				var lo := mini(x, y)
				var hi := maxi(x, y)
				var d := float(hi - lo) * inv_n
				var delta_a := (cum_a[hi] - cum_a[lo]) / d
				var delta_r := (cum_r[hi] - cum_r[lo]) / d
				var delta_g := (cum_g[hi] - cum_g[lo]) / d
				var delta_b := (cum_b[hi] - cum_b[lo]) / d
				var alpha := 1.0 - exp(-delta_a)
				var cr := delta_r / maxf(delta_a, 0.0001) if delta_a > 0.0 else 0.0
				var cg := delta_g / maxf(delta_a, 0.0001) if delta_a > 0.0 else 0.0
				var cb := delta_b / maxf(delta_a, 0.0001) if delta_a > 0.0 else 0.0
				data[ptr + 0] = int(clampf(cr * 255.0, 0.0, 255.0))
				data[ptr + 1] = int(clampf(cg * 255.0, 0.0, 255.0))
				data[ptr + 2] = int(clampf(cb * 255.0, 0.0, 255.0))
				data[ptr + 3] = int(clampf(alpha * 255.0, 0.0, 255.0))
			ptr += 4

	img.set_data(n, n, false, Image.FORMAT_RGBA8, data)
	return ImageTexture.create_from_image(img)

var _default_coarse_grid: Texture3D = null

func _get_default_coarse_grid() -> Texture3D:
	if _default_coarse_grid == null:
		var imgs: Array[Image] = []
		for z in range(2):
			var img := Image.create(2, 2, false, Image.FORMAT_L8)
			img.fill(Color(1.0, 1.0, 1.0, 1.0))
			imgs.append(img)
		var tex := ImageTexture3D.new()
		tex.create(Image.FORMAT_L8, 2, 2, 2, false, imgs)
		_default_coarse_grid = tex
	return _default_coarse_grid

var _default_normal_texture: Texture3D = null

func _get_default_normal_texture() -> Texture3D:
	if _default_normal_texture == null:
		var imgs: Array[Image] = []
		for z in range(2):
			var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
			img.fill(Color(0.5, 0.5, 1.0, 1.0))
			imgs.append(img)
		var tex := ImageTexture3D.new()
		tex.create(Image.FORMAT_RGBA8, 2, 2, 2, false, imgs)
		_default_normal_texture = tex
	return _default_normal_texture
