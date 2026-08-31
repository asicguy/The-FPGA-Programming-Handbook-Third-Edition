"""Tests for the DFX socket driver.

The behaviour under test is mostly REFUSAL. On ZynqMP a read of a partition
that is held in reset, or that is mid-reconfiguration, never returns -- there
is no bus timeout on the PL ports, so the CPU stops with no panic and no
console and only a power cycle recovers it. So the driver's job is to decline
rather than to hang, and these tests are almost all about the decline.
"""
import pytest

import dfx_socket as dfx


class FakeRegisters:
    """A register file that records writes and can be made to explode."""

    def __init__(self, initial=None):
        self.mem = dict(initial or {})
        self.reads = []
        self.writes = []
        self.forbidden = set()

    def read(self, offset):
        if offset in self.forbidden:
            raise AssertionError(
                f"read of {offset:#x} while the partition was not known good -- "
                "on hardware this hangs the CPU")
        self.reads.append(offset)
        return self.mem.get(offset, 0)

    def write(self, offset, value):
        if offset in self.forbidden:
            raise AssertionError(f"write of {offset:#x} while forbidden")
        self.writes.append((offset, value))
        self.mem[offset] = value


class FakeGpio(FakeRegisters):
    """The static-region status GPIO. Always answers -- that is its point."""

    def __init__(self):
        super().__init__({dfx.GPIO_DATA: 0, dfx.GPIO2_DATA: 0})
        self._hb = 0
        self.alive = True          # does the partition toggle its heartbeat?
        self.shutdown_acks = True  # do the managers report in_shutdown?

    def read(self, offset):
        if offset == dfx.GPIO2_DATA:
            v = 0
            if self.alive:
                self._hb ^= 1
                v |= self._hb << dfx.ST_HEARTBEAT
            if self.shutdown_acks and (self.mem[dfx.GPIO_DATA] & (1 << dfx.CTL_SHUTDOWN)):
                v |= (1 << dfx.ST_SDM_CTRL) | (1 << dfx.ST_SDM_GMEM0) | (1 << dfx.ST_SDM_GMEM1)
            self.reads.append(offset)
            return v
        return super().read(offset)


class FakeSocket(FakeRegisters):
    def __init__(self, kernel_id=dfx.KERNEL_PASSTHROUGH, idle=True):
        super().__init__({dfx.REG_CTRL: 0x4 if idle else 0x0,
                          dfx.REG_KERNEL_ID: kernel_id})


def make(kernel_id=dfx.KERNEL_PASSTHROUGH, idle=True):
    return dfx.DfxSocket(FakeSocket(kernel_id, idle), FakeGpio())


# ------------------------------------------------------------------ liveness

def test_reports_alive_when_the_heartbeat_toggles():
    s = make()
    assert s.alive() is True


def test_reports_not_alive_when_the_heartbeat_is_stuck():
    s = make()
    s.gpio.alive = False
    assert s.alive() is False


def test_alive_only_reads_the_static_gpio():
    s = make()
    s.alive()
    assert s.ip.reads == []


# ------------------------------------------------------------------- refusal

def test_refuses_to_read_kernel_id_when_the_partition_is_dead():
    s = make()
    s.gpio.alive = False
    s.ip.forbidden.add(dfx.REG_KERNEL_ID)
    with pytest.raises(dfx.SocketNotReady):
        s.kernel_id()


def test_refuses_to_read_kernel_id_while_the_partition_is_held_in_reset():
    s = make()
    s.hold_reset()
    s.ip.forbidden.add(dfx.REG_KERNEL_ID)
    with pytest.raises(dfx.SocketNotReady):
        s.kernel_id()


def test_refuses_to_start_a_frame_when_the_partition_is_dead():
    s = make()
    s.gpio.alive = False
    s.ip.forbidden.add(dfx.REG_CTRL)
    with pytest.raises(dfx.SocketNotReady):
        s.check_ready()


def test_reads_kernel_id_when_the_partition_is_alive_and_released():
    s = make(kernel_id=dfx.KERNEL_BLUR)
    s.release_reset()
    assert s.kernel_id() == dfx.KERNEL_BLUR


# ------------------------------------------------------------------ shutdown

def test_engaging_shutdown_sets_the_control_bit():
    s = make()
    s.engage_shutdown()
    assert s.gpio.mem[dfx.GPIO_DATA] & (1 << dfx.CTL_SHUTDOWN)


def test_engage_shutdown_waits_for_all_three_managers():
    s = make()
    s.engage_shutdown()
    assert s.shutdown_engaged() is True


def test_engage_shutdown_raises_if_a_manager_never_acknowledges():
    s = make()
    s.gpio.shutdown_acks = False
    with pytest.raises(dfx.ShutdownTimeout):
        s.engage_shutdown(timeout=0.05)


