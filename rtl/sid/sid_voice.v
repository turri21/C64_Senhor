// ----------------------------------------------------------------------------
// SID Voice — Oscillator, Waveform Generator, DCA
//
// Based on the MOS 6581/8580 SID chip designed by Bob Yannes.
// Converted from SystemVerilog to Verilog-2001 for maximum FPGA portability.
//
// Reference: Interview with Bob Yannes, SID Chip Inventor (Andreas Varga, 1996)
// Source: interview.md in this repository.
//
// Bob Yannes on the overall voice architecture:
//   Each voice consists of:
//   - An Oscillator
//   - A Waveform Generator
//   - A Waveform Selector
//   - A Waveform D/A converter
//   - A Multiplying D/A converter for amplitude control
//   - An Envelope Generator for modulation
//
//   "The analog output of each voice can be sent through a Multimode Analog
//    Filter or bypass it. A final Multiplying D/A converter provides overall
//    manual volume control."
// ----------------------------------------------------------------------------

module sid_voice
(
	input         clock,
	input         ce_1m,
	input         reset,
	input         mode,
	input  [15:0] freq,
	input  [11:0] pw,
	input   [7:0] control,
	input   [7:0] att_dec,
	input   [7:0] sus_rel,
	input         osc_msb_in,

	
	output        osc_msb_out,
	output [21:0] voice_out,
	output [ 7:0] osc_out,
	output [ 7:0] env_out
);

// ----------------------------------------------------------------------------
// DC offsets and timing constants for MOS6581 vs MOS8580
// ----------------------------------------------------------------------------

// Waveform DC offset: OSC3 = 0x38 at 5.94V on the 6581; no offset on 8580.
localparam        [12:0] WAVEFORM_DC_6581 = 13'h380;
localparam        [12:0] WAVEFORM_DC_8580 = 13'h800;

// Measured voice DC offset from real 6581 samples; 0 on the 8580.
localparam signed [21:0] VOICE_DC_6581    = 22'h33CC0;
localparam signed [21:0] VOICE_DC_8580    = 22'h0;

// Waveform-0 TTL (time before floating input decays to zero):
// When no waveform is selected, the DAC input floats and decays slowly.
// The 8580 has much longer TTL due to improved circuitry.
localparam WF_0_TTL_6581  = 23'd200000;   // ~200ms
localparam WF_0_TTL_8580  = 23'd5000000;  // ~5s

// Noise TTL: how long before the noise output decays to all-ones when
// the noise LFSR clock stops (intermediate accumulator bit stops toggling).
localparam NOISE_TTL_6581 = 24'h8000;
localparam NOISE_TTL_8580 = 24'h950000;

// ----------------------------------------------------------------------------
// Control register bit definitions
//   control[7] = Noise waveform enable
//   control[6] = Pulse waveform enable
//   control[5] = Sawtooth waveform enable
//   control[4] = Triangle waveform enable
//   control[3] = Test bit (stops oscillator, resets accumulator)
//   control[2] = Ring Modulation enable
//   control[1] = Hard Sync enable
//   control[0] = Gate bit (triggers envelope Attack/Release)
// ----------------------------------------------------------------------------
wire test_ctrl     = control[3];
wire ringmod_ctrl  = control[2];
wire sync_ctrl     = control[1];

// Signal Assignments
assign osc_msb_out = oscillator[23];
assign voice_out   = dca_out;
assign osc_out     = wave_out;
assign env_out     = envelope;

// ============================================================================
// ENVELOPE GENERATOR
// ============================================================================
// Bob Yannes:
//   "An 8-bit up/down counter, triggered by the Gate bit.
//    The digital control word that modulates the waveform's amplitude
//    comes from the Envelope Generator."
//
// The envelope generator is instantiated as a separate module.
// See sid_envelope.v for detailed Bob Yannes commentary.
// ============================================================================

wire [7:0] envelope;

