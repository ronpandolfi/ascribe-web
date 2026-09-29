import json
from pathlib import Path

import numpy as np

from ascribe_bundle.cli import main


def test_build_creates_bundle(tmp_path: Path):
    vol = tmp_path / "v.npy"
    np.save(vol, np.random.rand(8, 8, 8).astype(np.float32))
    story = tmp_path / "story.md"
    story.write_text("Hello volume.")
    out = tmp_path / "out"
    rc = main(["build", str(vol), "--story", str(story), "--title", "T", "-o", str(out)])
    assert rc == 0
    manifest = json.loads((out / "manifest.json").read_text())
    assert manifest["version"] == 1
    assert (out / manifest["specimens"][0]["data"]).exists()


def test_build_warns_on_size(tmp_path: Path, capsys):
    vol = tmp_path / "v.npy"
    np.save(vol, np.zeros((64, 64, 64), dtype=np.float32))
    out = tmp_path / "out"
    main(["build", str(vol), "-o", str(out), "--size-warn-mb", "0"])
    assert "exceeds" in capsys.readouterr().err


def test_build_preserves_story_image_subdirs(tmp_path: Path):
    vol = tmp_path / "v.npy"
    np.save(vol, np.random.rand(8, 8, 8).astype(np.float32))

    figs_dir = tmp_path / "figs"
    figs_dir.mkdir()
    (figs_dir / "fig1.png").write_bytes(b"\x89PNG\r\n\x1a\n")

    story = tmp_path / "story.md"
    story.write_text("![a figure](figs/fig1.png)\n")

    out = tmp_path / "out"
    rc = main(["build", str(vol), "--story", str(story), "-o", str(out)])
    assert rc == 0

    # Text keeps the subdir path, so the copied image must live at the same relative path.
    assert (out / "figs" / "fig1.png").exists()
    manifest = json.loads((out / "manifest.json").read_text())
    assert "figs/fig1.png" in manifest["story"][0]["text"]


def test_build_rejects_story_image_path_escape(tmp_path: Path, capsys):
    vol = tmp_path / "v.npy"
    np.save(vol, np.random.rand(8, 8, 8).astype(np.float32))

    outside_dir = tmp_path.parent / "outside_secret"
    outside_dir.mkdir(exist_ok=True)
    (outside_dir / "leak.png").write_bytes(b"\x89PNG\r\n\x1a\n")

    story = tmp_path / "story.md"
    story.write_text("![leak](../outside_secret/leak.png)\n")

    out = tmp_path / "out"
    rc = main(["build", str(vol), "--story", str(story), "-o", str(out)])
    assert rc == 1
    assert "escapes bundle" in capsys.readouterr().err
    assert not (out / "leak.png").exists()


def test_window_flag_is_applied(tmp_path):
    import numpy as np
    from ascribe_bundle.cli import main
    from ascribe_bundle.envelope import read_envelope

    arr = np.full((8, 8, 8), 100.0, dtype=np.float32)
    arr.reshape(-1)[0] = 0.0
    arr.reshape(-1)[1] = 1000.0
    arr.reshape(-1)[2:250] = 96.0
    src = tmp_path / "v.npy"
    np.save(src, arr)

    out = tmp_path / "out"
    assert main(["build", str(src), "--dtype", "u8", "--window", "1,99",
                 "-o", str(out)]) == 0
    _, payload = read_envelope((out / "specimen_0.bin").read_bytes())
    voxels = np.frombuffer(payload, dtype=np.uint8)
    assert voxels.max() == 255 and voxels.min() == 0


def test_window_flag_rejects_bad_range(tmp_path, capsys):
    import numpy as np
    import pytest
    from ascribe_bundle.cli import main

    src = tmp_path / "v.npy"
    np.save(src, np.zeros((4, 4, 4), dtype=np.float32))
    with pytest.raises(SystemExit):
        main(["build", str(src), "--window", "99,1", "-o", str(tmp_path / "o")])


def test_smooth_flag_is_applied(tmp_path):
    import numpy as np
    from ascribe_bundle.cli import main
    from ascribe_bundle.envelope import read_envelope

    rng = np.random.default_rng(1)
    arr = rng.normal(0.5, 0.2, (12, 12, 12)).astype(np.float32)
    src = tmp_path / "v.npy"
    np.save(src, arr)

    plain_out = tmp_path / "plain"
    smooth_out = tmp_path / "smooth"
    assert main(["build", str(src), "-o", str(plain_out)]) == 0
    assert main(["build", str(src), "--smooth", "1.0", "-o", str(smooth_out)]) == 0

    def voxels(d):
        _, payload = read_envelope((d / "specimen_0.bin").read_bytes())
        return np.frombuffer(payload, dtype=np.float16).astype(np.float32).reshape(12, 12, 12)

    assert np.abs(np.diff(voxels(smooth_out), axis=0)).mean() < \
        np.abs(np.diff(voxels(plain_out), axis=0)).mean() / 2


