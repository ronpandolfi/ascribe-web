"""Generate a synthetic demo mesh: a (p, q) torus knot swept into a tube, written as binary STL.

A torus knot is a good mesh specimen to look at shaders on: it is smooth everywhere (so a
faceting or normal bug shows up as visible seams), it is closed and watertight (so
`--flip-normals` has an unambiguous right answer -- with normals the wrong way round, lit
shaders go dark and back-face culled ones vanish), and it passes in front of itself, so
transparent shaders show their depth sorting.

The tube is generated on a periodic grid whose seam vertices are emitted bit-identically, so
the bundler's vertex de-duplication welds them and its smooth normals run continuously across
the seam. Triangles wind counter-clockwise seen from outside, so normals point outward (the
enclosed signed volume is positive).

    python demo/gen_knot.py out.stl [--p 2] [--q 3] [--segments 400] [--sides 32]
"""
from __future__ import annotations

import argparse

import numpy as np

STL_BINARY_DTYPE = np.dtype([
    ("normal", "<f4", (3,)),
    ("v1", "<f4", (3,)),
    ("v2", "<f4", (3,)),
    ("v3", "<f4", (3,)),
    ("attr", "<u2"),
])


def torus_knot(p: int = 2, q: int = 3, segments: int = 400, sides: int = 32,
               major: float = 2.0, minor: float = 0.8,
               tube: float = 0.35) -> tuple[np.ndarray, np.ndarray]:
    """Returns (vertices (segments*sides, 3), triangles (2*segments*sides, 3) index array)."""
    t = np.linspace(0.0, 2.0 * np.pi, segments, endpoint=False)
    ring = major + minor * np.cos(q * t)
    centre = np.stack([ring * np.cos(p * t), ring * np.sin(p * t), minor * np.sin(q * t)], -1)

    # Analytic tangent. Its xy speed is at least p * (major - minor) > 0, so it is never parallel
    # to z, which makes cross(tangent, z) a frame that is continuous and closes on itself.
    dring = -minor * q * np.sin(q * t)
    tangent = np.stack([dring * np.cos(p * t) - ring * p * np.sin(p * t),
                        dring * np.sin(p * t) + ring * p * np.cos(p * t),
                        minor * q * np.cos(q * t)], -1)
    tangent /= np.linalg.norm(tangent, axis=-1, keepdims=True)
    normal = np.cross(tangent, [0.0, 0.0, 1.0])
    normal /= np.linalg.norm(normal, axis=-1, keepdims=True)
    binormal = np.cross(tangent, normal)

    v = np.linspace(0.0, 2.0 * np.pi, sides, endpoint=False)
    offsets = (np.cos(v)[None, :, None] * normal[:, None, :]
               + np.sin(v)[None, :, None] * binormal[:, None, :])
    vertices = (centre[:, None, :] + tube * offsets).reshape(-1, 3)

    i = np.arange(segments)[:, None]
    j = np.arange(sides)[None, :]
    a = i * sides + j
    b = ((i + 1) % segments) * sides + j
    c = ((i + 1) % segments) * sides + (j + 1) % sides
    d = i * sides + (j + 1) % sides
    # a -> b runs along the knot and a -> d around the tube, so cross(b - a, d - a) points
    # *into* the tube (tangent x binormal = -normal). Wind a -> d -> c to face outward.
    triangles = np.concatenate([np.stack([a, d, c], -1).reshape(-1, 3),
                                np.stack([a, c, b], -1).reshape(-1, 3)])
    return vertices.astype(np.float32), triangles


def write_binary_stl(path: str, vertices: np.ndarray, triangles: np.ndarray) -> None:
    tri = vertices[triangles]
    face_normals = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    face_normals /= np.maximum(np.linalg.norm(face_normals, axis=-1, keepdims=True), 1e-12)
    records = np.zeros(len(tri), dtype=STL_BINARY_DTYPE)
    records["normal"] = face_normals
    records["v1"], records["v2"], records["v3"] = tri[:, 0], tri[:, 1], tri[:, 2]
    with open(path, "wb") as f:
        f.write(b"ascribe-web demo torus knot".ljust(80, b" "))
        f.write(np.uint32(len(records)).tobytes())
        records.tofile(f)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("output", help="path to write the binary .stl to")
    parser.add_argument("--p", type=int, default=2, help="turns around the axis of symmetry")
    parser.add_argument("--q", type=int, default=3, help="turns through the hole")
    parser.add_argument("--segments", type=int, default=400, help="samples along the knot")
    parser.add_argument("--sides", type=int, default=32, help="samples around the tube")
    args = parser.parse_args(argv)

    vertices, triangles = torus_knot(args.p, args.q, args.segments, args.sides)
    write_binary_stl(args.output, vertices, triangles)
    print(f"wrote {args.output}: ({args.p},{args.q}) torus knot, "
          f"{len(vertices)} vertices, {len(triangles)} triangles")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
