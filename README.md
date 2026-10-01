# ascribe-web

**Live demo:** <https://ronpandolfi.github.io/ascribe-web/?bundle=singer_bundle>
(ALS microtomography) and
<https://ronpandolfi.github.io/ascribe-web/?bundle=demo_bundle> (synthetic gyroid).
Served over HTTPS, which WebXR requires -- a plain `http://` LAN server will not let a
headset enter VR.

A browser-based viewer for volumetric and mesh data with accompanying story narratives. The
**ascribe-web** system combines a WebGL2-compatible Godot viewer with static hosting support,
allowing scientific volumes and meshes to be explored interactively through a web browser without
server-side processing. The viewer supports both desktop (mouse/keyboard) and WebXR headset
interaction modes.

## Author workflow: building and publishing a bundle

### 1. Set up the bundler

```powershell
cd bundler
py -3.13 -m venv ..\.venv   # any Python >=3.11 works
..\.venv\Scripts\activate
pip install -e .
```

(`.venv` lives at the repo root so it's shared by anything else that needs it; there's no `uv`
here, just a vanilla venv.)

### 2. Bake a bundle

```powershell
ascribe-bundle build data.npy --story story.md --title "My Data" -o out/
```

- `data.npy` (or `.tif`/`.tiff`) is a 3D volume array. It can be any numeric dtype on disk --
  the CLI converts it to a web-safe dtype for you (default `float16`; pass `--dtype u8` for an
  8-bit volume, which halves the payload size at the cost of dynamic range).
- `--story story.md` is optional. Pages are split on lines containing only `---`. A page can pin
  a specimen by starting with `@specimen <id>` (the pin persists until a later page pins a
  different one). Standard markdown (`#`/`##` headers, `**bold**`, `*italic*`,
  `![alt](image.png)`) is supported and converted to BBCode by the viewer at load time.
- `--max-dim N` downsamples any axis larger than `N` voxels (uniform stride) -- useful for keeping
  bundle size down.
- `--smooth SIGMA` Gaussian-smooths the volume (sigma in voxels) after downsampling. This is the
  main control over how "striped" a raymarched surface looks: fine layered structure in the data
  (laminations, reconstruction noise) reads as hard banding across a curved surface once a steep
  transfer function amplifies it. On the ALS sample, sigma 1.5 cuts that banding by ~75% (measured
  with `viewer/tools/shader_probe.gd`) while keeping ridges and inclusions legible; 0.6 preserves
  more fine texture but bands noticeably. Larger sigmas also push mid-range values up, which can
  make a volume read as a solid crust under an aggressive transfer function.
- `--colormap NAME` uses a perceptual colormap as the transfer function: `viridis`, `magma`,
  `inferno`, `plasma`, `cividis`, `turbo`, `jet`, `mako`, `rocket`, `flare`, `crest`, `icefire`
  or `gray`. The low end fades to transparent -- volume rendering needs that, or only the outer
  shell is ever visible -- and the transparent padding carries the colormap's own lowest colour
  rather than black, since the gradient is interpolated in straight alpha and a black stop drags
  everything blending toward it. `--colormap-alpha LO,HI` (default `0.15,0.5`) sets where that
  fade starts and finishes.
- `--gamma G` applies a gamma to the value before the transfer function is looked up. Below 1
  lifts faint material, above 1 suppresses it; the viewer's Gamma slider does the same thing
  live, so this is really just a saved starting point.
- `--window LOW,HIGH` contrast-windows the volume to that percentile range before casting. Real
  reconstructions often pack 90%+ of their voxels into a narrow intensity band with a few far-out
  outliers; plain min/max scaling then leaves the structure with almost no contrast (it renders as
  flat fog). `--window 1,99.8` is a good starting point -- see the demo bundle recipe below.
- `--size-warn-mb N` (default 100) prints a warning, not an error, if the baked bundle exceeds it.
- `-o out/` is the output directory: `manifest.json` + one `.bin` envelope per specimen, plus any
  images referenced by the story, copied alongside.

Run `ascribe-bundle inspect out/` to validate an existing bundle and print its manifest plus each
specimen's decoded envelope header.

### 3. Preview locally

On the desktop build you can point the viewer straight at a bundle without exporting for web:

```powershell
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --path viewer -- --bundle=http://localhost:8060/my_bundle
```