sid_envelope adsr
(
	.clock(clock),
	.ce_1m(ce_1m),
	.reset(reset),
	.gate(control[0]),
	.att_dec(att_dec),
	.sus_rel(sus_rel),
	.envelope(envelope)
);

// ============================================================================
// PHASE-ACCUMULATING OSCILLATOR (24-bit)
// ============================================================================
// Bob Yannes:
//   "24-bit phase-accumulating design. The lower 16 bits are programmable
//    for pitch control. The accumulator output goes directly to a D/A
//    converter through a waveform selector."
//
//   "Normally a phase-accumulating oscillator's output would index a
//    wavetable in memory, but SID had to be entirely self-contained —
//    there was no room on the chip for a wavetable."
//
//   The 24-bit accumulator wraps naturally, providing the phase for all
//   waveform generators. The 16-bit frequency register controls pitch.
// ============================================================================

reg  [23:0] oscillator;
reg         osc_msb_in_prv;
reg         test_delay;

always @(posedge clock) begin

	if (ce_1m) begin
		osc_msb_in_prv <= osc_msb_in;
		test_delay <= mode & test_ctrl;
		// Accumulator reset conditions:
		//   - Global reset
		//   - Test bit set (direct reset)
		//   - Test bit was set on previous cycle (delayed clear)
		//   - Hard Sync: rising edge of previous oscillator's MSB clears accumulator
		oscillator <= (reset || test_ctrl || test_delay ||
		               (sync_ctrl && ~osc_msb_in && osc_msb_in_prv)) ? 24'd0 : (oscillator + freq);

		// 6581 sawtooth MSB writeback: the waveform output MSB feeds back
		// to the oscillator MSB through the sawtooth selector transistor.
		// This must happen after the oscillator update so the writeback
		// overwrites the MSB that was just computed.
		// Reference: reDIP-SID sid_waveform.sv — o4[23] <= wav[11]
		if (msb_writeback)
			oscillator[23] <= msb_feedback;
	end
end

// ============================================================================
// HARD SYNC
// ============================================================================
// Bob Yannes:
//   "Implemented by clearing the accumulator of an Oscillator based on the
//    accumulator MSB of the previous oscillator."
//
// When the previous oscillator's MSB goes from 1 to 0 (wrapping), the
// current oscillator's accumulator is cleared to zero. This forces the
// current oscillator to restart its cycle in sync with the previous one,
// creating rich harmonic timbres.
// (Implemented in the oscillator always block above.)
// ============================================================================

