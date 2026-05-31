// calculator.sv
// ------------------------------------
// Calculator state machine
// ------------------------------------
// Author : Frank Bruno
`timescale 1ns/10ps
module calculator
  #
  (
   parameter DIVIDER = "false",
   parameter BITS = 32
   )
  (
   input               s_axi_aclk,
   input               s_axi_aresetn,
   input [15:0]        s_axi_awaddr,
   input               s_axi_awvalid,
   output logic        s_axi_awready,
   input [31:0]        s_axi_wdata,
   input [3:0]         s_axi_wstrb,
   input               s_axi_wvalid,
   output logic        s_axi_wready,
   output logic [1:0]  s_axi_bresp,
   output logic        s_axi_bvalid,
   input               s_axi_bready,
   input [15:0]        s_axi_araddr,
   input               s_axi_arvalid,
   output logic        s_axi_arready,
   output logic [31:0] s_axi_rdata,
   output logic [1:0]  s_axi_rresp,
   output logic        s_axi_rvalid,
   input               s_axi_rready,
   output logic        interrupt_out
   );

  localparam            REG_A   = 8'h0;
  localparam            REG_B   = 8'h4;
  localparam            REG_C   = 8'h8;
  localparam            REG_REM = 8'hC;
  localparam            REG_OP  = 8'h10;
  localparam            REG_INT = 8'h14;

  typedef enum bit [1:0] {RD_IDLE, RD_WAIT, RD_W4RREADY} axil_rd_cs_t;
  typedef enum bit [1:0] {WR_IDLE, WR_W4ADDR, WR_W4DATA, WR_BRESP} axil_cs_t;
  typedef enum bit [1:0] {IDLE, INTERRUPT, DIVIDE} state_t;
  typedef enum bit [1:0] {ADD, SUB, MUL, DIV} operator_t;

  axil_rd_cs_t     axil_rd_cs;
  axil_cs_t        axil_cs;
  state_t          state;
  operator_t       operator;

  logic [BITS-1:0] a_in, b_in, c_out, rem_out;
  logic [BITS-1:0] dividend, divisor;
  logic            start, start_div;
  logic            set_int;
  logic [15:0]     rd_addr;
  logic [31:0]     read_data;
  logic [31:0]     axil_din;
  logic [3:0]      axil_be;
  logic            axil_we;
  logic [15:0]     axil_addr;
  logic            done;
  logic [BITS-1:0] quotient;
  logic [BITS-1:0] remainder;

  initial begin
    axil_rd_cs    = RD_IDLE;
    axil_cs       = WR_IDLE;
    state         = IDLE;
    interrupt_out = '0;
  end

  always @(posedge s_axi_aclk) begin
    set_int   <= '0;
    start_div <= '0;
    case (state)
      IDLE: begin
        // Wait for data to be operated on to be entered. Then the user presses
        // The operation, add, sub, multiply, or divide
        if (start) begin
          case (operator)
            ADD: begin
              c_out <= a_in + b_in;
              state <= INTERRUPT;
            end
            SUB: begin
              c_out <= a_in - b_in;
              state <= INTERRUPT;
            end
            MUL: begin
              c_out <= a_in * b_in;
              state <= INTERRUPT;
            end
            DIV: begin
              if (DIVIDER == "true") begin
                start_div <= '1;
                dividend  <= a_in;
                divisor   <= b_in;
                state     <= DIVIDE;
              end
            end
          endcase // case (operator)
        end
      end // case: IDLE
      DIVIDE: begin
        if (done) begin
          c_out   <= quotient;
          rem_out <= remainder;
          state   <= INTERRUPT;
        end
      end
      INTERRUPT: begin
        set_int <= '1;
        state   <= IDLE;
      end
    endcase // case (state)
    if (~s_axi_aresetn) begin
      state         <= IDLE;
    end
  end

  divider_nr
    #
    (
     .BITS      (BITS)
     )
  divider_nr
    (
     .clk       (s_axi_aclk),
     .reset     (~s_axi_aresetn),
     .start     (start_div),
     .*
     );

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
    start <= '0;
    if (set_int) interrupt_out <= '1;
    if (axil_we) begin
      casez (axil_addr[7:0])
        REG_A: begin
          for (int i = 0; i < 4; i++) if (axil_be[i]) a_in[8*i+:8] <= axil_din[8*i+:8] ;
        end
        REG_B: begin
          for (int i = 0; i < 4; i++) if (axil_be[i]) b_in[8*i+:8] <= axil_din[8*i+:8] ;
        end
        REG_OP: begin
          start <= '1;
          if (axil_be[0]) operator <= operator_t'(axil_din[1:0]);
        end
        REG_INT: if (interrupt_out & axil_din[0] & axil_be[0]) interrupt_out <= '0;
      endcase // casez (axil_addr[7:0])
    end // if (axil_we)
  end // always @ (posedge s_axi_aclk)

  always @(posedge s_axi_aclk) begin
    read_data <= '0;
    casez (rd_addr[7:0])
      REG_A:   read_data      <= a_in;
      REG_B:   read_data      <= b_in;
      REG_C:   read_data      <= c_out;
      REG_REM: read_data      <= rem_out;
      REG_OP:  read_data[1:0] <= operator;
      REG_INT: read_data[0]   <= interrupt_out;
    endcase // casez (rd_addr[7:0])
  end
endmodule
