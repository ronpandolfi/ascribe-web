extends GdUnitTestSuite

const FIXTURE := "res://tests/fixtures/tiny_bundle/"


func _load_fixture_envelope() -> PackedByteArray:
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE + "manifest.json"))
	return FileAccess.get_file_as_bytes(FIXTURE + manifest["specimens"][0]["data"])


func test_envelope_parse_ok() -> void:
	var parsed := BinaryEnvelope.parse(_load_fixture_envelope())
	assert_that(parsed.has("error")).is_false()
	assert_that(parsed["preamble"]["type"]).is_equal("volume")
	assert_that(parsed["preamble"]["dtype"]).is_equal("float16")


func test_envelope_truncated() -> void:
	var parsed := BinaryEnvelope.parse(PackedByteArray([1, 2]))
	assert_that(parsed.has("error")).is_true()


func test_volume_set_from_bytes() -> void:
	var body := _load_fixture_envelope()
	var parsed := BinaryEnvelope.parse(body)
	var vol := WebVolumetricData.new()
	assert_that(vol.set_from_bytes(parsed["preamble"], body, parsed["offset"])).is_true()
	assert_that(vol.get_dimensions()).is_equal(Vector3i(16, 16, 16))
	assert_that(vol.get_texture()).is_not_null()


func test_volume_rejects_float32() -> void:
	var pre := {"type": "volume", "shape": [1, 1, 1], "dtype": "float32"}
	var body := PackedByteArray([0, 0, 0, 0])
	var vol := WebVolumetricData.new()
	assert_that(vol.set_from_bytes(pre, body, 0)).is_false()


## Builds a minimal mesh envelope (a single triangle) in-test: u32 LE preamble length, the JSON
## preamble, then 3 float32 vertices, 3 uint32 indices, and 3 float32 normals.
func _build_triangle_envelope() -> PackedByteArray:
	var preamble := JSON.stringify({
		"type": "mesh",
		"vertex_count": 3,
		"index_count": 3,
		"normal_count": 3,
	})
	var preamble_bytes := preamble.to_utf8_buffer()

	var buffer := StreamPeerBuffer.new()
	buffer.put_u32(preamble_bytes.size())
	buffer.put_data(preamble_bytes)

	var vertices := PackedFloat32Array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0])
	buffer.put_data(vertices.to_byte_array())

	var indices := PackedInt32Array([0, 1, 2])
	for i in indices:
		buffer.put_u32(i)

	var normals := PackedFloat32Array([0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0])
	buffer.put_data(normals.to_byte_array())

	return buffer.data_array


func test_mesh_set_from_bytes_builds_arraymesh() -> void:
	var body := _build_triangle_envelope()
	var parsed := BinaryEnvelope.parse(body)
	assert_that(parsed.has("error")).is_false()
	assert_that(parsed["preamble"]["type"]).is_equal("mesh")

	var mesh_data := WebMeshData.new()
	assert_that(mesh_data.set_from_bytes(parsed["preamble"], body, parsed["offset"])).is_true()

	var mesh := mesh_data.get_mesh()
	assert_that(mesh).is_not_null()
	assert_that(mesh.get_surface_count()).is_equal(1)


# Bundles store triangles counter-clockwise seen from outside (the STL convention, and what the
# bundler's normals assume), but Godot treats *clockwise* as front-facing. Unswapped, every mesh
# rendered inside-out: culling shaders showed the far wall's inside, and lit/fresnel shaders
# shaded with the wrong side's normals.
func test_mesh_winding_is_converted_to_godot_clockwise() -> void:
	var md := WebMeshData.new()
	md.vertices = PackedFloat32Array([0, 0, 0, 1, 0, 0, 0, 1, 0])
	md.indices = PackedInt32Array([0, 1, 2])
	md.normals = PackedFloat32Array([0, 0, 1, 0, 0, 1, 0, 0, 1])
	var idx: PackedInt32Array = md.get_mesh().surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	assert_array(Array(idx)).is_equal([0, 2, 1])

	# flip_normals is for files exported wound backwards: it leaves their order alone.
	md.flip_normals = true
	md.invalidate_mesh()
	idx = md.get_mesh().surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	assert_array(Array(idx)).is_equal([0, 1, 2])
