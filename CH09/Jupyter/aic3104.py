"""
aic3104.py  -  TLV320AIC3104 audio codec driver for the AUP-ZU3 base overlay.

The codec on the AUP-ZU3 (schematic page 7, IC1 = "TLV320AIC3104IRHBR") is a
TLV320AIC3104 -- NOT an AIC3204. Different chip, different register map. This
driver replaces aic3204.py; do not use the 3204 register addresses here.

Board wiring (from the AUP-ZU3 schematic; AIC nets on PL bank 66 @ 1.8 V):
    codec MCLK  <- FPGA F3   (AIC_MCLK)   FPGA-generated master clock
    codec BCLK  <- FPGA G1   (AIC_BCLK)   bit clock   (codec is slave)
    codec WCLK  <- FPGA F2   (AIC_WCLK)   word clock  (codec is slave)
    codec DIN   <- FPGA G3   (AIC_DIN)    FPGA playback out -> codec DAC
    codec DOUT  -> FPGA G4   (AIC_DOUT)   codec ADC -> FPGA capture in
    SCL/SDA          F5/G5   via audio/axi_iic_aic
    RESET       <- FPGA E2   (AIC_RST)    active low, likely on axi_gpio_0

    NOTE on direction: the codec names DIN/DOUT from its own point of view.
    Your FPGA's serial-data OUT (playback) drives codec DIN; codec DOUT drives
    your FPGA's serial-data IN (capture). Swapping them is the classic
    "wired but silent" bug.

    There is no audio oscillator on the board -- MCLK comes from the FPGA, so
    you control it. Generate 256*fs (12.288 MHz for 48 kHz) and the codec runs
    off its simple divider with no PLL (see init()).

Analog jacks (schematic page 7):
    Line in  (blue  J5) -> LINE2L (pin14) / LINE2R (pin16), single-ended
    Mic      (pink  J6) -> MIC1LP/LM, MIC1RP/RM differential (pins10-13)+MICBIAS
    Line out (green J4) -> LEFT_LOP (pin27) / RIGHT_LOP (pin29) differential

Device facts (datasheet SLAS510 / app note SLAA403 "Programming Made Easy"):
    * 7-bit I2C address 0x18 (0x30 write / 0x31 read).
    * Paged: write register 0 to select the page (page 0 = control,
      page 1 = filter coefficients). Single-byte register addresses.
    * MCLK need not be running while programming over I2C.
    * A hardware reset after power-up is recommended (see hw_reset()).

Usage:
    from pynq.overlays.base import BaseOverlay
    from aic3104 import AIC3104
    base  = BaseOverlay("base.bit")
    codec = AIC3104(base.audio.axi_iic_aic, gpio=base.audio.axi_gpio_0)
    codec.reset_controller()            # clear a wedged AXI-IIC core if needed
    print(codec.scan())                 # expect ['0x18']
    codec.init(mclk_hz=12_288_000, fs=48000, word_len=16)
    codec.select_line_in()              # or codec.select_microphone()
    print(codec.dump())                 # read-back confirms the I2C link

CONFIDENCE NOTES (cross-check SLAS510 if something is silent):
    DATASHEET-CONFIRMED in this build's sources:
      - 0x18 address, paged single-byte access, software reset (R1=0x80).
      - I2S-slave serial format: R8=0x00 (BCLK/WCLK inputs), R9 word length.
      - No-PLL clocking: fs(ref)=CLKDIV_IN/(128*Q), Q in R3[D6:3]; CODEC_CLKIN
        via R101, CLKDIV_IN=MCLK via R102. Derived Q below.
      - DAC datapath R7 (L-DAC<-L, R-DAC<-R), DAC power R37, DAC volumes,
        and DAC -> LEFT_LOP/RIGHT_LOP routing (R82/R86/R92/R93). These match
        TI's published working line-out script.
      - Input routing register NUMBERS: R17/R18 = LINE2L/LINE2R (the line-in
        jack), R19/R22 = LINE1/MIC1 (the mic), R15/R16 = ADC PGA gain.
    STILL WORTH VERIFYING for your exact gains/levels:
      - The fully-differential MIC1 configuration bits (select_microphone).
      - Exact per-input level codes if you want non-0 dB analog gain.
"""

import time

AIC3104_I2C_ADDR = 0x18

