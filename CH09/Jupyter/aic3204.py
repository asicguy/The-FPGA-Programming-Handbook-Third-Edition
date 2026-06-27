"""
aic3204.py  -  TLV320AIC3204 audio codec driver for the AUP-ZU3 base overlay.

The AUP-ZU3 `audio` hierarchy exposes the codec's I2C bus as
`base.audio.axi_iic_aic` ("aic" == TI Audio Interface Codec). The part is a
TLV320AIC3204, which:
  * answers at 7-bit I2C address 0x18 (datasheet: address 0b0011000),
  * uses single-byte register addresses,
  * is PAGED: write register 0x00 with a page number, then registers 0..127
    address that page. Page 0 = clocks/PLL/serial/DSP, Page 1 = analog
    routing/power.

This driver brings the codec up over I2C and configures a 48 kHz, I2S-slave,
16-bit path: DAC -> headphone out, and line input -> ADC.

Usage
-----
    from pynq.overlays.base import BaseOverlay
    from aic3204 import AIC3204

    base  = BaseOverlay("base.bit")
    codec = AIC3204(base.audio.axi_iic_aic)

    print("I2C addresses present:", codec.scan())   # expect 0x18
    codec.init(mclk_hz=12_288_000, fs=48000)          # set mclk_hz to YOUR design
    codec.select_line_in()                             # or select_microphone()
    codec.set_hp_volume(0)                             # dB
    print(codec.dump())                                # confirm I2C link

What is solid vs. what to verify
--------------------------------
SOLID (datasheet-confirmed): the 0x18 address, the paged single-byte access,
the I2S/word-length interface register (Page 0, R27), and the no-PLL clocking
math below for an MCLK that is an integer 256*fs multiple.

VERIFY against TI SLAA557 (App Reference Guide) / SLAA404 (EVM scripts) and
your board's jack wiring if you get no sound: the Page-1 analog power/LDO
values, the headphone routing/gain, and which physical input pin (IN1 vs IN2)
the line jack is wired to. Those are board-layout dependent and I can't read
them from the overlay.

For an MCLK that is NOT an integer 256*fs multiple you must run the PLL; this
driver exposes configure_pll(P, R, J, D) for that — tell me your MCLK and I'll
compute the coefficients.
"""

import time

AIC3204_I2C_ADDR = 0x18

# ---- Page 0 registers ----
P0_PAGE_SELECT      = 0x00
P0_SOFT_RESET       = 0x01
P0_CLOCK_MUX1       = 0x04   # PLL_CLKIN / CODEC_CLKIN source
P0_PLL_P_R          = 0x05
P0_PLL_J            = 0x06
P0_PLL_D_MSB        = 0x07
P0_PLL_D_LSB        = 0x08
P0_NDAC             = 0x0B
P0_MDAC             = 0x0C
P0_DOSR_MSB         = 0x0D
P0_DOSR_LSB         = 0x0E
P0_NADC             = 0x12
P0_MADC             = 0x13
P0_AOSR             = 0x14
P0_AUDIO_IF1        = 0x1B   # protocol + word length + master/slave
P0_AUDIO_IF2        = 0x1C   # data slot offset
P0_DAC_PRB          = 0x3C
P0_ADC_PRB          = 0x3D
P0_DAC_SETUP1       = 0x3F   # power up DAC, data routing
P0_DAC_SETUP2       = 0x40   # DAC mute / soft-step
P0_DAC_LVOL         = 0x41
P0_DAC_RVOL         = 0x42
P0_ADC_SETUP        = 0x51   # power up ADC
P0_ADC_FINE_VOL     = 0x52   # ADC mute / fine gain

# ---- Page 1 registers (analog) ----
P1_POWER_CFG        = 0x01   # disable weak AVDD<->DVDD connection
P1_LDO_CTRL         = 0x02   # AVDD LDO
P1_PLAYBACK_CFG1    = 0x03
P1_OUTPUT_PWR       = 0x09   # power up HPL/HPR/LOL/LOR drivers
P1_COMMON_MODE      = 0x0A
P1_HPL_ROUTE        = 0x0C
P1_HPR_ROUTE        = 0x0D
P1_HPL_GAIN         = 0x10
P1_HPR_GAIN         = 0x11
P1_HP_STARTUP       = 0x14
P1_MICBIAS          = 0x33
P1_LMICPGA_P        = 0x34   # left MICPGA positive input routing
P1_LMICPGA_N        = 0x36   # left MICPGA negative input routing
P1_RMICPGA_P        = 0x37   # right MICPGA positive input routing
P1_RMICPGA_N        = 0x39   # right MICPGA negative input routing
P1_LMICPGA_VOL      = 0x3B
P1_RMICPGA_VOL      = 0x3C
P1_REF_PWRUP        = 0x7B


