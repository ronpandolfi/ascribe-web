# Torus knot (synthetic mesh)

A (2,3) torus knot -- the trefoil -- swept into a tube and baked from a binary STL. It is
generated at deploy time by `demo/gen_knot.py`, so the repo carries no mesh binary.

---
## Why a knot

The surface is smooth everywhere, so a faceting or normal bug shows up as a visible seam. It is
closed and watertight, so its normals have one right answer: wound backwards, lit shaders go
dark. And it passes in front of itself, so transparent shaders show their depth sorting.

---
## Tuning the look

This knot uses the tunable **surface** material. Try the settings panel: colour, opacity,
roughness, metallic and rim light all change live, and **Show inner surfaces** lets a
translucent mesh show its own crossings.

The same knot is also published with each fixed-look shader (`?bundle=knot_pearl`,
`?bundle=knot_crystal`, `?bundle=knot_holographic`), and translucent with inner surfaces on as
`?bundle=knot_inner`.
