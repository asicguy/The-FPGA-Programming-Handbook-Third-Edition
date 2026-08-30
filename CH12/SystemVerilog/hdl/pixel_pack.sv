// pixel_pack.sv
// ------------------------------------
// 24-bit pixel pairs to 32-bit pixel pairs, for the camera hierarchy
// ------------------------------------
// Author : Frank Bruno
//
// A replacement for PYNQ's prebuilt `xilinx.com:hls:pixel_pack_2:1.0`, used by
// project 3's `sv` and `vhdl` builds. Projects 0 and 1 keep PYNQ's, and so does
// project 3's `hls` build -- the point of this module is that a build called
// "SystemVerilog" should not have an HLS block sitting in its datapath.
//
// Behaviour is transcribed from the 32bpp branch of the HLS source
// (AUP-ZU3/pynq/boards/ip/hls/pixel_pack_2/pixel_pack.cpp, case V_32):
//
//     data(23, 0)  = in.data(23, 0);     data(31, 24) = alpha;
//     data(55, 32) = in.data(47, 24);    data(63, 56) = alpha;
//     out.last = in.last;  out.user = in.user;
//
// One beat in, one beat out. TUSER is start-of-frame and TLAST is end-of-line;
// the VDMA tears the picture if either moves, so both are carried through with
// the beat they arrived on rather than regenerated.
//
// **32 bits per pixel only.** PYNQ's packer also does 8, 24 and two flavours of
// 16, chosen by the mode register. CH12 is a 32bpp chapter end to end, so this
// packs 32bpp unconditionally and does not decode mode at all. The register is
// still here, readable and writable, because the hierarchy's address map has to
// match -- and sw/pixel_packer.py is what refuses every other width, which is
// the only thing standing between a reader and 32bpp frames that were asked to
// be 24bpp. Reset value is 1 (32bpp) so a packer nothing has written to already
// reports the mode it is in.
//
// `ap_ctrl_none`, like the HLS original: no ap_start, no ap_done, nothing to
// arm. It runs whenever data arrives.
//
// The control aperture is 5 address bits -- 32 bytes -- which is what the HLS
// IP declared. Widening it would move the hierarchy's address map and PYNQ
// would not find the register.
`timescale 1ns/10ps
module pixel_pack
  #
  (
   parameter ADDR_WIDTH = 5,
   parameter DATA_WIDTH = 32
   )
  (
   input wire                     ap_clk,
   input wire                     ap_rst_n,

   // ---- AXI4-Lite control ----
   input wire [ADDR_WIDTH-1:0]    s_axi_control_awaddr,
   input wire                     s_axi_control_awvalid,
   output logic                   s_axi_control_awready,
   input wire [DATA_WIDTH-1:0]    s_axi_control_wdata,
   input wire [DATA_WIDTH/8-1:0]  s_axi_control_wstrb,
   input wire                     s_axi_control_wvalid,
   output logic                   s_axi_control_wready,
   output logic [1:0]             s_axi_control_bresp,
   output logic                   s_axi_control_bvalid,
   input wire                     s_axi_control_bready,
   input wire [ADDR_WIDTH-1:0]    s_axi_control_araddr,
   input wire                     s_axi_control_arvalid,
   output logic                   s_axi_control_arready,
   output logic [DATA_WIDTH-1:0]  s_axi_control_rdata,
   output logic [1:0]             s_axi_control_rresp,
   output logic                   s_axi_control_rvalid,
   input wire                     s_axi_control_rready,

   // ---- AXI4-Stream in: two 24-bit pixels per beat ----
   input wire [47:0]              stream_in_48_tdata,
   input wire                     stream_in_48_tvalid,
   output logic                   stream_in_48_tready,
   input wire [5:0]               stream_in_48_tkeep,
   input wire [5:0]               stream_in_48_tstrb,
   input wire [0:0]               stream_in_48_tuser,
   input wire [0:0]               stream_in_48_tlast,

   // ---- AXI4-Stream out: two 32-bit pixels per beat ----
   output logic [63:0]            stream_out_64_tdata,
   output logic                   stream_out_64_tvalid,
   input wire                     stream_out_64_tready,
   output logic [7:0]             stream_out_64_tkeep,
   output logic [7:0]             stream_out_64_tstrb,
   output logic [0:0]             stream_out_64_tuser,
   output logic [0:0]             stream_out_64_tlast
   );

  localparam [ADDR_WIDTH-1:0] ADDR_MODE  = 5'h10;
  localparam [ADDR_WIDTH-1:0] ADDR_ALPHA = 5'h18;

  localparam [31:0] MODE_32BPP = 32'd1;

  logic [31:0] mode_r;
  logic [7:0]  alpha_r;

  // ---------------------------------------------------------------------
  // AXI4-Lite write channel
  // ---------------------------------------------------------------------
  logic                    aw_hs, w_hs;
  logic [ADDR_WIDTH-1:0]   awaddr_r;
  logic                    awaddr_v;
  logic [DATA_WIDTH-1:0]   wdata_r;
  logic [DATA_WIDTH/8-1:0] wstrb_r;
  logic                    wdata_v;
  logic                    do_write;

  assign aw_hs = s_axi_control_awvalid && s_axi_control_awready;
  assign w_hs  = s_axi_control_wvalid  && s_axi_control_wready;

  assign s_axi_control_awready = !awaddr_v;
  assign s_axi_control_wready  = !wdata_v;
  assign do_write = awaddr_v && wdata_v &&
                    (!s_axi_control_bvalid || s_axi_control_bready);

  function automatic [DATA_WIDTH-1:0] wr_mask
    (input [DATA_WIDTH-1:0] old_v,
     input [DATA_WIDTH-1:0] new_v,
     input [DATA_WIDTH/8-1:0] strb);
    integer b;
    begin
      wr_mask = old_v;
      for (b = 0; b < DATA_WIDTH/8; b = b + 1)
        if (strb[b]) wr_mask[b*8 +: 8] = new_v[b*8 +: 8];
    end
  endfunction

  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n) begin
      awaddr_v            <= 1'b0;
      wdata_v             <= 1'b0;
      s_axi_control_bvalid <= 1'b0;
      s_axi_control_bresp  <= 2'b00;
    end else begin
      if (aw_hs) begin
        awaddr_r <= s_axi_control_awaddr;
        awaddr_v <= 1'b1;
      end
      if (w_hs) begin
        wdata_r <= s_axi_control_wdata;
        wstrb_r <= s_axi_control_wstrb;
        wdata_v <= 1'b1;
      end
      if (do_write) begin
        awaddr_v             <= 1'b0;
        wdata_v              <= 1'b0;
        s_axi_control_bvalid <= 1'b1;
        s_axi_control_bresp  <= 2'b00;
      end else if (s_axi_control_bvalid && s_axi_control_bready) begin
        s_axi_control_bvalid <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------
  // AXI4-Lite read channel
  // ---------------------------------------------------------------------
  logic [ADDR_WIDTH-1:0] araddr_r;
  logic                  do_read;

  assign s_axi_control_arready = !s_axi_control_rvalid;
  assign do_read = s_axi_control_arvalid && s_axi_control_arready;

  always_comb begin
    case (araddr_r)
      ADDR_MODE:  s_axi_control_rdata = mode_r;
      ADDR_ALPHA: s_axi_control_rdata = {24'd0, alpha_r};
      default:    s_axi_control_rdata = 32'd0;
    endcase
  end

  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n) begin
      s_axi_control_rvalid <= 1'b0;
      s_axi_control_rresp  <= 2'b00;
      araddr_r             <= '0;
    end else begin
      if (do_read) begin
        araddr_r             <= s_axi_control_araddr;
        s_axi_control_rvalid <= 1'b1;
        s_axi_control_rresp  <= 2'b00;
      end else if (s_axi_control_rvalid && s_axi_control_rready) begin
        s_axi_control_rvalid <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------
  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n) begin
      // 32bpp, and an alpha of zero -- both are what the camera has always
      // produced, because PYNQ's driver writes the mode on every configure()
      // and never writes alpha at all.
      mode_r  <= MODE_32BPP;
      alpha_r <= 8'd0;
    end else if (do_write) begin
      case (awaddr_r)
        ADDR_MODE:  mode_r <= wr_mask(mode_r, wdata_r, wstrb_r);
        ADDR_ALPHA: if (wstrb_r[0]) alpha_r <= wdata_r[7:0];
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------------
  // The packing itself, and a skid buffer
  // ---------------------------------------------------------------------
  // A skid buffer rather than a plain register, so TREADY is a register output
  // and does not run combinationally from the VDMA back to the CSI-2 receiver.
  // The camera pipeline is seven AXI4-Stream hops long; a ready path that
  // crosses all of them is a timing problem waiting for a hot day.
  wire [63:0] packed_data = {alpha_r, stream_in_48_tdata[47:24],
                             alpha_r, stream_in_48_tdata[23:0]};

  logic [63:0] out_data_r, skid_data_r;
  logic        out_user_r, out_last_r;
  logic        skid_user_r, skid_last_r;
  logic        out_valid_r, skid_valid_r;

  assign stream_in_48_tready = !skid_valid_r;

  assign stream_out_64_tvalid = out_valid_r;
  assign stream_out_64_tdata  = out_data_r;
  assign stream_out_64_tuser  = out_user_r;
  assign stream_out_64_tlast  = out_last_r;
  // Every byte of a packed beat is a real byte. The HLS IP says the same.
  assign stream_out_64_tkeep  = 8'hFF;
  assign stream_out_64_tstrb  = 8'hFF;

  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n) begin
      out_valid_r  <= 1'b0;
      skid_valid_r <= 1'b0;
    end else if (!skid_valid_r) begin
      if (!out_valid_r || stream_out_64_tready) begin
        out_valid_r <= stream_in_48_tvalid;
        if (stream_in_48_tvalid) begin
          out_data_r <= packed_data;
          out_user_r <= stream_in_48_tuser[0];
          out_last_r <= stream_in_48_tlast[0];
        end
      end else if (stream_in_48_tvalid) begin
        // The output is stalled and a beat arrived anyway -- TREADY was high,
        // so it is ours now and has to be parked rather than dropped.
        skid_valid_r <= 1'b1;
        skid_data_r  <= packed_data;
        skid_user_r  <= stream_in_48_tuser[0];
        skid_last_r  <= stream_in_48_tlast[0];
      end
    end else if (stream_out_64_tready) begin
      out_data_r   <= skid_data_r;
      out_user_r   <= skid_user_r;
      out_last_r   <= skid_last_r;
      out_valid_r  <= 1'b1;
      skid_valid_r <= 1'b0;
    end
  end

  // TKEEP and TSTRB in are ignored on purpose: the upstream converter drives
  // them all ones on every beat, and a packer that acted on a null byte would
  // have to decide what a half-pixel means. Say so, so lint does not guess.
  wire _unused_in = &{1'b0, stream_in_48_tkeep, stream_in_48_tstrb};

endmodule