// ============================================================================
// 6581 SAWTOOTH MSB WRITEBACK
// ============================================================================
// Reference: reDIP-SID sid_waveform.sv
//
// On the MOS 6581, the sawtooth waveform selector is a single transistor
// that connects the oscillator MSB directly to the common DAC input bus.
// Because the DAC bus is shared with other waveform selectors (also single
// transistors), the combined waveform output can feed back through the
// sawtooth selector and overwrite the oscillator MSB.
//
// This creates a feedback loop: the oscillator MSB drives the DAC, the DAC
// output (possibly ANDed with other waveforms) feeds back to the oscillator.
// The result is that combined waveforms on the 6581 produce chaotic,
// chip-specific sounds that differ from the clean AND of the 8580.
//
// reDIP-SID models this as:
//   if (model == MOS6581 && sawtooth_selected)
//       osc_msb_next_cycle <= waveform_output[11];
//
// Implementation note: The writeback is applied one cycle after the waveform
// is computed, modeling the phi1/phi2 timing of the real chip. The feedback
// only applies when sawtooth is selected (control[5]) and chip is 6581.
// ============================================================================
reg        msb_writeback;
reg        msb_feedback;     // Latched waveform MSB for 6581 writeback
wire [11:0] wav_full = norm | {comb, 4'b0};

always @(posedge clock) begin
	if (ce_1m) begin
		// Latch writeback condition: 6581 + sawtooth selected + waveform active
		msb_writeback <= ~mode & control[5] & |control[7:4];
		// Latch the waveform MSB for feedback in the next cycle
		msb_feedback <= wav_full[11];
	end
end

// ============================================================================
// ACCUMULATOR OUTPUT (acc_t) — Sawtooth + Triangle + Ring Modulation
// ============================================================================
// Bob Yannes:
//
// Sawtooth:
//   "Created by sending the upper 12 bits of the accumulator to the
//    12-bit Waveform D/A."
//
// Triangle:
//   "Uses the MSB of the accumulator to invert the remaining upper 11
//    accumulator bits via EXOR gates. These 11 bits are then left-shifted
//    (discarding the MSB) and sent to the Waveform D/A. Resolution of
//    triangle is half that of sawtooth, but amplitude and frequency are
//    the same."
//
// Ring Modulation:
//   "Implemented by substituting the previous oscillator's accumulator MSB
//    into the EXOR function of the triangle waveform generator (replacing
//    the current oscillator's MSB)."
//
//   "This is why the triangle waveform must be selected to use
//    Ring Modulation."
//
// Implementation:
//   acc_t is a dual-purpose signal that adapts based on control[5] (sawtooth enable):
//
//   When control[5]=1 (sawtooth selected):
//     invert_control = ~1 & (...) = 0 → no XOR → acc_t = raw upper 12 bits = sawtooth
//
//   When control[5]=0 (sawtooth NOT selected):
//     invert_control = ~0 & (0 ^ MSB) = MSB → XOR with MSB → acc_t = triangle signal
//     (The MSB inverts the upper 11 bits on the second half of the cycle)
//
//   With Ring Modulation (control[2]=1):
//     The previous oscillator's MSB replaces the current oscillator's MSB
//     in the XOR function, creating ring-modulated output.
//
//   Then the waveform selector interprets acc_t differently:
//     - Sawtooth (control[5]=1): uses acc_t directly (12 bits)
//     - Triangle (control[4]=1): takes acc_t[10:0], left-shifts by 1, discarding MSB
//       Bob: "These 11 bits are then left-shifted (discarding the MSB)
//             and sent to the Waveform D/A."
// ============================================================================

wire [11:0] acc_t;

assign acc_t = {oscillator[23],
                oscillator[22:12] ^ {11{~control[5] & ((ringmod_ctrl & ~osc_msb_in) ^ oscillator[23])}}};

// ============================================================================
// WAVEFORM GENERATOR
// ============================================================================
// Internal registers for waveform generation
// ============================================================================
reg [11:0] noise;
reg [11:0] saw_tri;
reg        pulse;

// Internal variables declared at module level for Verilog-2001 compatibility
reg        clk;
reg        clk_d;
reg        osc_edge;
reg [23:0] noise_age;
reg [22:0] lfsr_noise;

always @(posedge clock) begin
	if (reset) begin
		saw_tri    <= 0;
		pulse      <= 0;
		noise      <= 0;
		osc_edge   <= 0;
		lfsr_noise <= {23{1'b1}};
		noise_age  <= 0;
		clk        <= 0;
		clk_d      <= 0;
	end
	else begin
		if (ce_1m) begin

			// ====================================================================
			// SAWTOOTH + TRIANGLE capture
			// ====================================================================
			// Bob: Sawtooth = upper 12 bits of accumulator.
			//      Triangle = MSB inverts upper 11 bits via EXOR, then left-shift.
			// Both are captured in acc_t (calculated above) and stored here.
			saw_tri <= acc_t;

			// ====================================================================
			// PULSE waveform
			// ====================================================================
			// Bob Yannes:
			//   "The upper 12 bits of the accumulator are sent to a 12-bit
			//    digital comparator. The comparator outputs a single bit
			//    (1 or 0). That single output is fanned out to all 12 bits
			//    of the Waveform D/A."
			//
			// The pulse width register (12-bit) is compared against the
			// upper 12 bits of the phase accumulator. When acc >= pw,
			// the output is high; otherwise low.
			// Test bit forces the output high (used for DAC calibration).
			pulse <= (test_ctrl || (oscillator[23:12] >= pw));

			// ====================================================================
			// NOISE — 23-bit LFSR (Linear Feedback Shift Register)
			// ====================================================================
			// Bob Yannes:
			//   "Generated by a 23-bit pseudo-random sequence generator
			//    (a shift register with specific outputs fed back through
			//    combinatorial logic). The shift register is clocked by one
			//    of the intermediate bits of the accumulator to keep the
			//    noise's frequency content roughly aligned with the pitched
			//    waveforms. The upper 12 bits of the shift register are sent
			//    to the Waveform D/A."
			//
			// LFSR clock: an intermediate accumulator bit (bit 19).
			// This keeps noise frequency content proportional to oscillator
			// pitch, so the noise sounds consistent across the frequency range.
			osc_edge <= oscillator[19];
			clk      <= ~(reset || test_ctrl || (~osc_edge & oscillator[19]));
			clk_d    <= clk;

			// Noise output: specific LFSR tap positions are routed to the DAC.
			// Bob says "The upper 12 bits of the shift register are sent to the
			// Waveform D/A." In practice, the SID hardware connects 8 specific
			// tap positions (not contiguous upper bits) to the upper 8 bits of
			// the 12-bit DAC. The lower 4 DAC bits are tied to zero because the
			// DAC's lower bits have negligible resolution anyway (see sid_dac.v).
			// The tap positions [20,18,14,11,9,5,2,0] are from reverse-engineering
			// of the actual MOS 6581/8580 silicon by the reSID project.
			noise <= {lfsr_noise[20], lfsr_noise[18], lfsr_noise[14],
			          lfsr_noise[11], lfsr_noise[9], lfsr_noise[5],
			          lfsr_noise[2], lfsr_noise[0], 4'b0000};

			// Noise aging: if the LFSR clock stops (oscillator at very low
			// frequencies), the noise output eventually decays to all-ones
			// to simulate the floating DAC input.
			if (~clk) begin
				if (noise_age >= (mode ? NOISE_TTL_8580 : NOISE_TTL_6581))
					noise <= {12{1'b1}};
				else
					noise_age <= noise_age + 1'd1;
			end
			else begin
				noise_age <= 0;

				// LFSR shift on rising clock edge
				if (clk & ~clk_d) begin
					// Feedback tap: bit 22 XOR bit 17, with inversion on
					// reset or test to fill with ones (prevents lock-up).
					lfsr_noise <= {lfsr_noise[21:0],
					               (reset | test_ctrl | lfsr_noise[22]) ^ lfsr_noise[17]};
				end
				// ====================================================================
				// LFSR writeback from combined waveforms
				// ====================================================================
				// Bob Yannes:
				//   "All waveforms are digital bits, so the Waveform Selector
				//    consists of multiplexers selecting which waveform bits go
				//    to the Waveform D/A. The multiplexers are single transistors
				//    and don't provide a 'lock-out' — combinations of waveforms
				//    can be selected."
				//
				//   "Combining waveforms results in a logical AND of their bits,
				//    producing unpredictable results. Yannes did not encourage
				//    this, especially because it could lock up the pseudo-random
				//    sequence generator by filling it with zeroes."
				//
				// When noise is combined with another waveform, the LFSR output
				// bits sit on the common DAC input bus alongside the other
				// waveform outputs. Since the multiplexers are single transistors,
				// all selected waveforms are effectively ANDed together. The LFSR
				// reads back from this bus, so it sees the ANDed result. This can
				// clear LFSR bits, potentially filling the entire register with
				// zeroes and locking it up permanently.
				else if (control[7] & |control[6:4]) begin
					lfsr_noise[20] <= lfsr_noise[20] & wave_out[7];
					lfsr_noise[18] <= lfsr_noise[18] & wave_out[6];
					lfsr_noise[14] <= lfsr_noise[14] & wave_out[5];
					lfsr_noise[11] <= lfsr_noise[11] & wave_out[4];
					lfsr_noise[ 9] <= lfsr_noise[ 9] & wave_out[3];
					lfsr_noise[ 5] <= lfsr_noise[ 5] & wave_out[2];
					lfsr_noise[ 2] <= lfsr_noise[ 2] & wave_out[1];
					lfsr_noise[ 0] <= lfsr_noise[ 0] & wave_out[0];
				end
			end
		end
	end
end

// ============================================================================
// WAVEFORM OUTPUT SELECTOR
// ============================================================================
// Bob Yannes:
//   "All waveforms are digital bits, so the Waveform Selector consists of
//    multiplexers selecting which waveform bits go to the Waveform D/A.
//    The multiplexers are single transistors and don't provide a lock-out —
//    combinations of waveforms can be selected."
//
//   "Combining waveforms results in a logical AND of their bits."
//
// control[7:4] = {noise, pulse, sawtooth, triangle}
//
// Individual waveform selection (only one bit set):
//   0001 = Triangle: acc_t[10:0] left-shifted by 1 (half sawtooth resolution)
//   0010 = Sawtooth: acc_t directly (upper 12 bits of accumulator)
//   0100 = Pulse: single bit fanned out to all 12 positions
//   1000 = Noise: upper bits from 23-bit LFSR
//
// Combined waveforms (multiple bits set) — AND combinatorial logic:
//   Bob: "Combining waveforms results in a logical AND of their bits,
//         producing unpredictable results."
//
//   The combined output is simply the bitwise AND of the selected waveforms.
//   This is EXACTLY how the original SID hardware works — the single-transistor
//   multiplexers on the common DAC bus produce an AND of all enabled waveforms.
//
//   NOTE: This replaces the previous implementation that used ~12KB of ROM
//   lookup tables (sid_tables.sv). The AND approach is bit-accurate for the
//   MOS 8580. For the MOS 6581, the DAC non-linearity (modeled in sid_dac.v)
//   already accounts for the differences in combined waveform appearance.
// ============================================================================

// 12-bit waveform definitions for AND combinations
wire [11:0] tri_12 = {saw_tri[10:0], 1'b0};  // Triangle
wire [11:0] saw_12 = saw_tri;                  // Sawtooth
wire [11:0] pul_12 = {12{pulse}};             // Pulse (fanned out)

wire [11:0] and_st  = saw_12 & tri_12;
wire [11:0] and_pt  = pul_12 & tri_12;
wire [11:0] and_ps  = pul_12 & saw_12;
wire [11:0] and_pst = pul_12 & saw_12 & tri_12;

reg  [11:0] norm;
reg   [7:0] comb;

always @(*) begin
	// Single waveform selection
	case (control[7:4])
		4'b0001: norm = tri_12;     // Triangle only
		4'b0010: norm = saw_12;     // Sawtooth only
		4'b0100: norm = pul_12;     // Pulse only
		4'b1000: norm = noise;      // Noise only
		default: norm = 0;
	endcase

	// Combined waveform selection — pure AND combinatorial logic
	// Bob: "Combining waveforms results in a logical AND of their bits"
	// The 8-bit comb output = upper 8 bits of the ANDed 12-bit waveforms.
	case (control[7:4])
		4'b0011: comb = and_st[11:4];
		4'b0101: comb = and_pt[11:4];
		4'b0110: comb = and_ps[11:4];
		4'b0111: comb = and_pst[11:4];
		default: comb = 0;
	endcase
end

// ============================================================================
// WAVEFORM DAC — Non-linear R-2R emulation for MOS6581
// ============================================================================
// Bob Yannes:
//   The waveform DAC converts the 12-bit digital waveform to analog.
//   On the MOS6581, the DAC has a non-linear response due to missing
//   termination resistor and imperfect R/2R matching (see sid_dac.v).
//   On the MOS8580, the DAC is linear.
// ============================================================================

wire [11:0] norm_6581;

sid_dac #( .BITS(12) ) waveform_dac
(
	.vin  (norm),
	.vout (norm_6581)
);

reg [11:0] norm_dac;
always @(posedge clock) norm_dac <= mode ? norm : norm_6581;

// Envelope DAC for MOS6581 (non-linear)
wire [7:0] env_6581;

sid_dac #( .BITS(8) ) envelope_dac
(
	.vin  (envelope),
	.vout (env_6581)
);

// ============================================================================
// OSC3 readback (Voice 3 oscillator value for modulation registers)
// ============================================================================
// Bob Yannes:
//   "They give the microprocessor access to the upper 8 bits of the
//    instantaneous waveform and envelope values of Voice 3."
//
// The upper 8 bits of the 12-bit waveform output are combined with any
// combined waveform bits for CPU readback via the OSC3 register.
// ============================================================================
reg [7:0] wave_out;
always @(posedge clock) if (ce_1m) wave_out <= norm[11:4] | comb;

// ============================================================================
// DCA — Digitally-Controlled Amplifier
// ============================================================================
// Bob Yannes:
//   "The Waveform D/A output (an analog voltage) feeds the reference input
//    of an 8-bit multiplying D/A, creating a DCA (digitally-controlled
//    amplifier). The digital control word that modulates the waveform's
//    amplitude comes from the Envelope Generator."
//
//   "The 8-bit Envelope Generator output drives the Multiplying D/A to
//    modulate the selected Oscillator waveform's amplitude. Technically
//    the waveform is modulating the envelope output, but the result is
//    the same."
//
// Implementation: dca_out = (waveform_dac - DC_offset) * envelope_dac + voice_DC
// The multiplication implements the multiplying D/A that Bob describes.
// ============================================================================

reg signed [21:0] dca_out;

// Internal registers at module level for Verilog-2001
reg        [23:0] keep_cnt;
reg signed  [8:0] env_dac;
reg signed [12:0] dac_out;

always @(posedge clock) begin
	if (ce_1m) begin
		if (control[7:4]) begin
			// Active waveform: load TTL counter and compute DAC output
			keep_cnt <= mode ? WF_0_TTL_8580 : WF_0_TTL_6581;
			dac_out  <= {1'b0, norm_dac | {comb, 4'b0}} -
			            (mode ? WAVEFORM_DC_8580 : WAVEFORM_DC_6581);
		end
		else if (keep_cnt)
			// No waveform selected: input floats, decays slowly
			keep_cnt <= keep_cnt - 1'd1;
		else
			// Float expired: output decays to zero
			dac_out <= 0;

		// Select envelope DAC (non-linear for 6581, linear for 8580)
		env_dac <= mode ? envelope : env_6581;

		// DCA = waveform * envelope + voice DC offset
		dca_out <= (mode ? VOICE_DC_8580 : VOICE_DC_6581) + (dac_out * env_dac);
	end
end

// ============================================================================
// DIGI-SAMPLE TRICK
// ============================================================================
// Bob Yannes:
//   "By stopping an Oscillator, a DC voltage can be applied to this D/A.
//    Audio can then be created by writing the Final Volume register in
//    real time from the CPU. This is the technique used by games to
//    synthesize speech or play 'sampled' sounds."
//
// When the oscillator is stopped (test bit set or frequency = 0) and a
// waveform is selected, the DAC holds a steady DC voltage. The CPU can
// then write the volume register rapidly to produce arbitrary audio —
// effectively using the SID as a crude PCM playback device.
// This technique is entirely accidental but became iconic in C64 games.
// ============================================================================

endmodule
