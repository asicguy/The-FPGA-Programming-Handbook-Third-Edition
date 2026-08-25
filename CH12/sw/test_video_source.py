"""Tests for the source selection and the test pattern.

These run on a laptop. Most of video_source.py is hardware, but the two parts
that are easy to get silently wrong are not:

  * the suppress bits. `s_req_suppress` names the input to *stop*, so the
    mapping is inverted from how you would say it out loud, and getting it
    backwards produces a design that hangs rather than one that shows the wrong
    picture -- an hour on the bench to find, a second to check here.
  * the test pattern, which is the input the on-hardware bit-exact check is
    built on. If it were not deterministic that check would be meaningless.

    pytest -q test_video_source.py
    python3 test_video_source.py
"""
import numpy as np

import video_source as vs
import sobel_ref


class FakeMMIO:
    def __init__(self):
        self.regs = {}

    def write(self, offset, value):
        self.regs[offset] = value

    def read(self, offset):
        return self.regs.get(offset, 0)


class FakeIP:
    def __init__(self):
        self.mmio = FakeMMIO()


class FakeMipi:
    """Stands in for the PYNQ hierarchy -- a process boundary, not our code."""
    def __init__(self):
        self.source_select = FakeIP()


# --------------------------------------------------------------------------
# source selection
# --------------------------------------------------------------------------

def test_camera_is_selected_by_suppressing_the_file_player():
    mipi = FakeMipi()
    vs.select_source(mipi, vs.SOURCE_CAMERA)
    assert mipi.source_select.mmio.regs[0x00] == 0b10


def test_file_is_selected_by_suppressing_the_camera():
    mipi = FakeMipi()
    vs.select_source(mipi, vs.SOURCE_FILE)
    assert mipi.source_select.mmio.regs[0x00] == 0b01


def test_exactly_one_input_is_suppressed_either_way():
    # Suppressing both stalls the filter; suppressing neither lets the two
    # sources interleave their lines into one frame.
    for bits in vs._SUPPRESS.values():
        assert bin(bits & 0b11).count("1") == 1


def test_the_gpio_reset_default_selects_the_camera():
    # C_DOUT_DEFAULT in build_bd.tcl is 0x2, so an overlay nobody has spoken to
    # behaves as it did before the file path existed.
    assert vs._SUPPRESS[vs.SOURCE_CAMERA] == 0b10


def test_current_source_reads_back_what_was_written():
    mipi = FakeMipi()
    for src in (vs.SOURCE_CAMERA, vs.SOURCE_FILE):
        vs.select_source(mipi, src)
        assert vs.current_source(mipi) == src


def test_an_unknown_source_is_rejected():
    try:
        vs.select_source(FakeMipi(), 7)
    except ValueError:
        return
    raise AssertionError("an unknown source should raise ValueError")


# --------------------------------------------------------------------------
# the test pattern
# --------------------------------------------------------------------------

def test_pattern_has_the_shape_and_type_the_player_wants():
    f = vs.test_pattern(64, 32)
    assert f.shape == (32, 64, 3)
    assert f.dtype == np.uint8
    assert f.flags["C_CONTIGUOUS"]


def test_pattern_is_deterministic():
    assert np.array_equal(vs.test_pattern(64, 32), vs.test_pattern(64, 32))


def test_pattern_contains_edges_for_sobel_to_find():
    out = sobel_ref.filter_frame(vs.test_pattern(64, 32), sobel_ref.MODE_SOBEL)
    # a good fraction of the frame should be non-black, and something should
    # saturate -- a pattern Sobel barely responds to would prove nothing
    assert (out > 0).mean() > 0.2
    assert out.max() == 255


def test_pattern_can_be_filtered_by_the_reference_at_camera_sizes():
    for w, h in ((1280, 720), (1920, 1080)):
        f = vs.test_pattern(w, h)
        assert sobel_ref.filter_frame(f, sobel_ref.MODE_SOBEL).shape == (h, w, 3)


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"  PASS  {name}")
            except Exception as exc:                       # noqa: BLE001
                failures += 1
                print(f"  FAIL  {name}: {exc}")
    print("TEST PASSED" if failures == 0 else f"TEST FAILED -- {failures} failures")
    raise SystemExit(1 if failures else 0)
