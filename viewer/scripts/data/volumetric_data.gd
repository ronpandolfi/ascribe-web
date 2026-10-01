## Volumetric data container.
## Stores a 3D texture for volume rendering.
## Vendored from vr-start scripts/DataClasses/volumetric_data.gd (tag 1.1.0); local changes noted below.
## Local changes:
## - Renamed VolumetricData -> WebVolumetricData; extends RefCounted (Data base class not vendored)
##   with a locally declared `data_ready` signal instead.
## - Removed set_from_dict, set_from_images, and set_texture (web viewer only uses set_from_bytes).
## - _create_image_from_bytes supports only uint8/float16 (web-safe dtypes); float32 is rejected.
## - Added build_async (Task 7): identical to set_from_bytes but builds slice images in batches of
##   8, awaiting a scene-tree process frame between batches, so BundleLoader can decode large
##   volumes without stalling the main thread. set_from_bytes is kept as-is for synchronous tests.
class_name WebVolumetricData
extends RefCounted

signal data_ready

var _texture: Texture3D
var _coarse_texture: Texture3D
var _dimensions: Vector3i
var _spacing: Vector3 = Vector3.ONE
var _origin: Vector3 = Vector3.ZERO


func is_valid() -> bool:
	return _texture != null


func get_data() -> Texture3D:
	return _texture


func get_texture() -> Texture3D:
	return _texture


func get_coarse_texture() -> Texture3D:
	return _coarse_texture


func get_dimensions() -> Vector3i:
	return _dimensions


func get_spacing() -> Vector3:
	return _spacing


func get_origin() -> Vector3:
	return _origin


func _get_bytes_per_voxel(dtype: String) -> int:
	match dtype:
		"uint8", "int8":
			return 1
		"uint16", "int16", "float16":
			return 2
		"uint32", "int32", "float32":
			return 4
		"uint64", "int64", "float64":
			return 8
		_:
			push_warning("WebVolumetricData: unknown dtype '%s', assuming 4 bytes" % dtype)
			return 4


func _create_image_from_bytes(raw: PackedByteArray, width: int, height: int, dtype: String) -> Image:
	match dtype:
		"uint8":
			return Image.create_from_data(width, height, false, Image.FORMAT_L8, raw)
		"float16":
			return Image.create_from_data(width, height, false, Image.FORMAT_RH, raw)
		_:
			push_error("WebVolumetricData: dtype '%s' is not web-safe (float16/uint8 only)" % dtype)
			return null


func clear() -> void:
	_texture = null
	_coarse_texture = null
	_dimensions = Vector3i.ZERO
	_spacing = Vector3.ONE
	_origin = Vector3.ZERO


## Set data from the binary envelope body.
##
## `preamble` is the dict returned by `BinaryEnvelope.parse`.
## `body` is the full response body (including the 4-byte length prefix and JSON preamble).
## `offset` is the byte position where the volume bytes start (`preamble.offset` from the parser).
##
## Returns true on success, false on error (malformed preamble, body-too-short, bad dtype).
func set_from_bytes(preamble: Dictionary, body: PackedByteArray, offset: int) -> bool:
	if preamble.get("type", "") != "volume":
		push_error("WebVolumetricData.set_from_bytes: preamble.type is not 'volume'")
		return false

	var shape = preamble.get("shape", [])
	if shape.size() != 3:
		push_error("WebVolumetricData.set_from_bytes: shape must have 3 elements")
		return false
	var depth: int = int(shape[0])
	var height: int = int(shape[1])
	var width: int = int(shape[2])
	_dimensions = Vector3i(width, height, depth)

	var dtype: String = preamble.get("dtype", "float32")
	var bytes_per_voxel := _get_bytes_per_voxel(dtype)
	var slice_bytes := width * height * bytes_per_voxel
	var total_bytes := depth * slice_bytes

	if body.size() < offset + total_bytes:
		push_error("WebVolumetricData.set_from_bytes: body too short (need %d, got %d)" % [offset + total_bytes, body.size()])
		return false

	var spacing_arr = preamble.get("spacing", [1.0, 1.0, 1.0])
	var origin_arr = preamble.get("origin", [0.0, 0.0, 0.0])
	if spacing_arr == null:
		spacing_arr = [1.0, 1.0, 1.0]
	if origin_arr == null:
		origin_arr = [0.0, 0.0, 0.0]
	if spacing_arr.size() >= 3:
		# Preamble order is [sz, sy, sx]; Godot Vector3 is [x, y, z].
		_spacing = Vector3(spacing_arr[2], spacing_arr[1], spacing_arr[0])
	if origin_arr.size() >= 3:
		_origin = Vector3(origin_arr[2], origin_arr[1], origin_arr[0])

	var images: Array[Image] = []
	for z in range(depth):
		var start := offset + z * slice_bytes
		var end := start + slice_bytes
		var slice_buf := body.slice(start, end)
		var img := _create_image_from_bytes(slice_buf, width, height, dtype)
		if img == null:
			push_error("WebVolumetricData.set_from_bytes: failed to create image for slice %d" % z)
			return false
		images.append(img)

	var tex := ImageTexture3D.new()
	tex.create(images[0].get_format(), width, height, depth, false, images)
	_texture = tex
	_coarse_texture = create_coarse_occupancy_grid(images, width, height, depth, 16)
	data_ready.emit()
	return true


