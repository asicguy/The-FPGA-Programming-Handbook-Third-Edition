// ============================================================================
//  axi_dma_writer.sv
//
//  Simple stream-to-memory-map (S2MM) DMA write engine.
//
//  Purpose:
//    Given a DDR buffer base address and a length in bytes, consume samples
//    arriving on an AXI4-Stream slave port and burst them into that buffer
//    over an AXI4 (full) master write interface. Intended to sit downstream of
//    an I2S deserializer so audio capture happens at hardware rate with the
//    CPU out of the per-sample path.
//
//  Interface summary:
//    - cfg_*      : control inputs (wire to an AXI4-Lite slave or your reg block)
//    - s_axis_*   : AXI4-Stream slave, one sample (one beat) per AXI_DATA_WIDTH
//    - m_axi_*    : AXI4 master write channels (AW / W / B). Connect to a Zynq
//                   HP/HPC/ACP slave port (or an AXI interconnect to DDR).
//
//  Behaviour:
//    - On a cfg_start pulse it latches cfg_buf_addr / cfg_buf_len and writes
//      exactly cfg_buf_len bytes, then asserts sts_done and returns to idle.
//    - Data is buffered in an internal FIFO. A burst is only launched once the
//      FIFO holds a full burst's worth of beats, so the AXI W channel never
//      stalls mid-burst waiting for the audio clock.
//    - Bursts are sized to never cross a 4 KB boundary (AXI4 requirement) and
//      capped at MAX_BURST_LEN beats.
//    - Single outstanding burst at a time (issue AW -> stream W -> wait B).
//      This is plenty for 48 kHz audio; pipeline AW ahead of B for more BW.
//
//  Assumptions / caveats (READ THESE):
//    - cfg_buf_len must be a whole multiple of (AXI_DATA_WIDTH/8) bytes.
//    - wstrb is all-ones (full-width beats only). No sub-word writes.
//    - resetn is active-low (AXI convention).
//    - This has NOT been run through a simulator here. Verify in sim against an
//      AXI VIP / your DDR model before trusting it on hardware.
// ============================================================================

