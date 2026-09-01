# FPGA Project: The-FPGA-Programming-Handbook-Third-Edition

## Overview
- Target Device: xczu3eg-sfvc784-2-e
- Board: AUP-ZU3 8GB

## Environment & Tooling Constraints
- ALWAYS source the vendor environment before running lint/simulation/build commands:
  `source /opt/Xilinx/2025.2/Vivado/settings64.sh`
- Do not run GUI tools; use batch/Tcl mode scripts provided in `/scripts`.

## Frequently Used Tools
- Verilator
- Vivado
- Vitis
- Icarus Verilog
- GHDL

## HDL Style & Safety Rules
- Use synchronous active-high resets unless specified otherwise.
- Explicitly define signal widths; avoid unsized constants.
- Avoid inferred latches; ensure all `case` and `if-else` statements are fully specified.
- Place all pin constraints in `constraints/pins.xdc` (do not hardcode in source).