// ----------------------------------------------------------------------------
// SID Filter — Multi-mode State-Variable VCF
//
// Based on the MOS 6581/8580 SID chip designed by Bob Yannes.
// Converted from SystemVerilog to Verilog-2001 for maximum FPGA portability.
//
// Reference: reDIP-SID by Dag Lem (resid@nimrod.no)
// Reference: Interview with Bob Yannes (interview.md)
//
// Bob Yannes on the filter:
//   "Classic multi-mode (state-variable) VCF design. No variable
//    transconductance amplifier was possible in MOS's NMOS process, so
//    FETs are used as voltage-controlled resistors to set the cutoff
//    frequency."
//
//   "An 11-bit D/A converter generates the FET control voltage.
//    (It's actually a 12-bit D/A, but the LSB had no audible effect so
//    it was disconnected.) Resonance is controlled by a 4-bit weighted
//    resistor ladder: each bit switches in one of the weighted resistors,
//    feeding a portion of the output back to the input."
//
//   "The state-variable topology provides simultaneous low-pass, band-pass
//    and high-pass outputs. Analog switches select which combination of
//    outputs goes to the final amplifier. A notch is created by enabling
//    both high-pass and low-pass simultaneously."
//
// Why the filter is the worst part of SID:
//   "Yannes states bluntly that the filter is the worst part of SID.
//    He could not create high-gain op-amps in NMOS, which were essential
//    to a resonant filter. The FET resistance varied considerably with
//    processing, so different lots of SID chips had different cutoff
//    frequency characteristics. He knew it wouldn't work very well, but
//    it was better than nothing — he didn't have time to make it better."
// ----------------------------------------------------------------------------

module sid_filter
(
	input               clk,
	input         [2:0] state,
	input               mode,

	input        [15:0] F0,
	input         [7:0] Res_Filt,
	input         [7:0] Mode_Vol,
	input signed [21:0] voice1,
	input signed [21:0] voice2,
	input signed [21:0] voice3,
	input signed [21:0] ext_in,

	output       [17:0] audio
);

// ----------------------------------------------------------------------------
// Mixer DC offset for MOS 6581
// The 6581 mixer adds a DC offset due to imperfect op-amps.
// Bob: "He could not create high-gain op-amps in NMOS"
// ----------------------------------------------------------------------------
localparam signed [23:0] MIXER_DC_6581 = 24'shFF1C72;

// ----------------------------------------------------------------------------
// Clamp to 16 bits (saturating arithmetic for filter state variables)
// ----------------------------------------------------------------------------
function signed [15:0] clamp;
	input signed [16:0] x;
	begin
		clamp = (^x[16:15]) ? {x[16], {15{x[15]}}} : x[15:0];
	end
endfunction

// ----------------------------------------------------------------------------
// Resonance table (1/Q values)
//
// Bob: "Resonance is controlled by a 4-bit weighted resistor ladder:
//        each bit switches in one of the weighted resistors, feeding a
//        portion of the output back to the input."
//
// MOS6581: 1/Q =~ ~res/8 (not used — op-amps are not ideal)
// MOS8580: 1/Q =~ 2^((4 - res)/8)
// The table is indexed by {mode, Res_Filt[7:4]} (5 bits = 32 entries).
// First 16 entries = MOS6581, last 16 entries = MOS8580.
// Values are 1/Q shifted left by 10 for fixed-point arithmetic.
// ----------------------------------------------------------------------------
reg [10:0] _1_Q_lsl10_tbl [0:31];