def test_releasing_shutdown_clears_the_control_bit():
    s = make()
    s.engage_shutdown()
    s.release_shutdown()
    assert not (s.gpio.mem[dfx.GPIO_DATA] & (1 << dfx.CTL_SHUTDOWN))


def test_hold_reset_and_release_reset_move_only_their_own_bit():
    s = make()
    s.engage_shutdown()
    before = s.gpio.mem[dfx.GPIO_DATA]
    s.hold_reset()
    assert not (s.gpio.mem[dfx.GPIO_DATA] & (1 << dfx.CTL_RM_RESETN))
    assert s.gpio.mem[dfx.GPIO_DATA] & (1 << dfx.CTL_SHUTDOWN)
    s.release_reset()
    assert s.gpio.mem[dfx.GPIO_DATA] & (1 << dfx.CTL_RM_RESETN)
    assert s.gpio.mem[dfx.GPIO_DATA] & (1 << dfx.CTL_SHUTDOWN) == before & (1 << dfx.CTL_SHUTDOWN)


# ---------------------------------------------------------------- the swap

def test_swap_follows_the_documented_order():
    s = make()
    loaded = []
    s.swap(lambda: loaded.append("partial"), dfx.KERNEL_PASSTHROUGH)
    names = [step for step, _ in s.trace]
    assert names == ["wait_idle", "engage_shutdown", "hold_reset", "download",
                     "release_reset", "check_alive", "release_shutdown",
                     "check_kernel_id"]


def test_swap_downloads_exactly_once():
    s = make()
    calls = []
    s.swap(lambda: calls.append(1), dfx.KERNEL_PASSTHROUGH)
    assert len(calls) == 1


def test_swap_refuses_when_the_new_rm_reports_the_wrong_identity():
    s = make(kernel_id=dfx.KERNEL_SOBEL)
    with pytest.raises(dfx.WrongKernel):
        s.swap(lambda: None, dfx.KERNEL_BLUR)


def test_swap_leaves_the_partition_in_reset_if_it_never_comes_alive():
    s = make()

    def kill():
        s.gpio.alive = False

    with pytest.raises(dfx.SocketNotReady):
        s.swap(kill, dfx.KERNEL_PASSTHROUGH, alive_timeout=0.05)
    assert not (s.gpio.mem[dfx.GPIO_DATA] & (1 << dfx.CTL_RM_RESETN))


def test_swap_keeps_shutdown_engaged_if_the_partition_never_comes_alive():
    # Releasing the managers would let traffic reach a partition that is not
    # answering, which is the hang this whole mechanism exists to prevent.
    s = make()

    def kill():
        s.gpio.alive = False

    with pytest.raises(dfx.SocketNotReady):
        s.swap(kill, dfx.KERNEL_PASSTHROUGH, alive_timeout=0.05)
    assert s.gpio.mem[dfx.GPIO_DATA] & (1 << dfx.CTL_SHUTDOWN)


def test_swap_does_not_touch_the_socket_before_it_is_known_alive():
    s = make()
    order = []
    real_read = s.ip.read

    def watched(offset):
        order.append(("ip", offset))
        return real_read(offset)

    s.ip.read = watched
    s.swap(lambda: order.append(("download", None)), dfx.KERNEL_PASSTHROUGH)
    dl = order.index(("download", None))
    after = [o for o in order[dl:] if o[0] == "ip"]
    # the only socket access after the download is the identity check
    assert all(off == dfx.REG_KERNEL_ID for _, off in after)


def test_wait_idle_gives_up_rather_than_spinning_forever():
    s = make(idle=False)
    with pytest.raises(dfx.NotIdle):
        s.swap(lambda: None, dfx.KERNEL_PASSTHROUGH, idle_timeout=0.05)


def test_a_failed_swap_does_not_download_anything():
    s = make(idle=False)
    calls = []
    with pytest.raises(dfx.NotIdle):
        s.swap(lambda: calls.append(1), dfx.KERNEL_PASSTHROUGH, idle_timeout=0.05)
    assert calls == []


# -------------------------------------------------------------- the registry

def test_every_kernel_id_has_a_name():
    for k in dfx.KERNEL_NAMES:
        assert isinstance(dfx.KERNEL_NAMES[k], str)


def test_kernel_ids_match_the_golden_model():
    import rm_ref
    assert dfx.KERNEL_PASSTHROUGH == rm_ref.KERNEL_PASSTHROUGH
    assert dfx.KERNEL_SOBEL == rm_ref.KERNEL_SOBEL
    assert dfx.KERNEL_BLUR == rm_ref.KERNEL_BLUR
    assert dfx.KERNEL_THRESHOLD == rm_ref.KERNEL_THRESHOLD
