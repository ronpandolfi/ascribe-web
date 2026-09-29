"""STL (stereolithography) mesh reader for both binary and ASCII formats."""
from __future__ import annotations

from pathlib import Path
import re
import struct

import numpy as np

STL_BINARY_DTYPE = np.dtype([
    ("normal", "<f4", (3,)),
    ("v1", "<f4", (3,)),
    ("v2", "<f4", (3,)),
    ("v3", "<f4", (3,)),
    ("attr", "<u2"),
])

_ASCII_VERTEX_RE = re.compile(
    r"vertex\s+([+-]?(?:[0-9]*[.])?[0-9]+(?:[eE][+-]?[0-9]+)?)\s+([+-]?(?:[0-9]*[.])?[0-9]+(?:[eE][+-]?[0-9]+)?)\s+([+-]?(?:[0-9]*[.])?[0-9]+(?:[eE][+-]?[0-9]+)?)",
    re.IGNORECASE,
)


def load_stl(
    path: str | Path,
    deduplicate: bool = True,
    compute_normals: bool = True,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Loads an STL file and returns (vertices, indices, normals).

    vertices: (V, 3) float32
    indices: (I,) uint32
    normals: (V, 3) float32 (or (0, 3) if not computed)
    """
    path = Path(path)
    file_size = path.stat().st_size

    with open(path, "rb") as f:
        header = f.read(84)

    is_binary = False
    if file_size >= 84:
        count = struct.unpack("<I", header[80:84])[0]
        if file_size == 84 + count * 50:
            is_binary = True
        elif not header.startswith(b"solid") and (file_size >= 84 + count * 50):
            is_binary = True

    if is_binary:
        with open(path, "rb") as f:
            f.seek(84)
            data = np.fromfile(f, dtype=STL_BINARY_DTYPE, count=count)
        triangles = np.stack([data["v1"], data["v2"], data["v3"]], axis=1)
    else:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            text = f.read()
        matches = _ASCII_VERTEX_RE.findall(text)
        if not matches:
            stripped = text.strip()
            if stripped.startswith("solid") and "endsolid" in stripped:
                triangles = np.zeros((0, 3, 3), dtype=np.float32)
            elif file_size >= 84:
                count = struct.unpack("<I", header[80:84])[0]
                with open(path, "rb") as f:
                    f.seek(84)
                    data = np.fromfile(f, dtype=STL_BINARY_DTYPE)
                if len(data) > 0:
                    triangles = np.stack([data["v1"], data["v2"], data["v3"]], axis=1)
                else:
                    raise ValueError(f"Failed to parse STL file: {path}")
            else:
                raise ValueError(f"Failed to parse STL file: {path}")
        else:
            if len(matches) % 3 != 0:
                raise ValueError(f"ASCII STL contains incomplete triangles: {len(matches)} vertices found")
            raw_verts = np.array(matches, dtype=np.float32)
            triangles = raw_verts.reshape(-1, 3, 3)

    if len(triangles) == 0:
        return (
            np.zeros((0, 3), dtype=np.float32),
            np.zeros((0,), dtype=np.uint32),
            np.zeros((0, 3), dtype=np.float32),
        )

    flat_verts = triangles.reshape(-1, 3).astype(np.float32)

    if deduplicate:
        unique_verts, inverse = np.unique(flat_verts, axis=0, return_inverse=True)
        vertices = unique_verts.astype(np.float32)
        indices = inverse.astype(np.uint32)
    else:
        vertices = flat_verts
        indices = np.arange(len(flat_verts), dtype=np.uint32)

    if compute_normals:
        normals = compute_mesh_normals(vertices, indices)
    else:
        normals = np.zeros((0, 3), dtype=np.float32)

    return vertices, indices, normals


def compute_mesh_normals(vertices: np.ndarray, indices: np.ndarray) -> np.ndarray:
    """Computes area-weighted per-vertex smooth normals."""
    if len(vertices) == 0 or len(indices) == 0:
        return np.zeros((len(vertices), 3), dtype=np.float32)

    tri_indices = indices.reshape(-1, 3)
    v0 = vertices[tri_indices[:, 0]]
    v1 = vertices[tri_indices[:, 1]]
    v2 = vertices[tri_indices[:, 2]]

    # Cross product magnitude is proportional to triangle area
    fn = np.cross(v1 - v0, v2 - v0)

    vn = np.zeros_like(vertices, dtype=np.float64)
    np.add.at(vn, tri_indices[:, 0], fn)
    np.add.at(vn, tri_indices[:, 1], fn)
    np.add.at(vn, tri_indices[:, 2], fn)

    vn_len = np.linalg.norm(vn, axis=1, keepdims=True)
    zero_mask = (vn_len.squeeze(-1) == 0.0)
    vn_len[vn_len == 0.0] = 1.0
    vn /= vn_len
    vn[zero_mask] = [0.0, 1.0, 0.0]

    return vn.astype(np.float32)