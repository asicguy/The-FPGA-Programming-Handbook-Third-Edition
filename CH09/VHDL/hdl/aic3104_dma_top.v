//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.2 (lin64) Build 6299465 Fri Nov 14 12:34:56 MST 2025
//Date        : Sun Jun 28 20:36:44 2026
//Host        : HoboKitty running 64-bit Ubuntu 24.04.4 LTS
//Command     : generate_target hw_wrapper.bd
//Design      : hw_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module hw_wrapper
   (AIC_lrclk_o,
    AIC_mclk_o,
    AIC_nRST,
    AIC_sclk_o,
    AIC_sdata_i,
    AIC_sdata_o,
    i2c_aic_scl_io,
    i2c_aic_sda_io);
  output AIC_lrclk_o;
  output AIC_mclk_o;
  output [0:0]AIC_nRST;
  output AIC_sclk_o;
  input AIC_sdata_i;
  output AIC_sdata_o;
  inout i2c_aic_scl_io;
  inout i2c_aic_sda_io;

  wire AIC_lrclk_o;
  wire AIC_mclk_o;
  wire [0:0]AIC_nRST;
  wire AIC_sclk_o;
  wire AIC_sdata_i;
  wire AIC_sdata_o;
  wire i2c_aic_scl_i;
  wire i2c_aic_scl_io;
  wire i2c_aic_scl_o;
  wire i2c_aic_scl_t;
  wire i2c_aic_sda_i;
  wire i2c_aic_sda_io;
  wire i2c_aic_sda_o;
  wire i2c_aic_sda_t;

  hw hw_i
       (.AIC_lrclk_o(AIC_lrclk_o),
        .AIC_mclk_o(AIC_mclk_o),
        .AIC_nRST(AIC_nRST),
        .AIC_sclk_o(AIC_sclk_o),
        .AIC_sdata_i(AIC_sdata_i),
        .AIC_sdata_o(AIC_sdata_o),
        .i2c_aic_scl_i(i2c_aic_scl_i),
        .i2c_aic_scl_o(i2c_aic_scl_o),
        .i2c_aic_scl_t(i2c_aic_scl_t),
        .i2c_aic_sda_i(i2c_aic_sda_i),
        .i2c_aic_sda_o(i2c_aic_sda_o),
        .i2c_aic_sda_t(i2c_aic_sda_t));
  IOBUF i2c_aic_scl_iobuf
       (.I(i2c_aic_scl_o),
        .IO(i2c_aic_scl_io),
        .O(i2c_aic_scl_i),
        .T(i2c_aic_scl_t));
  IOBUF i2c_aic_sda_iobuf
       (.I(i2c_aic_sda_o),
        .IO(i2c_aic_sda_io),
        .O(i2c_aic_sda_i),
        .T(i2c_aic_sda_t));
endmodule // hw_wrapper
