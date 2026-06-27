module aic3104_poll
  (
   input               s_axi_aclk,
   input               s_axi_aresetn,
   input [21:0]        s_axi_awaddr,
   input               s_axi_awvalid,
   output logic        s_axi_awready,
   input [31:0]        s_axi_wdata,
   input [3:0]         s_axi_wstrb,
   input               s_axi_wvalid,
   output logic        s_axi_wready,
   output logic [1:0]  s_axi_bresp,
   output logic        s_axi_bvalid,
   input               s_axi_bready,
   input [21:0]        s_axi_araddr,
   input               s_axi_arvalid,
   output logic        s_axi_arready,
   output logic [31:0] s_axi_rdata,
   output logic [1:0]  s_axi_rresp,
   output logic        s_axi_rvalid,
   input               s_axi_rready,
   output logic        interrupt_out,

   input               AIC_mclk_o,
   (* mark_debug = "true" *)output logic AIC_lrclk_o,
   (* mark_debug = "true" *)output logic AIC_sclk_o,
   (* mark_debug = "true" *)input i2s_sdata_i,
   (* mark_debug = "true" *)output logic i2s_sdata_o
   );

  localparam            REG_TX_CTRL  = 12'h0;
  localparam            REG_TX_COUNT = 12'h4;
  localparam            REG_TX_DATA  = 12'h8;
  localparam            REG_TX_STAT  = 12'hc;
  localparam            REG_RX_CTRL  = 12'h110;
  localparam            REG_RX_COUNT = 12'h114;
  localparam            REG_RX_DATA  = 12'h118;
  localparam            REG_RX_STAT  = 12'h11c;
  localparam            REG_DEV      = 12'h200;
  localparam            REG_VER      = 12'h204;
  localparam            REG_INT      = 12'h208;

  typedef enum bit [1:0] {RD_IDLE, RD_WAIT, RD_W4RREADY} axil_rd_cs_t;
  typedef enum bit [1:0] {WR_IDLE, WR_W4ADDR, WR_W4DATA, WR_BRESP} axil_cs_t;
  typedef enum bit [1:0] {IDLE, INTERRUPT, DIVIDE} state_t;
  typedef enum bit [1:0] {ADD, SUB, MUL, DIV} operator_t;

  axil_rd_cs_t     axil_rd_cs;
  axil_cs_t        axil_cs;

  (* mark_debug = "true" *)logic [15:0] rd_addr;
  (* mark_debug = "true" *)logic [31:0] read_data;
  logic [31:0] axil_din;
  logic [3:0]  axil_be;
  logic        axil_we;
  logic [15:0] axil_addr;
  logic        set_int;
  logic [7:0]  tx_ctrl = '0, rx_ctrl = '0;
  logic [15:0] tx_count, rx_count;
  (* mark_debug = "true" *)logic [31:0] tx_data, rx_data;
  (* mark_debug = "true" *)logic        rx_push, tx_pop;
  logic [31:0] tx_din;
  logic        tx_push;
  logic        tx_empty, rx_empty;
  logic        rx_pop;
  logic        tx_full;
  (* mark_debug = "true" *)logic [31:0] rx_din;
  logic        rx_push_gate;

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
    tx_push <= '0;
    if (set_int) interrupt_out <= '1;
    if (axil_we) begin
      casez (axil_addr[11:0])
        REG_TX_CTRL: begin
          if (axil_be[0]) tx_ctrl[7:0] <= axil_din[7:0];
        end
        REG_TX_COUNT: begin
          if (axil_be[0]) tx_count[7:0] <= axil_din[7:0];
          if (axil_be[1]) tx_count[15:8] <= axil_din[15:8];
        end
        REG_TX_DATA: begin
          tx_push <= |axil_be;
          for (int i = 0; i < 4; i++) begin
            if (axil_be[i]) tx_din[i*8+:8] <= axil_din[i*8+:8];
          end
        end
        REG_TX_STAT: begin

        end
        REG_RX_CTRL: begin
          if (axil_be[0]) rx_ctrl[7:0] <= axil_din[7:0];
        end
        REG_RX_COUNT: begin
          if (axil_be[0]) rx_count[7:0] <= axil_din[7:0];
          if (axil_be[1]) rx_count[15:8] <= axil_din[15:8];
        end
        REG_RX_STAT: begin
        end
        REG_INT: if (interrupt_out & axil_din[0] & axil_be[0]) interrupt_out <= '0;
      endcase // casez (axil_addr[7:0])
    end // if (axil_we)
  end // always @ (posedge s_axi_aclk)

  always @(posedge s_axi_aclk) begin
    read_data <= '0;
    rx_pop    <= '0;
    casez (rd_addr[11:0])
      REG_TX_CTRL:  read_data[7:0] <= tx_ctrl;
      REG_TX_COUNT: read_data[15:0] <= tx_count;
      REG_TX_STAT:  read_data[0] <= tx_full;
      REG_RX_CTRL:  read_data[7:0] <= rx_ctrl;
      REG_RX_COUNT: read_data[15:0] <= rx_count;
      REG_RX_DATA: begin
        read_data <= rx_data;
        rx_pop <= ~rx_empty;
      end
      REG_RX_STAT: read_data[0] <= rx_empty;
      REG_DEV: read_data        <= "3104";
      REG_VER: read_data        <= 1;
      REG_INT: read_data[0]     <= interrupt_out;
    endcase // casez (rd_addr[7:0])
  end

  // I2S timing generation
  logic [7:0] i2s_counter; // Divide by 256

  initial begin
    i2s_counter = '0;
  end

  always @(posedge AIC_mclk_o) begin
    i2s_counter <= i2s_counter + 1; // free running counter for clock gen
    rx_push     <= &i2s_counter;
    if (i2s_counter[2:0] == 3'b100) begin
      i2s_sdata_o              <= tx_data[{i2s_counter[7], 4'(15-i2s_counter[6:3])}];
      rx_din[{i2s_counter[7], 4'(15-i2s_counter[6:3])}] <= i2s_sdata_i;
    end
  end
  assign rx_push_gate = rx_push & rx_ctrl[0];
  assign tx_pop = rx_push;
  assign AIC_lrclk_o = i2s_counter[$left(i2s_counter)];
  assign AIC_sclk_o = i2s_counter[2];

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
     .rst                  (~s_axi_aresetn),

     // Write Domain ports
     .wr_clk               (AIC_mclk_o),
     .wr_en                (rx_push_gate),
     .din                  (rx_din),
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

endmodule // aic3204
