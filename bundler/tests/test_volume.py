from pathlib import Path

import numpy as np
import pytest

from ascribe_bundle.volume import compute_normal_volume, convert_volume, load_volume


def test_load_npy(tmp_path: Path):
    arr = np.random.rand(4, 5, 6).astype(np.float32)
    p = tmp_path / "v.npy"
    np.save(p, arr)
    assert load_volume(p).shape == (4, 5, 6)


def test_load_tiff(tmp_path: Path):
    import tifffile
    arr = (np.random.rand(3, 4, 4) * 255).astype(np.uint8)
    p = tmp_path / "v.tif"
    tifffile.imwrite(p, arr)
    assert np.array_equal(load_volume(p), arr)


def test_convert_to_float16_preserves_values():
    arr = np.linspace(0, 1000, 27, dtype=np.float32).reshape(3, 3, 3)
    out = convert_volume(arr, "float16")
    assert out.dtype == np.float16
    assert np.allclose(out.astype(np.float32), arr, rtol=1e-3)


def test_convert_to_uint8_windows_minmax():
    arr = np.array([[[-5.0, 5.0]]], dtype=np.float32)
    out = convert_volume(arr, "uint8")
    assert out.dtype == np.uint8
    assert out.min() == 0 and out.max() == 255


def test_max_dim_downsamples():
    arr = np.zeros((100, 40, 100), dtype=np.float16)
    out = convert_volume(arr, "float16", max_dim=50)
    assert max(out.shape) <= 50


def test_rejects_bad_dtype():
    with pytest.raises(ValueError, match="float16 or uint8"):
        convert_volume(np.zeros((2, 2, 2)), "float32")


def test_window_stretches_percentile_range():
    # 98% of voxels in a narrow band, 2% outliers -- min/max scaling would crush the band.
    arr = np.full((10, 10, 10), 100.0, dtype=np.float32)
    arr.reshape(-1)[:5] = 0.0
    arr.reshape(-1)[5:10] = 1000.0
    arr.reshape(-1)[10:500] = 96.0
    arr.reshape(-1)[500:995] = 104.0

    plain = convert_volume(arr, "uint8")
    windowed = convert_volume(arr, "uint8", window=(1.0, 99.0))

    # Without windowing the 96..104 band collapses to a couple of levels.
    assert plain[arr == 104.0].mean() - plain[arr == 96.0].mean() < 10
    # With windowing it spans most of the 0..255 range.
    assert windowed[arr == 104.0].mean() - windowed[arr == 96.0].mean() > 100


def test_window_clips_outliers_to_endpoints():
    arr = np.linspace(0.0, 100.0, 1000, dtype=np.float32).reshape(10, 10, 10)
    out = convert_volume(arr, "uint8", window=(10.0, 90.0))
    assert out.min() == 0
    assert out.max() == 255
    assert (out == 0).sum() >= 100   # bottom decile clipped to black
    assert (out == 255).sum() >= 100  # top decile clipped to white


def test_window_requires_low_below_high():
    arr = np.ones((2, 2, 2), dtype=np.float32)
    with pytest.raises(ValueError):
        convert_volume(arr, "uint8", window=(90.0, 10.0))


def test_window_applies_to_float16_too():
    arr = np.linspace(0.0, 100.0, 1000, dtype=np.float32).reshape(10, 10, 10)
    out = convert_volume(arr, "float16", window=(10.0, 90.0))
    assert float(out.min()) == 0.0
    assert float(out.max()) == 1.0


def test_smooth_reduces_high_frequency_noise():
    rng = np.random.default_rng(0)
    smooth_field = np.linspace(0.0, 1.0, 16)[:, None, None] * np.ones((16, 16, 16))
    noisy = (smooth_field + rng.normal(0, 0.1, (16, 16, 16))).astype(np.float32)

    plain = convert_volume(noisy, "float16").astype(np.float32)
    smoothed = convert_volume(noisy, "float16", smooth=1.0).astype(np.float32)

    # Neighbour-to-neighbour variation along a noisy axis drops after smoothing.
    assert np.abs(np.diff(smoothed, axis=1)).mean() < np.abs(np.diff(plain, axis=1)).mean() / 2


def test_smooth_preserves_overall_level():
    arr = np.full((8, 8, 8), 5.0, dtype=np.float32)
    out = convert_volume(arr, "float16", smooth=1.5).astype(np.float32)
    # A constant volume must stay constant -- the kernel is normalized and edges are handled.
    assert np.allclose(out, 5.0, atol=1e-2)


def test_smooth_zero_or_none_is_a_no_op():
    arr = np.linspace(0, 1, 512, dtype=np.float32).reshape(8, 8, 8)
    base = convert_volume(arr, "float16")
    assert np.array_equal(convert_volume(arr, "float16", smooth=0.0), base)
    assert np.array_equal(convert_volume(arr, "float16", smooth=None), base)


def test_smooth_rejects_negative_sigma():
    arr = np.ones((4, 4, 4), dtype=np.float32)
    with pytest.raises(ValueError):
        convert_volume(arr, "float16", smooth=-1.0)


def test_smooth_runs_before_windowing():
    # A single hot voxel should be spread by smoothing, so the 99.9th percentile window
    # lands differently than it would on the raw spike.
    arr = np.zeros((12, 12, 12), dtype=np.float32)
    arr[6, 6, 6] = 100.0
    out = convert_volume(arr, "uint8", smooth=1.0, window=(0.0, 100.0))
    assert (out > 0).sum() > 1  # the spike has neighbours now


def test_downsampling_averages_blocks_instead_of_striding():
    # Alternating bright/dark planes 1 voxel apart -- exactly the structure that plain
    # striding aliases. Block averaging must return the local mean (~0.5), not whichever
    # phase the stride happened to land on.
    arr = np.zeros((12, 4, 4), dtype=np.float32)
    arr[::2] = 1.0

    out = convert_volume(arr, "float16", max_dim=6).astype(np.float32)

    assert out.shape == (6, 2, 2)
    assert np.allclose(out, 0.5, atol=0.01)


def test_downsampling_preserves_coarse_structure():
    # A smooth ramp must survive decimation with its overall shape intact.
    ramp = np.linspace(0.0, 1.0, 24, dtype=np.float32)[:, None, None] * np.ones((24, 8, 8))
    out = convert_volume(ramp.astype(np.float32), "float16", max_dim=12).astype(np.float32)
    assert out.shape == (12, 4, 4)
    profile = out.mean(axis=(1, 2))
    assert profile[0] < 0.1 and profile[-1] > 0.9
    assert np.all(np.diff(profile) > 0)


def test_downsampling_handles_non_multiple_shapes():
    arr = np.random.default_rng(3).random((10, 7, 5)).astype(np.float32)
    out = convert_volume(arr, "float16", max_dim=5)
    # ceil(10/5) = 2 -> every axis is halved, rounding up on ragged edges.
    assert out.shape == (5, 4, 3)

def test_compute_normal_volume_shape_and_range():
    vol = np.zeros((8, 8, 8), dtype=np.float32)
    # Put a solid sphere in the middle
    z, y, x = np.ogrid[:8, :8, :8]
    dist = np.sqrt((x - 3.5)**2 + (y - 3.5)**2 + (z - 3.5)**2)
    vol[dist < 3.0] = 1.0

    normals = compute_normal_volume(vol)
    assert normals.shape == (8, 8, 8, 4)
    assert normals.dtype == np.uint8
    assert normals.min() >= 0
    assert normals.max() <= 255
