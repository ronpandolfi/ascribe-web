"""Writer/reader for the ascribe-link binary envelope (v1).

Layout: <u32 LE preamble_len><UTF-8 JSON preamble><contiguous data blocks>.
Mirrors vr-start's scripts/DataSources/binary_envelope.gd.
"""
from __future__ import annotations

import json
import struct

import numpy as np

MEDIA_TYPE = "application/x-ascribe-envelope-v1"
_ALLOWED_VOLUME_DTYPES = {"float16", "uint8"}


def write_envelope(preamble: dict, blocks: list[bytes]) -> bytes:
    p = json.dumps(preamble, separators=(",", ":")).encode("utf-8")
    return struct.pack("<I", len(p)) + p + b"".join(blocks)


def read_envelope(data: bytes) -> tuple[dict, bytes]:
    if len(data) < 4:
        raise ValueError("envelope truncated: missing length prefix")
    n = struct.unpack("<I", data[:4])[0]
    if len(data) < 4 + n:
        raise ValueError("envelope truncated: preamble incomplete")
    return json.loads(data[4 : 4 + n].decode("utf-8")), data[4 + n :]


def volume_envelope(arr: np.ndarray, spacing=(1, 1, 1), origin=(0, 0, 0)) -> bytes:
    if arr.ndim != 3:
        raise ValueError(f"volume must be 3D (z,y,x), got {arr.ndim}D")
    dtype = str(arr.dtype)
    if dtype not in _ALLOWED_VOLUME_DTYPES:
        raise ValueError(f"volume dtype must be float16 or uint8, got {dtype}")
    preamble = {
        "type": "volume",
        "shape": list(arr.shape),
        "dtype": dtype,
        "spacing": list(spacing),
        "origin": list(origin),
    }
    payload = np.ascontiguousarray(arr).astype(arr.dtype.newbyteorder("<")).tobytes()
    return write_envelope(preamble, [payload])


def mesh_envelope(
    vertices: np.ndarray,
    indices: np.ndarray,
    normals: np.ndarray | None = None,
) -> bytes:
    """Builds a binary envelope for mesh data.

    Vertices: (V, 3) float32.
    Indices: (I,) uint32.
    Normals: (V, 3) float32 (or (N, 3)), optional. If omitted or empty, normal_count is 0.
    """
    v_arr = np.ascontiguousarray(vertices, dtype="<f4").reshape(-1, 3)
    i_arr = np.ascontiguousarray(indices, dtype="<u4").ravel()

    vc = len(v_arr)
    ic = len(i_arr)
    nc = 0
    blocks = [v_arr.tobytes(), i_arr.tobytes()]

    if normals is not None and len(normals) > 0:
        n_arr = np.ascontiguousarray(normals, dtype="<f4").reshape(-1, 3)
        nc = len(n_arr)
        blocks.append(n_arr.tobytes())

    preamble = {
        "type": "mesh",
        "vertex_count": vc,
        "index_count": ic,
        "normal_count": nc,
    }
    return write_envelope(preamble, blocks)