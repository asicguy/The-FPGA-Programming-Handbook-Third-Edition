// ============================================================================
//  axi_dma_reader.sv
//
//  Simple memory-map-to-stream (MM2S) DMA read engine with read-ahead.
//
//  Purpose:
//    Given a DDR buffer base address and a length in bytes, read that buffer
//    over an AXI4 (full) master read interface and emit it as an AXI4-Stream.
//    The mirror image of axi_dma_writer.sv -- use it to play a captured buffer
//    back out (e.g. into an I2S transmitter) at hardware rate.
//
//  Keeping the output FIFO from going empty (the read-ahead mechanism):
//    Two things work together.
//      1. Credit-based outstanding bursts. The engine tracks "reserved" FIFO
//         space = (beats currently in the FIFO) + (beats requested on AR but
//         not yet returned on R). It issues a new read burst whenever
//         reserved + next_burst <= FIFO_DEPTH. This lets MANY bursts be in
//         flight at once, so the FIFO is refilled well ahead of the stream
//         draining it -- a generalisation of ping-pong double buffering.
//      2. Prime threshold. The stream output (tvalid) is held off at the start
//         of a transfer until the FIFO has filled to PRIME_THRESHOLD beats (or
//         the whole buffer has been fetched, whichever comes first). This hides
//         the initial AXI read latency so the very first samples don't underrun.
//    sts_underflow latches high if the consumer ever asserts tready while the
//    FIFO is empty mid-stream -- i.e. read-ahead failed to keep up. If you see
//    it, increase FIFO_DEPTH / PRIME_THRESHOLD or the AXI clock/bandwidth.
//
//  Interface summary:
//    - cfg_*    : control inputs (wire to an AXI4-Lite slave / register block)
//    - m_axi_*  : AXI4 master READ channels (AR / R). Connect to a Zynq
//                 UltraScale+ HP/HPC slave port (or interconnect to DDR).
//    - m_axis_* : AXI4-Stream master output, one beat per AXI_DATA_WIDTH word.
//
//  Assumptions / caveats (READ THESE):
//    - cfg_buf_len must be a whole multiple of (AXI_DATA_WIDTH/8) bytes.
//    - resetn is active-low (AXI convention).
//    - PRIME_THRESHOLD must be <= FIFO_DEPTH.
//    - Set AXI_ADDR_WIDTH to match the PS HP/HPC port (40 or 49 on MPSoC);
//      32 is NOT safe where PYNQ buffers land above the 4 GB boundary.
//    - NOT simulated here. Verify in a testbench against an AXI VIP / DDR model
//      before trusting on hardware. Watch the 4 KB-boundary burst math, the
//      credit (reserved-space) accounting, and the FIFO push/pop counters.
// ============================================================================