initial begin
	// MOS6581 resonance (index 0-15)
	_1_Q_lsl10_tbl[ 0] = 1448;
	_1_Q_lsl10_tbl[ 1] = 1324;
	_1_Q_lsl10_tbl[ 2] = 1219;
	_1_Q_lsl10_tbl[ 3] = 1129;
	_1_Q_lsl10_tbl[ 4] = 1052;
	_1_Q_lsl10_tbl[ 5] = 984;
	_1_Q_lsl10_tbl[ 6] = 925;
	_1_Q_lsl10_tbl[ 7] = 872;
	_1_Q_lsl10_tbl[ 8] = 826;
	_1_Q_lsl10_tbl[ 9] = 783;
	_1_Q_lsl10_tbl[10] = 745;
	_1_Q_lsl10_tbl[11] = 711;
	_1_Q_lsl10_tbl[12] = 679;
	_1_Q_lsl10_tbl[13] = 651;
	_1_Q_lsl10_tbl[14] = 624;
	_1_Q_lsl10_tbl[15] = 600;
	// MOS8580 resonance (index 16-31)
	_1_Q_lsl10_tbl[16] = 1448;
	_1_Q_lsl10_tbl[17] = 1328;
	_1_Q_lsl10_tbl[18] = 1218;
	_1_Q_lsl10_tbl[19] = 1117;
	_1_Q_lsl10_tbl[20] = 1024;
	_1_Q_lsl10_tbl[21] = 939;
	_1_Q_lsl10_tbl[22] = 861;
	_1_Q_lsl10_tbl[23] = 790;
	_1_Q_lsl10_tbl[24] = 724;
	_1_Q_lsl10_tbl[25] = 664;
	_1_Q_lsl10_tbl[26] = 609;
	_1_Q_lsl10_tbl[27] = 558;
	_1_Q_lsl10_tbl[28] = 512;
	_1_Q_lsl10_tbl[29] = 470;
	_1_Q_lsl10_tbl[30] = 431;
	_1_Q_lsl10_tbl[31] = 395;
end

// ----------------------------------------------------------------------------
// Multiplier: o = c +- (a * b)
// Used for all filter computations (w0*vbp, w0*vhp, 1/Q*vbp, vol*amix)
// ----------------------------------------------------------------------------
reg signed  [31:0] c;
reg                s;
reg signed  [15:0] a;
reg signed  [15:0] b;
wire signed [31:0] m = a * b;
wire signed [31:0] o = s ? (c - m) : (c + m);

// ----------------------------------------------------------------------------
// State-variable filter core
//
// Bob: "The state-variable topology provides simultaneous low-pass,
//        band-pass and high-pass outputs."
//
// Filter equations (per sample):
//   vlp = vlp - w0*vbp       (low-pass update)
//   vbp = vbp - w0*vhp       (band-pass update)
//   vhp = 1/Q*vbp - vlp - vi (high-pass update)
//
// vlp, vbp, vhp are maintained for two SID chips (dual mode).
// The filter is computed iteratively across multiple clock cycles
// (states 2-5) to share a single hardware multiplier.
//
// NOTE on chip-to-chip variation:
//   "The FET resistance varied considerably with processing, so different
//    lots of SID chips had different cutoff frequency characteristics."
//   The F0 input already accounts for this via fc_offset from sid_top.
// ----------------------------------------------------------------------------

reg signed [15:0] vlp, vlp2, vlp_next;
reg signed [15:0] vbp, vbp2, vbp_next;
reg signed [15:0] vhp, vhp2, vhp_next;
reg signed [16:0] dv;

reg [10:0] _1_Q_lsl10;
reg signed [15:0] vi;
reg signed [15:0] vd;

wire signed [23:0] voice1_24 = voice1;
wire signed [23:0] voice2_24 = voice2;
wire signed [23:0] voice3_24 = voice3;
wire signed [23:0] ext_in_24 = ext_in;
wire signed [31:0] vlp2_32 = vlp2;
wire signed [31:0] vi_32 = vi;
wire signed [16:0] vd_17 = vd;
wire signed [16:0] vlp2_17 = vlp2;
wire signed [16:0] vbp2_17 = vbp2;
wire signed [16:0] vhp_next_17 = vhp_next;

always @(*) begin
	// Intermediate results for filter.
	// Shifts -w0*vbp and -w0*vhp right by 17 for fixed-point scaling.
	dv       = $signed(o >>> 17);
	vlp_next = clamp(vlp + dv);
	vbp_next = clamp(vbp + dv);
	vhp_next = clamp(o[10 +: 17]);