(Everything after `--` goes to the game; `--bundle=` also accepts a `res://` path.)


The viewer's `res://tests/fixtures/tiny_bundle` fixture bundle is baked into the exported web
build for offline testing, but to preview a real bundle you need a same-origin HTTP server (the
viewer never assumes CORS):

```powershell
ascribe-bundle serve build\web
```

(Use `ascribe-bundle serve`, not `python -m http.server`: the plain server sends no
`Cache-Control`, so a browser -- Firefox in particular -- will happily keep running a cached
`index.pck`/`index.wasm` after you re-export, which looks exactly like a bug you already fixed.
`serve` sends `no-store` on everything. If you do use another static server, hard-reload
(Ctrl+Shift+R) after every export.)

Then open `http://localhost:8060/index.html?bundle=../../out` (or copy your bundle's `out/`
directory next to `index.html` first and use a relative `?bundle=` path — see below).

### 4. Deploy

Pushing to `main` builds and publishes the site automatically: `.github/workflows/pages.yml`
exports the viewer with headless Godot, copies `demo/bundle` and `demo/singer/bundle` next to
it as `demo_bundle`/`singer_bundle`, and deploys to GitHub Pages. Adding a bundle to the
published site means committing it under `demo/` and staging it in that workflow.


Re-export before previewing locally: `build/web/` is a build artifact, and a stale one will not
show features added since it was made (the deploy workflow exports its own copy, so CI being
green says nothing about what is sitting in your local `build/web`).

The exported `build/web/` directory is fully static: copy it, plus one or more bundle directories,
to any static host (GitHub Pages, S3 + CloudFront, an internal file server, `python -m
http.server` for a LAN demo, etc.) preserving relative paths. Load a specific bundle with the
`?bundle=` query parameter, e.g.:

```
https://your-host.example/index.html?bundle=demo_bundle
```

`?bundle=` is resolved relative to `index.html`'s own URL (same-origin, no CORS needed). Omitting
it falls back to the bundle baked into the exported `.pck` (the test fixture, for a bare desktop
smoke-test).

The repo also ships a bundle baked from real beamline data at `build/web/singer_bundle/` (kept
at `demo/singer/` with its story). It was produced from an ALS 8.3.2 microtomography
reconstruction with:

```powershell
ascribe-bundle build rec20201028_190153_esther-singer_wet2_pipette_z50_YESagar_x00y01_8bitcrop-roi.tif `
  --story demo/singer/story.md --title "Agar column microtomography (ALS 8.3.2)" `
  --dtype u8 --max-dim 384 --smooth 0.6 --window 1,99.8 -o demo/singer/bundle
```

Its presentation -- viridis, the framing, gamma/opacity/quality -- was then set in the viewer's
edit mode and saved back into the manifest, which is the intended way to do it (see below).
`demo/apply_display.py` re-applies a colormap or preset after a rebake, since `ascribe-bundle
build` always rewrites `display`.

This repo also ships a synthetic demo bundle at `build/web/demo_bundle/` (also kept at `demo/bundle/` alongside
the numpy generator that produced it, `demo/gen_demo_volume.py`, and its story, `demo/story.md`) --
load it with `?bundle=demo_bundle` against the exported build.

## Controls

Desktop: left-drag orbits, right-drag pans, wheel zooms. On a touchscreen, one finger orbits and
two fingers pinch to zoom and drag to pan (Godot synthesises neither gesture on web, so these are
resolved from raw touch events). **V** prints a shareable `?view=` URL to the browser console.

In VR: holding one grip moves and rotates the specimen; holding both grips scales it by the
change in distance between your hands (clamped to 0.1x-10x). The settings and story panels float
beside it, and the settings panel carries an **Exit VR** button -- a headset has no browser chrome to fall
back on, and the system gesture is not obvious to a first-time user.

## Rebuilding the viewer

```powershell
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path viewer --export-release Web ../build/web/index.html
```

Godot 4.7, Compatibility renderer, single-threaded web export (no COOP/COEP headers required by
the host). A benign segfault after "Saving resource cache" during headless export is expected and
does not indicate export failure -- check that the export artifacts were actually written/updated.

## The synthetic control bundle

