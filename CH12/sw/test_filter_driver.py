#!/usr/bin/env python3
"""Tests for the CH12 accelerator driver.

    python3 test_filter_driver.py

No board and no PYNQ needed. The driver talks to the accelerator through
`read(offset)` / `write(offset, value)` -- PYNQ's `DefaultIP` interface, and the
hardware boundary -- so that is what gets mocked, and nothing else. The clock is
injected for the same reason.

Most of this file is about the register map. Getting an offset wrong does not
produce a wrong picture, it produces an accelerator that never asserts done and
a notebook that hangs, which is a slow thing to debug on a board and a fast
thing to check here.
"""
import unittest

import numpy as np

import filter_driver as fd
import sobel_ref as ref


class FakeIP:
    """Stands in for a PYNQ DefaultIP. Records writes, scripts CTRL reads."""

    def __init__(self, done_after=1, clock=None):
        self.writes = []
        self.reads = 0
        self._done_after = done_after
        self._clock = clock
        self.regs = {}

    def write(self, offset, value):
        self.writes.append((offset, value))
        self.regs[offset] = value

    def read(self, offset):
        if offset == fd.REG_CTRL:
            self.reads += 1
            if self._clock is not None:
                self._clock.advance()
            return fd.CTRL_AP_DONE if self.reads >= self._done_after else 0
        return self.regs.get(offset, 0)

    def written(self, offset):
        for off, val in reversed(self.writes):
            if off == offset:
                return val
        raise AssertionError(f"nothing was written to offset {offset:#x}")


class ReadTrapIP:
    """A DefaultIP whose registers must not be touched at construction.

    On this board an IP can be held in reset when its driver is built, and a
    transaction to one does not raise -- it wedges the CPU with no console.
    So construction is required to be inert, and this fails loudly instead.
    """

    def read(self, offset):
        raise AssertionError("the driver read a register during construction")

    def write(self, offset, value):
        raise AssertionError("the driver wrote a register during construction")


class FakeClock:
    """A clock that moves when the hardware is polled, not when it is read.

    Reading a clock must not make time pass -- computing a timeout deadline
    would otherwise show up in the measurement. What makes time pass here is
    the accelerator being busy, so FakeIP advances this on every CTRL poll.
    """

    def __init__(self, step=0.001):
        self.now = 0.0
        self.step = step

    def advance(self):
        self.now += self.step

    def __call__(self):
        return self.now


def driver(done_after=1, clock=None):
    clock = clock or FakeClock()
    ip = FakeIP(done_after=done_after, clock=clock)
    return fd.VideoFilter(ip, clock=clock), ip


# ------------------------------------------------------------- register map
class ConfigureTest(unittest.TestCase):
    def test_writes_the_low_half_of_the_source_address(self):
        d, ip = driver()
        d.configure(0x1_2345_6789, 0, 64, 48, ref.MODE_SOBEL)
        self.assertEqual(ip.written(fd.REG_SRC_LO), 0x2345_6789)

    def test_writes_the_high_half_of_the_source_address(self):
        d, ip = driver()
        d.configure(0x1_2345_6789, 0, 64, 48, ref.MODE_SOBEL)
        self.assertEqual(ip.written(fd.REG_SRC_HI), 0x1)

    def test_writes_the_low_half_of_the_destination_address(self):
        d, ip = driver()
        d.configure(0, 0x7_ABCD_EF01, 64, 48, ref.MODE_SOBEL)
        self.assertEqual(ip.written(fd.REG_DST_LO), 0xABCD_EF01)

    def test_writes_the_high_half_of_the_destination_address(self):
        d, ip = driver()
        d.configure(0, 0x7_ABCD_EF01, 64, 48, ref.MODE_SOBEL)
        self.assertEqual(ip.written(fd.REG_DST_HI), 0x7)

    def test_writes_the_width(self):
        d, ip = driver()
        d.configure(0, 0, 640, 48, ref.MODE_SOBEL)
        self.assertEqual(ip.written(fd.REG_WIDTH), 640)

    def test_writes_the_height(self):
        d, ip = driver()
        d.configure(0, 0, 64, 480, ref.MODE_SOBEL)
        self.assertEqual(ip.written(fd.REG_HEIGHT), 480)

    def test_writes_the_mode(self):
        d, ip = driver()
        d.configure(0, 0, 64, 48, ref.MODE_INVERT)
        self.assertEqual(ip.written(fd.REG_MODE), ref.MODE_INVERT)

    def test_does_not_touch_the_control_register(self):
        d, ip = driver()
        d.configure(0, 0, 64, 48, ref.MODE_SOBEL)
        self.assertNotIn(fd.REG_CTRL, [off for off, _ in ip.writes])


