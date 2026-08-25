// sobel_stream.sv
// ------------------------------------
// Streaming Sobel video filter -- top level
// ------------------------------------
// Author : Frank Bruno
//
// Sits inside the MIPI pipeline between axis_channel_swap and pixel_pack:
//
//   csi2_rx -> subset -> demosaic -> gamma_lut -> v_proc_ss (CSC)
//           -> axis_channel_swap -> [ sobel_stream ] -> pixel_pack -> VDMA
//
// The port names, their widths and the register offsets are all copied from
// what Vitis HLS generates for the C version, so either can be dropped into
// that slot and driven by the same notebook. The one testbench in ../tb binds
// against this, against the VHDL, and against the HLS output.
//
// 48 bits of TDATA carry two pixels: pixel 0 in [23:0] and pixel 1 in [47:24],
// each B,G,R from the LSB up. TUSER bit 0 is start-of-frame, TLAST is
// end-of-line. TKEEP and TSTRB are all-ones in and ignored; a video stream has
// no partial beats.
//
// Free-running: there is no ap_start to write and no ap_done to poll, and the
// AXI4-Lite slave has no CTRL register. The block is driven by the stream.
`timescale 1ns/10ps
module sobel_stream
  #
  (
   parameter int MAX_WIDTH = 1920
   )
  (
   input  wire        ap_clk,
   input  wire        ap_rst_n,

   // AXI4-Stream slave: pixels from the colour-space converter
   input  wire [47:0] stream_in_TDATA,
   input  wire        stream_in_TVALID,
   output wire        stream_in_TREADY,
   input  wire [5:0]  stream_in_TKEEP,
   input  wire [5:0]  stream_in_TSTRB,
   input  wire [0:0]  stream_in_TUSER,
   input  wire [0:0]  stream_in_TLAST,

   // AXI4-Stream master: pixels to the packer
   output wire [47:0] stream_out_TDATA,
   output wire        stream_out_TVALID,
   input  wire        stream_out_TREADY,
   output wire [5:0]  stream_out_TKEEP,
   output wire [5:0]  stream_out_TSTRB,
   output wire [0:0]  stream_out_TUSER,
   output wire [0:0]  stream_out_TLAST,

   // AXI4-Lite control
   input  wire        s_axi_control_AWVALID,
   output wire        s_axi_control_AWREADY,
   input  wire [5:0]  s_axi_control_AWADDR,
   input  wire        s_axi_control_WVALID,
   output wire        s_axi_control_WREADY,
   input  wire [31:0] s_axi_control_WDATA,
   input  wire [3:0]  s_axi_control_WSTRB,
   input  wire        s_axi_control_ARVALID,
   output wire        s_axi_control_ARREADY,
   input  wire [5:0]  s_axi_control_ARADDR,
   output wire        s_axi_control_RVALID,
   input  wire        s_axi_control_RREADY,
   output wire [31:0] s_axi_control_RDATA,
   output wire [1:0]  s_axi_control_RRESP,
   output wire        s_axi_control_BVALID,
   input  wire        s_axi_control_BREADY,
   output wire [1:0]  s_axi_control_BRESP
   );

  // TKEEP and TSTRB carry no information on a video stream: every beat is two
  // whole pixels. They are accepted because the upstream IP drives them, and
  // regenerated as all-ones on the way out.
  wire unused_ok = &{1'b0, stream_in_TKEEP, stream_in_TSTRB, 1'b0};

  wire [31:0] img_width, img_height, mode;

  sobel_stream_ctrl #(.ADDR_WIDTH (6), .DATA_WIDTH (32)) u_ctrl
    (.clk        (ap_clk),
     .rst_n      (ap_rst_n),
     .awaddr     (s_axi_control_AWADDR),
     .awvalid    (s_axi_control_AWVALID),
     .awready    (s_axi_control_AWREADY),
     .wdata      (s_axi_control_WDATA),
     .wstrb      (s_axi_control_WSTRB),
     .wvalid     (s_axi_control_WVALID),
     .wready     (s_axi_control_WREADY),
     .bresp      (s_axi_control_BRESP),
     .bvalid     (s_axi_control_BVALID),
     .bready     (s_axi_control_BREADY),
     .araddr     (s_axi_control_ARADDR),
     .arvalid    (s_axi_control_ARVALID),
     .arready    (s_axi_control_ARREADY),
     .rdata      (s_axi_control_RDATA),
     .rresp      (s_axi_control_RRESP),
     .rvalid     (s_axi_control_RVALID),
     .rready     (s_axi_control_RREADY),
     .img_width  (img_width),
     .img_height (img_height),
     .mode       (mode));

  wire        core_wr;
  wire [47:0] core_data;
  wire        core_user, core_last;
  wire        skid_full;

  sobel_stream_core #(.MAX_WIDTH (MAX_WIDTH)) u_core
    (.clk        (ap_clk),
     .rst_n      (ap_rst_n),
     .img_width  (img_width),
     .img_height (img_height),
     .mode       (mode),
     .s_valid    (stream_in_TVALID),
     .s_data     (stream_in_TDATA),
     .s_user     (stream_in_TUSER[0]),
     .s_last     (stream_in_TLAST[0]),
     .s_ready    (stream_in_TREADY),
     .m_wr       (core_wr),
     .m_data     (core_data),
     .m_user     (core_user),
     .m_last     (core_last),
     .m_full     (skid_full));

  wire [49:0] skid_dout;

  axis_skid #(.WIDTH (50)) u_skid
    (.clk     (ap_clk),
     .rst_n   (ap_rst_n),
     .wr      (core_wr),
     .din     ({core_user, core_last, core_data}),
     .full    (skid_full),
     .m_valid (stream_out_TVALID),
     .m_data  (skid_dout),
     .m_ready (stream_out_TREADY));

  assign stream_out_TDATA = skid_dout[47:0];
  assign stream_out_TLAST = skid_dout[48];
  assign stream_out_TUSER = skid_dout[49];
  assign stream_out_TKEEP = 6'h3F;
  assign stream_out_TSTRB = 6'h3F;

endmodule
