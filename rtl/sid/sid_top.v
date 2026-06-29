// ----------------------------------------------------------------------------
// SID Top — Chip-level integration
//
// Based on the MOS 6581/8580 SID chip designed by Bob Yannes.
// Converted from SystemVerilog to Verilog-2001 for maximum FPGA portability.
//
// Bob Yannes on the overall architecture:
//   Each voice consists of an Oscillator, Waveform Generator, Waveform
//   Selector, Waveform D/A, Multiplying D/A (amplitude), and Envelope Generator.
//   The analog output of each voice can be sent through a Multimode Analog
//   Filter or bypass it. A final Multiplying D/A provides overall volume control.
//
// This implementation supports:
//   - Dual SID mode (two chips for stereo)
//   - MOS6581 and MOS8580 mode selection (per chip)
//   - Waveform combinations via combinatorial AND (no ROM tables)
//   - Runtime-loadable filter cutoff curves
// ----------------------------------------------------------------------------

module sid_top
#(
	parameter MULTI_FILTERS = 1,
	parameter DUAL = 1
)
(
	input         reset,

	input         clk,
	input         ce_1m,

	input [N-1:0] cs,
	input         we,
	input   [4:0] addr,
	input   [7:0] data_in,
	output  [7:0] data_out,

	input  [12:0] fc_offset_l,
	input   [7:0] pot_x_l,
	input   [7:0] pot_y_l,
	input  [17:0] ext_in_l,
	output [17:0] audio_l,

	input  [12:0] fc_offset_r,
	input   [7:0] pot_x_r,
	input   [7:0] pot_y_r,
	input  [17:0] ext_in_r,
	output [17:0] audio_r,

	input [N-1:0] filter_en,
	input [N-1:0] mode,
	input [(N*2)-1:0] cfg,

	input         ld_clk,
	input  [11:0] ld_addr,
	input  [15:0] ld_data,
	input         ld_wr
);

localparam N = DUAL ? 2 : 1;

// ----------------------------------------------------------------------------
// Internal Signals — Register file (29 write registers per SID)
// Bob: "Cramming a wide range of rates into 4 bits allowed the ADSR to be
//        defined in two bytes instead of eight."
// Each voice uses 7 bytes: freq(2) + pw(2) + control(1) + ADSR(2)
// Filter uses 3 bytes: FC(2) + Res/Filt(1) + Mode/Vol(1)
// Total: 7*3 + 3 = 24 write registers + 4 read-only registers
// ----------------------------------------------------------------------------
reg  [15:0] Voice_1_Freq[N];
reg  [11:0] Voice_1_Pw[N];
reg   [7:0] Voice_1_Control[N];
reg   [7:0] Voice_1_Att_dec[N];
reg   [7:0] Voice_1_Sus_Rel[N];

reg  [15:0] Voice_2_Freq[N];
reg  [11:0] Voice_2_Pw[N];
reg   [7:0] Voice_2_Control[N];
reg   [7:0] Voice_2_Att_dec[N];
reg   [7:0] Voice_2_Sus_Rel[N];

reg  [15:0] Voice_3_Freq[N];
reg  [11:0] Voice_3_Pw[N];
reg   [7:0] Voice_3_Control[N];
reg   [7:0] Voice_3_Att_dec[N];
reg   [7:0] Voice_3_Sus_Rel[N];

reg  [10:0] Filter_Fc[N];
reg   [7:0] Filter_Res_Filt[N];
reg   [7:0] Filter_Mode_Vol[N];

// Voice outputs
wire  [7:0] Misc_Osc3[N];
wire  [7:0] Misc_Env3[N];

wire [21:0] voice_1[N];
wire [21:0] voice_2[N];
wire [21:0] voice_3[N];

wire        voice_1_PA_MSB[N];
wire        voice_2_PA_MSB[N];
wire        voice_3_PA_MSB[N];

reg  [17:0] audio[N];

reg   [7:0] bus_data[N];
reg  [12:0] Fc_offset[N];

// ============================================================================
// Voice instances (3 per SID chip)
// ============================================================================
// Bob Yannes: "Each voice consists of an Oscillator, Waveform Generator,
//   Waveform Selector, Waveform D/A converter, Multiplying D/A converter
//   for amplitude control, and an Envelope Generator for modulation."
//
// Hard Sync chain: Voice3 → Voice1 → Voice2 → Voice3
// Ring Mod chain:  Voice3 → Voice1, Voice1 → Voice2, Voice2 → Voice3
// Bob: "Hard Sync: clearing the accumulator of an Oscillator based on the
//        accumulator MSB of the previous oscillator."
// Bob: "Ring Mod: substituting the previous oscillator's accumulator MSB
//        into the EXOR function of the triangle waveform generator."
// ============================================================================

