"""ascribe-bundle command-line interface."""
from __future__ import annotations

import argparse
import functools
import json
import shutil
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np

from .colormaps import gradient_stops, list_colormaps
from .envelope import mesh_envelope, read_envelope, volume_envelope
from .stl import load_stl

MESH_SHADERS = [
    "glass",
    "crystal",
    "brick",
    "water",
    "pearl",
    "holographic",
    "edges",
    "jello",
    "hologram",
]
from .manifest import DEFAULT_GRADIENT, make_manifest, validate_manifest
from .story import parse_story
from .volume import convert_volume, load_volume


def build(args) -> int:
    src = Path(args.input)
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)

    if src.suffix == ".bin":  # pre-baked envelope, pass through after dtype check
        data = src.read_bytes()
        pre, _ = read_envelope(data)
        if pre.get("type") == "volume" and pre.get("dtype") not in ("float16", "uint8"):
            print(f"error: envelope dtype {pre.get('dtype')} not web-safe", file=sys.stderr)
            return 1
        env = data
        spec_type = pre.get("type", "volume")
    elif src.suffix.lower() == ".stl":
        verts, indices, normals = load_stl(src)
        env = mesh_envelope(verts, indices, normals)
        spec_type = "mesh"
    else:
        arr = convert_volume(load_volume(src),
                             "uint8" if args.dtype == "u8" else "float16",
                             max_dim=args.max_dim,
                             window=args.window,
                             smooth=args.smooth)
        env = volume_envelope(arr)
        spec_type = "volume"

    data_name = "specimen_0.bin"
    (out / data_name).write_bytes(env)

    pages: list[dict] = []
    if args.story:
        md = Path(args.story).read_text(encoding="utf-8")
        pages, images = parse_story(md)
        for img in images:
            img_path = Path(img)
            if img_path.is_absolute() or ".." in img_path.parts:
                print(f"error: story image path escapes bundle: {img}", file=sys.stderr)
                return 1
            src_img = Path(args.story).parent / img_path
            if not src_img.exists():
                print(f"error: story references missing image {img}", file=sys.stderr)
                return 1
            dest_img = out / img_path
            dest_img.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(src_img, dest_img)

    if spec_type == "mesh":
        display = {"shader": args.shader or "glass"}
        if getattr(args, "flip_normals", False):
            display["flip_normals"] = True
    else:
        gradient = DEFAULT_GRADIENT
        if args.colormap:
            lo, hi = args.colormap_alpha
            gradient = gradient_stops(args.colormap, alpha_lo=lo, alpha_hi=hi)
        display = {"gamma": args.gamma, "opacity": 1.0, "gradient": gradient}
    specimen = {"id": "specimen_0", "type": spec_type, "data": data_name, "display": display}
    for page in pages:
        if page["specimen"] is None:
            page["specimen"] = "specimen_0"
    manifest = make_manifest(args.title or src.stem, [specimen], pages)
    validate_manifest(manifest)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    total_mb = sum(f.stat().st_size for f in out.rglob("*") if f.is_file()) / 1e6
    if total_mb > args.size_warn_mb:
        print(f"warning: bundle is {total_mb:.0f} MB, exceeds {args.size_warn_mb} MB "
              f"(consider --max-dim or --dtype u8)", file=sys.stderr)
    print(f"bundle written to {out} ({total_mb:.1f} MB)")
    return 0


def inspect(args) -> int:
    out = Path(args.bundle)
    manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    validate_manifest(manifest)
    print(json.dumps(manifest, indent=2))
    for s in manifest["specimens"]:
        pre, payload = read_envelope((out / s["data"]).read_bytes())
        print(f"{s['id']}: {pre} payload={len(payload)} bytes")
    return 0


def _alpha_pair(text: str) -> tuple[float, float]:
    parts = text.split(",")
    if len(parts) != 2:
        raise argparse.ArgumentTypeError(f"expected LO,HI fractions, got {text!r}")
    try:
        lo, hi = (float(x) for x in parts)
    except ValueError:
        raise argparse.ArgumentTypeError(f"alpha bounds must be numbers, got {text!r}") from None
    if not 0.0 <= lo <= hi <= 1.0:
        raise argparse.ArgumentTypeError(
            f"alpha bounds must satisfy 0 <= LO <= HI <= 1, got {text!r}")
    return (lo, hi)


def _percentile_pair(text: str) -> tuple[float, float]:
    parts = text.split(",")
    if len(parts) != 2:
        raise argparse.ArgumentTypeError(f"expected LOW,HIGH percentiles, got {text!r}")
    try:
        low, high = (float(x) for x in parts)
    except ValueError:
        raise argparse.ArgumentTypeError(f"percentiles must be numbers, got {text!r}") from None
    if not 0.0 <= low < high <= 100.0:
        raise argparse.ArgumentTypeError(
            f"percentiles must satisfy 0 <= LOW < HIGH <= 100, got {text!r}")
    return (low, high)