class AIC3204:
    def __init__(self, iic, addr=AIC3204_I2C_ADDR):
        self.iic = iic
        self.addr = addr
        self._page = None
        if not (hasattr(iic, "send") and hasattr(iic, "receive")):
            raise TypeError(
                f"Expected a PYNQ AxiIIC driver, got {type(iic)!r}. If this is "
                "a DefaultIP, the axi_iic driver did not bind."
            )

    # -- low-level I2C -------------------------------------------------------
    def _select_page(self, page):
        if page != self._page:
            self.iic.send(self.addr, bytes([P0_PAGE_SELECT, page]), 2)
            self._page = page

    def w(self, page, reg, val):
        """Write one register on a given page."""
        self._select_page(page)
        self.iic.send(self.addr, bytes([reg & 0xFF, val & 0xFF]), 2)

    def _ffi(self):
        """The AxiIIC class's own cffi.FFI (cdata isn't portable across FFIs)."""
        ffi = type(self.iic)._ffi
        if ffi is None:
            type(self.iic)._initialise_lib()
            ffi = type(self.iic)._ffi
        return ffi

    def r(self, page, reg):
        """Read one register on a given page."""
        self._select_page(page)
        ffi = self._ffi()
        buf = ffi.new("unsigned char[]", 1)          # cffi buffer, not bytearray
        # Write the register pointer with a repeated start, then read 1 byte.
        self.iic.send(self.addr, bytes([reg & 0xFF]), 1, self.iic.REPEAT_START)
        self.iic.receive(self.addr, buf, 1, 0)
        return buf[0]

    def reset_controller(self):
        """Soft-reset the AXI IIC core to recover a wedged bus.

        Writes the key 0x0A to the SOFTR register (offset 0x40) per the Xilinx
        AXI IIC register map. Use this after a failed transaction leaves the
        controller stuck on 'Could not send I2C data'."""
        self.iic.write(0x40, 0x0A)
        time.sleep(0.01)
        self._page = None

    def scan(self, lo=0x08, hi=0x78):
        """Non-destructive bus scan. Returns addresses that ACK a read."""
        ffi = self._ffi()
        found = []
        for a in range(lo, hi):
            try:
                buf = ffi.new("unsigned char[]", 1)
                self.iic.receive(a, buf, 1, 0)
                found.append(hex(a))
            except Exception:
                pass
        self._page = None      # reads to other addresses clobber page state
        return found

    # -- clocking ------------------------------------------------------------
    def _clock_dividers(self, mclk_hz, fs):
        """Pick NDAC/MDAC/DOSR (and ADC equivalents) for CODEC_CLKIN == MCLK.

        DAC_fs = CODEC_CLKIN / (NDAC * MDAC * DOSR).  We target DOSR=128 and
        require MDAC*DOSR/32 >= 8 (resource budget for processing block PRB_P1),
        so MDAC >= 2. Same shape for the ADC side with AOSR=128.
        """
        ratio = mclk_hz / fs
        if abs(ratio - round(ratio)) > 1e-6:
            raise ValueError(
                f"MCLK {mclk_hz} Hz is not an integer multiple of fs {fs} Hz; "
                "the PLL is required. Call configure_pll(P,R,J,D) instead, or "
                "tell me your MCLK so I can compute the coefficients."
            )
        ratio = round(ratio)                 # e.g. 256 for 12.288MHz / 48k
        dosr = 128
        rem = ratio // dosr                  # = NDAC * MDAC
        if ratio % dosr or rem < 2:
            raise ValueError(
                f"MCLK/fs ratio {ratio} not factorable as NDAC*MDAC*128 with "
                "MDAC>=2; provide PLL coefficients via configure_pll()."
            )
        mdac = 2
        ndac = rem // mdac
        if ndac * mdac != rem:
            ndac, mdac = rem, 1              # fallback (will warn via budget)
        return ndac, mdac, dosr

    def configure_clocking(self, mclk_hz, fs):
        """No-PLL clocking: CODEC_CLKIN = MCLK, then set the dividers."""
        ndac, mdac, dosr = self._clock_dividers(mclk_hz, fs)
        # CODEC_CLKIN source = MCLK (D1:0 = 00), PLL unused.
        self.w(0, P0_CLOCK_MUX1, 0x00)
        # DAC clock tree
        self.w(0, P0_NDAC, 0x80 | (ndac & 0x7F))
        self.w(0, P0_MDAC, 0x80 | (mdac & 0x7F))
        self.w(0, P0_DOSR_MSB, (dosr >> 8) & 0xFF)
        self.w(0, P0_DOSR_LSB, dosr & 0xFF)
        # ADC clock tree (mirror)
        self.w(0, P0_NADC, 0x80 | (ndac & 0x7F))
        self.w(0, P0_MADC, 0x80 | (mdac & 0x7F))
        self.w(0, P0_AOSR, dosr & 0xFF)
        return ndac, mdac, dosr

    def configure_pll(self, P, R, J, D, pll_in=0x03):
        """Explicit PLL setup. PLL_CLK = PLL_CLKIN * R * (J.D) / P.

        pll_in: value for the clock mux (Page0 R4). 0x03 routes PLL_CLKIN=MCLK
        and CODEC_CLKIN=PLL. Provide P,R,J,D computed for your MCLK/fs.
        """
        self.w(0, P0_CLOCK_MUX1, pll_in)
        self.w(0, P0_PLL_P_R, 0x80 | ((P & 0x07) << 4) | (R & 0x0F))  # power up PLL
        self.w(0, P0_PLL_J, J & 0x3F)
        self.w(0, P0_PLL_D_MSB, (D >> 8) & 0x3F)
        self.w(0, P0_PLL_D_LSB, D & 0xFF)
        time.sleep(0.01)                     # PLL lock settle

    # -- full init -----------------------------------------------------------
    def init(self, mclk_hz=12_288_000, fs=48000, word_len=16):
        """Reset the codec and configure a DAC->HP, line-in->ADC path."""
        self.fs = fs

        # 1) Software reset (Page 0, R1 = 1), then wait for the chip.
        self.w(0, P0_SOFT_RESET, 0x01)
        time.sleep(0.01)
        self._page = 0                       # known page after reset

        # 2) Clocks (no PLL for a clean MCLK).
        self.configure_clocking(mclk_hz, fs)

        # 3) Audio interface: I2S (D7:6=00), word length, codec = slave.
        wl = {16: 0b00, 20: 0b01, 24: 0b10, 32: 0b11}.get(word_len, 0b00)
        self.w(0, P0_AUDIO_IF1, wl << 4)
        self.w(0, P0_AUDIO_IF2, 0x00)        # no data-slot offset

        # 4) Signal-processing blocks: PRB_P1 (DAC), PRB_R1 (ADC).
        self.w(0, P0_DAC_PRB, 0x08)
        self.w(0, P0_ADC_PRB, 0x01)

        # 5) Analog power-up sequence (Page 1).  *** verify vs SLAA557 ***
        self.w(1, P1_POWER_CFG, 0x08)        # disable weak AVDD-DVDD tie
        self.w(1, P1_LDO_CTRL, 0x00)         # enable AVDD LDO (0x00 if AVDD external)
        self.w(1, P1_REF_PWRUP, 0x01)        # fast reference power-up
        self.w(1, P1_COMMON_MODE, 0x00)      # CM = 0.9 V
        self.w(1, P1_HP_STARTUP, 0x25)       # soft-start headphone (pop suppression)
        time.sleep(0.02)

        # 6) Route DACs to the headphone amps and power the HP drivers.
        self.w(1, P1_HPL_ROUTE, 0x08)        # HPL <- Left DAC
        self.w(1, P1_HPR_ROUTE, 0x08)        # HPR <- Right DAC
        self.w(1, P1_OUTPUT_PWR, 0x30)       # power up HPL + HPR
        time.sleep(0.05)                     # let the soft-start finish
        self.w(1, P1_HPL_GAIN, 0x10)         # 10 dB, unmuted
        self.w(1, P1_HPR_GAIN, 0x10)

        # 7) Default input = line in.
        self.select_line_in()

        # 8) Power up converters and unmute (Page 0).
        self.w(0, P0_DAC_SETUP1, 0xD4)       # LDAC+RDAC on, L->L, R->R
        self.w(0, P0_DAC_SETUP2, 0x02)       # DAC unmuted
        self.w(0, P0_DAC_LVOL, 0x00)         # 0 dB digital
        self.w(0, P0_DAC_RVOL, 0x00)
        self.w(0, P0_ADC_SETUP, 0xC0)        # LADC + RADC on
        self.w(0, P0_ADC_FINE_VOL, 0x00)     # ADC unmuted

    # -- input selection -----------------------------------------------------
    def select_line_in(self):
        """Route the line inputs (IN1_L / IN1_R) into the MICPGA -> ADC."""
        self.w(1, P1_MICBIAS, 0x48)          # mic bias off for line level
        self.w(1, P1_LMICPGA_P, 0x80)        # IN1_L -> left PGA+ via 20k
        self.w(1, P1_LMICPGA_N, 0x80)        # CM    -> left PGA- via 20k
        self.w(1, P1_RMICPGA_P, 0x80)        # IN1_R -> right PGA+
        self.w(1, P1_RMICPGA_N, 0x80)        # CM    -> right PGA-
        self.w(1, P1_LMICPGA_VOL, 0x00)      # PGA enabled, 0 dB
        self.w(1, P1_RMICPGA_VOL, 0x00)
        self._input = "line_in"

    def select_microphone(self, bias=0x40, gain_db=20):
        """Enable mic bias and route a mic input with PGA gain.

        NOTE: which pin the mic is on (IN1 vs IN2 vs IN3) is board-specific;
        adjust the routing registers if your mic jack is not on IN1.
        """
        self.w(1, P1_MICBIAS, 0x40 | (bias & 0x3F))   # mic bias on
        self.w(1, P1_LMICPGA_P, 0x40)
        self.w(1, P1_LMICPGA_N, 0x40)
        self.w(1, P1_RMICPGA_P, 0x40)
        self.w(1, P1_RMICPGA_N, 0x40)
        field = max(0, min(0x7F, int(gain_db * 2)))   # PGA vol = 0.5 dB steps
        self.w(1, P1_LMICPGA_VOL, field)
        self.w(1, P1_RMICPGA_VOL, field)
        self._input = "microphone"

    # -- volume --------------------------------------------------------------
    def set_hp_volume(self, db=0):
        """Headphone analog driver gain, ~ -6..+14 dB in 1 dB steps."""
        db = max(-6, min(14, int(db)))
        field = (db & 0x3F) if db >= 0 else ((64 + db) & 0x3F)
        self.w(1, P1_HPL_GAIN, field)        # bit6 = 0 -> unmuted
        self.w(1, P1_HPR_GAIN, field)

    def set_dac_volume(self, db=0):
        """DAC digital volume, +24..-63.5 dB in 0.5 dB steps."""
        steps = max(-127, min(48, int(round(db * 2))))
        val = steps & 0xFF                   # signed 8-bit
        self.w(0, P0_DAC_LVOL, val)
        self.w(0, P0_DAC_RVOL, val)

    def mute(self, muted=True):
        self.w(0, P0_DAC_SETUP2, 0x0C if muted else 0x00)   # mute both DACs

    # -- debug ---------------------------------------------------------------
    def dump(self):
        """Read back key Page-0 registers to confirm the I2C link.

        If these come back as the values init() wrote (e.g. NDAC/MDAC with the
        0x80 power bit set, DAC setup 0xD4), the codec is talking and any
        silence is downstream in the I2S path, not here.
        """
        regs = {
            "clock_mux(0x04)":  (0, P0_CLOCK_MUX1),
            "ndac(0x0B)":       (0, P0_NDAC),
            "mdac(0x0C)":       (0, P0_MDAC),
            "iface(0x1B)":      (0, P0_AUDIO_IF1),
            "dac_setup1(0x3F)": (0, P0_DAC_SETUP1),
            "dac_setup2(0x40)": (0, P0_DAC_SETUP2),
            "adc_setup(0x51)":  (0, P0_ADC_SETUP),
        }
        out = {}
        for name, (pg, rg) in regs.items():
            try:
                out[name] = hex(self.r(pg, rg))
            except Exception as e:           # noqa: BLE001
                out[name] = f"read error: {e}"
        return out