def _get(port, path="/index.html"):
    import urllib.request
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}") as resp:
        return resp.status, resp.headers, resp.read()


def _running_server(tmp_path):
    import threading
    from ascribe_bundle.cli import make_server

    httpd = make_server(tmp_path, port=0)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def test_serve_sends_no_store_headers(tmp_path):
    (tmp_path / "index.html").write_text("<h1>hi</h1>", encoding="utf-8")
    httpd = _running_server(tmp_path)
    try:
        status, headers, body = _get(httpd.server_address[1])
        assert status == 200
        assert body == b"<h1>hi</h1>"
        # Browsers (Firefox especially) otherwise reuse a cached index.pck/wasm across a
        # re-export and silently run the old build.
        assert "no-store" in headers["Cache-Control"]
        assert headers["Pragma"] == "no-cache"
        assert headers["Expires"] == "0"
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_serve_serves_from_the_requested_directory(tmp_path):
    site = tmp_path / "site"
    site.mkdir()
    (site / "index.html").write_text("served", encoding="utf-8")
    (tmp_path / "outside.txt").write_text("secret", encoding="utf-8")

    httpd = _running_server(site)
    try:
        port = httpd.server_address[1]
        assert _get(port)[2] == b"served"
        import urllib.error
        import pytest
        with pytest.raises(urllib.error.HTTPError):
            _get(port, "/outside.txt")
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_serve_rejects_a_missing_directory(tmp_path, capsys):
    from ascribe_bundle.cli import main
    assert main(["serve", str(tmp_path / "nope")]) == 1
    assert "not a directory" in capsys.readouterr().err


def test_gen_cube_is_uniform_inside_and_oblique(tmp_path):
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "demo"))
    import numpy as np
    from gen_cube import rotated_cube

    vol = rotated_cube(size=64, edge_voxels=2.0)

    # The control is only useful if the interior is genuinely featureless: any pattern seen on
    # its faces in the viewer must come from rendering, not from the data.
    assert vol[vol > 0.999].std() < 1e-4
    assert 0.02 < float((vol > 0.5).mean()) < 0.5

    # ...and no face may be axis-aligned, or the test would not exercise oblique sampling.
    # A face parallel to a bounding-box plane would make whole slices identical.
    filled = vol > 0.5
    for axis in range(3):
        counts = filled.sum(axis=tuple(i for i in range(3) if i != axis))
        occupied = counts[counts > 0]
        assert occupied.min() < occupied.max() * 0.9


def test_colormap_flag_writes_the_colormap_gradient(tmp_path):
    import numpy as np
    from ascribe_bundle.cli import main

    src = tmp_path / "v.npy"
    np.save(src, np.linspace(0, 1, 512, dtype=np.float32).reshape(8, 8, 8))
    out = tmp_path / "out"
    assert main(["build", str(src), "--colormap", "viridis", "-o", str(out)]) == 0

    manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    gradient = manifest["specimens"][0]["display"]["gradient"]
    assert len(gradient) > 4
    # First stop transparent, and not black -- see colormaps.gradient_stops.
    assert gradient[0][1].endswith("00")
    assert gradient[0][1][:7] != "#000000"
    assert gradient[-1][1].endswith("ff")


def test_colormap_alpha_bounds_are_applied(tmp_path):
    import numpy as np
    from ascribe_bundle.cli import main

    src = tmp_path / "v.npy"
    np.save(src, np.linspace(0, 1, 512, dtype=np.float32).reshape(8, 8, 8))
    out = tmp_path / "out"
    assert main(["build", str(src), "--colormap", "magma",
                 "--colormap-alpha", "0.4,0.8", "-o", str(out)]) == 0

    gradient = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    stops = gradient["specimens"][0]["display"]["gradient"]
    for offset, hexcode in stops:
        alpha = int(hexcode[7:9], 16)
        if offset <= 0.4:
            assert alpha == 0
        if offset >= 0.8:
            assert alpha == 255


def test_bad_colormap_alpha_is_rejected(tmp_path):
    import numpy as np
    import pytest
    from ascribe_bundle.cli import main

    src = tmp_path / "v.npy"
    np.save(src, np.zeros((4, 4, 4), dtype=np.float32))
    with pytest.raises(SystemExit):
        main(["build", str(src), "--colormap", "viridis",
              "--colormap-alpha", "0.9,0.1", "-o", str(tmp_path / "o")])