generate
	genvar i;

	for(i=0; i<N; i=i+1) begin :chip

		sid_voice v1
		(
			.clock(clk),
			.ce_1m(ce_1m),
			.reset(reset),
			.mode(mode[i]),
			.freq(Voice_1_Freq[i]),
			.pw(Voice_1_Pw[i]),
			.control(Voice_1_Control[i]),
			.att_dec(Voice_1_Att_dec[i]),
			.sus_rel(Voice_1_Sus_Rel[i]),
			.osc_msb_in(voice_3_PA_MSB[i]),
			.osc_msb_out(voice_1_PA_MSB[i]),
			.voice_out(voice_1[i])
		);

		sid_voice v2
		(
			.clock(clk),
			.ce_1m(ce_1m),
			.reset(reset),
			.mode(mode[i]),
			.freq(Voice_2_Freq[i]),
			.pw(Voice_2_Pw[i]),
			.control(Voice_2_Control[i]),
			.att_dec(Voice_2_Att_dec[i]),
			.sus_rel(Voice_2_Sus_Rel[i]),
			.osc_msb_in(voice_1_PA_MSB[i]),
			.osc_msb_out(voice_2_PA_MSB[i]),
			.voice_out(voice_2[i])
		);

		sid_voice v3
		(
			.clock(clk),
			.ce_1m(ce_1m),
			.reset(reset),
			.mode(mode[i]),
			.freq(Voice_3_Freq[i]),
			.pw(Voice_3_Pw[i]),
			.control(Voice_3_Control[i]),
			.att_dec(Voice_3_Att_dec[i]),
			.sus_rel(Voice_3_Sus_Rel[i]),
			.osc_msb_in(voice_2_PA_MSB[i]),
			.osc_msb_out(voice_3_PA_MSB[i]),
			.voice_out(voice_3[i]),
			.osc_out(Misc_Osc3[i]),
			.env_out(Misc_Env3[i])
		);

		always @(posedge clk) Fc_offset[i] <= i ? fc_offset_r : fc_offset_l;

		// ====================================================================
		// Register Decoding (SID register map)
		// ====================================================================
		// $00-$06: Voice 1 (Freq L/H, PW L/H, Control, Attack/Decay, Sustain/Release)
		// $07-$0D: Voice 2
		// $0E-$14: Voice 3
		// $15-$18: Filter + Mode/Volume
		// $19-$1C: Read-only (Pot X/Y, Osc3, Env3)
		// ====================================================================
		always @(posedge clk) begin
			if (reset) begin
				Voice_1_Freq[i]    <= 0;
				Voice_1_Pw[i]      <= 0;
				Voice_1_Control[i] <= 0;
				Voice_1_Att_dec[i] <= 0;
				Voice_1_Sus_Rel[i] <= 0;
				Voice_2_Freq[i]    <= 0;
				Voice_2_Pw[i]      <= 0;
				Voice_2_Control[i] <= 0;
				Voice_2_Att_dec[i] <= 0;
				Voice_2_Sus_Rel[i] <= 0;
				Voice_3_Freq[i]    <= 0;
				Voice_3_Pw[i]      <= 0;
				Voice_3_Control[i] <= 0;
				Voice_3_Att_dec[i] <= 0;
				Voice_3_Sus_Rel[i] <= 0;
				Filter_Fc[i]       <= 0;
				Filter_Res_Filt[i] <= 0;
				Filter_Mode_Vol[i] <= 0;
			end
			else if(cs[i]) begin
				if (we) begin
					bus_data[i] <= data_in;
					case (addr)
						5'h00: Voice_1_Freq[i][7:0] <= data_in;
						5'h01: Voice_1_Freq[i][15:8]<= data_in;
						5'h02: Voice_1_Pw[i][7:0]   <= data_in;
						5'h03: Voice_1_Pw[i][11:8]  <= data_in[3:0];
						5'h04: Voice_1_Control[i]   <= data_in;
						5'h05: Voice_1_Att_dec[i]   <= data_in;
						5'h06: Voice_1_Sus_Rel[i]   <= data_in;
						5'h07: Voice_2_Freq[i][7:0] <= data_in;
						5'h08: Voice_2_Freq[i][15:8]<= data_in;
						5'h09: Voice_2_Pw[i][7:0]   <= data_in;
						5'h0a: Voice_2_Pw[i][11:8]  <= data_in[3:0];
						5'h0b: Voice_2_Control[i]   <= data_in;
						5'h0c: Voice_2_Att_dec[i]   <= data_in;
						5'h0d: Voice_2_Sus_Rel[i]   <= data_in;
						5'h0e: Voice_3_Freq[i][7:0] <= data_in;
						5'h0f: Voice_3_Freq[i][15:8]<= data_in;
						5'h10: Voice_3_Pw[i][7:0]   <= data_in;
						5'h11: Voice_3_Pw[i][11:8]  <= data_in[3:0];
						5'h12: Voice_3_Control[i]   <= data_in;
						5'h13: Voice_3_Att_dec[i]   <= data_in;
						5'h14: Voice_3_Sus_Rel[i]   <= data_in;
						5'h15: Filter_Fc[i][2:0]    <= data_in[2:0];
						5'h16: Filter_Fc[i][10:3]   <= data_in;
						5'h17: Filter_Res_Filt[i]   <= data_in;
						5'h18: Filter_Mode_Vol[i]   <= data_in;
					endcase
				end
				else begin
					// Read-only registers
					// Bob: "They give the microprocessor access to the upper 8 bits
					//        of the instantaneous waveform and envelope values of Voice 3."
					case (addr)
						5'h19: bus_data[i] = i ? pot_x_r : pot_x_l;
						5'h1a: bus_data[i] = i ? pot_y_r : pot_y_l;
						5'h1b: bus_data[i] = Misc_Osc3[i];
						5'h1c: bus_data[i] = Misc_Env3[i];
					endcase
				end
			end
		end
	end
