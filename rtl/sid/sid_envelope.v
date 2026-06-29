// ----------------------------------------------------------------------------
// SID Envelope Generator — ADSR
//
// Based on the MOS 6581/8580 SID chip designed by Bob Yannes.
// Converted from SystemVerilog to Verilog-2001 for maximum FPGA portability.
//
// Reference: Interview with Bob Yannes, SID Chip Inventor (Andreas Varga, 1996)
// Source: interview.md in this repository.
// ----------------------------------------------------------------------------

module sid_envelope
(
	input            clock,
	input            ce_1m,

	input            reset,
	input            gate,
	input     [ 7:0] att_dec,
	input     [ 7:0] sus_rel,

	output reg [7:0] envelope
);

// ----------------------------------------------------------------------------
// Envelope States
//
// Bob Yannes describes the envelope as:
//   "An 8-bit up/down counter, triggered by the Gate bit:
//    - Counts 0 -> 255 at the Attack rate.
//    - Counts 255 -> Sustain value at the Decay rate.
//    - Holds at the Sustain value until Gate is cleared.
//    - Counts Sustain value -> 0 at the Release rate."
// ----------------------------------------------------------------------------
localparam ST_RELEASE  = 0;
localparam ST_ATTACK   = 1;
localparam ST_DEC_SUS  = 2;

reg  [1:0] state;

// ----------------------------------------------------------------------------
// Rate look-up table
//
// Bob Yannes:
//   "A programmable frequency divider sets the rates. I didn't recall whether
//    it was 12 or 16 bits. A small look-up table translates the 16
//    register-programmable rate values into the appropriate divider load value.
//    The state (A, D, or R) selects which register is used.
//    Individual bit control of the divider would have given better resolution,
//    but he didn't have enough silicon area for that many register bits.
//    Cramming a wide range of rates into 4 bits allowed the ADSR to be defined
//    in two bytes instead of eight."
//
//   "The actual numbers in the look-up table were arrived at subjectively:
//    he set up typical patches on a Sequential Circuits Pro-1 and measured the
//    envelope times by ear — which is why the available rates seem strange."
//
// 16 rates, one per 4-bit value. The divider period is calculated as:
//   rate_period = time_seconds * 1MHz / 256
// These values reproduce Bob's subjective measurements from the Pro-1.
// ----------------------------------------------------------------------------
reg [14:0] rates [0:15];

initial begin
	rates[ 0] = 8;       //   2ms * 1.0MHz / 256 =     7.81
	rates[ 1] = 31;      //   8ms * 1.0MHz / 256 =    31.25
	rates[ 2] = 62;      //  16ms * 1.0MHz / 256 =    62.50
	rates[ 3] = 94;      //  24ms * 1.0MHz / 256 =    93.75
	rates[ 4] = 148;     //  38ms * 1.0MHz / 256 =   148.44
	rates[ 5] = 219;     //  56ms * 1.0MHz / 256 =   218.75
	rates[ 6] = 266;     //  68ms * 1.0MHz / 256 =   265.63
	rates[ 7] = 312;     //  80ms * 1.0MHz / 256 =   312.50
	rates[ 8] = 391;     // 100ms * 1.0MHz / 256 =   390.63
	rates[ 9] = 976;     // 250ms * 1.0MHz / 256 =   976.56
	rates[10] = 1953;    // 500ms * 1.0MHz / 256 =  1953.13
	rates[11] = 3125;    // 800ms * 1.0MHz / 256 =  3125.00
	rates[12] = 3906;    //   1s * 1.0MHz / 256 =  3906.25
	rates[13] = 11719;   //   3s * 1.0MHz / 256 = 11718.75
	rates[14] = 19531;   //   5s * 1.0MHz / 256 = 19531.25
	rates[15] = 31250;   //   8s * 1.0MHz / 256 = 31250.00
end

wire [14:0] rate_period = rates[(state == ST_ATTACK) ? att_dec[7:4] :
                                (state == ST_DEC_SUS)  ? att_dec[3:0] :
                                                         sus_rel[3:0]];

// ----------------------------------------------------------------------------
// Internal registers (declared at module level for Verilog-2001 compatibility)
// ----------------------------------------------------------------------------
reg        hold_zero;
reg  [4:0] exponential_counter_period;
reg        gate_edge;
reg [14:0] rate_counter;
reg  [4:0] exponential_counter;