end

// Filter state computation pipeline
always @(posedge clk) begin
	case (state)
		2:	begin
				// Load resonance value for current chip model.
				// MOS6581: 1/Q =~ ~res/8
				// MOS8580: 1/Q =~ 2^((4 - res)/8)
				_1_Q_lsl10 <= _1_Q_lsl10_tbl[{mode, Res_Filt[7:4]}];

				// Mux for filter path.
				// Bob: "Analog switches route each Oscillator either through
				//        or around the filter to the final amplifier."
				// Each voice contributes if its Filter enable bit is set.
				// Each voice is 22 bits; sum of four voices is 24 bits.
				vi <= ((Res_Filt[0] ? voice1_24 : 24'sd0) +
							  (Res_Filt[1] ? voice2_24 : 24'sd0) +
							  (Res_Filt[2] ? voice3_24 : 24'sd0) +
							  (Res_Filt[3] ? ext_in_24 : 24'sd0)) >>> 7;

				// Mux for direct audio path (voices bypassing the filter).
				// 3-OFF (Mode_Vol[7]) disconnects Voice 3 from the direct
				// audio path so it can be used as a modulation source.
				// Bob: "An analog switch disables the audio output of Voice 3
				//        so that the modulation source isn't heard in the
				//        output mix."
				// We add the mixer DC here to save time in the final sum.
				vd <= ((mode        ? 24'sd0 : MIXER_DC_6581) +
							  (Res_Filt[0] ? 24'sd0 : voice1_24) +
							  (Res_Filt[1] ? 24'sd0 : voice2_24) +
							  ((Res_Filt[2] |
							   Mode_Vol[7]) ? 24'sd0 : voice3_24) +
							  (Res_Filt[3] ? 24'sd0 : ext_in_24)) >>> 7;

				// vlp = vlp - w0*vbp
				// Calculate -w0*vbp
				c <= 0;
				s <= 1;
				a <= F0;   // w0*T << 17 (cutoff frequency from DAC)
				b <= vbp;
			end
		3:	begin
				// Result for vlp ready (see vlp_next above).
				{vlp, vlp2} <= {vlp2, vlp_next};

				// vbp = vbp - w0*vhp
				// Calculate -w0*vhp
				c <= 0;
				s <= 1;
				// a <= a; // w0*T << 17 (held from previous state)
				b <= vhp;
			end
		4:	begin
				// Result for vbp ready (see vbp_next above).
				{vbp, vbp2} <= {vbp2, vbp_next};

				// vhp = 1/Q*vbp - vlp - vi
				c <= -(vlp2_32 + vi_32) << 10;
				s <= 0;
				a <= _1_Q_lsl10; // 1/Q << 10 (resonance)
				b <= vbp_next;
			end
		5: begin
				// Result for vbp ready (see vhp_next above).
				{vhp, vhp2} <= {vhp2, vhp_next};

				// Audio output: aout = vol * amix
				// Bob: "The final amp is a 4-bit multiplying D/A converter
				//        providing master volume control."
				//
				// Filter mode selection (simultaneous outputs):
				// Bob: "Analog switches select which combination of outputs
				//        goes to the final amplifier."
				// Mode_Vol[4] = LP, Mode_Vol[5] = BP, Mode_Vol[6] = HP
				// Bob: "A notch is created by enabling both high-pass and
				//        low-pass simultaneously." (LP+HP = notch)
				c <= 0;
				s <= 0;
				a <= {12'b0, Mode_Vol[3:0]}; // Master volume (4-bit)
				b <= clamp(vd_17 +
						(Mode_Vol[4] ? vlp2_17     : 17'sd0) +
						(Mode_Vol[5] ? vbp2_17     : 17'sd0) +
						(Mode_Vol[6] ? vhp_next_17 : 17'sd0));
			end
	endcase
end

assign audio = o[19:2];

endmodule