`timescale 1ns / 1ps

module axi_dma_reader #(
    parameter int AXI_ADDR_WIDTH  = 40,    // match the PS HP/HPC port width
    parameter int AXI_DATA_WIDTH  = 32,    // 32 = one packed L/R sample per beat
    parameter int AXI_ID_WIDTH    = 6,
    parameter int MAX_BURST_LEN   = 16,    // AMD recommends 16 on MPSoC HP ports
    parameter int FIFO_DEPTH      = 1024,  // power of two recommended
    parameter int PRIME_THRESHOLD = 512    // fill cushion before streaming starts
) (
    input  logic                          clk,
    input  logic                          resetn,      // active-low

    // ---- Control / status (drive from AXI-Lite slave or register block) ----
    input  logic [AXI_ADDR_WIDTH-1:0]     cfg_buf_addr,      // DDR buffer base (physical)
    input  logic [31:0]                   cfg_buf_len,       // buffer size in BYTES
    input  logic                          cfg_start,         // 1-cycle pulse to begin
    output logic                          sts_busy,
    output logic                          sts_done,          // held high once buffer streamed
    output logic [31:0]                   sts_bytes_read,
    output logic                          sts_underflow,     // sticky: FIFO went empty mid-stream
    output logic [1:0]                    sts_rresp,         // last read response captured

    // ---- AXI4 master: read address channel ----
    output logic [AXI_ID_WIDTH-1:0]       m_axi_arid,
    output logic [AXI_ADDR_WIDTH-1:0]     m_axi_araddr,
    output logic [7:0]                    m_axi_arlen,
    output logic [2:0]                    m_axi_arsize,
    output logic [1:0]                    m_axi_arburst,
    output logic                          m_axi_arlock,
    output logic [3:0]                    m_axi_arcache,
    output logic [2:0]                    m_axi_arprot,
    output logic                          m_axi_arvalid,
    input  logic                          m_axi_arready,

    // ---- AXI4 master: read data channel ----
    input  logic [AXI_DATA_WIDTH-1:0]     m_axi_rdata,
    input  logic [1:0]                    m_axi_rresp,
    input  logic                          m_axi_rlast,
    input  logic                          m_axi_rvalid,
    output logic                          m_axi_rready,

    // ---- AXI4-Stream master output ----
    (* mark_debug = "true" *) output logic [AXI_DATA_WIDTH-1:0]     m_axis_tdata,
    (* mark_debug = "true" *) output logic                          m_axis_tvalid,
    (* mark_debug = "true" *) input  logic                          m_axis_tready,
    output logic                          m_axis_tlast
);

    // ------------------------------------------------------------------
    // Derived constants
    // ------------------------------------------------------------------
    localparam int BYTES_PER_BEAT = AXI_DATA_WIDTH / 8;
    localparam int ARSIZE_VAL     = $clog2(BYTES_PER_BEAT);
    localparam int CNT_W          = $clog2(FIFO_DEPTH) + 1;   // FIFO count width
    localparam int PTR_W          = $clog2(FIFO_DEPTH);

    // ------------------------------------------------------------------
    // Static AXI master signal values
    // ------------------------------------------------------------------
    assign m_axi_arid    = '0;
    assign m_axi_arsize  = ARSIZE_VAL[2:0];
    assign m_axi_arburst = 2'b01;          // INCR
    assign m_axi_arlock  = 1'b0;
    // AxCACHE[3:2]==00 => non-coherent (plain HP port). Use 4'b1111 for a
    // coherent HPC port, and allocate the buffer cacheable on the PYNQ side.
    assign m_axi_arcache = 4'b0011;        // Normal, non-cacheable, bufferable
    assign m_axi_arprot  = 3'b000;

    // ==================================================================
    //  Output sample FIFO (simple synchronous FIFO)
    // ==================================================================
    logic [AXI_DATA_WIDTH-1:0] fifo_mem [0:FIFO_DEPTH-1];
    logic [PTR_W-1:0]          wr_ptr, rd_ptr;
    logic [CNT_W-1:0]          fifo_count;

    logic fifo_push, fifo_pop;
    logic fifo_full, fifo_empty;

    assign fifo_full  = (fifo_count == FIFO_DEPTH[CNT_W-1:0]);
    assign fifo_empty = (fifo_count == '0);

    // ==================================================================
    //  Control / counters
    // ==================================================================
    typedef enum logic [1:0] { S_IDLE, S_RUN, S_DONE } state_t;
    state_t state;
    logic   run;
    assign  run = (state == S_RUN);

    logic [AXI_ADDR_WIDTH-1:0] base_addr;
    logic [31:0]               total_bytes;
    logic [31:0]               total_beats;
    logic [31:0]               bytes_issued;    // bytes whose AR has been accepted
    logic [31:0]               beats_streamed;  // beats popped to the stream
    logic [15:0]               inflight_beats;  // AR-requested, not yet on R
    logic                      primed;          // cushion built -> streaming allowed

    // ==================================================================
    //  AR-issue sub-FSM
    // ==================================================================
    typedef enum logic [0:0] { AR_IDLE, AR_REQ } ar_state_t;
    ar_state_t ar_state;
    logic [8:0] burst_beats_q;                  // beats latched for the in-flight AR

    // --- Combinational next-burst sizing (mirrors the writer) ---
    logic [31:0] remaining_bytes;
    logic [31:0] remaining_beats;
    logic [11:0] addr_low_12;
    logic [31:0] bytes_to_4k;
    logic [31:0] beats_to_4k;
    logic [31:0] chosen_beats;
    logic [31:0] reserved;       // FIFO space already spoken for
    logic        can_issue;

    always_comb begin
        remaining_bytes = total_bytes - bytes_issued;
        remaining_beats = remaining_bytes >> ARSIZE_VAL;

        // Distance to the next 4 KB boundary from this burst's start address.
        addr_low_12 = base_addr[11:0] + bytes_issued[11:0];
        bytes_to_4k = 32'd4096 - {20'd0, addr_low_12};
        beats_to_4k = bytes_to_4k >> ARSIZE_VAL;

        // next burst = min(MAX_BURST_LEN, remaining_beats, beats_to_4k)
        chosen_beats = MAX_BURST_LEN;
        if (remaining_beats < chosen_beats) chosen_beats = remaining_beats;
        if (beats_to_4k     < chosen_beats) chosen_beats = beats_to_4k;

        // Read-ahead credit: only issue if the returning data is guaranteed a
        // home in the FIFO. reserved = in-FIFO beats + in-flight beats.
        reserved  = {{(32-CNT_W){1'b0}}, fifo_count}
                  + {16'd0, inflight_beats};
        can_issue = run
                  && (bytes_issued < total_bytes)
                  && (chosen_beats != 32'd0)
                  && ((reserved + chosen_beats) <= FIFO_DEPTH);
    end

    // ar_commit: the cycle an AR request is accepted by the slave.
    logic ar_commit;
    assign ar_commit = (ar_state == AR_REQ) && m_axi_arvalid && m_axi_arready;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            ar_state      <= AR_IDLE;
            m_axi_arvalid <= 1'b0;
            m_axi_araddr  <= '0;
            m_axi_arlen   <= '0;
            burst_beats_q <= 9'd0;
        end else begin
            case (ar_state)
                AR_IDLE: begin
                    if (can_issue) begin
                        m_axi_araddr  <= base_addr + bytes_issued;
                        m_axi_arlen   <= chosen_beats[7:0] - 8'd1;  // arlen = beats-1
                        burst_beats_q <= chosen_beats[8:0];
                        m_axi_arvalid <= 1'b1;
                        ar_state      <= AR_REQ;
                    end
                end
                AR_REQ: begin
                    if (m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        ar_state      <= AR_IDLE;
                    end
                end
                default: ar_state <= AR_IDLE;
            endcase
        end
    end

    // ==================================================================
    //  R-data capture  (always accept when FIFO has room)
    // ==================================================================
    assign m_axi_rready = ~fifo_full;           // credit accounting keeps this true
    logic r_beat;
    assign r_beat    = m_axi_rvalid && m_axi_rready;
    assign fifo_push = r_beat;

    // ==================================================================
    //  Stream output  (gated by the prime cushion)
    // ==================================================================
    logic all_fetched;
    assign all_fetched = (bytes_issued >= total_bytes) && (inflight_beats == 16'd0);

    assign m_axis_tdata  = fifo_mem[rd_ptr];
    assign m_axis_tvalid = run && primed && ~fifo_empty;
    assign m_axis_tlast  = m_axis_tvalid && (beats_streamed == (total_beats - 32'd1));
    assign fifo_pop      = m_axis_tvalid && m_axis_tready;

    // ==================================================================
    //  FIFO storage + count
    // ==================================================================
    always_ff @(posedge clk) begin
        if (!resetn) begin
            wr_ptr     <= '0;
            rd_ptr     <= '0;
            fifo_count <= '0;
        end else begin
            if (fifo_push) begin
                fifo_mem[wr_ptr] <= m_axi_rdata;
                wr_ptr           <= wr_ptr + 1'b1;
            end
            if (fifo_pop) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
            case ({fifo_push, fifo_pop})
                2'b10:   fifo_count <= fifo_count + 1'b1;
                2'b01:   fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end

    // ==================================================================
    //  Main control: counters, priming, completion, status
    // ==================================================================
    always_ff @(posedge clk) begin
        if (!resetn) begin
            state          <= S_IDLE;
            base_addr      <= '0;
            total_bytes    <= '0;
            total_beats    <= '0;
            bytes_issued   <= 32'd0;
            beats_streamed <= 32'd0;
            inflight_beats <= 16'd0;
            primed         <= 1'b0;
            sts_busy       <= 1'b0;
            sts_done       <= 1'b0;
            sts_underflow  <= 1'b0;
            sts_rresp      <= 2'b00;
        end else begin
            // ---- in-flight beat accounting (commit adds, each R beat removes)
            unique case ({ar_commit, r_beat})
                2'b10: inflight_beats <= inflight_beats + {7'd0, burst_beats_q};
                2'b01: inflight_beats <= inflight_beats - 16'd1;
                2'b11: inflight_beats <= inflight_beats + {7'd0, burst_beats_q} - 16'd1;
                default: inflight_beats <= inflight_beats;
            endcase

            // ---- bytes issued advances when an AR is accepted
            if (ar_commit)
                bytes_issued <= bytes_issued
                              + ({23'd0, burst_beats_q} << ARSIZE_VAL);

            // ---- capture read response (sticky on error)
            if (r_beat && (m_axi_rresp != 2'b00))
                sts_rresp <= m_axi_rresp;

            // ---- beats streamed out
            if (fifo_pop)
                beats_streamed <= beats_streamed + 32'd1;

            // ---- prime: latch high once the cushion is met (or all data is in)
            if (!primed && ((fifo_count >= PRIME_THRESHOLD[CNT_W-1:0]) || all_fetched))
                primed <= 1'b1;

            // ---- underflow: consumer wanted data but FIFO was empty mid-stream
            if (run && primed && m_axis_tready && fifo_empty
                     && (beats_streamed < total_beats))
                sts_underflow <= 1'b1;

            // ---- top-level state machine
            case (state)
                S_IDLE: begin
                    sts_busy <= 1'b0;
                    if (cfg_start && (cfg_buf_len != 32'd0)) begin
                        base_addr      <= cfg_buf_addr;
                        total_bytes    <= cfg_buf_len;
                        total_beats    <= cfg_buf_len >> ARSIZE_VAL;
                        bytes_issued   <= 32'd0;
                        beats_streamed <= 32'd0;
                        inflight_beats <= 16'd0;
                        primed         <= 1'b0;
                        sts_underflow  <= 1'b0;
                        sts_busy       <= 1'b1;
                        sts_done       <= 1'b0;
                        state          <= S_RUN;
                    end
                end

                S_RUN: begin
                    if (beats_streamed == total_beats) begin
                        sts_busy <= 1'b0;
                        sts_done <= 1'b1;
                        state    <= S_DONE;
                    end
                end

                S_DONE: begin
                    if (!cfg_start)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign sts_bytes_read = bytes_issued;

endmodule