# ---- Page 0 registers (decimal addresses, per SLAS510) ----
R_PAGE_SELECT   = 0
R_RESET         = 1     # write 0x80 -> self-clearing software reset
R_SAMPLE_RATE   = 2     # ADC/DAC fs divider (NCODEC); 0x00 = both at fsref
R_PLL_A         = 3     # D7 PLL enable, D6:3 Q (also the non-PLL divider), D2:0 P
R_PLL_B         = 4     # PLL J
R_PLL_C         = 5     # PLL D (MSB)
R_PLL_D         = 6     # PLL D (LSB)
R_DATAPATH      = 7     # D7 fsref(0=48k,1=44.1k), D4:3 L-DAC, D2:1 R-DAC datapath
R_SERIAL_A      = 8     # D7 BCLK dir, D6 WCLK dir (0=input=slave), 3-state...
R_SERIAL_B      = 9     # D7:6 transfer mode (00=I2S), D5:4 word length
R_SERIAL_C      = 10    # data offset
R_DIGITAL_FILT  = 12    # ADC high-pass filter enable
R_LEFT_PGA      = 15    # left ADC PGA gain  (D7 mute, D6:0 gain 0.5 dB steps)
R_RIGHT_PGA     = 16    # right ADC PGA gain
R_LINE2L_TO_L   = 17    # MIC2L/LINE2L -> left  ADC PGA (line-in left)
R_LINE2R_TO_R   = 18    # MIC2R/LINE2R -> right ADC PGA (line-in right)
R_LINE1LP_TO_L  = 19    # MIC1LP/LINE1LP -> left  ADC PGA; D2 powers left ADC
R_LINE1LM_TO_L  = 20    # MIC1LM/LINE1LM -> left  ADC PGA (diff -)
R_LINE1RP_TO_R  = 22    # MIC1RP/LINE1RP -> right ADC PGA; D2 powers right ADC
R_LINE1RM_TO_R  = 24    # MIC1RM/LINE1RM -> right ADC PGA (diff -)
R_MICBIAS       = 25    # D7:6 = 00 off, 01 2.0V, 10 2.5V, 11 AVDD
R_DAC_POWER     = 37    # D7 left DAC power, D6 right DAC power
R_DAC_SWITCH    = 41    # DAC_L1/DAC_R1 output path select
R_LDAC_VOL      = 43    # left DAC digital volume  (D7 mute, D6:0 atten 0.5 dB)
R_RDAC_VOL      = 44    # right DAC digital volume
R_DACL1_LEFTLOP = 82    # route DAC_L1 -> LEFT_LOP  (D7 route, D6:0 gain)
R_LEFTLOP_LVL   = 86    # LEFT_LOP output level / power-up / unmute
R_DACR1_RIGHTLOP= 92    # route DAC_R1 -> RIGHT_LOP
R_RIGHTLOP_LVL  = 93    # RIGHT_LOP output level / power-up / unmute
R_CLKGEN        = 101   # CODEC_CLKIN source: 0x00 = CLKDIV_OUT (no PLL)
R_CLKDIV        = 102   # CLKDIV_IN source: D7:6 = 00 -> MCLK