class _EditingHandler(SimpleHTTPRequestHandler):
    """Static handler that tells the browser never to reuse a response.

    Godot's web export is a handful of big files (index.pck, index.wasm) fetched by XHR.
    `python -m http.server` sends no Cache-Control at all, so a browser -- Firefox in
    particular -- is free to heuristically cache them and keep running a stale build after a
    re-export. That shows up as fixed bugs mysteriously reappearing, which is a miserable
    thing to debug during a demo.
    """

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, fmt: str, *args) -> None:  # quieter than the default stderr spew
        print("  " + (fmt % args), file=sys.stderr)

    def do_POST(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler naming)
        """Save an edited manifest back into the bundle.

        The viewer has no way to write files itself -- a browser cannot, even from localhost --
        so authoring tools that let someone pose a specimen and tune its display need somewhere
        to send the result. This accepts a manifest for a bundle under the served directory and
        writes it, which is why it is off unless `serve --edit` asked for it.
        """
        if not self.server.allow_save:
            self._reply(403, {"error": "saving is disabled; restart with: "
                                       "ascribe-bundle serve <dir> --edit"})
            return

        target = self._resolve_manifest_path()
        if target is None:
            self._reply(404, {"error": "only <bundle>/manifest.json can be saved"})
            return

        length = int(self.headers.get("Content-Length", 0))
        try:
            manifest = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            self._reply(400, {"error": f"body is not valid JSON: {exc}"})
            return

        try:
            validate_manifest(manifest)
        except ValueError as exc:
            self._reply(400, {"error": str(exc)})
            return

        # Write via a temporary file in the same directory, so an interrupted save cannot leave
        # a half-written manifest where a valid one used to be.
        tmp = target.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        tmp.replace(target)
        self._reply(200, {"saved": str(target.name)})

    def _resolve_manifest_path(self) -> Path | None:
        """The manifest this request targets, or None if it is not one we may write."""
        path = self.path.split("?", 1)[0]
        if not path.endswith("/manifest.json"):
            return None
        root = Path(self.directory).resolve()
        candidate = (root / path.lstrip("/")).resolve()
        # Reject anything that escapes the served directory, however it was spelled.
        if not candidate.is_relative_to(root) or not candidate.parent.is_dir():
            return None
        return candidate

    def _reply(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def make_server(directory: Path, port: int = 8060,
                allow_save: bool = False) -> ThreadingHTTPServer:
    """Builds (but does not start) a no-cache static server rooted at `directory`.

    With `allow_save`, a POST to `<bundle>/manifest.json` writes that manifest back to disk --
    the escape hatch the viewer's edit mode needs, since a browser cannot write files itself.
    It stays off by default: serving a directory should not imply letting anything modify it.

    Pass `port=0` to let the OS pick a free port; read it back from `server_address`.
    """
    handler = functools.partial(_EditingHandler, directory=str(directory))
    httpd = ThreadingHTTPServer(("127.0.0.1", port), handler)
    httpd.allow_save = allow_save
    return httpd


def serve(args) -> int:
    root = Path(args.directory)
    if not root.is_dir():
        print(f"error: {root} is not a directory", file=sys.stderr)
        return 1

    httpd = make_server(root, args.port, allow_save=args.edit)
    port = httpd.server_address[1]
    mode = "no-store, saving enabled" if args.edit else "no-store"
    print(f"serving {root} at http://localhost:{port}/ ({mode}; Ctrl+C to stop)")
    if args.edit:
        print("  edit mode: append &edit=1 to the viewer URL to save view and display settings")
    print(f"  e.g. http://localhost:{port}/index.html?bundle=<bundle-dir>")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("stopped")
    finally:
        httpd.server_close()
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="ascribe-bundle")
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build", help="bake a bundle from a volume + story")
    b.add_argument("input", help=".npy / .tif volume, .stl mesh, or a pre-baked .bin envelope")
    b.add_argument("--story", help="markdown story file")
    b.add_argument("--title", default=None)
    b.add_argument("--dtype", choices=["float16", "u8"], default="float16")
    b.add_argument("--max-dim", type=int, default=None)
    b.add_argument("--smooth", type=float, default=None, metavar="SIGMA",
                   help="Gaussian-smooth the volume by SIGMA voxels after downsampling; "
                        "0.6-1.0 takes the hard edges off blocky voxels")
    b.add_argument("--window", type=_percentile_pair, default=None, metavar="LOW,HIGH",
                   help="contrast-window the volume to this percentile range, e.g. "
                        "'0.5,99.5'; stretches the band the data actually occupies across "
                        "the full output range instead of min/max scaling")
    b.add_argument("--colormap", choices=list_colormaps(), default=None,
                   help="use a named colormap as the transfer function instead of the default "
                        "gradient; the low end fades to transparent (see --colormap-alpha)")
    b.add_argument("--colormap-alpha", type=_alpha_pair, default=(0.15, 0.5), metavar="LO,HI",
                   help="where the colormap's alpha ramp starts and finishes, as fractions of "
                        "the value range (default 0.15,0.5). Everything at or below LO is "
                        "invisible; at or above HI is solid")
    b.add_argument("--gamma", type=float, default=1.0,
                   help="gamma applied to the value before the transfer function is looked up")
    b.add_argument("--shader", choices=MESH_SHADERS, default="glass",
                   help="shader to statically set in the bundle for mesh rendering (default: glass; "
                        "choices: glass, crystal, brick, water, pearl, holographic, edges, jello, hologram)")
    b.add_argument("--flip-normals", action="store_true",
                   help="invert mesh winding/normals")
    b.add_argument("--size-warn-mb", type=float, default=100)
    b.add_argument("-o", "--output", required=True)
    b.set_defaults(func=build)
    s_ = sub.add_parser("serve", help="serve a directory over HTTP with caching disabled")
    s_.add_argument("directory", help="directory to serve (usually build/web)")
    s_.add_argument("--port", type=int, default=8060)
    s_.add_argument("--edit", action="store_true",
                    help="allow the viewer to save view and display settings back into a "
                         "bundle's manifest.json (local authoring; off by default)")
    s_.set_defaults(func=serve)
    i = sub.add_parser("inspect", help="validate and describe a bundle")
    i.add_argument("bundle")
    i.set_defaults(func=inspect)
    args = p.parse_args(argv)
    return args.func(args)
