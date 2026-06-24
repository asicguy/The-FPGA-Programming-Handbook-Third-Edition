//============================================================================
// i2s_sine_gen.sv
//
// I2S transmitter with an internal sine-wave (DDS) source.
//
//   * Internal 16-bit signed (two's-complement) left / right sample registers
//   * Direct Digital Synthesis: phase accumulator + sine ROM lookup
//   * The I2S bus clocks (sclk / bclk / lrclk) are ALL INPUTS, so this block
//     is an I2S slave / clock-follower.
//
//   sclk   : system / master clock (a.k.a. MCLK). Drives ALL logic.
//            Must be several times faster than bclk - true for the usual
//            MCLK = 256*fs with bclk = 32..64*fs relationship (>= ~4x bclk).
//   bclk   : bit clock (input).  Serial data is updated on its falling edge.
//   lrclk  : word-select / frame clock (input). Selects L vs R; its
//            frequency is the audio sample rate fs.
//   sdata  : serial audio data out, MSB-first, two's complement.
//
//   bclk and lrclk are treated as asynchronous inputs: they are
//   double-flop synchronized into the sclk domain and sampled there on
//   synchronized bclk falling edges. No real clock is gated, so the whole
//   design is fully synchronous to sclk.
//============================================================================
module i2s_sine_gen #(
    parameter int DATA_WIDTH     = 16,           // sample width (bits)
    parameter int PHASE_WIDTH    = 32,           // phase accumulator width
    parameter int LUT_ADDR_WIDTH = 8,            // sine ROM has 2^N entries

    // Frequency tuning word:  PHASE_INC = round(f_tone / fs * 2^PHASE_WIDTH)
    // Default below ~= 1 kHz tone at fs = 48 kHz with PHASE_WIDTH = 32.
    parameter logic [PHASE_WIDTH-1:0] PHASE_INC = 32'd89478485,

    // Phase offset (in phase-accumulator units) applied to the RIGHT channel.
    //   0                  -> both channels identical
    //   2^(PHASE_WIDTH-2)  -> right lags left by 90 degrees
    parameter logic [PHASE_WIDTH-1:0] R_PHASE_OFFSET = '0,

    // I2S framing:
    //   I2S_DELAY    = 1 -> standard Philips I2S (MSB delayed 1 bclk after WS)
    //                = 0 -> left-justified       (MSB on the WS edge)
    //   WS_LEFT_LVL  = level of lrclk that selects the LEFT channel
    //                  (standard I2S: WS low = left -> 1'b0)
    parameter bit I2S_DELAY   = 1'b1,
    parameter bit WS_LEFT_LVL = 1'b0
)(
    input  logic sclk,      // master clock (fast)
    input  logic rst_n,     // async active-low reset
    input  logic bclk,      // I2S bit clock   (input)
    input  logic lrclk,     // I2S word select (input)
    output logic sdata      // I2S serial data (output)
);

    localparam int LUT_SIZE = (1 << LUT_ADDR_WIDTH);

    //------------------------------------------------------------------
    // Sine ROM, filled at elaboration time.
    // For synthesis flows that dislike $sin in an initial block, replace
    // the loop with $readmemh("sine_rom.hex", sine_rom);
    //------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0] sine_rom [LUT_SIZE];

    function automatic logic signed [DATA_WIDTH-1:0] sine_sample(input int idx);
        real pi, angle, s;
        begin
            pi    = 3.14159265358979323846;
            angle = (2.0 * pi * idx) / real'(LUT_SIZE);
            s     = $sin(angle);
            // full-scale signed amplitude, rounded to nearest
            sine_sample = integer'(s * (2.0**(DATA_WIDTH-1) - 1.0));
        end
    endfunction

    initial begin
        for (int i = 0; i < LUT_SIZE; i++)
            sine_rom[i] = sine_sample(i);
    end

    //------------------------------------------------------------------
    // Synchronize bclk / lrclk into the sclk domain + bclk edge detect
    //------------------------------------------------------------------
    logic [1:0] bclk_sync, lrclk_sync;
    logic       bclk_s_d;

    always_ff @(posedge sclk or negedge rst_n) begin
        if (!rst_n) begin
            bclk_sync  <= '0;
            lrclk_sync <= '0;
            bclk_s_d   <= 1'b0;
        end else begin
            bclk_sync  <= {bclk_sync[0],  bclk};
            lrclk_sync <= {lrclk_sync[0], lrclk};
            bclk_s_d   <= bclk_sync[1];
        end
    end

    wire bclk_s    = bclk_sync[1];
    wire lrclk_s   = lrclk_sync[1];
    wire bclk_fall = bclk_s_d & ~bclk_s;     // 1->0 on synchronized bclk

    //------------------------------------------------------------------
    // DDS phase accumulator + combinational ROM lookups
    //------------------------------------------------------------------
    logic [PHASE_WIDTH-1:0] phase_acc;
    wire  [PHASE_WIDTH-1:0] phase_next   = phase_acc + PHASE_INC;
    wire  [PHASE_WIDTH-1:0] phase_next_r = phase_next + R_PHASE_OFFSET;

    wire [LUT_ADDR_WIDTH-1:0] idx_l = phase_next  [PHASE_WIDTH-1 -: LUT_ADDR_WIDTH];
    wire [LUT_ADDR_WIDTH-1:0] idx_r = phase_next_r[PHASE_WIDTH-1 -: LUT_ADDR_WIDTH];

    wire signed [DATA_WIDTH-1:0] sine_l_next = sine_rom[idx_l];
    wire signed [DATA_WIDTH-1:0] sine_r_next = sine_rom[idx_r];

    //------------------------------------------------------------------
    // I2S transmit engine + internal L/R sample registers.
    // Everything is in the sclk domain and only advances on synchronized
    // bclk falling edges (the edge on which an I2S transmitter drives data).
    //------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0]     sample_r;   // right held until its WS phase
    logic        [DATA_WIDTH-1:0]     shifter;    // MSB-first shift register
    logic [$clog2(DATA_WIDTH+1)-1:0]  bit_cnt;    // data bits emitted this word
    logic                             ws_prev;    // lrclk sampled at last bclk fall

    always_ff @(posedge sclk or negedge rst_n) begin
        if (!rst_n) begin
            phase_acc <= '0;
            sample_r  <= '0;
            shifter   <= '0;
            bit_cnt   <= '0;
            ws_prev   <= WS_LEFT_LVL;
            sdata     <= 1'b0;
        end else if (bclk_fall) begin
            automatic logic                       ws_changed = (lrclk_s != ws_prev);
            automatic logic                       now_left   = (lrclk_s == WS_LEFT_LVL);
            automatic logic signed [DATA_WIDTH-1:0] new_word;

            ws_prev <= lrclk_s;

            if (ws_changed) begin
                // --- start of a new channel word ---
                if (now_left) begin
                    // new audio frame: advance the DDS, latch L and R samples
                    new_word  = sine_l_next;
                    phase_acc <= phase_next;
                    sample_r  <= sine_r_next;
                end else begin
                    new_word  = sample_r;
                end

                if (I2S_DELAY) begin
                    sdata   <= 1'b0;        // 1-bclk delay slot before MSB
                    shifter <= new_word;    // MSB leaves on the next bclk fall
                    bit_cnt <= '0;
                end else begin
                    sdata   <= new_word[DATA_WIDTH-1];            // MSB now
                    shifter <= {new_word[DATA_WIDTH-2:0], 1'b0};
                    bit_cnt <= 'd1;
                end
            end else begin
                // --- mid-word: stream remaining bits, then pad with 0 ---
                if (bit_cnt < DATA_WIDTH) begin
                    sdata   <= shifter[DATA_WIDTH-1];
                    shifter <= {shifter[DATA_WIDTH-2:0], 1'b0};
                    bit_cnt <= bit_cnt + 1'b1;
                end else begin
                    sdata   <= 1'b0;        // unused slots until next WS edge
                end
            end
        end
    end

endmodule
