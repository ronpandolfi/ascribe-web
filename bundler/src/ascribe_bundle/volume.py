"""Load volumes from disk and convert them to web-safe dtypes."""
from __future__ import annotations

import math
from pathlib import Path

import numpy as np


def load_volume(path: Path) -> np.ndarray:
    path = Path(path)
    if path.suffix == ".npy":
        arr = np.load(path)
    elif path.suffix in (".tif", ".tiff"):
        import tifffile

        arr = tifffile.imread(path)
    else:
        raise ValueError(f"unsupported volume file type: {path.suffix}")
    if arr.ndim != 3:
        raise ValueError(f"expected a 3D volume, got shape {arr.shape}")
    return arr


def gaussian_smooth(arr: np.ndarray, sigma: float) -> np.ndarray:
    """Separable 3D Gaussian blur, implemented with numpy alone (no scipy dependency).

    Edges are handled by edge-clamping ("nearest") so a constant volume stays constant and
    the borders don't darken. The kernel is truncated at 3 sigma, which is where the tail is
    below ~1% of the peak.
    """
    if sigma < 0.0:
        raise ValueError(f"smooth sigma must be >= 0, got {sigma}")
    if sigma == 0.0:
        return arr

    radius = max(1, int(math.ceil(3.0 * sigma)))
    x = np.arange(-radius, radius + 1, dtype=np.float64)
    kernel = np.exp(-(x ** 2) / (2.0 * sigma ** 2))
    kernel /= kernel.sum()

    out = arr.astype(np.float64)
    for axis in range(3):
        padded = np.pad(out, [(radius, radius) if a == axis else (0, 0) for a in range(3)],
                        mode="edge")
        out = np.apply_along_axis(
            lambda line: np.convolve(line, kernel, mode="valid"), axis, padded)
    return out


def block_downsample(arr: np.ndarray, stride: int) -> np.ndarray:
    """Downsample by averaging each `stride`^3 block (an anti-aliased decimation).

    Taking every Nth voxel (`arr[::N, ::N, ::N]`) is cheaper but aliases: structure finer
    than the new sampling interval folds back as moire rather than disappearing, which is
    very visible in a raymarched volume. Averaging the block each output voxel covers is the
    low-pass prefilter that decimation is supposed to have.

    Ragged edges (a shape that isn't a multiple of `stride`) are handled by averaging the
    short final block rather than dropping it.
    """
    if stride <= 1:
        return arr

    out = arr.astype(np.float64)
    for axis in range(3):
        length = out.shape[axis]
        full = (length // stride) * stride
        head = np.moveaxis(out, axis, 0)
        blocks = head[:full].reshape(full // stride, stride, *head.shape[1:]).mean(axis=1)
        if full < length:  # ragged tail: average whatever is left
            blocks = np.concatenate([blocks, head[full:].mean(axis=0, keepdims=True)], axis=0)
        out = np.moveaxis(blocks, 0, axis)
    return out


def convert_volume(
    arr: np.ndarray,
    dtype: str = "float16",
    max_dim: int | None = None,
    window: tuple[float, float] | None = None,
    smooth: float | None = None,
) -> np.ndarray:
    """Downsample, contrast-window and cast a volume to a web-safe dtype.

    `window` is a (low, high) pair of *percentiles*. Voxels at or below the low percentile
    clip to the bottom of the output range, voxels at or above the high percentile clip to
    the top, and everything between is stretched linearly across the full range. Real
    tomographic reconstructions often pack 90%+ of their voxels into a narrow band with a
    few far-out outliers; plain min/max scaling then leaves the interesting structure with
    almost no contrast, so windowing (e.g. `(0.5, 99.5)`) is usually what you want.

    `max_dim` downsamples any axis longer than it, by averaging blocks rather than striding
    (see `block_downsample`) so fine structure low-passes away instead of aliasing into moire.

    `smooth` is a Gaussian sigma in voxels, applied after downsampling and before windowing.
    A little smoothing (0.6-1.0) takes the hard edges off blocky voxels without visibly
    softening real structure; `None` or 0 skips it.

    Without `window`, uint8 output is min/max scaled and float16 output is passed through
    with its original values.
    """
    if dtype not in ("float16", "uint8"):
        raise ValueError(f"dtype must be float16 or uint8, got {dtype}")

    if max_dim is not None and max(arr.shape) > max_dim:
        stride = math.ceil(max(arr.shape) / max_dim)
        arr = block_downsample(arr, stride)

    if smooth is not None and smooth > 0.0:
        arr = gaussian_smooth(arr, smooth)
    elif smooth is not None and smooth < 0.0:
        raise ValueError(f"smooth sigma must be >= 0, got {smooth}")

    if window is not None:
        low, high = window
        if not 0.0 <= low < high <= 100.0:
            raise ValueError(
                f"window percentiles must satisfy 0 <= low < high <= 100, got {window}"
            )
        a = arr.astype(np.float64)
        lo, hi = np.percentile(a, [low, high])
        if hi <= lo:
            raise ValueError(
                f"window percentiles {window} map to a degenerate range "
                f"[{lo}, {hi}] -- the volume is (near-)constant"
            )
        a = np.clip((a - lo) / (hi - lo), 0.0, 1.0)
        if dtype == "uint8":
            return np.rint(a * 255.0).astype(np.uint8)
        return a.astype(np.float16)

    if dtype == "uint8":
        a = arr.astype(np.float64)
        lo, hi = a.min(), a.max()
        scale = 255.0 / (hi - lo) if hi > lo else 0.0
        return ((a - lo) * scale).astype(np.uint8)
    return arr.astype(np.float16)

def compute_normal_volume(arr: np.ndarray) -> np.ndarray:
    """Computes normalized surface gradients (normals) for a 3D scalar volume.

    Returns an RGBA volume of shape (*arr.shape, 4) in uint8 where:
    RGB represents the normalized normal vector mapped to [0, 255] ((n + 1.0) * 0.5 * 255).
    A represents the scalar density normalized to [0, 255].
    """
    if arr.ndim != 3:
        raise ValueError(f"expected a 3D volume, got shape {arr.shape}")
    a = arr.astype(np.float32)
    gz, gy, gx = np.gradient(a)
    nx = -gx
    ny = -gy
    nz = -gz
    norm = np.sqrt(nx**2 + ny**2 + nz**2)
    norm = np.maximum(norm, 1e-6)
    nx /= norm
    ny /= norm
    nz /= norm

    r = np.clip((nx + 1.0) * 0.5 * 255.0, 0, 255).astype(np.uint8)
    g = np.clip((ny + 1.0) * 0.5 * 255.0, 0, 255).astype(np.uint8)
    b = np.clip((nz + 1.0) * 0.5 * 255.0, 0, 255).astype(np.uint8)

    lo, hi = float(a.min()), float(a.max())
    density = np.clip((a - lo) / (hi - lo) * 255.0 if hi > lo else 0.0, 0, 255).astype(np.uint8)

    return np.stack([r, g, b, density], axis=-1)