endgenerate

// ============================================================================
// Filter Cutoff Frequency Generator
// ============================================================================
// Bob: "An 11-bit D/A converter generates the FET control voltage.
//        The FET resistance varied considerably with processing, so
//        different lots of SID chips had different cutoff characteristics."
//
// sid_cutoff generates F0 (w0*T << 17) for the filter from the 11-bit
// cutoff register (Filter_Fc). The MOS8580 uses linear mapping;
// the MOS6581 uses a non-linear curve with per-chip calibration.
// ============================================================================

wire [15:0] F0;
wire n = DUAL && state[3];

sid_cutoff #(MULTI_FILTERS) sid_cutoff_inst
(
	.clock(clk),
	.mode(mode[n]),

	.cfg(cfg[n*2 +:2]),
	.Fc(Filter_Fc[n]),
	.Fc_offset(Fc_offset[n]),
	.F0(F0),
	.ld_clk(ld_clk),
	.ld_addr(ld_addr),
	.ld_data(ld_data),
	.ld_wr(ld_wr)
);

// ============================================================================
// Filter state machine (time-shared multiplier for dual SID)
// ============================================================================
// The filter uses a single hardware multiplier shared between two SID chips.
// States 0-7: Chip 0 filter computation
// States 8-15: Chip 1 filter computation (if DUAL)
// ce_1m resets the state counter each 1MHz cycle.
// ============================================================================
reg [3:0] state;

always @(posedge clk) begin
	if(~&state) state <= state + 1'd1;
	if(ce_1m) state <= 0;
end

// ============================================================================
// Filter instance
// ============================================================================
wire [17:0] faudio;

wire signed [21:0] ext_in_signed = $signed({n ? ext_in_r : ext_in_l, 3'b000});

sid_filter sid_filter_inst
(
	.clk(clk),
	.state(state[2:0]),
	.mode(mode[n]),

	.F0(F0),
	.Res_Filt(Filter_Res_Filt[n]),
	.Mode_Vol(Filter_Mode_Vol[n]),
	.voice1(voice_1[n]),
	.voice2(voice_2[n]),
	.voice3(voice_3[n]),
	.ext_in(ext_in_signed),

	.audio(faudio)
);

// ============================================================================
// Audio output capture (sample at correct pipeline stage)
// ============================================================================
reg [17:0] audio0;

always @(posedge clk) begin
	if (state == 6)  audio0 <= faudio;
	if (state == 14) begin
		audio[n] <= faudio;
		audio[0] <= audio0;
	end
end

// ============================================================================
// Bus output mux (dual chip select)
// ============================================================================
assign data_out = cs[0] ? bus_data[0] : bus_data[N-1];

assign audio_l = audio[0];
assign audio_r = audio[N-1];

endmodule
