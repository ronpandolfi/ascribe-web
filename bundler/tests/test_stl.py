import struct
import numpy as np
import pytest

from ascribe_bundle.stl import compute_mesh_normals, load_stl, STL_BINARY_DTYPE


def test_load_stl_ascii(tmp_path):
    ascii_content = """solid tetrahedron
  facet normal 0.0 0.0 1.0
    outer loop
      vertex 0.0 0.0 0.0
      vertex 1.0 0.0 0.0
      vertex 0.0 1.0 0.0
    endloop
  endfacet
  facet normal 0.0 -1.0 0.0
    outer loop
      vertex 0.0 0.0 0.0
      vertex 0.0 0.0 1.0
      vertex 1.0 0.0 0.0
    endloop
  endfacet
endsolid tetrahedron
"""
    stl_file = tmp_path / "test.stl"
    stl_file.write_text(ascii_content, encoding="utf-8")

    verts, indices, normals = load_stl(stl_file)
    assert len(verts) == 4  # 4 unique vertices
    assert len(indices) == 6  # 2 triangles * 3
    assert len(normals) == 4
    assert verts.dtype == np.float32
    assert indices.dtype == np.uint32
    assert normals.dtype == np.float32


def test_load_stl_binary(tmp_path):
    stl_file = tmp_path / "test_bin.stl"
    # Write 80-byte header, 1 triangle count, and 50 bytes of triangle data
    header = b"Binary STL test".ljust(80, b"\0")
    count = 1
    tri_record = (
        (0.0, 0.0, 1.0),   # normal
        (0.0, 0.0, 0.0),   # v1
        (1.0, 0.0, 0.0),   # v2
        (0.0, 1.0, 0.0),   # v3
        0                  # attr
    )
    tri_bytes = np.array([tri_record], dtype=STL_BINARY_DTYPE).tobytes()

    with open(stl_file, "wb") as f:
        f.write(header)
        f.write(struct.pack("<I", count))
        f.write(tri_bytes)

    verts, indices, normals = load_stl(stl_file)
    assert len(verts) == 3
    assert len(indices) == 3
    assert len(normals) == 3
    assert np.allclose(normals, [[0, 0, 1], [0, 0, 1], [0, 0, 1]])


def test_load_stl_empty(tmp_path):
    ascii_content = """solid empty
endsolid empty
"""
    stl_file = tmp_path / "empty.stl"
    stl_file.write_text(ascii_content, encoding="utf-8")

    verts, indices, normals = load_stl(stl_file)
    assert len(verts) == 0
    assert len(indices) == 0
    assert len(normals) == 0


def test_load_stl_invalid(tmp_path):
    stl_file = tmp_path / "corrupt.stl"
    stl_file.write_bytes(b"garbage that is not stl")
    with pytest.raises(ValueError):
        load_stl(stl_file)


def test_compute_mesh_normals_degenerate():
    verts = np.array([[0, 0, 0], [0, 0, 0], [0, 0, 0]], dtype=np.float32)
    indices = np.array([0, 1, 2], dtype=np.uint32)
    normals = compute_mesh_normals(verts, indices)
    assert len(normals) == 3
    # Degenerate normal defaults to [0, 1, 0]
    assert np.allclose(normals, [[0, 1, 0], [0, 1, 0], [0, 1, 0]])
