module aic3104_dma
  #
  (
   parameter int AXI_ADDR_WIDTH = 40, // match the PS HP/HPC port width
   parameter int AXI_DATA_WIDTH = 32, // 32 = one packed L/R sample per beat
   parameter int AXI_ID_WIDTH = 6, // ZynqMP HP IDs are wider than ZC7000
   parameter int MAX_BURST_LEN = 16, // AMD recommends 16 on MPSoC HP ports
   parameter int FIFO_DEPTH = 1024  // power of two recommended
   )
  (
   // AXI lite interface for register acceess
   input                               s_axi_aclk,
   input                               s_axi_aresetn,
   input [21:0]                        s_axi_awaddr,
   input                               s_axi_awvalid,
   output logic                        s_axi_awready,
   input [31:0]                        s_axi_wdata,
   input [3:0]                         s_axi_wstrb,
   input                               s_axi_wvalid,
   output logic                        s_axi_wready,
   output logic [1:0]                  s_axi_bresp,
   output logic                        s_axi_bvalid,
   input                               s_axi_bready,
   input [21:0]                        s_axi_araddr,
   input                               s_axi_arvalid,
   output logic                        s_axi_arready,
   output logic [31:0]                 s_axi_rdata,
   output logic [1:0]                  s_axi_rresp,
   output logic                        s_axi_rvalid,
   input                               s_axi_rready,

   // AXI Memory Master Write interface for Audio capture
   output logic [AXI_ID_WIDTH-1:0]     m_axi_awid,
   output logic [AXI_ADDR_WIDTH-1:0]   m_axi_awaddr,
   output logic [7:0]                  m_axi_awlen,
   output logic [2:0]                  m_axi_awsize,
   output logic [1:0]                  m_axi_awburst,
   output logic                        m_axi_awlock,
   output logic [3:0]                  m_axi_awcache,
   output logic [2:0]                  m_axi_awprot,
   output logic                        m_axi_awvalid,
   input                               m_axi_awready,

    // ---- AXI4 master: write data channel ----
   output logic [AXI_DATA_WIDTH-1:0]   m_axi_wdata,
   output logic [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
   output logic                        m_axi_wlast,
   output logic                        m_axi_wvalid,
   input                               m_axi_wready,

    // ---- AXI4 master: write response channel ----
   input [AXI_ID_WIDTH-1:0]            m_axi_bid,
   input [1:0]                         m_axi_bresp,
   input                               m_axi_bvalid,
   output logic                        m_axi_bready,

    // ---- AXI4 master: read address channel (playback / MM2S) ----
   output logic [AXI_ID_WIDTH-1:0]     m_axi_arid,
   output logic [AXI_ADDR_WIDTH-1:0]   m_axi_araddr,
   output logic [7:0]                  m_axi_arlen,
   output logic [2:0]                  m_axi_arsize,
   output logic [1:0]                  m_axi_arburst,
   output logic                        m_axi_arlock,
   output logic [3:0]                  m_axi_arcache,
   output logic [2:0]                  m_axi_arprot,
   output logic                        m_axi_arvalid,
   input                               m_axi_arready,

    // ---- AXI4 master: read data channel ----
   input [AXI_DATA_WIDTH-1:0]          m_axi_rdata,
   input [1:0]                         m_axi_rresp,
   input                               m_axi_rlast,
   input                               m_axi_rvalid,
   output logic                        m_axi_rready,

   output logic                        interrupt_out,

   input                               AIC_mclk_o,
   output logic                        AIC_lrclk_o,
   output logic                        AIC_sclk_o,
   input                               i2s_sdata_i,
   output logic                        i2s_sdata_o
   );

  localparam            REG_TX_ADDR_LO    = 12'h0;
  localparam            REG_TX_ADDR_HI    = 12'h4;
  localparam            REG_TX_BYTES      = 12'h8;
  localparam            REG_TX_START      = 12'hc;
  localparam            REG_TX_BYTES_READ = 12'h10;
  localparam            REG_TX_STAT       = 12'h14;
  localparam            REG_RX_ADDR_LO    = 12'h100;
  localparam            REG_RX_ADDR_HI    = 12'h104;
  localparam            REG_RX_BYTES      = 12'h108;
  localparam            REG_RX_START      = 12'h10c;
  localparam            REG_RX_BYTES_READ = 12'h110;
  localparam            REG_RX_STAT       = 12'h114;
  localparam            REG_DEV           = 12'h200;
  localparam            REG_VER           = 12'h204;
  localparam            REG_INT           = 12'h208;

  typedef enum bit [1:0] {RD_IDLE, RD_WAIT, RD_W4RREADY} axil_rd_cs_t;
  typedef enum bit [1:0] {WR_IDLE, WR_W4ADDR, WR_W4DATA, WR_BRESP} axil_cs_t;
  typedef enum bit [1:0] {IDLE, INTERRUPT, DIVIDE} state_t;
  typedef enum bit [1:0] {ADD, SUB, MUL, DIV} operator_t;

  axil_rd_cs_t     axil_rd_cs;
  axil_cs_t        axil_cs;

  (* mark_debug = "true" *) logic [15:0] rd_addr;
  (* mark_debug = "true" *) logic [31:0] read_data;
  logic [31:0] axil_din;
  logic [3:0]  axil_be;
  logic        axil_we;
  logic [15:0] axil_addr;
  logic        set_int;
  logic [7:0]  tx_ctrl = '0;
  logic [15:0] tx_count, rx_count;
  logic [31:0] tx_data;
  logic [63:0] tx_dout;
  (* mark_debug = "true" *) logic [31:0] rx_data;
  (* mark_debug = "true" *) logic        rx_push;
  logic        tx_pop;
  logic [31:0] tx_din;
  logic        tx_push;
  logic        tx_stream_valid, tx_stream_ready;
  logic        tx_empty;
  (* mark_debug = "true" *) logic        rx_empty;
  (* mark_debug = "true" *) logic        rx_pop;
  logic        tx_full;
  (* mark_debug = "true" *) logic [63:0] rx_din;
  logic [63:0] buf_rd_addr, buf_wr_addr;
  logic [31:0] buf_rd_count, buf_wr_count;
  (* mark_debug = "true" *) logic        rd_start;
  (* mark_debug = "true" *) logic        rd_busy;
  (* mark_debug = "true" *) logic        rd_done;
  logic [31:0] rd_bytes_written;
  logic        rd_overflow;
  logic [1:0]  rd_bresp;
  logic        wr_start;
  logic        wr_busy;
  (* mark_debug = "true" *) logic        wr_done;
  logic [31:0] wr_bytes_read;
  logic        wr_underflow;
  logic [1:0]  wr_bresp;
  logic        rd_tready;

  // AXI Read Channel
  always @(posedge s_axi_aclk) begin
    s_axi_arready <= '1;
    s_axi_rvalid  <= '0;
    s_axi_rresp   <= '0;

    case (axil_rd_cs)
      RD_IDLE: begin
        if (s_axi_arvalid) begin
          s_axi_arready <= '0;
          rd_addr       <= s_axi_araddr[15:0];
          axil_rd_cs    <= RD_WAIT;
        end
      end
      RD_WAIT: begin
        s_axi_arready <= '0;
        axil_rd_cs    <= RD_W4RREADY;
      end
      RD_W4RREADY: begin
        s_axi_arready <= '0;
        s_axi_rdata   <= read_data;
        s_axi_rvalid  <= '1;
        if (s_axi_rready && s_axi_rvalid) begin
          s_axi_arready <= '1;
          s_axi_rvalid  <= '0;
          axil_rd_cs    <= RD_IDLE;
        end
      end
    endcase // case (axil_rd_cs)
    if (~s_axi_aresetn) begin
      axil_rd_cs <= RD_IDLE;
    end
  end

  // AXI Write Channel
  always @(posedge s_axi_aclk) begin
    axil_we       <= '0;
    s_axi_bvalid  <= '0;
    s_axi_bresp   <= '0; // OKAY

    case (axil_cs)
      WR_IDLE: begin
        s_axi_awready <= '1;
        s_axi_wready  <= '1;
        case ({s_axi_awvalid, s_axi_wvalid})
          2'b11: begin
            s_axi_awready <= '0;
            s_axi_wready  <= '0;
            axil_addr     <= s_axi_awaddr[15:0];
            axil_we       <= '1;
            s_axi_bvalid  <= '1;
            axil_cs       <= WR_BRESP;
            axil_din      <= s_axi_wdata;
            axil_be       <= s_axi_wstrb;
          end
          2'b10: begin
            // Address only
            s_axi_awready <= '0;
            axil_addr     <= s_axi_awaddr[15:0];
            axil_cs       <= WR_W4DATA;
          end
          2'b01: begin
            s_axi_wready <= '0;
            axil_we      <= '1;
            axil_din     <= s_axi_wdata;
            axil_be      <= s_axi_wstrb;
            axil_cs      <= WR_W4ADDR;
          end
        endcase
      end
      WR_W4DATA: begin
        if (s_axi_wvalid) begin
          s_axi_wready <= '0;
          axil_we      <= '1;
          s_axi_bvalid <= '1;
          axil_din     <= s_axi_wdata;
          axil_be      <= s_axi_wstrb;
          axil_cs      <= WR_BRESP;
        end
      end
      WR_W4ADDR: begin
        if (s_axi_awvalid) begin
          s_axi_awready <= '0;
          s_axi_bvalid  <= '1;
          axil_addr     <= s_axi_awaddr[15:0];
          axil_cs       <= WR_BRESP;
        end
      end
      WR_BRESP: begin
        s_axi_awready <= '0;
        s_axi_wready  <= '0;
        s_axi_bvalid  <= '1;
        if (s_axi_bready) begin
          s_axi_awready <= '1;
          s_axi_wready  <= '1;
          s_axi_bvalid  <= '0;
          axil_cs       <= WR_IDLE;
        end
      end
    endcase
    if (~s_axi_aresetn) begin
      axil_cs <= WR_IDLE;
    end
  end // always @ (posedge axil_clk)

  always @(posedge s_axi_aclk) begin
    rd_start <= '0;
    wr_start <= '0;
    if (set_int) interrupt_out <= '1;
    if (axil_we) begin
      casez (axil_addr[11:0])
        REG_TX_ADDR_LO: begin
          for (int i = 0; i < 4; i++) begin
            if (axil_be[i]) buf_rd_addr[i*8+:8] <= axil_din[i*8+:8];
          end
        end
        REG_TX_ADDR_HI: begin
          for (int i = 0; i < 4; i++) begin
            if (axil_be[i]) buf_rd_addr[(i+4)*8+:8] <= axil_din[i*8+:8];
          end
        end
        REG_TX_BYTES: begin
          for (int i = 0; i < 4; i++) begin
            if (axil_be[i]) buf_rd_count[i*8+:8] <= axil_din[i*8+:8];
          end
        end
        REG_TX_START: if (axil_be[0]) rd_start <= '1;
        REG_RX_ADDR_LO: begin
          for (int i = 0; i < 4; i++) begin
            if (axil_be[i]) buf_wr_addr[i*8+:8] <= axil_din[i*8+:8];
          end
        end
        REG_RX_ADDR_HI: begin
          for (int i = 0; i < 4; i++) begin
            if (axil_be[i]) buf_wr_addr[(i+4)*8+:8] <= axil_din[i*8+:8];
          end
        end
        REG_RX_BYTES: begin
          for (int i = 0; i < 4; i++) begin
            if (axil_be[i]) buf_wr_count[i*8+:8] <= axil_din[i*8+:8];
          end
        end
        REG_RX_START: if (axil_be[0]) wr_start <= '1;
        REG_INT: if (interrupt_out & axil_din[0] & axil_be[0]) interrupt_out <= '0;
      endcase // casez (axil_addr[7:0])
    end // if (axil_we)
  end // always @ (posedge s_axi_aclk)

  always @(posedge s_axi_aclk) begin
    read_data <= '0;
    casez (rd_addr[11:0])
      REG_TX_ADDR_LO: read_data[31:0] <= buf_rd_addr[31:0];
      REG_TX_ADDR_HI: read_data[(AXI_ADDR_WIDTH - 32):0] <= buf_rd_addr[AXI_ADDR_WIDTH-1:32];
      REG_TX_BYTES: read_data <= buf_rd_count;
      REG_TX_BYTES_READ: read_data <= rd_bytes_written;
      REG_TX_STAT: begin
        read_data[31]              <= rd_done;
        read_data[1:0]             <= rd_bresp;
        read_data[2]               <= rd_busy;
        read_data[3]               <= rd_overflow;
      end
      REG_RX_ADDR_LO: read_data[31:0] <= buf_wr_addr[31:0];
      REG_RX_ADDR_HI: read_data[(AXI_ADDR_WIDTH - 32):0] <= buf_wr_addr[AXI_ADDR_WIDTH-1:32];
      REG_RX_BYTES: read_data <= buf_wr_count;
      REG_RX_BYTES_READ: read_data <= wr_bytes_read;
      REG_RX_STAT: begin
        read_data[31]              <= wr_done;
        read_data[1:0]             <= wr_bresp;
        read_data[2]               <= wr_busy;
        read_data[3]               <= wr_underflow;
      end
      REG_DEV: read_data    <= "3104";
      REG_VER: read_data    <= 2;
      REG_INT: read_data[0] <= interrupt_out;
    endcase // casez (rd_addr[7:0])
  end

  // I2S timing generation
  logic [7:0] i2s_counter; // Divide by 256

  initial begin
    i2s_counter = '0;
  end

  assign tx_dout = {tx_data[31:16], 16'b0, tx_data[15:0], 16'b0};
  always @(posedge AIC_mclk_o) begin
    i2s_counter <= i2s_counter + 1; // free running counter for clock gen
    rx_push     <= &i2s_counter;
    if (i2s_counter[1:0] == 2'b10) begin
      i2s_sdata_o              <= tx_dout[{i2s_counter[7], 5'(31-i2s_counter[6:2])}];
      rx_din[{i2s_counter[7], 5'(31-i2s_counter[6:2])}] <= i2s_sdata_i;
    end
  end

  assign tx_pop = rx_push;
  assign AIC_lrclk_o = i2s_counter[$left(i2s_counter)];
  assign AIC_sclk_o = i2s_counter[1];

  (* async_reg = "true" *) logic [1:0] rst_sync;

  always @(posedge AIC_mclk_o) begin
    rst_sync <= rst_sync << 1 | s_axi_aresetn;
  end

  xpm_fifo_async
    #
    (
     .FIFO_WRITE_DEPTH     (128),
     .WRITE_DATA_WIDTH     (32),
     .READ_MODE            ("fwft")
     )
  tx_fifo
    (
     // Common module ports
     .sleep                ('0),
     .rst                  (~s_axi_aresetn),

     // Write Domain ports
     .wr_clk               (s_axi_aclk),
     .wr_en                (tx_push),
     .din                  (tx_din),
     .full                 (tx_full),
     .prog_full            (),
     .wr_data_count        (),
     .overflow             (),
     .wr_rst_busy          (),
     .almost_full          (),
     .wr_ack               (),

     // Read Domain ports
     .rd_clk               (AIC_mclk_o),
     .rd_en                (tx_pop & ~tx_empty),
     .dout                 (tx_data),
     .empty                (tx_empty),
     .prog_empty           (),
     .rd_data_count        (),
     .underflow            (),
     .rd_rst_busy          (),
     .almost_empty         (),
     .data_valid           (),

     // ECC Related ports
     .injectsbiterr        ('0),
     .injectdbiterr        ('0),
     .sbiterr              (),
     .dbiterr              ()
     );

  (* async_reg = "true" *)
  logic [1:0] rx_en;

  always @(posedge AIC_mclk_o) begin
    rx_en <= rx_en << 1 | wr_busy;
  end
  xpm_fifo_async
    #
    (
     .FIFO_WRITE_DEPTH     (128),
     .WRITE_DATA_WIDTH     (32),
     .READ_MODE            ("fwft")
     )
  rx_fifo
    (
     // Common module ports
     .sleep                ('0),
     .rst                  (~rst_sync[1]),

     // Write Domain ports
     .wr_clk               (AIC_mclk_o),
     .wr_en                (rx_en[1] & rx_push),
     .din                  ({rx_din[63:48], rx_din[31:16]}),
     .full                 (),
     .prog_full            (),
     .wr_data_count        (),
     .overflow             (),
     .wr_rst_busy          (),
     .almost_full          (),
     .wr_ack               (),

     // Read Domain ports
     .rd_clk               (s_axi_aclk),
     .rd_en                (rx_pop),
     .dout                 (rx_data),
     .empty                (rx_empty),
     .prog_empty           (),
     .rd_data_count        (),
     .underflow            (),
     .rd_rst_busy          (),
     .almost_empty         (),
     .data_valid           (),

     // ECC Related ports
     .injectsbiterr        ('0),
     .injectdbiterr        ('0),
     .sbiterr              (),
     .dbiterr              ()
     );
  assign rx_pop = ~rx_empty & rd_tready;

  axi_dma_writer
    #
    (
     // UltraScale+ note: set AXI_ADDR_WIDTH to match the HP/HPC slave port in
     // your block design (commonly 40 or 49). 32 is NOT safe on MPSoC boards
     // whose PYNQ CMA buffers can be placed above the 4 GB boundary.
     .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH), // match the PS HP/HPC port width
     .AXI_DATA_WIDTH (AXI_DATA_WIDTH), // 32 = one packed L/R sample per beat
     .AXI_ID_WIDTH (AXI_ID_WIDTH), // ZynqMP HP IDs are wider than ZC7000
     .MAX_BURST_LEN (MAX_BURST_LEN), // AMD recommends 16 on MPSoC HP ports
     .FIFO_DEPTH (FIFO_DEPTH)  // power of two recommended
     )
  axi_dma_writer
    (
     .clk   (s_axi_aclk),
     .resetn(s_axi_aresetn),      // active-low

     // ---- Control / status (drive from AXI-Lite slave or register block) ----
     .cfg_buf_addr(buf_wr_addr[AXI_ADDR_WIDTH-1:0]),      // DDR buffer base (physical)
     .cfg_buf_len(buf_wr_count),       // buffer size in BYTES
     .cfg_start(wr_start),         // 1-cycle pulse to begin
     .sts_busy(wr_busy),
     .sts_done(wr_done),          // held high once buffer filled
     .sts_bytes_written(wr_bytes_read),   // read back via REG_RX_BYTES_READ
     .sts_overflow(wr_underflow),     // sticky: a sample was dropped (REG_RX_STAT[3])
     .sts_bresp(wr_bresp),         // last write response captured

     // ---- Audio sample input: AXI4-Stream slave ----
     .s_axis_tdata(rx_data),
     .s_axis_tvalid(~rx_empty),
     .s_axis_tready(rd_tready),

     // AXI interface we can use
     .*
     );

  // ---------------------------------------------------------------------------
  //  Playback (MM2S): axi_dma_reader streams the DDR buffer into the TX FIFO,
  //  which the I2S generator drains one packed L/R sample per LRCLK frame.
  //  Same 32-bit packing as capture: bits[31:16]=right, bits[15:0]=left.
  //  The reader shares the m_axi master with the writer (writer drives AW/W/B,
  //  reader drives AR/R), so one HP/HPC slave port carries both directions.
  // ---------------------------------------------------------------------------
  assign tx_stream_ready = ~tx_full;
  assign tx_push         = tx_stream_valid & tx_stream_ready;

  axi_dma_reader
    #
    (
     .AXI_ADDR_WIDTH  (AXI_ADDR_WIDTH),
     .AXI_DATA_WIDTH  (AXI_DATA_WIDTH),
     .AXI_ID_WIDTH    (AXI_ID_WIDTH),
     .MAX_BURST_LEN   (MAX_BURST_LEN),
     .FIFO_DEPTH      (FIFO_DEPTH),
     .PRIME_THRESHOLD (FIFO_DEPTH/2)
     )
  axi_dma_reader
    (
     .clk             (s_axi_aclk),
     .resetn          (s_axi_aresetn),      // active-low

     // ---- Control / status (TX registers) ----
     .cfg_buf_addr    (buf_rd_addr[AXI_ADDR_WIDTH-1:0]),
     .cfg_buf_len     (buf_rd_count),
     .cfg_start       (rd_start),
     .sts_busy        (rd_busy),
     .sts_done        (rd_done),
     .sts_bytes_read  (rd_bytes_written),
     .sts_underflow   (rd_overflow),        // sticky: TX FIFO starved mid-play
     .sts_rresp       (rd_bresp),

     // ---- AXI4 master: read address channel ----
     .m_axi_arid      (m_axi_arid),
     .m_axi_araddr    (m_axi_araddr),
     .m_axi_arlen     (m_axi_arlen),
     .m_axi_arsize    (m_axi_arsize),
     .m_axi_arburst   (m_axi_arburst),
     .m_axi_arlock    (m_axi_arlock),
     .m_axi_arcache   (m_axi_arcache),
     .m_axi_arprot    (m_axi_arprot),
     .m_axi_arvalid   (m_axi_arvalid),
     .m_axi_arready   (m_axi_arready),

     // ---- AXI4 master: read data channel ----
     .m_axi_rdata     (m_axi_rdata),
     .m_axi_rresp     (m_axi_rresp),
     .m_axi_rlast     (m_axi_rlast),
     .m_axi_rvalid    (m_axi_rvalid),
     .m_axi_rready    (m_axi_rready),

     // ---- AXI4-Stream master -> TX FIFO ----
     .m_axis_tdata    (tx_din),
     .m_axis_tvalid   (tx_stream_valid),
     .m_axis_tready   (tx_stream_ready),
     .m_axis_tlast    ()
     );

endmodule // aic3204