class AIC3104:
    def __init__(self, iic, gpio=None, addr=AIC3104_I2C_ADDR):
        self.iic = iic
        self.gpio = gpio
        self.addr = addr
        self.fs = None
        self._page = None
        self._input = None
        if not (hasattr(iic, "send") and hasattr(iic, "receive")):
            raise TypeError(f"Expected a PYNQ AxiIIC driver, got {type(iic)!r}.")

    # -- low-level I2C (cffi buffer for reads, page-aware) ------------------
    def _ffi(self):
        ffi = type(self.iic)._ffi
        if ffi is None:
            type(self.iic)._initialise_lib()
            ffi = type(self.iic)._ffi
        return ffi

    def _select_page(self, page):
        if page != self._page:
            self.iic.send(self.addr, bytes([R_PAGE_SELECT, page]), 2)
            self._page = page

    def w(self, reg, val, page=0):
        """Write one register on a given page."""
        self._select_page(page)
        self.iic.send(self.addr, bytes([reg & 0xFF, val & 0xFF]), 2)

    def r(self, reg, page=0):
        """Read one register on a given page (uses a cffi cdata buffer,
        which this PYNQ build's AxiIIC.receive requires)."""
        self._select_page(page)
        ffi = self._ffi()
        buf = ffi.new("unsigned char[]", 1)
        self.iic.send(self.addr, bytes([reg & 0xFF]), 1, self.iic.REPEAT_START)
        self.iic.receive(self.addr, buf, 1, 0)
        return buf[0]

    def reset_controller(self):
        """Soft-reset the AXI IIC core (SOFTR register @ 0x40, key 0x0A).
        A failed repeated-start read can wedge the controller; call this to
        recover, then re-scan."""
        self.iic.write(0x40, 0x0A)
        time.sleep(0.01)
        self._page = None

    def scan(self, lo=0x08, hi=0x78):
        """Non-destructive bus scan; expect ['0x18'] for the AIC3104."""
        ffi = self._ffi()
        found = []
        for a in range(lo, hi):
            try:
                self.iic.receive(a, ffi.new("unsigned char[]", 1), 1, 0)
                found.append(hex(a))
            except Exception:
                pass
        self._page = None
        return found

    # -- hardware reset (AIC_RST, if wired to axi_gpio_0) ------------------
    def hw_reset(self, channel=1, settle=0.005):
        """Pulse the codec RESET line low->high (AIC_RST is active-low).
        The GPIO channel/bit is board-specific -- confirm against the overlay.
        No-op if no gpio was supplied."""
        if self.gpio is None:
            return
        ch = self.gpio.channel[channel - 1] if hasattr(self.gpio, "channel") else self.gpio
        if hasattr(ch, "setdirection"):
            ch.setdirection("out")
        ch.write(0x0, 0xFFFFFFFF)          # assert reset (low)
        time.sleep(settle)
        ch.write(0xFFFFFFFF, 0xFFFFFFFF)   # release (high)
        time.sleep(settle)

    # -- clock planning ----------------------------------------------------
    @staticmethod
    def clock_plan(mclk_hz, fs):
        """Return (Q, ok) for the no-PLL path: fs = MCLK / (128 * Q).
        Q must be an integer in 2..17. ok is False if the PLL is required."""
        q_exact = mclk_hz / (128.0 * fs)
        q = int(round(q_exact))
        ok = abs(q_exact - q) < 1e-6 and 2 <= q <= 17
        return q, ok

    # -- full init ---------------------------------------------------------
    def init(self, mclk_hz=12_288_000, fs=48000, word_len=16):
        """Reset and configure: I2S slave, DAC -> line out, line-in -> ADC.

        No-PLL clocking: with the PLL disabled the codec reference rate is
        fs(ref) = CLKDIV_IN / (128 * Q), Q in R3[D6:3], and CODEC_CLK = 256*fsref.
        With CLKDIV_IN = MCLK this needs Q = MCLK / (128*fs); 12.288 MHz / 48 kHz
        gives Q = 2 exactly. A non-integer Q means you must run the PLL instead.
        """
        self.fs = fs
        self.hw_reset()                      # no-op unless gpio reset is known
        self.w(R_RESET, 0x80)                # software reset
        time.sleep(0.01)
        self._page = 0

        # ---- clocking (no PLL; CLKDIV_IN = MCLK) ----
        q, ok = self.clock_plan(mclk_hz, fs)
        if not ok:
            print(f"WARNING: MCLK={mclk_hz} Hz, fs={fs} Hz wants "
                  f"Q={mclk_hz/(128.0*fs):.3f}, not an integer in 2..17. The "
                  f"non-PLL divider can't hit this rate. Either set MCLK to "
                  f"128*Q*fs (e.g. {256*fs} Hz for Q=2) or program the PLL "
                  f"(R3-R6). Clamping Q={max(2, min(17, q))} for now.")
            q = max(2, min(17, q))
        #self.w(R_CLKDIV, 0x00)               # R102: CLKDIV_IN = MCLK (D7:6=00)
        #self.w(R_CLKGEN, 0x00)               # R101: CODEC_CLKIN = CLKDIV_OUT
        #self.w(R_PLL_A, ((q & 0x0F) << 3) | 0x01)  # R3: PLL off (D7=0), Q, P=1
        #self.w(R_SAMPLE_RATE, 0x00)          # R2: ADC=DAC=fsref (NCODEC=1)
        #self.w(R_SAMPLE_RATE, 0x00)          # R2: ADC=DAC=fsref (NCODEC=1)

        # ---- datapath: pick fsref base, route L->L and R->R ----
        fsref_44k = (fs % 11025 == 0)        # 44.1k family vs 48k family
        self.w(R_DATAPATH, (0x80 if fsref_44k else 0x00) | 0x0A)

        # ---- serial audio interface: I2S, slave, word length ----
        self.w(R_SERIAL_A, 0x00)             # BCLK & WCLK = inputs (codec slave)
        wl = {16: 0b00, 20: 0b01, 24: 0b10, 32: 0b11}.get(word_len, 0b00)
        #self.w(R_SERIAL_B, wl << 4)          # I2S (D7:6=00) + word length (D5:4)
        self.w(R_SERIAL_B, 0xF0)          # I2S (D7:6=00) + word length (D5:4)
        self.w(R_SERIAL_C, 0x00)             # no data offset
        self.w(R_DIGITAL_FILT, 0x00)         # ADC HPF off (0x50 to enable L&R)

        # ---- record path: default to line in ----
        self.w(R_LEFT_PGA, 0x00)             # left ADC PGA 0 dB, unmuted
        self.w(R_RIGHT_PGA, 0x00)            # right ADC PGA 0 dB, unmuted
        self.select_line_in()

        # ---- playback path: DAC -> LEFT_LOP / RIGHT_LOP (green jack J4) ----
        self.w(R_DAC_POWER, 0xC0)            # power up left + right DAC
        self.w(R_DAC_SWITCH, 0x00)           # DAC_L1 / DAC_R1 selected
        self.w(R_LDAC_VOL, 0x00)             # 0 dB, unmuted
        self.w(R_RDAC_VOL, 0x00)
        self.w(R_DACL1_LEFTLOP, 0x80)        # route DAC_L1 -> LEFT_LOP, 0 dB
        self.w(R_LEFTLOP_LVL, 0x09)          # LEFT_LOP power up + unmute
        self.w(R_DACR1_RIGHTLOP, 0x80)       # route DAC_R1 -> RIGHT_LOP, 0 dB
        self.w(R_RIGHTLOP_LVL, 0x09)         # RIGHT_LOP power up + unmute

    # -- input selection ---------------------------------------------------
    def select_line_in(self):
        """Route the line-in jack (LINE2L/LINE2R) into the ADC, 0 dB.
        LINE1/MIC1 is disconnected but its register still powers the ADC
        channel (D2)."""
        self.w(R_MICBIAS, 0x00)              # mic bias off
        self.w(R_LINE2L_TO_L, 0x00)          # LINE2L -> left  ADC, 0 dB
        self.w(R_LINE2R_TO_R, 0x00)          # LINE2R -> right ADC, 0 dB
        self.w(R_LINE1LP_TO_L, 0xFC)         # LINE1LP off (D7:4=1111), L ADC pwr
        self.w(R_LINE1RP_TO_R, 0xFC)         # LINE1RP off,             R ADC pwr
        self._input = "line_in"

    def select_microphone(self, bias=0b01):
        """Enable MICBIAS and route the mic jack (MIC1 -> LINE1) to the ADC.
        bias: 00 off, 01 2.0V, 10 2.5V, 11 AVDD.
        NOTE: this routes the LINE1 positive inputs and powers the ADC; the
        exact fully-differential bit config should be checked against SLAS510
        if you need true differential rejection on the mic pair."""
        self.w(R_MICBIAS, (bias & 0b11) << 6)
        self.w(R_LINE2L_TO_L, 0xF0)          # LINE2L disconnected
        self.w(R_LINE2R_TO_R, 0xF0)          # LINE2R disconnected
        self.w(R_LINE1LP_TO_L, 0x04)         # MIC1LP -> left  ADC, 0 dB + power
        self.w(R_LINE1LM_TO_L, 0x00)         # MIC1LM (differential -)
        self.w(R_LINE1RP_TO_R, 0x04)         # MIC1RP -> right ADC, 0 dB + power
        self.w(R_LINE1RM_TO_R, 0x00)         # MIC1RM (differential -)
        self._input = "microphone"

    # -- volume ------------------------------------------------------------
    def set_dac_volume(self, db=0):
        """DAC digital volume, 0 dB .. -63.5 dB in 0.5 dB steps (attenuation)."""
        atten = max(0, min(127, int(round(-db * 2))))   # 0.5 dB / step
        self.w(R_LDAC_VOL, atten & 0x7F)     # D7=0 -> unmuted
        self.w(R_RDAC_VOL, atten & 0x7F)

    def mute(self, muted=True):
        v = 0x80 if muted else 0x00
        self.w(R_LDAC_VOL, v)
        self.w(R_RDAC_VOL, v)

    # -- debug -------------------------------------------------------------
    def dump(self):
        """Read back key page-0 registers to confirm the I2C link. If these
        match what init() wrote (e.g. dac_power 0xc0, datapath 0x0a), the codec
        is talking and any silence is downstream in the I2S/clock path."""
        regs = {
            "sample_rate(2)": R_SAMPLE_RATE,
            "pll_a(3)":       R_PLL_A,
            "datapath(7)":    R_DATAPATH,
            "serial_a(8)":    R_SERIAL_A,
            "serial_b(9)":    R_SERIAL_B,
            "clkgen(101)":    R_CLKGEN,
            "clkdiv(102)":    R_CLKDIV,
            "dac_power(37)":  R_DAC_POWER,
            "ldac_vol(43)":   R_LDAC_VOL,
            "leftlop(86)":    R_LEFTLOP_LVL,
        }
        out = {}
        for name, reg in regs.items():
            try:
                out[name] = hex(self.r(reg))
            except Exception as e:           # noqa: BLE001
                out[name] = f"read error: {e}"
        return out
