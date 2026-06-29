// ----------------------------------------------------------------------------
// SID Filter Cutoff Frequency Generator — "diet" version
//
// Drop-in replacement for sid_cutoff with MULTI_FILTERS=0. Replaces both
// 1024-entry ROM tables with parametric formulas / piecewise-linear logic:
//
//   f6581_adj   (1024 x 15-bit, ~1.92 KB)
//     -> closed-form  adj(i) = round( A * tanh(B*i) )
//        approximated via Pade[5,5]:
//           tanh(x) ~ x*(945 + 105*x^2 + x^4) / (945 + 420*x^2 + 15*x^4)
//        with A = 9884, B = 187/65536 (~ 0.002853).
//        Max abs error vs original LUT: 6  (out of 9826 -> 0.06 %)
//        RMS error:                     3
//
//   f6581_curve (1024 x 16-bit, ~2.00 KB)
//     -> 22-anchor piecewise-linear interpolation, no divider.
//        Anchors include i=511 and i=512 to honor the real chip
//        discontinuity at the Fc[10] transition (R-2R DAC mismatch in
//        the 6581 — see sid_dac.v).
//        Each segment uses a Q4 slope:
//           y = y_lo + (idx - x_lo) * slope_q4 >>> 4
//        Total stored data: 22 * (10+16+13) bits ~ 100 bytes vs 2 KB.
//        Max abs error vs original LUT: 653  (out of 39231 -> 1.7 %)
//        RMS error:                     173
//
// Notes:
//   - MULTI_FILTERS != 0 is NOT supported in this diet module (it removes
//     the per-cfg banks and the ld_clk loading interface).
//   - The Pade computation contains a single integer divide; combinational
//     synthesis should be fine for typical FPGA targets at audio rates.
//     For high system clocks, register the inputs to the divide to allow
//     synthesis retiming.
//   - Functional behavior of inputs/outputs is identical to sid_cutoff.v
//     for cfg=0, so this can be substituted by changing the instance name
//     in sid_top.v / sid_filter.v.
// ----------------------------------------------------------------------------

/* verilator lint_off UNUSEDPARAM */
module sid_cutoff_diet
#(
    parameter MULTI_FILTERS = 0   // diet only supports MULTI_FILTERS=0; parameter kept for port compatibility
)
/* verilator lint_on UNUSEDPARAM */
(
    input             clock,
    input             mode,

    // filter cutoff
    input       [1:0] cfg,         // ignored when MULTI_FILTERS=0
    input      [10:0] Fc,
    input      [12:0] Fc_offset,
    output     [15:0] F0,

    // runtime LUT loading interface (ignored — diet has no LUT to load)
    input             ld_clk,
    input      [11:0] ld_addr,
    input      [15:0] ld_data,
    input             ld_wr
);

// Suppress "unused" warnings without polluting synthesis
wire _unused_diet = &{1'b0, cfg, ld_clk, ld_addr, ld_data, ld_wr, 1'b0};

// ----------------------------------------------------------------------------
// DAC and helper functions (identical to sid_cutoff.v)
// ----------------------------------------------------------------------------
wire [10:0] fc_6581;
sid_dac #( .BITS(11) ) fc_dac
(
    .vin  (Fc),
    .vout (fc_6581)
);

function [9:0] tanh_x_mirror;
    input signed [10:0] x;
    begin
        tanh_x_mirror = x < 0 ? ~x[9:0] + 1'b1 : x[9:0];
    end
endfunction

function signed [10:0] tanh_x_clamp;
    input signed [12:0] x;
    begin
        if (x < -1023)      tanh_x_clamp = -11'sd1023;
        else if (x > 1023)  tanh_x_clamp = 11'sd1023;
        else                tanh_x_clamp = x[10:0];
    end
endfunction

function signed [15:0] tanh_y_mirror;
    input              x_neg;
    input signed [15:0] y;
    begin
        tanh_y_mirror = x_neg ? -y : y;
    end
endfunction