class StartTest(unittest.TestCase):
    def test_sets_ap_start(self):
        d, ip = driver()
        d.start()
        self.assertEqual(ip.written(fd.REG_CTRL), fd.CTRL_AP_START)

    def test_run_starts_only_after_every_argument_is_written(self):
        d, ip = driver()
        d.run(0, 0, 64, 48, ref.MODE_SOBEL)
        self.assertEqual(ip.writes[-1][0], fd.REG_CTRL)


# --------------------------------------------------------------- completion
class WaitTest(unittest.TestCase):
    def test_polls_the_control_register_until_done(self):
        d, ip = driver(done_after=5)
        d.wait()
        self.assertEqual(ip.reads, 5)

    def test_returns_immediately_when_done_is_already_set(self):
        d, ip = driver(done_after=1)
        d.wait()
        self.assertEqual(ip.reads, 1)

    def test_raises_when_done_never_arrives(self):
        d, _ = driver(done_after=10**9)
        with self.assertRaises(TimeoutError):
            d.wait(timeout=0.01)

    def test_run_reports_the_elapsed_time(self):
        clock = FakeClock(step=0.25)
        d, _ = driver(clock=clock)
        self.assertAlmostEqual(d.run(0, 0, 64, 48, ref.MODE_SOBEL), 0.25, places=6)


# ------------------------------------------------------------ argument checks
class ArgumentValidationTest(unittest.TestCase):
    def test_rejects_a_width_above_the_line_buffer_depth(self):
        d, _ = driver()
        with self.assertRaises(ValueError):
            d.configure(0, 0, ref.MAX_WIDTH + 1, 48, ref.MODE_SOBEL)

    def test_rejects_a_zero_width(self):
        d, _ = driver()
        with self.assertRaises(ValueError):
            d.configure(0, 0, 0, 48, ref.MODE_SOBEL)

    def test_rejects_a_zero_height(self):
        d, _ = driver()
        with self.assertRaises(ValueError):
            d.configure(0, 0, 64, 0, ref.MODE_SOBEL)

    def test_rejects_an_unknown_mode(self):
        d, _ = driver()
        with self.assertRaises(ValueError):
            d.configure(0, 0, 64, 48, 4)

    def test_rejects_an_address_wider_than_the_pointer_registers(self):
        d, _ = driver()
        with self.assertRaises(ValueError):
            d.configure(1 << 64, 0, 64, 48, ref.MODE_SOBEL)


# ------------------------------------------------------------- frame layout
class FakeFrame(np.ndarray):
    """A NumPy array carrying a device address, like a PynqBuffer."""

    def __new__(cls, shape, device_address=0x7000_0000):
        obj = np.zeros(shape, dtype=np.uint8).view(cls)
        obj.device_address = device_address
        return obj

    def __array_finalize__(self, obj):
        if obj is not None:
            self.device_address = getattr(obj, "device_address", 0)


class FrameLayoutTest(unittest.TestCase):
    def test_accepts_a_contiguous_frame(self):
        f = FakeFrame((48, 64, 4))
        self.assertEqual(fd.frame_address(f, 64, 48), 0x7000_0000)

    def test_rejects_a_frame_whose_rows_are_padded(self):
        # What a DRM dumb buffer looks like when its stride is aligned up: the
        # visible pixels are a strided view, so consecutive rows are not
        # consecutive in memory and the accelerator would write into the pad.
        padded = FakeFrame((48, 64 * 4 + 16))[:, :64 * 4].reshape(48, 64, 4)
        with self.assertRaises(ValueError):
            fd.frame_address(padded, 64, 48)

    def test_rejects_a_frame_of_the_wrong_shape(self):
        with self.assertRaises(ValueError):
            fd.frame_address(FakeFrame((48, 32, 4)), 64, 48)

    def test_rejects_a_frame_with_three_channels(self):
        with self.assertRaises(ValueError):
            fd.frame_address(FakeFrame((48, 64, 3)), 64, 48)

    def test_rejects_a_frame_with_no_device_address(self):
        with self.assertRaises(ValueError):
            fd.frame_address(np.zeros((48, 64, 4), dtype=np.uint8), 64, 48)

    def test_rejects_a_frame_whose_device_address_is_zero(self):
        with self.assertRaises(ValueError):
            fd.frame_address(FakeFrame((48, 64, 4), device_address=0), 64, 48)