`timescale 1ns / 1ps

module axi_dma_writer #(
    // UltraScale+ note: set AXI_ADDR_WIDTH to match the HP/HPC slave port in
    // your block design (commonly 40 or 49). 32 is NOT safe on MPSoC boards
    // whose PYNQ CMA buffers can be placed above the 4 GB boundary.
    parameter int AXI_ADDR_WIDTH = 40,   // match the PS HP/HPC port width
    parameter int AXI_DATA_WIDTH = 32,   // 32 = one packed L/R sample per beat
    parameter int AXI_ID_WIDTH   = 6,    // ZynqMP HP IDs are wider than ZC7000
    parameter int MAX_BURST_LEN  = 16,   // AMD recommends 16 on MPSoC HP ports
    parameter int FIFO_DEPTH     = 1024  // power of two recommended
) (
    input  logic                          clk,
    input  logic                          resetn,      // active-low

    // ---- Control / status (drive from AXI-Lite slave or register block) ----
    input  logic [AXI_ADDR_WIDTH-1:0]     cfg_buf_addr,      // DDR buffer base (physical)
    input  logic [31:0]                   cfg_buf_len,       // buffer size in BYTES
    input  logic                          cfg_start,         // 1-cycle pulse to begin
    output logic                          sts_busy,
    output logic                          sts_done,          // held high once buffer filled
    output logic [31:0]                   sts_bytes_written,
    output logic                          sts_overflow,      // sticky: a sample was dropped
    output logic [1:0]                    sts_bresp,         // last write response captured

    // ---- Audio sample input: AXI4-Stream slave ----
    (* mark_debug = "true" *) input  logic [AXI_DATA_WIDTH-1:0]     s_axis_tdata,
    (* mark_debug = "true" *) input  logic                          s_axis_tvalid,
    (* mark_debug = "true" *) output logic                          s_axis_tready,

    // ---- AXI4 master: write address channel ----
    output logic [AXI_ID_WIDTH-1:0]       m_axi_awid,
    output logic [AXI_ADDR_WIDTH-1:0]     m_axi_awaddr,
    output logic [7:0]                    m_axi_awlen,
    output logic [2:0]                    m_axi_awsize,
    output logic [1:0]                    m_axi_awburst,
    output logic                          m_axi_awlock,
    output logic [3:0]                    m_axi_awcache,
    output logic [2:0]                    m_axi_awprot,
    output logic                          m_axi_awvalid,
    input  logic                          m_axi_awready,

    // ---- AXI4 master: write data channel ----
    output logic [AXI_DATA_WIDTH-1:0]     m_axi_wdata,
    output logic [AXI_DATA_WIDTH/8-1:0]   m_axi_wstrb,
    output logic                          m_axi_wlast,
    output logic                          m_axi_wvalid,
    input  logic                          m_axi_wready,

    // ---- AXI4 master: write response channel ----
    input  logic [AXI_ID_WIDTH-1:0]       m_axi_bid,
    input  logic [1:0]                    m_axi_bresp,
    input  logic                          m_axi_bvalid,
    output logic                          m_axi_bready
);

    // ------------------------------------------------------------------
    // Derived constants
    // ------------------------------------------------------------------
    localparam int BYTES_PER_BEAT = AXI_DATA_WIDTH / 8;
    localparam int AWSIZE_VAL     = $clog2(BYTES_PER_BEAT);   // AXI awsize encoding
    localparam int CNT_W          = $clog2(FIFO_DEPTH) + 1;   // FIFO count width
    localparam int PTR_W          = $clog2(FIFO_DEPTH);

    // ------------------------------------------------------------------
    // Static AXI master signal values
    // ------------------------------------------------------------------
    assign m_axi_awid    = '0;
    assign m_axi_awsize  = AWSIZE_VAL[2:0];
    assign m_axi_awburst = 2'b01;          // INCR
    assign m_axi_awlock  = 1'b0;
    // AxCACHE[3:2] selects coherency on MPSoC: 00 => non-coherent (plain HP
    // port), non-zero => coherent via CCI (HPC port + cacheable buffer).
    //   HP  (non-coherent): 4'b0011  (Normal, non-cacheable, bufferable)
    //   HPC (coherent)    : 4'b1111  (Write-back, allocate) -- also set the
    //                       buffer cacheable on the PYNQ side.
    assign m_axi_awcache = 4'b0011;        // default: non-coherent HP port
    assign m_axi_awprot  = 3'b000;
    assign m_axi_wstrb   = {(AXI_DATA_WIDTH/8){1'b1}};

    // ==================================================================
    //  Internal sample FIFO (simple synchronous FIFO)
    // ==================================================================
    logic [AXI_DATA_WIDTH-1:0] fifo_mem [0:FIFO_DEPTH-1];
    logic [PTR_W-1:0]          wr_ptr, rd_ptr;
    logic [CNT_W-1:0]          fifo_count;

    logic fifo_push, fifo_pop;
    logic fifo_full, fifo_empty;

    assign fifo_full  = (fifo_count == FIFO_DEPTH[CNT_W-1:0]);
    assign fifo_empty = (fifo_count == '0);

    // Accept a stream beat whenever there's room.
    assign s_axis_tready = ~fifo_full;
    assign fifo_push     = s_axis_tvalid & s_axis_tready;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            wr_ptr     <= '0;
            rd_ptr     <= '0;
            fifo_count <= '0;
        end else begin
            if (fifo_push) begin
                fifo_mem[wr_ptr] <= s_axis_tdata;
                wr_ptr           <= wr_ptr + 1'b1;
            end
            if (fifo_pop) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
            // Net count update (push and pop can occur in the same cycle)
            case ({fifo_push, fifo_pop})
                2'b10:   fifo_count <= fifo_count + 1'b1;
                2'b01:   fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end

    // ==================================================================
    //  DMA write FSM
    // ==================================================================
    typedef enum logic [2:0] {
        S_IDLE,
        S_DECIDE,
        S_ADDR,
        S_DATA,
        S_RESP,
        S_DONE
    } state_t;

    state_t state;

    logic [AXI_ADDR_WIDTH-1:0] base_addr;        // latched cfg_buf_addr
    logic [31:0]               total_bytes;      // latched cfg_buf_len
    logic [31:0]               bytes_committed;  // bytes whose AW has been issued+responded

    logic [AXI_ADDR_WIDTH-1:0] burst_addr;       // start address of current burst
    logic [8:0]                burst_beats;      // beats in current burst (1..256)
    logic [8:0]                beat_idx;         // beat counter within burst

    // --- Combinational burst-length computation (used in S_DECIDE) ---
    logic [31:0] remaining_bytes;
    logic [31:0] remaining_beats;
    logic [11:0] addr_low_12;       // low 12 bits of this burst's start addr
    logic [31:0] bytes_to_4k;       // distance to next 4 KB boundary
    logic [31:0] beats_to_4k;
    logic [31:0] chosen_beats;      // min() result, kept 32-bit to avoid width bugs
    logic [8:0]  beats_this_burst;

    always_comb begin
        remaining_bytes = total_bytes - bytes_committed;
        remaining_beats = remaining_bytes >> AWSIZE_VAL;

        // Low 12 bits of this burst's start address -> distance to the 4 KB
        // edge. Discarding the carry gives (addr mod 4096) for free.
        addr_low_12 = base_addr[11:0] + bytes_committed[11:0];
        bytes_to_4k = 32'd4096 - {20'd0, addr_low_12};
        beats_to_4k = bytes_to_4k >> AWSIZE_VAL;

        // burst = min(MAX_BURST_LEN, remaining_beats, beats_to_4k)
        // All operands are 32-bit unsigned, so the comparisons are unambiguous.
        chosen_beats = MAX_BURST_LEN;
        if (remaining_beats < chosen_beats) chosen_beats = remaining_beats;
        if (beats_to_4k     < chosen_beats) chosen_beats = beats_to_4k;
        beats_this_burst = chosen_beats[8:0];
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state           <= S_IDLE;
            base_addr       <= '0;
            total_bytes     <= '0;
            bytes_committed <= '0;
            burst_addr      <= '0;
            burst_beats     <= '0;
            beat_idx        <= '0;
            m_axi_awaddr    <= '0;
            m_axi_awlen     <= '0;
            m_axi_awvalid   <= 1'b0;
            m_axi_wvalid    <= 1'b0;
            m_axi_wlast     <= 1'b0;
            m_axi_bready    <= 1'b0;
            sts_busy        <= 1'b0;
            sts_done        <= 1'b0;
            sts_overflow    <= 1'b0;
            sts_bresp       <= 2'b00;
        end else begin
            // Sticky overflow: a sample was offered but the FIFO was full.
            if (s_axis_tvalid & ~s_axis_tready)
                sts_overflow <= 1'b1;

            case (state)
                // ----------------------------------------------------------
                S_IDLE: begin
                    sts_busy <= 1'b0;
                    if (cfg_start && (cfg_buf_len != 32'd0)) begin
                        base_addr       <= cfg_buf_addr;
                        total_bytes     <= cfg_buf_len;
                        bytes_committed <= 32'd0;
                        sts_busy        <= 1'b1;
                        sts_done        <= 1'b0;
                        sts_overflow    <= 1'b0;
                        state           <= S_DECIDE;
                    end
                end

                // ----------------------------------------------------------
                // Work out the next burst length and wait until the FIFO holds
                // enough beats that the W channel won't stall mid-burst.
                S_DECIDE: begin
                    if (bytes_committed >= total_bytes) begin
                        state <= S_DONE;
                    end else if ({{(32-CNT_W){1'b0}}, fifo_count} >= chosen_beats) begin
                        burst_addr    <= base_addr + bytes_committed;
                        burst_beats   <= beats_this_burst;
                        beat_idx      <= 9'd0;
                        m_axi_awaddr  <= base_addr + bytes_committed;
                        m_axi_awlen   <= beats_this_burst[7:0] - 8'd1; // awlen = beats-1
                        m_axi_awvalid <= 1'b1;
                        state         <= S_ADDR;
                    end
                end

                // ----------------------------------------------------------
                S_ADDR: begin
                    if (m_axi_awready && m_axi_awvalid) begin
                        m_axi_awvalid <= 1'b0;
                        m_axi_wvalid  <= 1'b1;
                        m_axi_wlast   <= (burst_beats == 9'd1);
                        state         <= S_DATA;
                    end
                end

                // ----------------------------------------------------------
                S_DATA: begin
                    // Gate wvalid on FIFO occupancy as a safety net; by
                    // construction the FIFO already holds >= burst_beats beats.
                    m_axi_wvalid <= ~fifo_empty;
                    m_axi_wlast  <= ((beat_idx == burst_beats - 9'd1) & ~fifo_empty);

                    if (m_axi_wvalid && m_axi_wready) begin
                        if (beat_idx == burst_beats - 9'd1) begin
                            // Last beat accepted -> close out the W channel.
                            m_axi_wvalid <= 1'b0;
                            m_axi_wlast  <= 1'b0;
                            m_axi_bready <= 1'b1;
                            state        <= S_RESP;
                        end else begin
                            beat_idx <= beat_idx + 9'd1;
                        end
                    end
                end

                // ----------------------------------------------------------
                S_RESP: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready    <= 1'b0;
                        sts_bresp       <= m_axi_bresp;
                        bytes_committed <= bytes_committed
                                           + ({23'd0, burst_beats} << AWSIZE_VAL);
                        state           <= S_DECIDE;
                    end
                end

                // ----------------------------------------------------------
                S_DONE: begin
                    sts_busy <= 1'b0;
                    sts_done <= 1'b1;
                    // Wait for start to be deasserted before allowing re-arm.
                    if (!cfg_start)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // FIFO read data drives the W channel; pop on accepted W beat.
    assign m_axi_wdata = fifo_mem[rd_ptr];
    assign fifo_pop    = (state == S_DATA) & m_axi_wvalid & m_axi_wready;

    assign sts_bytes_written = bytes_committed;

endmodule