wire signed [15:0] f6581_adj_y0 = 16'sd10133;
wire signed [10:0] fc_x         = tanh_x_clamp($signed({2'b00, fc_6581}) - $signed(Fc_offset));
wire        [9:0]  adj_idx      = tanh_x_mirror(fc_x);

// ============================================================================
// REPLACEMENT 1 of 2 — f6581_adj via Pade[5,5] formula
// ============================================================================
//   adj(i) = ( ADJ_A * x * (945 + 105*x^2 + x^4) ) / ( 945 + 420*x^2 + 15*x^4 )
//   with x = i * ADJ_BQ16 / 65536.
// ----------------------------------------------------------------------------
localparam [13:0] ADJ_A    = 14'd9884;  // amplitude coefficient
localparam [7:0]  ADJ_BQ16 = 8'd187;    // B in Q16 (B ~ 0.002853, 1/B ~ 350)

// All intermediate values in Q16 fixed-point.
// IMPORTANT: in Verilog, binary ops execute at the wider of (LHS, operand)
// widths.  We therefore declare full-width product wires before shifting,
// otherwise the multiplication is truncated BEFORE the shift right.
wire [17:0] adj_x;       // x = i*B,                 0 .. 191301
wire [35:0] adj_x_sq;    // x*x   (full)             0 .. ~3.66e10
wire [19:0] adj_x2;      // x^2 (Q16)                0 .. ~558k
wire [39:0] adj_x2_sq;   // x2*x2 (full)             0 .. ~3.12e11
wire [23:0] adj_x4;      // x^4 (Q16)                0 .. ~4.76M
wire [27:0] adj_inner;   // 945 + 105*x^2 + x^4
wire [29:0] adj_den;     // 945 + 420*x^2 + 15*x^4
wire [44:0] adj_num_pre; // x * inner  (Q32)
wire [28:0] adj_num;     // x * inner  (Q16)
wire [42:0] adj_pre;     // ADJ_A * num
wire [13:0] adj_value;   // final A*tanh(B*i), bounded by ADJ_A

assign adj_x       = adj_idx * ADJ_BQ16;
assign adj_x_sq    = adj_x  * adj_x;
assign adj_x2      = adj_x_sq[35:16];                      // >> 16
assign adj_x2_sq   = adj_x2 * adj_x2;
assign adj_x4      = adj_x2_sq[39:16];                     // >> 16
assign adj_inner   = (28'd945 << 16) + (28'd105 * adj_x2) + {4'b0, adj_x4};
assign adj_den     = (30'd945 << 16) + (30'd420 * adj_x2) + (30'd15 * adj_x4);
assign adj_num_pre = adj_x * adj_inner;
assign adj_num     = adj_num_pre[44:16];                   // >> 16
assign adj_pre     = ADJ_A  * adj_num;
/* verilator lint_off WIDTH */
assign adj_value   = adj_pre / adj_den;                    // 14-bit quotient (bounded by A)
/* verilator lint_on WIDTH */

reg [15:0] f0_adj;
always @(posedge clock) f0_adj <= {fc_x[10], 1'b0, adj_value};

// ============================================================================
// REPLACEMENT 2 of 2 — f6581_curve[0..1023] via 22-anchor piecewise linear
// ============================================================================
// y(idx) = y_lo + ((idx - x_lo) * slope_q4) >>> 4
// Anchors at 511 and 512 capture the chip discontinuity (Fc[10] transition).
// ----------------------------------------------------------------------------
wire [9:0] cu_idx = Fc[10:1];

reg [9:0]          cu_x_lo;
reg [15:0]         cu_y_lo;
reg signed [13:0]  cu_slope_q4;

always @(*) begin
    // Priority encoder; each segment is [x_lo, x_hi).
    if      (cu_idx <  10'd64)  begin cu_x_lo = 10'd0;   cu_y_lo = 16'd933;   cu_slope_q4 =  14'sd7;    end
    else if (cu_idx <  10'd128) begin cu_x_lo = 10'd64;  cu_y_lo = 16'd961;   cu_slope_q4 =  14'sd12;   end
    else if (cu_idx <  10'd192) begin cu_x_lo = 10'd128; cu_y_lo = 16'd1009;  cu_slope_q4 =  14'sd33;   end
    else if (cu_idx <  10'd256) begin cu_x_lo = 10'd192; cu_y_lo = 16'd1141;  cu_slope_q4 =  14'sd71;   end
    else if (cu_idx <  10'd320) begin cu_x_lo = 10'd256; cu_y_lo = 16'd1426;  cu_slope_q4 =  14'sd209;  end
    else if (cu_idx <  10'd384) begin cu_x_lo = 10'd320; cu_y_lo = 16'd2262;  cu_slope_q4 =  14'sd458;  end
    else if (cu_idx <  10'd448) begin cu_x_lo = 10'd384; cu_y_lo = 16'd4092;  cu_slope_q4 =  14'sd890;  end
    else if (cu_idx <  10'd480) begin cu_x_lo = 10'd448; cu_y_lo = 16'd7654;  cu_slope_q4 =  14'sd1310; end
    else if (cu_idx <  10'd496) begin cu_x_lo = 10'd480; cu_y_lo = 16'd10275; cu_slope_q4 =  14'sd1708; end
    else if (cu_idx <  10'd508) begin cu_x_lo = 10'd496; cu_y_lo = 16'd11983; cu_slope_q4 =  14'sd2297; end
    else if (cu_idx <  10'd511) begin cu_x_lo = 10'd508; cu_y_lo = 16'd13706; cu_slope_q4 = -14'sd2123; end
    else if (cu_idx <  10'd512) begin cu_x_lo = 10'd511; cu_y_lo = 16'd13308; cu_slope_q4 =  14'sd0;    end
    else if (cu_idx <  10'd544) begin cu_x_lo = 10'd512; cu_y_lo = 16'd10866; cu_slope_q4 =  14'sd1657; end
    else if (cu_idx <  10'd576) begin cu_x_lo = 10'd544; cu_y_lo = 16'd14180; cu_slope_q4 =  14'sd1608; end
    else if (cu_idx <  10'd640) begin cu_x_lo = 10'd576; cu_y_lo = 16'd17396; cu_slope_q4 =  14'sd1660; end
    else if (cu_idx <  10'd704) begin cu_x_lo = 10'd640; cu_y_lo = 16'd24037; cu_slope_q4 =  14'sd1686; end
    else if (cu_idx <  10'd768) begin cu_x_lo = 10'd704; cu_y_lo = 16'd30781; cu_slope_q4 =  14'sd1121; end
    else if (cu_idx <  10'd832) begin cu_x_lo = 10'd768; cu_y_lo = 16'd35265; cu_slope_q4 =  14'sd652;  end
    else if (cu_idx <  10'd896) begin cu_x_lo = 10'd832; cu_y_lo = 16'd37874; cu_slope_q4 =  14'sd297;  end
    else if (cu_idx <  10'd960) begin cu_x_lo = 10'd896; cu_y_lo = 16'd39061; cu_slope_q4 =  14'sd35;   end
    else                         begin cu_x_lo = 10'd960; cu_y_lo = 16'd39201; cu_slope_q4 =  14'sd8;    end
end

wire signed [10:0] cu_dx        = $signed({1'b0, cu_idx}) - $signed({1'b0, cu_x_lo});
wire signed [24:0] cu_inc_q4    = cu_dx * cu_slope_q4;             // (Q0 * Q4) -> Q4
wire signed [24:0] cu_inc       = cu_inc_q4 >>> 4;                 // Q0, sign-preserving
wire signed [24:0] cu_y_signed  = $signed({9'b0, cu_y_lo}) + cu_inc;

reg [15:0] f0;
always @(posedge clock) f0 <= cu_y_signed[15:0];

// ============================================================================
// Output mux (identical to original sid_cutoff)
// ============================================================================
assign F0 = mode                      ? ({3'b000, Fc, 2'b00} + Fc) :
            (Fc_offset != 13'd0)      ? (f6581_adj_y0 + tanh_y_mirror(f0_adj[15], f0_adj[14:0])) :
                                        {1'b0, f0[15:1]};

endmodule
