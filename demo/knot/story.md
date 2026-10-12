# Torus knot (synthetic mesh)

A (2,3) torus knot -- the trefoil -- swept into a tube and baked from a binary STL. It is
generated at deploy time by `demo/gen_knot.py`, so the repo carries no mesh binary.

---
## Why a knot

The surface is smooth everywhere, so a faceting or normal bug shows up as a visible seam. It is
closed and watertight, so its normals have one right answer: wound backwards, lit shaders go
dark. And it passes in front of itself, so transparent shaders show their depth sorting.

---
## Shaders

A mesh's look is chosen at bake time with `ascribe-bundle build --shader NAME`. The same knot
is published once per shader for comparison: `?bundle=knot_crystal`, `?bundle=knot_hologram`,
and so on.