// ----------------------------------------------------------------------------
// Exponential decay approximation
//
// Bob Yannes:
//   "Another look-up table on the Envelope Generator output divides the clock
//    by two at specific counts during Decay and Release. This produces a
//    piece-wise linear approximation of an exponential decay. Yannes was
//    particularly happy with how well this worked given the simplicity of the
//    circuitry. The Attack is linear, but it sounded fine."
//
// The exponential counter period determines how many rate ticks must elapse
// before the envelope counter advances by one step during Decay and Release.
// At specific envelope values, the period doubles, creating the piece-wise
// linear approximation of an exponential curve.
//
// Note: At envelope = 0xFF (top), period = 0 (no extra delay during attack).
// At envelope = 0x00, period = 0 (freeze at zero via hold_zero).
// ----------------------------------------------------------------------------

// ----------------------------------------------------------------------------
// Main envelope state machine
// ----------------------------------------------------------------------------
always @(posedge clock) begin
	if (reset) begin
		state <= ST_RELEASE;
		gate_edge <= gate;
		envelope  <= 0;
		hold_zero <= 1;
		exponential_counter <= 0;
		exponential_counter_period <= 0;
		rate_counter <= 0;
	end
	else if (ce_1m) begin

		// Rate counter: counts up to rate_period, then resets.
		// This is the programmable frequency divider Bob describes.
		rate_counter <= rate_counter + 1'd1;
		if (rate_counter == rate_period) begin
			rate_counter <= 0;

			// Exponential counter: during Decay/Release, the envelope only
			// advances when this counter reaches its period value.
			// During Attack, the exponential counter is bypassed (linear ramp).
			exponential_counter <= exponential_counter + 1'b1;
			if (state == ST_ATTACK || exponential_counter == exponential_counter_period) begin
				exponential_counter <= 0;

				case (state)
					// Attack: linear ramp from 0 to 254 (then transitions to Decay).
					// Bob: "The Attack is linear, but it sounded fine."
					ST_ATTACK: begin
						envelope <= envelope + 1'b1;
						if (envelope == 8'hfe) state <= ST_DEC_SUS;
					end

					// Decay/Sustain: count down from 255 toward sustain level.
					// Bob: "Counts 255 -> Sustain value at the Decay rate."
					// The sustain comparison uses the upper 4 bits (see below).
					ST_DEC_SUS: begin
						if (envelope != {2{sus_rel[7:4]}} && !hold_zero) begin
							envelope <= envelope - 1'b1;
						end
					end

					// Release: count down from current level to 0.
					// Bob: "Counts Sustain value -> 0 at the Release rate."
					ST_RELEASE: begin
						if (!hold_zero) envelope <= envelope - 1'b1;
					end
				endcase

				// Freeze at zero to prevent underflow.
				if (state != ST_ATTACK && envelope == 1) hold_zero <= 1;
			end
		end

		// Gate edge detection: rising edge triggers Attack, falling edge triggers Release.
		gate_edge <= gate;
		if (~gate_edge & gate) begin
			state <= ST_ATTACK;
			hold_zero <= 0;
		end
		if (gate_edge & ~gate) state <= ST_RELEASE;

		// Exponential counter period: registered lookup from envelope.
		// Updates period when envelope crosses a threshold value.
		case (envelope)
			8'hff: exponential_counter_period <= 0;
			8'h5d: exponential_counter_period <= 1;
			8'h36: exponential_counter_period <= 3;
			8'h1a: exponential_counter_period <= 7;
			8'h0e: exponential_counter_period <= 15;
			8'h06: exponential_counter_period <= 29;
			8'h00: exponential_counter_period <= 0;
			default: ;
		endcase
	end
end

// ----------------------------------------------------------------------------
// Sustain level explanation
//
// Bob Yannes:
//   "A digital comparator is used for Sustain. The upper four bits of the
//    up/down counter are compared to the programmed Sustain value, stopping
//    the Envelope Generator clock when the counter reaches Sustain.
//    This produces 16 linearly-spaced sustain levels without needing a
//    look-up table between the 4-bit register and the 8-bit envelope output.
//    Sustain levels are therefore adjustable in steps of 16."
//
// Implementation: envelope != {2{sus_rel[7:4]}}
//   This replicates the 4-bit sustain value into an 8-bit value (steps of 16),
//   then compares against the full 8-bit envelope counter.
//
// Sustain quirks:
//   "Like an analog envelope generator, SID's tracks the Sustain level if
//    it's lowered during the Sustain phase. However, it does NOT count UP
//    if Sustain is set to a higher value."
//   - This is naturally handled: the counter only decrements, never increments
//     during DEC_SUS state.
// ----------------------------------------------------------------------------

endmodule