class RearmIP:
    """A fake that completes only on the Nth arming, like a re-armed kernel.

    Polls are counted from the last AP_START write, so a retry that does not
    actually re-arm the hardware cannot be mistaken for one that does. While
    busy it reports AP_IDLE and not AP_DONE -- the signature of a start that
    was dropped rather than a frame still in flight, which is the case the
    diagnostics exist to tell apart.
    """

    def __init__(self, succeed_on_attempt, clock):
        self.succeed_on_attempt = succeed_on_attempt
        self.attempts = 0
        self.ctrl_reads = 0
        self._clock = clock
        self.regs = {}

    def write(self, offset, value):
        if offset == fd.REG_ISR:
            # Toggle-on-write, the way video_filter_ctrl.sv implements it
            # (`isr <= isr ^ wdata_r[1:0]`). Storing the value verbatim would
            # let a driver that never actually clears the status pass.
            self.regs[offset] = self.regs.get(offset, 0) ^ value
            return
        self.regs[offset] = value
        if offset == fd.REG_CTRL and value & fd.CTRL_AP_START:
            self.attempts += 1

    def read(self, offset):
        if offset == fd.REG_CTRL:
            self.ctrl_reads += 1
            self._clock.advance()
            if self.attempts >= self.succeed_on_attempt:
                return fd.CTRL_AP_DONE
            return fd.CTRL_AP_IDLE
        return self.regs.get(offset, 0)


def rearm_driver(succeed_on_attempt, step=0.001):
    clock = FakeClock(step=step)
    ip = RearmIP(succeed_on_attempt, clock)
    return fd.VideoFilter(ip, clock=clock), ip


def timed_out(driver_, ip, **kwargs):
    """Run a frame that will not complete; return the exception raised."""
    driver_.configure(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL)
    try:
        driver_.wait(timeout=0.01, **kwargs)
    except TimeoutError as exc:
        return exc
    raise AssertionError("expected a TimeoutError")


