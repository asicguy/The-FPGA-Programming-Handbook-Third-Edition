// sobel_stream_ctrl.sv
// ------------------------------------
// AXI4-Lite register file for the streaming Sobel filter
// ------------------------------------
// Author : Frank Bruno
//
// Register map -- byte for byte what Vitis HLS generates for this kernel, so
// the same notebook drives either implementation:
//
//   0x10 img_width    [31:0]
//   0x18 img_height   [31:0]
//   0x20 mode         [31:0]
//
// There is no CTRL register, no GIER, no ISR and no interrupt. CH11's kernel
// was ap_ctrl_hs: PYNQ wrote the arguments, set ap_start and polled ap_done for
// each frame. This one is ap_ctrl_none -- it free-runs off the video stream the
// way every other IP in the MIPI pipeline does, and 0x00 through 0x0C read back
// as zero because HLS does not implement them for a free-running block.
//
// Everything else about the slave matches the generated one: six address bits,
// 32-bit data, byte strobes honoured, one outstanding transaction, and reads of
// unmapped addresses returning zero rather than erroring.
//
// NOTE the argument names: img_width / img_height, never width / height. PYNQ
// builds register_map by making a Python property per register field on its
// Register class, and Register.__init__ assigns self.width -- a field named
// "width" shadows that attribute and recurses to death on first access. See
// CH11's image_filter.hpp for the full trace.
`timescale 1ns/10ps
module sobel_stream_ctrl
  #
  (
   parameter ADDR_WIDTH = 6,
   parameter DATA_WIDTH = 32
   )
  (
   input  wire                    clk,
   input  wire                    rst_n,

   // AXI4-Lite slave
   input  wire [ADDR_WIDTH-1:0]   awaddr,
   input  wire                    awvalid,
   output logic                   awready,
   input  wire [DATA_WIDTH-1:0]   wdata,
   input  wire [DATA_WIDTH/8-1:0] wstrb,
   input  wire                    wvalid,
   output logic                   wready,
   output logic [1:0]             bresp,
   output logic                   bvalid,
   input  wire                    bready,
   input  wire [ADDR_WIDTH-1:0]   araddr,
   input  wire                    arvalid,
   output logic                   arready,
   output logic [DATA_WIDTH-1:0]  rdata,
   output logic [1:0]             rresp,
   output logic                   rvalid,
   input  wire                    rready,

   // to the datapath
   output logic [31:0]            img_width,
   output logic [31:0]            img_height,
   output logic [31:0]            mode
   );

  localparam [ADDR_WIDTH-1:0] ADDR_WIDTH_R  = 6'h10;
  localparam [ADDR_WIDTH-1:0] ADDR_HEIGHT_R = 6'h18;
  localparam [ADDR_WIDTH-1:0] ADDR_MODE_R   = 6'h20;

  // ---------------------------------------------------------------------
  // Write channel
  // ---------------------------------------------------------------------
  logic                    aw_hs;
  logic                    w_hs;
  logic [ADDR_WIDTH-1:0]   awaddr_r;
  logic                    awaddr_v;
  logic [DATA_WIDTH-1:0]   wdata_r;
  logic [DATA_WIDTH/8-1:0] wstrb_r;
  logic                    wdata_v;
  logic                    do_write;

  assign aw_hs    = awvalid && awready;
  assign w_hs     = wvalid  && wready;
  assign awready  = !awaddr_v;
  assign wready   = !wdata_v;
  assign do_write = awaddr_v && wdata_v && (!bvalid || bready);

  function automatic [DATA_WIDTH-1:0] wr_mask
    (input [DATA_WIDTH-1:0]   old_v,
     input [DATA_WIDTH-1:0]   new_v,
     input [DATA_WIDTH/8-1:0] strb);
    integer b;
    begin
      wr_mask = old_v;
      for (b = 0; b < DATA_WIDTH/8; b = b + 1)
        if (strb[b]) wr_mask[b*8 +: 8] = new_v[b*8 +: 8];
    end
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      awaddr_v <= 1'b0;
      wdata_v  <= 1'b0;
      bvalid   <= 1'b0;
      bresp    <= 2'b00;
    end else begin
      if (aw_hs) begin
        awaddr_r <= awaddr;
        awaddr_v <= 1'b1;
      end
      if (w_hs) begin
        wdata_r <= wdata;
        wstrb_r <= wstrb;
        wdata_v <= 1'b1;
      end
      if (do_write) begin
        awaddr_v <= 1'b0;
        wdata_v  <= 1'b0;
        bvalid   <= 1'b1;
        bresp    <= 2'b00;
      end else if (bvalid && bready) begin
        bvalid <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Read channel
  // ---------------------------------------------------------------------
  logic [ADDR_WIDTH-1:0] araddr_r;
  logic                  do_read;

  assign arready = !rvalid;
  assign do_read = arvalid && arready;

  always_comb begin
    case (araddr_r)
      ADDR_WIDTH_R:  rdata = img_width;
      ADDR_HEIGHT_R: rdata = img_height;
      ADDR_MODE_R:   rdata = mode;
      default:       rdata = 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rvalid   <= 1'b0;
      rresp    <= 2'b00;
      araddr_r <= '0;
    end else begin
      if (do_read) begin
        araddr_r <= araddr;
        rvalid   <= 1'b1;
        rresp    <= 2'b00;
      end else if (rvalid && rready) begin
        rvalid <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      img_width  <= 32'd0;
      img_height <= 32'd0;
      mode       <= 32'd0;
    end else if (do_write) begin
      case (awaddr_r)
        ADDR_WIDTH_R:  img_width  <= wr_mask(img_width,  wdata_r, wstrb_r);
        ADDR_HEIGHT_R: img_height <= wr_mask(img_height, wdata_r, wstrb_r);
        ADDR_MODE_R:   mode       <= wr_mask(mode,       wdata_r, wstrb_r);
        default: ;
      endcase
    end
  end

endmodule
