## Mesh-specific data container.
## Stores vertices, indices, normals and can produce an ArrayMesh.
## Vendored from vr-start scripts/DataClasses/mesh_data.gd (tag 1.1.0); local changes noted below.
## Local changes:
## - Renamed MeshData -> WebMeshData; extends RefCounted (Data base class not vendored) with a
##   locally declared `data_ready` signal instead.
## - Removed set_from_dict / to_dict (web viewer only uses set_from_bytes) and the dependency on
##   MeshUtils (not vendored): get_mesh() builds the ArrayMesh directly, generating normals via
##   SurfaceTool when the envelope didn't include a matching normal count.
class_name WebMeshData
extends RefCounted

signal data_ready

var vertices: PackedFloat32Array
var indices: PackedInt32Array
var normals: PackedFloat32Array
var flip_normals: bool = false

var _cached_mesh: ArrayMesh = null


func is_valid() -> bool:
	return vertices.size() > 0 and indices.size() > 0


## Returns a built ArrayMesh (cached after first call).
func get_mesh() -> ArrayMesh:
	if _cached_mesh == null and is_valid():
		_cached_mesh = _build_mesh()
	return _cached_mesh


func invalidate_mesh() -> void:
	_cached_mesh = null


func _build_mesh() -> ArrayMesh:
	var verts := _unflatten_vector3(vertices)
	var idx := indices.duplicate()

	if idx.size() % 3 != 0:
		push_error("WebMeshData: index count (%d) is not a multiple of 3" % idx.size())
		return null

	# Bundles are wound counter-clockwise seen from outside (the STL convention, matching the
	# bundler's normals); Godot treats clockwise as front-facing, so swap each triangle. A file
	# exported wound backwards is already clockwise, which is what `flip_normals` says.
	if not flip_normals:
		for i in range(0, idx.size(), 3):
			var tmp = idx[i + 1]
			idx[i + 1] = idx[i + 2]
			idx[i + 2] = tmp

	var max_idx = verts.size() - 1
	for j in range(idx.size()):
		if idx[j] < 0 or idx[j] > max_idx:
			push_error("WebMeshData: index %d out of bounds (max %d)" % [idx[j], max_idx])
			return null

	var norms := _unflatten_vector3(normals)
	if norms.size() == verts.size() and norms.size() > 0:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_INDEX] = idx
		arrays[Mesh.ARRAY_NORMAL] = norms
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		return mesh

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in verts:
		st.add_vertex(v)
	for i in idx:
		st.add_index(i)
	st.generate_normals()
	return st.commit()


func _unflatten_vector3(flat: PackedFloat32Array) -> PackedVector3Array:
	var arr := PackedVector3Array()
	if flat.size() % 3 != 0:
		push_warning("WebMeshData: array size (%d) is not a multiple of 3 — truncating" % flat.size())
		flat = flat.slice(0, flat.size() - (flat.size() % 3))
	arr.resize(flat.size() / 3)
	for i in range(arr.size()):
		arr[i] = Vector3(flat[i * 3], flat[i * 3 + 1], flat[i * 3 + 2])
	return arr


func clear() -> void:
	vertices = PackedFloat32Array()
	indices = PackedInt32Array()
	normals = PackedFloat32Array()
	_cached_mesh = null


## Set data from the binary envelope body.
##
## `preamble` is the dict returned by `BinaryEnvelope.parse`.
## `body` is the full response body (including the 4-byte length prefix and JSON preamble).
## `offset` is the byte position where the data blocks start (`preamble.offset` from the parser).
##
## Block order (per ascribe-link envelope v1): vertices (float32), indices (uint32),
## normals (float32). Counts of 0 omit the block.
##
## Returns true on success, false on error (malformed preamble or body-too-short).
func set_from_bytes(preamble: Dictionary, body: PackedByteArray, offset: int) -> bool:
	if preamble.get("type", "") != "mesh":
		push_error("WebMeshData.set_from_bytes: preamble.type is not 'mesh'")
		return false

	var vc: int = int(preamble.get("vertex_count", 0))
	var ic: int = int(preamble.get("index_count", 0))
	var nc: int = int(preamble.get("normal_count", 0))

	var vertex_bytes := vc * 3 * 4
	var index_bytes := ic * 4
	var normal_bytes := nc * 3 * 4
	var required := offset + vertex_bytes + index_bytes + normal_bytes
	if body.size() < required:
		push_error("WebMeshData.set_from_bytes: body too short (need %d, got %d)" % [required, body.size()])
		return false

	var cursor := offset
	if vc > 0:
		vertices = body.slice(cursor, cursor + vertex_bytes).to_float32_array()
	else:
		vertices = PackedFloat32Array()
	cursor += vertex_bytes

	if ic > 0:
		indices = body.slice(cursor, cursor + index_bytes).to_int32_array()
	else:
		indices = PackedInt32Array()
	cursor += index_bytes

	if nc > 0:
		normals = body.slice(cursor, cursor + normal_bytes).to_float32_array()
	else:
		normals = PackedFloat32Array()

	_cached_mesh = null
	data_ready.emit()
	return true
