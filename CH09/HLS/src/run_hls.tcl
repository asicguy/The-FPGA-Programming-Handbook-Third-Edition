# ============================================================================
#  run_hls.tcl  --  build the AIC3104 DMA HLS components (Vitis unified flow)
#
#  Run from THIS directory (src/), so the relative source paths resolve and the
#  generated component folders land here, matching the book's other HLS chapters:
#
#     vitis-run --mode hls --tcl run_hls.tcl
#
#  Produces two IP-catalog packages:
#     dma_s2mm  (capture : AXI4-Stream -> DDR)   <- replaces axi_dma_writer.sv
#     dma_mm2s  (playback: DDR -> AXI4-Stream)   <- replaces axi_dma_reader.sv
#
#  Stage / scope control via environment variables (all optional):
#     RUN_CSIM=0      skip C simulation        (default 1)
#     RUN_COSIM=1     also run C/RTL co-sim    (default 0)
#     COMPONENTS="dma_s2mm"   build a subset   (default both)
# ============================================================================

set PART {xczu3eg-sfvc784-2-e}
set CLK  100MHz

# Both .cpp files go into every component so the shared loopback test bench
# links; only the set_top function is actually synthesized.
set SRCS {dma_s2mm.cpp dma_mm2s.cpp}

proc opt {name default} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $default}]
}
set do_csim  [opt RUN_CSIM  1]
set do_cosim [opt RUN_COSIM 0]
set comps    [opt COMPONENTS "dma_s2mm dma_mm2s"]

proc build_one {top} {
    global PART CLK SRCS do_csim do_cosim
    puts "=== Building $top ==="
    open_component -reset $top -flow_target vivado
    foreach f $SRCS { add_files $f }
    add_files -tb test_bench.cpp
    set_top $top
    set_part $PART
    create_clock -period $CLK
    if {$do_csim}  { csim_design }
    csynth_design
    if {$do_cosim} { cosim_design }
    export_design -format ip_catalog
}

foreach c $comps { build_one $c }
