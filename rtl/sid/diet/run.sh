#!/bin/sh
set -e
cd "$(dirname "$0")"

echo "=== verilator lint ==="
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
          -Wno-UNUSEDSIGNAL -Wno-SELRANGE \
          ../sid_dac.v sid_cutoff_diet.v --top-module sid_cutoff_diet

echo
echo "=== iverilog compile ==="
iverilog -g2005 -o tb_diet.out ../sid_dac.v sid_cutoff_diet.v tb_cutoff_diet.v

echo
echo "=== run simulation ==="
vvp tb_diet.out
