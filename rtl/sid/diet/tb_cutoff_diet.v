// Testbench: drives sid_cutoff_diet and a "reference" model built from the
// original LUT contents, then compares F0 over the entire input range.

`timescale 1ns/1ps

module tb_cutoff_diet;

reg clock = 0;
always #5 clock = ~clock;  // 100 MHz

reg         mode = 0;
reg  [10:0] Fc   = 0;
reg  [12:0] Fc_offset = 0;

wire [15:0] F0_diet;

sid_cutoff_diet #(.MULTI_FILTERS(0)) u_diet (
    .clock(clock), .mode(mode), .cfg(2'b00),
    .Fc(Fc), .Fc_offset(Fc_offset),
    .F0(F0_diet),
    .ld_clk(1'b0), .ld_addr(12'd0), .ld_data(16'd0), .ld_wr(1'b0)
);

// -------------------------------------------------------------------
// Reference model: original LUTs + same surrounding logic, simplified
// -------------------------------------------------------------------
reg [15:0] curve_lut [0:1023];
reg [14:0] adj_lut   [0:1023];

initial begin
    $readmemh("curve_bank0.hex", curve_lut);
    $readmemh("adj.hex",         adj_lut);
end

// Instantiate the same DAC for fc_6581
wire [10:0] fc_6581_ref;
sid_dac #(.BITS(11)) ref_dac (.vin(Fc), .vout(fc_6581_ref));

function [9:0] tanh_x_mirror;
    input signed [10:0] x;
    begin tanh_x_mirror = x < 0 ? ~x[9:0] + 1'b1 : x[9:0]; end
endfunction
function signed [10:0] tanh_x_clamp;
    input signed [12:0] x;
    begin
        if (x < -1023) tanh_x_clamp = -11'sd1023;
        else if (x > 1023) tanh_x_clamp = 11'sd1023;
        else tanh_x_clamp = x[10:0];
    end
endfunction
function signed [15:0] tanh_y_mirror;
    input              x_neg;
    input signed [15:0] y;
    begin tanh_y_mirror = x_neg ? -y : y; end
endfunction

wire signed [15:0] f6581_adj_y0 = 16'sd10133;
wire signed [10:0] fc_x_ref     = tanh_x_clamp($signed({2'b00, fc_6581_ref}) - $signed(Fc_offset));
wire        [9:0]  adj_idx_ref  = tanh_x_mirror(fc_x_ref);

reg [15:0] f0_adj_ref, f0_ref;
always @(posedge clock) begin
    f0_adj_ref <= {fc_x_ref[10], adj_lut[adj_idx_ref]};
    f0_ref     <= curve_lut[Fc[10:1]];
end

wire [15:0] F0_ref =
    mode               ? ({3'b000, Fc, 2'b00} + Fc) :
    (Fc_offset != 0)   ? (f6581_adj_y0 + tanh_y_mirror(f0_adj_ref[15], f0_adj_ref[14:0])) :
                         {1'b0, f0_ref[15:1]};

// -------------------------------------------------------------------
// Sweep & compare
// -------------------------------------------------------------------
integer max_abs_err, sum_sq, count, diff, i;
integer fc_off_arr [0:5];

function integer abs;
    input integer x;
    begin abs = (x < 0) ? -x : x; end
endfunction

function integer isqrt;
    input integer x;
    integer r, r2;
    begin
        if (x < 1) isqrt = 0;
        else begin
            r = x; r2 = (r + 1) >> 1;
            while (r2 < r) begin r = r2; r2 = (r + x/r) >> 1; end
            isqrt = r;
        end
    end
endfunction

task run_sweep;
    input integer label_id;
    input integer fc_off_signed;
    begin
        Fc_offset = fc_off_signed[12:0];
        max_abs_err = 0; sum_sq = 0; count = 0;
        for (Fc = 0; Fc <= 11'h7FE; Fc = Fc + 1) begin
            @(posedge clock); @(posedge clock); #1;
            diff = abs($signed({1'b0,F0_ref}) - $signed({1'b0,F0_diet}));
            if (diff > max_abs_err) max_abs_err = diff;
            sum_sq = sum_sq + diff*diff;
            count = count + 1;
        end
        // Last value (Fc=2047)
        Fc = 11'h7FF;
        @(posedge clock); @(posedge clock); #1;
        diff = abs($signed({1'b0,F0_ref}) - $signed({1'b0,F0_diet}));
        if (diff > max_abs_err) max_abs_err = diff;
        sum_sq = sum_sq + diff*diff; count = count + 1;
        $display("  label=%0d  mode=%0d  Fc_off=%0d  max=%0d  rms=%0d  count=%0d",
                 label_id, mode, fc_off_signed, max_abs_err, isqrt(sum_sq/count), count);
    end
endtask

initial begin
    fc_off_arr[0] = 0;
    fc_off_arr[1] = 1;
    fc_off_arr[2] = 256;
    fc_off_arr[3] = 1023;
    fc_off_arr[4] = -1024;
    fc_off_arr[5] = 4095;

    // wait for $readmemh
    #10;

    $display("=== Mode 0 (6581), curve path (Fc_offset=0) ===");
    mode = 0;
    run_sweep(0, 0);

    $display("=== Mode 1 (8580), linear path (must match exactly) ===");
    mode = 1;
    run_sweep(1, 0);

    $display("=== Mode 0 (6581), adj path (Fc_offset != 0) ===");
    mode = 0;
    for (i = 1; i < 6; i = i + 1) begin
        run_sweep(2+i, fc_off_arr[i]);
    end

    $finish;
end

endmodule
