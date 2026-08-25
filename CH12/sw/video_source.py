"""Choosing what the filter looks at: the camera, or frames from DDR.

The accelerator is a streaming block with no memory port, so "run this video
file through it" is not a software question -- there has to be a path in the PL
that plays frames from DDR into the video stream. There is:

    camera  --> csi2_rx -> demosaic -> gamma -> CSC -> channel_swap --\\
                                                                       axis_switch -> sobel -> pixel_pack -> VDMA S2MM -> DDR
    DDR --> VDMA MM2S -> pixel_unpack --------------------------------/

Both sources hand the filter the identical 48-bit two-pixel stream, so the
hardware cannot tell them apart -- which is the point. A frame played from a
file is filtered by exactly the same logic, at exactly the same rate, as a frame
from the sensor.

The switch is a two-into-one AXI4-Stream switch, and a switch with one master
port has no AXI4-Lite register map, so the selection is made through
`s_req_suppress`: one bit per input, driven from a small AXI GPIO. Suppressing
an input stops the arbiter granting it, which leaves exactly one source
connected and backpressures the other.

Backpressuring the camera is not free: the CSI-2 receiver's line buffer fills
and it starts flagging overflow. It recovers at the next start-of-frame once the
camera is selected again, but if a file is going to play for a while, turn the
receiver off with `camera_enabled(mipi, False)` and back on afterwards.
"""
import numpy as np

SOURCE_CAMERA = 0
SOURCE_FILE   = 1

# axis_switch s_req_suppress, driven by the source_select GPIO's data register.
# Bit 0 suppresses S00 (the camera), bit 1 suppresses S01 (the file player).
_SUPPRESS = {
    SOURCE_CAMERA: 0b10,      # suppress the file player
    SOURCE_FILE:   0b01,      # suppress the camera
}

_GPIO_DATA = 0x00


def select_source(mipi, source):
    """Point the filter at the camera or at the frame player.

    The reset default is the camera, so an overlay that is loaded and never
    told anything behaves as though this path did not exist.
    """
    if source not in _SUPPRESS:
        raise ValueError(f"source must be SOURCE_CAMERA or SOURCE_FILE, got {source}")
    mipi.source_select.mmio.write(_GPIO_DATA, _SUPPRESS[source])


def current_source(mipi):
    val = mipi.source_select.mmio.read(_GPIO_DATA) & 0b11
    for src, bits in _SUPPRESS.items():
        if bits == val:
            return src
    raise RuntimeError(f"source_select holds {val:#04b}, which selects neither "
                       f"source cleanly")


def camera_enabled(mipi, enable):
    """Turn the CSI-2 receiver core on or off.

    Worth doing before a long stretch of file playback: with the camera
    selected away, its pixels have nowhere to go and the receiver's line buffer
    overflows. Nothing breaks -- it resynchronises at the next frame -- but the
    error flags are noise you do not need.
    """
    mipi.mipi_csi2_rx_subsyst.register_map.core_configuration.core_enabled = int(bool(enable))


class FramePlayer:
    """Plays frames from DDR into the filter through the VDMA's MM2S channel.

    Usage:

        player = FramePlayer(mipi, 1280, 720)
        with player:
            player.play(frame)                 # a (H, W, 3) uint8 BGR array
            out = mipi.readframe()             # the filtered result

    Note the width constraint. pixel_unpack turns three 64-bit words into four
    48-bit beats, so a line has to be a whole number of those groups: the width
    must be a multiple of 8. Both camera modes (1280 and 1920) are.
    """

    def __init__(self, mipi, width, height):
        if width % 8:
            raise ValueError(f"width must be a multiple of 8 for the frame "
                             f"player, got {width}")
        from pynq.lib.video import VideoMode

        self._mipi = mipi
        self._vdma = mipi.axi_vdma
        self.width = width
        self.height = height
        self._mode = VideoMode(width, height, 24)
        self._started = False

    def start(self):
        self._mipi.pixel_unpack.bits_per_pixel = 24
        self._vdma.writechannel.mode = self._mode
        self._vdma.writechannel.start()
        select_source(self._mipi, SOURCE_FILE)
        self._started = True
        return self

    def stop(self, restore_camera=True):
        if self._started:
            self._vdma.writechannel.stop()
            self._started = False
        if restore_camera:
            select_source(self._mipi, SOURCE_CAMERA)

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()
        return False

    def play(self, frame):
        """Push one (H, W, 3) uint8 BGR frame into the filter."""
        if frame.shape != (self.height, self.width, 3):
            raise ValueError(f"expected {(self.height, self.width, 3)}, "
                             f"got {frame.shape}")
        buf = self._vdma.writechannel.newframe()
        buf[:] = frame
        self._vdma.writechannel.writeframe(buf)


def test_pattern(width, height):
    """A deterministic frame with edges in both directions.

    This is what makes a bit-exact check against the software reference
    possible on hardware. With the camera there is no way to know what went
    into the filter -- the sensor is still exposing, and the frame before the
    one you filtered is not the frame you filtered. Play a known pattern in
    instead and the comparison has an exact answer.
    """
    y, x = np.mgrid[0:height, 0:width]
    b = ((x * 255) // max(width - 1, 1)).astype(np.uint8)
    g = ((y * 255) // max(height - 1, 1)).astype(np.uint8)
    r = (((x // 16) + (y // 16)) % 2 * 200).astype(np.uint8)     # checkerboard

    frame = np.dstack([b, g, r])

    # a hard-edged bright box, so there is something Sobel obviously fires on
    frame[height//4:3*height//4, width//4:3*width//4] = 240
    # and a one-pixel line, which is where an off-by-one column shows up
    frame[:, width//2] = 0
    return np.ascontiguousarray(frame)
