#!/usr/bin/env python3
"""The software reference design: camera in, Sobel, DisplayPort out.

The same pipeline the PL implements, with the filter done by the A53s instead:

    Pcam 5C -> MIPI front end (PL) -> DDR -> [ A53: filter ] -> DPDMA -> DP

Note what is still hardware even here. The MIPI receiver, the demosaic, the
gamma LUT and the colour-space converter are in the PL in every version of this
design -- there is no way to get RAW10 off a D-PHY into a Python process
otherwise. What moves between "software" and "hardware" is the *filter*, which
is the part the chapter is actually about. In software mode the PL filter is
put into colour passthrough so it does nothing, and NumPy or OpenCV does the
work on the frame after the VDMA has written it to DDR.

    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 \\
        video_sobel.py --impl numpy

The pixels can come from the camera or from DDR -- a video file, a still, or the
built-in test pattern -- because the PL has a path for both and a switch to
choose between them:

    video_sobel.py --source file --video clip.mp4 --impl pl

Root is required (programming the PL, opening the DRM device) and XILINX_XRT
must be set -- /etc/profile.d/xrt_setup.sh does not run for non-interactive
shells.

Run the same thing with --impl pl to see the accelerator do it, which is the
comparison the chapter is built around: the software filter costs milliseconds
per frame and the streaming one costs nothing, because it is not in the frame
loop at all -- it is in the pixel path, several stages upstream of DDR.
"""
import argparse
import os
import signal
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sobel_ref                                            # noqa: E402
import video_source as vs                                   # noqa: E402

DP_STATUS = "/sys/class/drm/card0-DP-1/status"

MODES = [sobel_ref.MODE_SOBEL, sobel_ref.MODE_GRAY,
         sobel_ref.MODE_INVERT, sobel_ref.MODE_COLOR]


def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--impl", choices=("numpy", "opencv", "pl"), default="numpy",
                   help="who does the filtering (default: numpy)")
    p.add_argument("--source", choices=("camera", "file"), default="camera",
                   help="where the pixels come from (default: camera)")
    p.add_argument("--video", default="pattern",
                   help="with --source file: a video file, an image file, or "
                        "'pattern' for the built-in test pattern (default)")
    p.add_argument("--bitstream", default="sobel_stream.bit",
                   help="overlay to load (default: sobel_stream.bit)")
    p.add_argument("--mode", type=int, default=sobel_ref.MODE_SOBEL,
                   help="0 gray, 1 sobel, 2 invert, 3 colour (default: 1)")
    p.add_argument("--cycle", action="store_true",
                   help="cycle through all four modes instead of holding one")
    p.add_argument("--interval", type=float, default=3.0,
                   help="seconds per mode when cycling (default: 3)")
    p.add_argument("--duration", type=float, default=30.0,
                   help="seconds to run (default 30; --hold overrides)")
    p.add_argument("--hold", action="store_true",
                   help="run until stopped")
    p.add_argument("--width", type=int, default=1280)
    p.add_argument("--height", type=int, default=720)
    return p.parse_args()


# --------------------------------------------------------------------------
# systemd stops a unit with SIGTERM, whose default disposition kills the
# interpreter outright -- no finally block, so the DisplayPort is never
# released and the camera keeps writing into freed buffers. Turning the signal
# into an exception lets the normal cleanup path run.
# --------------------------------------------------------------------------
class Stop(Exception):
    pass


def _on_signal(signum, frame):
    raise Stop(signal.Signals(signum).name)