def _start(directory, allow_save):
    import threading
    from ascribe_bundle.cli import make_server

    httpd = make_server(directory, port=0, allow_save=allow_save)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def _post(port, path, payload):
    import urllib.error
    import urllib.request
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", data=json.dumps(payload).encode("utf-8"),
        method="POST", headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def _bundle(tmp_path):
    from ascribe_bundle.manifest import DEFAULT_GRADIENT, make_manifest
    d = tmp_path / "b"
    d.mkdir()
    specimen = {"id": "specimen_0", "type": "volume", "data": "specimen_0.bin",
                "display": {"gamma": 1.0, "opacity": 1.0, "gradient": DEFAULT_GRADIENT}}
    manifest = make_manifest("t", [specimen], [])
    (d / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return d, manifest


def test_save_writes_the_manifest_when_editing_is_enabled(tmp_path):
    d, manifest = _bundle(tmp_path)
    httpd = _start(tmp_path, allow_save=True)
    try:
        manifest["view"] = "1.0,0.5,2.0"
        manifest["specimens"][0]["display"]["gamma"] = 2.5
        status, _ = _post(httpd.server_address[1], "/b/manifest.json", manifest)
        assert status == 200

        written = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
        assert written["view"] == "1.0,0.5,2.0"
        assert written["specimens"][0]["display"]["gamma"] == 2.5
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_save_is_refused_unless_explicitly_enabled(tmp_path):
    d, manifest = _bundle(tmp_path)
    httpd = _start(tmp_path, allow_save=False)
    try:
        status, _ = _post(httpd.server_address[1], "/b/manifest.json", manifest)
        assert status == 403
        # ...and the file on disk is untouched.
        assert "view" not in json.loads((d / "manifest.json").read_text(encoding="utf-8"))
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_save_rejects_an_invalid_manifest(tmp_path):
    d, manifest = _bundle(tmp_path)
    httpd = _start(tmp_path, allow_save=True)
    try:
        broken = dict(manifest)
        broken["specimens"] = [{"id": "x"}]        # missing required keys
        status, body = _post(httpd.server_address[1], "/b/manifest.json", broken)
        assert status == 400
        assert b"invalid" in body.lower()
        # The existing bundle must survive a bad save.
        assert json.loads((d / "manifest.json").read_text(encoding="utf-8"))["specimens"][0]["id"]
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_save_only_accepts_manifest_paths(tmp_path):
    _bundle(tmp_path)
    httpd = _start(tmp_path, allow_save=True)
    try:
        status, _ = _post(httpd.server_address[1], "/b/specimen_0.bin", {"x": 1})
        assert status == 404
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_save_refuses_to_escape_the_served_directory(tmp_path):
    _bundle(tmp_path)
    outside = tmp_path.parent / "outside.json"
    httpd = _start(tmp_path, allow_save=True)
    try:
        status, _ = _post(httpd.server_address[1], "/../outside/manifest.json", {"version": 1})
        assert status in (400, 403, 404)
        assert not outside.exists()
    finally:
        httpd.shutdown()
        httpd.server_close()


from ascribe_bundle.envelope import read_envelope


def test_build_mesh_stl(tmp_path: Path):
    stl_content = """solid triangle
  facet normal 0.0 0.0 1.0
    outer loop
      vertex 0.0 0.0 0.0
      vertex 1.0 0.0 0.0
      vertex 0.0 1.0 0.0
    endloop
  endfacet
endsolid triangle
"""
    stl_file = tmp_path / "model.stl"
    stl_file.write_text(stl_content, encoding="utf-8")

    out = tmp_path / "out_mesh"
    rc = main(["build", str(stl_file), "--shader", "crystal", "-o", str(out)])
    assert rc == 0

    manifest = json.loads((out / "manifest.json").read_text())
    assert manifest["version"] == 1
    assert manifest["specimens"][0]["type"] == "mesh"
    assert manifest["specimens"][0]["display"]["shader"] == "crystal"

    bin_data = (out / manifest["specimens"][0]["data"]).read_bytes()
    pre, payload = read_envelope(bin_data)
    assert pre["type"] == "mesh"
    assert pre["vertex_count"] == 3
    assert pre["index_count"] == 3
    assert pre["normal_count"] == 3


def test_build_mesh_default_shader(tmp_path: Path):
    stl_content = """solid triangle
  facet normal 0.0 0.0 1.0
    outer loop
      vertex 0.0 0.0 0.0
      vertex 1.0 0.0 0.0
      vertex 0.0 1.0 0.0
    endloop
  endfacet
endsolid triangle
"""
    stl_file = tmp_path / "model.stl"
    stl_file.write_text(stl_content, encoding="utf-8")

    out = tmp_path / "out_mesh_default"
    rc = main(["build", str(stl_file), "-o", str(out)])
    assert rc == 0

    manifest = json.loads((out / "manifest.json").read_text())
    assert manifest["specimens"][0]["display"]["shader"] == "glass"
