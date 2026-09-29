"""Bundle manifest construction and validation (schema version 1)."""
from __future__ import annotations

import jsonschema

SCHEMA = {
    "type": "object",
    "required": ["version", "title", "specimens", "story"],
    "properties": {
        "version": {"const": 1},
        "title": {"type": "string"},
        "specimens": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["id", "type", "data", "display"],
                "properties": {
                    "id": {"type": "string"},
                    "type": {"enum": ["volume", "mesh"]},
                    "data": {"type": "string"},
                    "display": {
                        "type": "object",
                        "properties": {
                            "gamma": {"type": "number"},
                            "opacity": {"type": "number"},
                            "gradient": {"type": "array", "items": {
                                "type": "array", "prefixItems": [
                                    {"type": "number"}, {"type": "string"}]}},
                            "shader": {"type": "string"},
                            "flip_normals": {"type": "boolean"},
                        },
                    },
                },
            },
        },
        # Optional default camera framing, as "yaw,pitch,distance" (radians, radians, metres)
        # -- the same spelling the viewer's `?view=` parameter and its edit mode use, so a view
        # can be shared as a URL and then saved into the bundle as its default.
        "view": {"type": "string", "pattern": r"^-?\d*\.?\d+,-?\d*\.?\d+,-?\d*\.?\d+$"},
        "story": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["text"],
                "properties": {"text": {"type": "string"},
                               "specimen": {"type": ["string", "null"]}},
            },
        },
    },
}

DEFAULT_GRADIENT = [[0.0, "#00000000"], [1.0, "#ffe6b3ff"]]


def make_manifest(title: str, specimens: list[dict], story: list[dict]) -> dict:
    return {"version": 1, "title": title, "specimens": specimens, "story": story}


def validate_manifest(m: dict) -> None:
    try:
        jsonschema.validate(m, SCHEMA)
    except jsonschema.ValidationError as e:
        raise ValueError(f"manifest invalid ({'/'.join(map(str, e.path)) or 'version'}): {e.message}") from e
    ids = {s["id"] for s in m["specimens"]}
    for page in m["story"]:
        pin = page.get("specimen")
        if pin is not None and pin not in ids:
            raise ValueError(f"story page pins unknown specimen '{pin}'")