## Async variant of set_from_bytes for use by BundleLoader.
##
## Identical validation and decoding to set_from_bytes, but builds slice images in batches of 8,
## awaiting `tree.process_frame` between batches so a large volume (e.g. 512 slices) does not
## stall the main thread during decode.
##
## Returns true on success, false on error (malformed preamble, body-too-short, bad dtype).
func build_async(preamble: Dictionary, body: PackedByteArray, offset: int, tree: SceneTree) -> bool:
	if preamble.get("type", "") != "volume":
		push_error("WebVolumetricData.build_async: preamble.type is not 'volume'")
		return false

	var shape = preamble.get("shape", [])
	if shape.size() != 3:
		push_error("WebVolumetricData.build_async: shape must have 3 elements")
		return false
	var depth: int = int(shape[0])
	var height: int = int(shape[1])
	var width: int = int(shape[2])
	_dimensions = Vector3i(width, height, depth)

	var dtype: String = preamble.get("dtype", "float32")
	var bytes_per_voxel := _get_bytes_per_voxel(dtype)
	var slice_bytes := width * height * bytes_per_voxel
	var total_bytes := depth * slice_bytes

	if body.size() < offset + total_bytes:
		push_error("WebVolumetricData.build_async: body too short (need %d, got %d)" % [offset + total_bytes, body.size()])
		return false

	var spacing_arr = preamble.get("spacing", [1.0, 1.0, 1.0])
	var origin_arr = preamble.get("origin", [0.0, 0.0, 0.0])
	if spacing_arr == null:
		spacing_arr = [1.0, 1.0, 1.0]
	if origin_arr == null:
		origin_arr = [0.0, 0.0, 0.0]
	if spacing_arr.size() >= 3:
		# Preamble order is [sz, sy, sx]; Godot Vector3 is [x, y, z].
		_spacing = Vector3(spacing_arr[2], spacing_arr[1], spacing_arr[0])
	if origin_arr.size() >= 3:
		_origin = Vector3(origin_arr[2], origin_arr[1], origin_arr[0])

	var images: Array[Image] = []
	for z in range(depth):
		var start := offset + z * slice_bytes
		var end := start + slice_bytes
		var slice_buf := body.slice(start, end)
		var img := _create_image_from_bytes(slice_buf, width, height, dtype)
		if img == null:
			push_error("WebVolumetricData.build_async: failed to create image for slice %d" % z)
			return false
		images.append(img)
		if (z + 1) % 8 == 0 and tree != null:
			await tree.process_frame

	var tex := ImageTexture3D.new()
	tex.create(images[0].get_format(), width, height, depth, false, images)
	_texture = tex
	_coarse_texture = create_coarse_occupancy_grid(images, width, height, depth, 16)
	data_ready.emit()
	return true

## Generates a 16x16x16 coarse occupancy grid texture from slice images for empty-space skipping.
static func create_coarse_occupancy_grid(images: Array[Image], width: int, height: int, depth: int, grid_size: int = 16) -> ImageTexture3D:
	if images.is_empty() or width <= 0 or height <= 0 or depth <= 0:
		return null
	var coarse_images: Array[Image] = []
	var z_step := float(depth) / float(grid_size)
	var y_step := float(height) / float(grid_size)
	var x_step := float(width) / float(grid_size)

	for cz in range(grid_size):
		var raw_bytes := PackedByteArray()
		raw_bytes.resize(grid_size * grid_size)
		var z_mid := clampi(int((float(cz) + 0.5) * z_step), 0, depth - 1)
		var img_z: Image = images[z_mid]

		for cy in range(grid_size):
			var y_mid := clampi(int((float(cy) + 0.5) * y_step), 0, height - 1)
			var y_offset := cy * grid_size

			for cx in range(grid_size):
				var x_mid := clampi(int((float(cx) + 0.5) * x_step), 0, width - 1)
				var c_val: float = img_z.get_pixel(x_mid, y_mid).r
				var max_val: float = c_val
				var x_corner := clampi(int(float(cx) * x_step), 0, width - 1)
				var y_corner := clampi(int(float(cy) * y_step), 0, height - 1)
				max_val = maxf(max_val, img_z.get_pixel(x_corner, y_corner).r)

				raw_bytes[y_offset + cx] = int(clampf(max_val * 255.0, 0.0, 255.0))

		var coarse_slice := Image.create_from_data(grid_size, grid_size, false, Image.FORMAT_L8, raw_bytes)
		coarse_images.append(coarse_slice)

	var coarse_tex := ImageTexture3D.new()
	var err := coarse_tex.create(Image.FORMAT_L8, grid_size, grid_size, grid_size, false, coarse_images)
	if err != OK:
		return null
	return coarse_tex