def main():
    args = parse_args()

    if os.geteuid() != 0:
        sys.exit("must run as root (needs the PL and /dev/dri) -- use sudo")

    try:
        with open(DP_STATUS) as fh:
            status = fh.read().strip()
        if status != "connected":
            sys.exit(f"no monitor: {DP_STATUS} reads '{status}'")
    except FileNotFoundError:
        sys.exit(f"no DisplayPort connector found at {DP_STATUS}")

    if not os.path.exists(args.bitstream):
        sys.exit(f"missing file: {args.bitstream}")

    from pynq import Overlay
    from pynq.lib.video import DisplayPort, VideoMode, PIXEL_RGB

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    W, H = args.width, args.height

    print(f"1. Overlay: {args.bitstream}")
    ol = Overlay(args.bitstream)
    mipi = ol.mipi
    sobel = ol.mipi.sobel

    # The filter needs the geometry whatever it is going to do with it: without
    # it the block cannot know where a line ends, and it drains the stream
    # rather than filtering it.
    sobel.register_map.img_width = W
    sobel.register_map.img_height = H

    if args.impl == "pl":
        print(f"2. Filtering in the PL, mode {args.mode}")
    else:
        # Colour passthrough: the accelerator forwards the stream untouched and
        # the A53s do the work.
        sobel.register_map.mode = sobel_ref.MODE_COLOR
        print(f"2. Filtering on the A53s with {args.impl}")

    mipi.configure(VideoMode(W, H, 24))
    mipi.start()

    # --- where the pixels come from ------------------------------------
    # Both sources hand the filter the identical stream, so nothing below this
    # point cares which one is running. `feed` is either a no-op (the camera is
    # already producing) or a call that pushes the next frame into DDR for the
    # VDMA to play back.
    player = None
    capture = None
    still = None

    if args.source == "camera":
        vs.select_source(mipi, vs.SOURCE_CAMERA)
        print(f"   camera streaming {W}x{H}")
    else:
        player = vs.FramePlayer(mipi, W, H).start()
        vs.camera_enabled(mipi, False)
        if args.video == "pattern":
            still = vs.test_pattern(W, H)
            print(f"   playing the built-in test pattern at {W}x{H}")
        else:
            if not os.path.exists(args.video):
                sys.exit(f"missing file: {args.video}")
            import cv2
            capture = cv2.VideoCapture(args.video)
            if capture.isOpened() and capture.read()[0]:
                capture.set(cv2.CAP_PROP_POS_FRAMES, 0)
                print(f"   playing {args.video} at {W}x{H}")
            else:
                # not a video, or no codec for it -- try it as a still
                capture.release()
                capture = None
                img = cv2.imread(args.video)
                if img is None:
                    sys.exit(f"could not read {args.video} as video or image")
                still = np.ascontiguousarray(cv2.resize(img, (W, H)))
                print(f"   playing {args.video} as a still at {W}x{H}")

    def feed():
        """Put the next frame into the pipeline. Returns False at end of file."""
        if player is None:
            return True
        if capture is not None:
            ok, frm = capture.read()
            if not ok:
                capture.set(cv2.CAP_PROP_POS_FRAMES, 0)      # loop
                ok, frm = capture.read()
                if not ok:
                    return False
            if frm.shape[:2] != (H, W):
                frm = cv2.resize(frm, (W, H))
            player.play(np.ascontiguousarray(frm))
        else:
            player.play(still)
        return True

    dp = DisplayPort()
    dp.configure(VideoMode(W, H, 24), PIXEL_RGB)
    print(f"   DisplayPort {W}x{H}")

    filt = (sobel_ref.filter_frame_opencv if args.impl == "opencv"
            else sobel_ref.filter_frame)

    modes = MODES if args.cycle else [args.mode]
    mode_i = 0
    mode = modes[0]
    if args.impl == "pl":
        sobel.register_map.mode = mode

    frames = 0
    t_filter = 0.0
    t_start = time.perf_counter()
    t_mode = t_start
    t_end = t_start + args.duration
    rc = 0

    print("3. Running" + ("" if args.hold else f" for {args.duration:.0f}s"))
    try:
        while args.hold or time.perf_counter() < t_end:
            if not feed():
                break
            frame = mipi.readframe()

            if args.impl == "pl":
                out = frame
            else:
                t0 = time.perf_counter()
                out = filt(frame, mode)
                t_filter += time.perf_counter() - t0

            # The video stream is B,G,R whichever source it came from, and the
            # DisplayPort is configured for R,G,B, so the channels are reversed
            # on the way out.
            dp_frame = dp.newframe()
            dp_frame[:] = out[:, :, ::-1]
            dp.writeframe(dp_frame)

            frames += 1
            now = time.perf_counter()

            if args.cycle and now - t_mode >= args.interval:
                mode_i = (mode_i + 1) % len(modes)
                mode = modes[mode_i]
                t_mode = now
                if args.impl == "pl":
                    sobel.register_map.mode = mode
                print(f"   mode -> {sobel_ref.MODE_NAMES[mode]}")

            if frames % 30 == 0:
                elapsed = now - t_start
                msg = f"   {frames} frames, {frames / elapsed:5.1f} fps"
                if args.impl != "pl":
                    msg += f", {t_filter / frames * 1e3:6.2f} ms/frame in the filter"
                print(msg)

    except Stop as why:
        print(f"\n   stopping on {why}")
    except KeyboardInterrupt:
        print("\n   interrupted")
    except Exception as exc:                                # noqa: BLE001
        print(f"\n   error: {exc}")
        rc = 1
    finally:
        elapsed = time.perf_counter() - t_start
        if frames:
            print(f"\n   {frames} frames in {elapsed:.1f}s = {frames / elapsed:.1f} fps")
            if args.impl != "pl":
                print(f"   filter alone: {t_filter / frames * 1e3:.2f} ms/frame "
                      f"({t_filter / elapsed * 100:.0f}% of the time)")
        dp.close()
        if capture is not None:
            capture.release()
        if player is not None:
            player.stop()                 # restores the camera as the source
            vs.camera_enabled(mipi, True)
        mipi.stop()
        print("4. DisplayPort and camera released")
    return rc


if __name__ == "__main__":
    sys.exit(main())