`?bundle=cube` is a solid cube, rotated so no face is parallel to a bounding-box plane, with a
perfectly uniform interior (standard deviation ~1e-6) and soft two-voxel edges. Because the
object has no structure of its own, **any pattern visible on its faces comes from the rendering
pipeline, not from the data** -- which makes it the first thing to load when a real dataset looks
banded or moire-y. It is generated at deploy time by `demo/gen_cube.py`, so it costs the repo no
binary.

`?bundle=cube_flat` is the same cube with a single flat colour, and `?bundle=singer_early` is the
ALS volume with colour decoupled from the alpha ramp -- both for isolating how much of a banding
artifact is colour-from-first-hit rather than opacity variation.

Transfer functions live in `demo/apply_display.py` as named presets; run it against a baked
`manifest.json` after every rebake (`ascribe-bundle build` always writes the default gradient).

## Authoring a bundle's presentation (edit mode)

Transfer functions, framing and display settings otherwise have to be hand-edited into
`manifest.json` after every rebake. Edit mode does it from the viewer:

```powershell
ascribe-bundle serve build\web --edit
```

then open `http://localhost:8060/index.html?bundle=<dir>&edit=1`. Frame the specimen, set the
sliders, and press **Save view + settings**. The viewer POSTs the updated manifest back to the
server, which validates it and replaces the file; anything the panel does not control (the
gradient, the story, specimen ids) is carried through untouched. A saved `view` becomes the
bundle's default framing, which an explicit `?view=` still overrides.

Saving is refused unless `--edit` was passed, and the button is hidden without `&edit=1`, so a
deployed bundle never offers an action that cannot work.

## What a bundle can specify

Everything under a specimen's `display` in `manifest.json`, all optional:

| key | meaning |
|---|---|
| `gradient` | transfer function: `[[offset, "#rrggbbaa"], ...]`. Keep transparent stops coloured, not black -- the viewer interpolates in straight alpha, so a black stop drags the colour of anything fading in |
| `gamma` | applied to the value before the gradient lookup |
| `opacity` | scales every sample's alpha |
| `max_steps`, `step_size` | ray sampling. An authored value wins over the automatic quality tier, except in a headset, where it is capped by the XR tier so a bundle cannot cost someone their framerate |
| `lateral_jitter` | screen-plane dither, in march steps (default 4). Breaks up the coherent moire that neighbouring rays otherwise produce, at the cost of grain. Set 0 to disable |
| `lut_substeps` | transfer-function sub-step budget (default 192). Lower it if a headset cannot hold framerate |

Plus a top-level `view` (`"yaw,pitch,distance"`), the bundle's default framing.

## Comparing shader changes

Volume rendering regressions are hard to judge by eye. `viewer/tools/shader_probe.gd` renders a
fixed close-up of a bundle so two variants can be measured rather than eyeballed:

```powershell
& "<godot>" --path viewer --quit-after 4000 --fixed-fps 30 --write-movie out\p.png `
    -s res://tools/shader_probe.gd -- --bundle=http://localhost:8060/singer_bundle `
    --param=max_steps:512 --param=step_size:0.0025
```

Note that quality and dithering interact: with `lateral_jitter` at 0 the quality setting does
almost nothing (sub-step integration makes the render step-invariant -- 512 and 2048 steps differ
by 0.2 of 255 on the ALS bundle), while with dithering on, more steps means less per-ray error to
scatter and the difference is obvious. `?bundle=singer_nodither` is the demo with it off, for
comparison.

The viewer also draws a small axes gadget in the bottom-left corner showing how world X/Y/Z
currently sit relative to the camera, which makes it much easier to say *which* plane an
artifact lies in.

`--param` pokes a uniform on the staged material, which is the only way to override the startup
quality tier (it takes precedence over the manifest's `max_steps`/`step_size`).

## Running tests

Bundler (pytest):

```powershell
.venv\Scripts\python -m pytest bundler
```

Viewer (gdUnit4, headless):

```powershell
& "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path viewer -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd -a res://tests --ignoreHeadlessMode
```

## Roadmap / limitations

- **Building directly from a running ascribe-link server is not yet implemented.** The bundler CLI
  (`ascribe-bundle build`) only accepts local files -- a `.npy`/`.tif`/`.tiff` volume array, or a
  pre-baked `.bin` envelope. There is no "point the CLI at a specimen ID on a live server" workflow
  yet; that would require an ascribe-link client and is left for a future iteration.