# --------------------------------------------------- diagnosing a timeout
class TimeoutDiagnosticsTest(unittest.TestCase):
    """What the exception has to say.

    An AP_DONE timeout is intermittent and expensive to reproduce, so the one
    that happens has to name its own cause. CTRL alone separates the two
    possibilities: ap_idle set means the launch never took, ap_idle clear
    means the kernel started and hung mid-frame.
    """

    def test_message_reports_the_control_register(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        self.assertIn("0x00000004", str(timed_out(d, ip)))

    def test_message_names_the_handshake_bits_that_are_set(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        self.assertIn("ap_idle", str(timed_out(d, ip)))

    def test_message_reports_the_frame_geometry_read_back_from_hardware(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        self.assertIn("1280x720", str(timed_out(d, ip)))

    def test_message_reports_the_mode_read_back_from_hardware(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        self.assertIn("mode=1", str(timed_out(d, ip)))

    def test_message_reports_the_source_address_read_back_from_hardware(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        self.assertIn("0x70000000", str(timed_out(d, ip)))

    def test_message_reports_the_destination_address_read_back_from_hardware(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        self.assertIn("0x80000000", str(timed_out(d, ip)))

    def test_reads_the_control_register_exactly_once_more_at_the_deadline(self):
        # This used to assert that CTRL was NEVER read again, because AP_DONE
        # is clear-on-read and a diagnostic read could consume a late
        # completion. That invariant was deliberately relaxed: the frame is
        # already being declared lost at this point, and comparing the polled
        # word against a fresh one is the only way to tell "the completion was
        # consumed" from "the poll was not seeing the hardware" -- a
        # distinction three refuted theories turned on.
        #
        # What still matters is that it happens ONCE, and only after the
        # deadline: timeout / step = ten polls, plus the single fresh read.
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        timed_out(d, ip)
        self.assertEqual(ip.ctrl_reads, 11)

    def test_records_the_timeout_on_the_driver(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        timed_out(d, ip)
        self.assertEqual(len(d.timeouts), 1)

    def test_the_record_carries_the_control_word(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        timed_out(d, ip)
        self.assertEqual(d.timeouts[0]["ctrl"], fd.CTRL_AP_IDLE)

    def test_the_record_carries_the_arguments(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        timed_out(d, ip)
        self.assertEqual(d.timeouts[0]["img_width"], 1280)


class DeadlineReadTest(unittest.TestCase):
    """What CTRL says when a fresh read is issued at the deadline.

    `wait()` reports the word the last poll returned, deliberately: AP_DONE is
    clear-on-read and a diagnostic read could consume a completion that arrived
    late. But that means the reported value is what the poll kept seeing, not
    the state at the deadline -- and if those ever differ, the difference is
    the fault. One extra read once the frame is already lost costs nothing.
    """

    def test_reports_a_fresh_read_alongside_the_polled_one(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        self.assertIn("fresh", str(timed_out(d, ip)))

    def test_the_record_carries_both(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        timed_out(d, ip)
        self.assertIn("ctrl_fresh", d.timeouts[0])

    def test_the_record_carries_the_poll_count(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        timed_out(d, ip)
        self.assertGreater(d.timeouts[0]["polls"], 0)


class DecodeCtrlTest(unittest.TestCase):
    def test_names_every_bit_that_is_set(self):
        self.assertEqual(fd.decode_ctrl(fd.CTRL_AP_DONE | fd.CTRL_AP_IDLE),
                         "ap_done | ap_idle")

    def test_says_so_when_nothing_is_set(self):
        self.assertEqual(fd.decode_ctrl(0), "nothing set")

    def test_names_auto_restart(self):
        self.assertEqual(fd.decode_ctrl(fd.CTRL_AUTO_RESTART), "auto_restart")


# ------------------------------------------------------------ re-arm and retry
class RetryTest(unittest.TestCase):
    """Opt-in, because a silent retry would hide the fault being investigated."""

    def test_does_not_retry_by_default(self):
        d, _ = rearm_driver(succeed_on_attempt=2)
        with self.assertRaises(TimeoutError):
            d.run(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL,
                  timeout=0.01)

    def test_a_retry_completes_a_frame_the_first_arming_lost(self):
        d, _ = rearm_driver(succeed_on_attempt=2)
        d.run(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL,
              timeout=0.01, retries=1)   # must not raise

    def test_a_retry_arms_the_accelerator_again(self):
        d, ip = rearm_driver(succeed_on_attempt=2)
        d.run(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL,
              timeout=0.01, retries=1)
        self.assertEqual(ip.attempts, 2)

    def test_a_retry_rewrites_the_arguments_before_arming(self):
        d, ip = rearm_driver(succeed_on_attempt=2)
        d.run(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL,
              timeout=0.01, retries=1)
        self.assertEqual(ip.regs[fd.REG_WIDTH], 1280)

    def test_raises_when_every_attempt_times_out(self):
        d, _ = rearm_driver(succeed_on_attempt=10**9)
        with self.assertRaises(TimeoutError):
            d.run(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL,
                  timeout=0.01, retries=2)

    def test_every_timeout_is_recorded_not_just_the_last(self):
        d, _ = rearm_driver(succeed_on_attempt=3)
        d.run(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL,
              timeout=0.01, retries=2)
        self.assertEqual(len(d.timeouts), 2)

    def test_the_elapsed_time_reported_is_the_successful_attempt_only(self):
        # A retried frame took longer than a frame takes; charging the lost
        # attempt to the measurement would poison every timing table in the
        # chapter.
        d, _ = rearm_driver(succeed_on_attempt=2, step=0.25)
        t = d.run(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL,
                  timeout=1.0, retries=1)
        self.assertAlmostEqual(t, 0.25, places=6)

    def test_run_frames_passes_retries_through(self):
        d, ip = rearm_driver(succeed_on_attempt=2)
        src = FakeFrame((48, 64, 4), device_address=0x7000_0000)
        dst = FakeFrame((48, 64, 4), device_address=0x8000_0000)
        d.run_frames(src, dst, ref.MODE_SOBEL, timeout=0.01, retries=1)
        self.assertEqual(ip.attempts, 2)


# ------------------------------------------------- did the start take at all?
class StartProbeTest(unittest.TestCase):
    """One read, immediately after AP_START, to split the two things an
    ap_idle timeout can mean.

    After the 5 s deadline both look identical -- ap_idle set, nothing
    running. They separate only at the instant the start was written: if the
    kernel launched, ap_idle is already low one transaction later; if the write
    was dropped, ap_start reads back 0 and ap_idle is still 1. Opt-in, because
    it costs an extra AXI4-Lite read on every frame.
    """

    def test_is_off_by_default(self):
        d, ip = rearm_driver(succeed_on_attempt=1)
        d.run(0, 0, 64, 48, ref.MODE_SOBEL, timeout=0.01)
        self.assertEqual(ip.ctrl_reads, 1)      # the wait poll, and nothing else

    def test_reads_the_control_register_once_after_arming(self):
        d, ip = rearm_driver(succeed_on_attempt=1)
        d.probe_start = True
        d.run(0, 0, 64, 48, ref.MODE_SOBEL, timeout=0.01)
        self.assertEqual(ip.ctrl_reads, 2)      # the probe, then the wait poll

    def test_records_what_the_probe_saw(self):
        d, ip = rearm_driver(succeed_on_attempt=1)
        d.probe_start = True
        d.run(0, 0, 64, 48, ref.MODE_SOBEL, timeout=0.01)
        self.assertEqual(d.last_start_ctrl, fd.CTRL_AP_DONE)

    def timed_out_run(self, d):
        """The probe happens in run(), so these have to go through run()."""
        try:
            d.run(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL,
                  timeout=0.01)
        except TimeoutError as exc:
            return exc
        raise AssertionError("expected a TimeoutError")

    def test_the_timeout_message_reports_it(self):
        d, _ = rearm_driver(succeed_on_attempt=10**9)
        d.probe_start = True
        self.assertIn("at start", str(self.timed_out_run(d)))

    def test_the_timeout_message_says_the_start_was_dropped(self):
        # RearmIP reports AP_IDLE while busy, which is the dropped-start
        # signature: armed, yet still idle one transaction later.
        d, _ = rearm_driver(succeed_on_attempt=10**9)
        d.probe_start = True
        self.assertIn("never took", str(self.timed_out_run(d)))

    def test_the_record_is_absent_when_the_probe_is_off(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        timed_out(d, ip)
        self.assertIsNone(d.last_start_ctrl)


# ------------------------------------------- the interrupt-status shadow copy
class DoneLatchTest(unittest.TestCase):
    """IP_ISR bit 0 latches the same ap_done that CTRL reports.

    CTRL's copy is clear-on-read, so a poll that races the completion can
    consume it; ISR is toggle-on-write and cannot be lost that way. It only
    latches when IP_IER bit 0 is enabled, which nothing does by default.
    """

    def test_enabling_the_latch_writes_the_interrupt_enable(self):
        d, ip = rearm_driver(succeed_on_attempt=1)
        d.enable_done_latch()
        self.assertEqual(ip.regs[fd.REG_IER], 1)

    def test_the_timeout_reports_the_latched_status(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        d.done_latch = False          # else the frame is recovered, not lost
        ip.regs[fd.REG_ISR] = 1
        self.assertIn("IP_ISR", str(timed_out(d, ip)))

    def test_a_latched_done_says_the_completion_was_lost(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        d.done_latch = False          # else the frame is recovered, not lost
        ip.regs[fd.REG_ISR] = 1
        self.assertIn("ap_done DID fire", str(timed_out(d, ip)))

    def test_an_unlatched_done_does_not_claim_it_fired(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        ip.regs[fd.REG_ISR] = 0
        self.assertNotIn("ap_done DID fire", str(timed_out(d, ip)))

    def test_the_record_carries_the_status(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        d.done_latch = False          # else the frame is recovered, not lost
        ip.regs[fd.REG_ISR] = 1
        timed_out(d, ip)
        self.assertEqual(d.timeouts[0]["isr"], 1)


class LatchedCompletionTest(unittest.TestCase):
    """Accepting the sticky copy of ap_done, so a lost CTRL bit is survivable.

    Measured on hardware: in 4000 frames, 18 completions fired and latched in
    IP_ISR while CTRL's clear-on-read AP_DONE never reached the poll. ISR
    cannot be lost that way, so a frame whose CTRL bit vanished is still
    recoverable -- and counted, because the underlying race is not fixed by
    reading around it.
    """

    def test_a_latched_done_completes_the_wait(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)   # CTRL never reports done
        d.enable_done_latch()
        ip.regs[fd.REG_ISR] = 1
        d.configure(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL)
        d.wait(timeout=0.01)                             # must not raise

    def test_consuming_it_clears_the_status(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        d.enable_done_latch()
        ip.regs[fd.REG_ISR] = 1
        d.configure(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL)
        d.wait(timeout=0.01)
        self.assertEqual(ip.regs[fd.REG_ISR], 0)

    def test_it_is_counted_rather_than_hidden(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        d.enable_done_latch()
        ip.regs[fd.REG_ISR] = 1
        d.configure(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL)
        d.wait(timeout=0.01)
        self.assertEqual(d.recovered_completions, 1)

    def test_the_latch_is_ignored_when_it_is_turned_off(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)
        d.done_latch = False
        ip.regs[fd.REG_ISR] = 1
        d.configure(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL)
        with self.assertRaises(TimeoutError):
            d.wait(timeout=0.01)

    def test_the_latch_is_on_by_default(self):
        # The race costs a 5 s stall and an exception in a notebook that has
        # done nothing wrong. Nothing else uses IP_ISR, and IP_IER bit 0 alone
        # raises no interrupt because GIER is zero, so there is no reason to
        # make every caller ask for it.
        d, _ = rearm_driver(succeed_on_attempt=1)
        self.assertTrue(d.done_latch)

    def test_construction_touches_no_registers(self):
        # Learned the hard way: a driver that reads or writes in __init__ can
        # hit an IP that is still in reset, and on ZynqMP that wedges the CPU
        # rather than raising. Arming is deferred to the first start().
        ip = ReadTrapIP()
        fd.VideoFilter(ip)                      # must not raise

    def test_the_first_arm_enables_the_interrupt_status(self):
        d, ip = rearm_driver(succeed_on_attempt=1)
        d.start()
        self.assertEqual(ip.regs[fd.REG_IER], 1)

    def test_it_can_be_turned_off(self):
        d, ip = rearm_driver(succeed_on_attempt=1)
        d.done_latch = False
        d.start()
        self.assertNotIn(fd.REG_IER, ip.regs)

    def test_arming_clears_a_stale_latch(self):
        # IP_ISR is sticky. Left set from the previous frame it would satisfy
        # the very first poll of the next one -- returning before the frame has
        # run, and counting a recovery that never happened.
        d, ip = rearm_driver(succeed_on_attempt=1)
        d.enable_done_latch()
        ip.regs[fd.REG_ISR] = 1
        d.start()
        self.assertEqual(ip.regs[fd.REG_ISR], 0)

    def test_a_stale_latch_does_not_complete_the_next_frame(self):
        d, ip = rearm_driver(succeed_on_attempt=10**9)   # never completes
        d.enable_done_latch()
        ip.regs[fd.REG_ISR] = 1                          # left over
        with self.assertRaises(TimeoutError):
            d.run(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL,
                  timeout=0.01)

    def test_a_completion_that_merely_landed_late_is_not_a_recovery(self):
        # ISR set AND CTRL set means the frame finished between the CTRL read
        # and the ISR read of the same poll -- ordinary timing, nothing lost.
        # Counting it would inflate the loss rate by orders of magnitude.
        d, ip = rearm_driver(succeed_on_attempt=1)
        d.enable_done_latch()
        ip.regs[fd.REG_ISR] = 1
        d.run(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL, timeout=0.01)
        self.assertEqual(d.recovered_completions, 0)

    def test_a_normal_completion_is_not_counted_as_a_recovery(self):
        # Through run(), because RearmIP only reports done once it has seen an
        # AP_START write -- which is what makes it a model of the hardware
        # rather than of a register file.
        d, _ = rearm_driver(succeed_on_attempt=1)        # CTRL reports done
        d.enable_done_latch()
        d.run(0x7000_0000, 0x8000_0000, 1280, 720, ref.MODE_SOBEL, timeout=0.01)
        self.assertEqual(d.recovered_completions, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
