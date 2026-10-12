import pytest

from ascribe_bundle.manifest import make_manifest, validate_manifest


def _specimen():
    return {"id": "vol0", "type": "volume", "data": "specimen_0.bin",
            "display": {"gamma": 1.0, "opacity": 1.0,
                        "gradient": [[0.0, "#00000000"], [1.0, "#ffe6b3ff"]]}}


def test_make_and_validate_roundtrip():
    m = make_manifest("My Data", [_specimen()], [{"text": "hello", "specimen": "vol0"}])
    validate_manifest(m)  # should not raise
    assert m["version"] == 1


def test_validate_rejects_wrong_version():
    m = make_manifest("t", [_specimen()], [])
    m["version"] = 2
    with pytest.raises(ValueError, match="version"):
        validate_manifest(m)


def test_validate_rejects_story_referencing_unknown_specimen():
    m = make_manifest("t", [_specimen()], [{"text": "x", "specimen": "nope"}])
    with pytest.raises(ValueError, match="unknown specimen"):
        validate_manifest(m)


def test_view_accepts_a_pose_string():
    from ascribe_bundle.manifest import DEFAULT_GRADIENT, make_manifest, validate_manifest
    specimen = {"id": "s", "type": "volume", "data": "s.bin",
                "display": {"gamma": 1.0, "opacity": 1.0, "gradient": DEFAULT_GRADIENT}}
    m = make_manifest("t", [specimen], [])
    m["view"] = "2.9267,-0.4002,0.5811"
    validate_manifest(m)


def test_view_rejects_a_malformed_pose():
    import pytest
    from ascribe_bundle.manifest import DEFAULT_GRADIENT, make_manifest, validate_manifest
    specimen = {"id": "s", "type": "volume", "data": "s.bin",
                "display": {"gamma": 1.0, "opacity": 1.0, "gradient": DEFAULT_GRADIENT}}
    m = make_manifest("t", [specimen], [])
    m["view"] = "not a pose"
    with pytest.raises(ValueError):
        validate_manifest(m)


def _mesh(display):
    return {"id": "m0", "type": "mesh", "data": "specimen_0.bin", "display": display}


def test_validate_accepts_mesh_surface_display():
    m = make_manifest("t", [_mesh({"shader": "surface", "color": "#d4af37", "opacity": 0.4,
                                   "roughness": 0.5, "metallic": 0.0, "rim": 0.3,
                                   "inner_surfaces": True})], [])
    validate_manifest(m)


def test_validate_rejects_malformed_mesh_color():
    m = make_manifest("t", [_mesh({"color": "gold"})], [])
    with pytest.raises(ValueError):
        validate_manifest(m)

