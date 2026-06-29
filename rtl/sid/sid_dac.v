// ----------------------------------------------------------------------------
// SID DAC — R-2R Resistor Ladder Emulation
//
// Based on the MOS 6581/8580 SID chip designed by Bob Yannes.
// Converted from SystemVerilog to Verilog-2001 for maximum FPGA portability.
//
// Reference: reDIP-SID by Dag Lem (resid@nimrod.no)
//
// Bob Yannes on DAC imperfections:
//   (From interview.md — context on why the 6581 sounds different)
//   "He could not create high-gain op-amps in NMOS, which were essential
//    to a resonant filter. The FET resistance varied considerably with
//    processing, so different lots of SID chips had different cutoff
//    frequency characteristics."
//
//   The 6581 DACs exhibit severe discontinuities due to:
//   - Missing termination resistor at bit 0 (causes lower 4-5 bit errors)
//   - Imperfect R/2R resistor matching (2R/R ~ 2.20 instead of 2.00)
//   - Output impedance in NMOS transistors providing bit voltages
//
//   The 8580 DACs include correct termination and matched resistors (2R/R=2.00).
//
// DAC topology (R-2R ladder):
//
//          n  n-1      2   1   0    VGND
//          |   |       |   |   |      |   Termination
//         2R  2R      2R  2R  2R     2R   only for
//          |   |       |   |   |      |   MOS 8580
//      Vo  --R---R--...--R---R--    ---
// ----------------------------------------------------------------------------

module sid_dac #(
    parameter  BITS       = 12,
    parameter  _2R_DIV_R  = 2.20,
    parameter  TERM       = 0
)(
    input  [BITS-1:0] vin,
    output reg [BITS-1:0] vout
);

// Scaling for fixed-point calculation of R-2R ladder output
localparam SCALEBITS  = 4;
localparam MSB        = BITS + SCALEBITS - 1;

// Per-bit voltage contributions (calculated from R-2R ladder model)
reg [MSB:0] bitval [0:BITS-1];

// Running sum of bit contributions
reg [MSB:0] bitsum [0:BITS-1];

// ----------------------------------------------------------------------------
// Sum values for all set bits, adding 0.5 for rounding by truncation.
// This models the actual R-2R ladder output voltage for each bit combination.
// ----------------------------------------------------------------------------
integer i;

always @(*) begin
    for (i = 0; i < BITS; i = i + 1) begin
        if (i == 0)
            bitsum[i] = (1 << (SCALEBITS - 1)) + (vin[i] ? bitval[i] : 1'd0);
        else
            bitsum[i] = bitsum[i-1] + (vin[i] ? bitval[i] : 1'd0);
    end
    vout = bitsum[BITS-1][MSB-:BITS];
end

// ----------------------------------------------------------------------------
// Bit values for MOS 6581 DACs (2R/R = 2.20, no termination resistor)
// These values reproduce the non-linear response of the original chip.
// The 6581 has a missing termination resistor at bit 0 and imperfect R/2R
// matching, causing pronounced errors for the lower 4-5 bits.
// ----------------------------------------------------------------------------
initial begin
    if (_2R_DIV_R == 2.20 && TERM == 0 && SCALEBITS == 4) begin
        case (BITS)
            12: begin
                // 12-bit Waveform DAC (6581)
                bitval[ 0] = 16'h21;
                bitval[ 1] = 16'h30;
                bitval[ 2] = 16'h55;
                bitval[ 3] = 16'ha0;
                bitval[ 4] = 16'h135;
                bitval[ 5] = 16'h256;
                bitval[ 6] = 16'h486;
                bitval[ 7] = 16'h8c6;
                bitval[ 8] = 16'h1102;
                bitval[ 9] = 16'h20f8;
                bitval[10] = 16'h3fec;
                bitval[11] = 16'h7bed;
            end
            8: begin
                // 8-bit Envelope DAC (6581)
                bitval[0] = 16'h1d;
                bitval[1] = 16'h2a;
                bitval[2] = 16'h4b;
                bitval[3] = 16'h8d;
                bitval[4] = 16'h110;
                bitval[5] = 16'h20e;
                bitval[6] = 16'h3fb;
                bitval[7] = 16'h7b8;
            end
            11: begin
                // 11-bit Cutoff Frequency DAC (6581)
                // Bob: "An 11-bit D/A converter generates the FET control
                //       voltage. (It's actually a 12-bit D/A, but the LSB had
                //       no audible effect so it was disconnected.)"
                bitval[ 0] = 16'h20;
                bitval[ 1] = 16'h2f;
                bitval[ 2] = 16'h52;
                bitval[ 3] = 16'h9c;
                bitval[ 4] = 16'h12b;
                bitval[ 5] = 16'h243;
                bitval[ 6] = 16'h463;
                bitval[ 7] = 16'h880;
                bitval[ 8] = 16'h107b;
                bitval[ 9] = 16'h1ff4;
                bitval[10] = 16'h3df3;
            end
        endcase
    end
end

endmodule
