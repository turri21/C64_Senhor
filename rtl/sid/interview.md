# Interview with Bob Yannes — SID Chip Inventor

> **Source:** AusRetroGamer — *Interview with Bob Yannes, SID Chip Inventor*
> **Original interview:** Andreas Varga, August 1996
> **Note:** The original interview was lost from the internet and recovered via the Internet Archive Wayback Machine. Republished by AusRetroGamer.

---

## About

An interview with **Robert (Bob) Yannes**, the designer of the MOS 6581 SID (Sound Interface Device) chip used in the Commodore 64. Conducted by **Andreas Varga** in August 1996.

Bob Yannes was an electronic music hobbyist before joining MOS Technology (a Commodore chip division). He designed both the SID chip and the Commodore 64 itself.

---

## Background and motivation

**AV: Did you foresee that people would actually treat your little VLSI-chip like an instrument?**

**BY:** Yannes was an electronic music hobbyist before joining MOS Technology, and one of the reasons he was hired was that his knowledge of music synthesis was considered valuable for future MOS/Commodore products. When he designed the SID chip, he was attempting to create a single-chip synthesizer voice that he hoped would find its way into polyphonic/polytimbral synthesizers.

**AV: Are you aware of the existence of programs like SIDPLAY, PlaySID, etc., which emulate the SID chip up to the smallest click?**

**BY:** He had only recently become aware of them (via Varga's website). He hadn't thought much about SID in the previous 15 years and expressed amazement at how many people had been positively affected by the SID chip and the Commodore 64, and continued to do productive things with them despite their "obsolescence".

**AV: Have you heard the tunes by Rob Hubbard, Martin Galway, Tim Follin, Jeroen Tel, and the other composers?**

**BY:** No, and he asked whether recordings were available in the US.

**AV: Did you believe this was possible to do with your chip?**

**BY:** Since he hadn't heard them he wasn't sure what was being referred to, but he did design SID with enough resolution to produce high-quality music. He was never able to refine the signal-to-noise ratio to the level he wanted.

---

## Influence on Ensoniq and the synth industry

**AV: How much of the architecture in the SID inspired you when working with the Ensoniq synthesizers?**

**BY:** The SID chip was his first attempt at a phase-accumulating oscillator, the heart of all wavetable synthesis systems. Due to time constraints, the oscillators in SID were not multiplexed and therefore took up a lot of chip area, constraining the number of voices that could fit on a chip. All ENSONIQ sound chips use a multiplexed oscillator allowing at least 32 voices per chip. Aside from that, little else of SID is found in Ensoniq designs, which more closely resemble the Mountain Computer sound card for the Apple II (the basis of the Alpha Syntauri system). The DOC I chip (used in the Mirage and ESQ-1) was modeled on this sound card. Ensoniq's later designs — featuring waveform interpolation, digital filters and digital effects — were new designs not really based on anything other than imagination.

**AV: How big an impact do you think the SID had on the synthesizer industry?**

**BY:** Not much. He recalls Sequential Circuits being interested in buying the chip, but nothing came of it. His intention had been to sell the SID chip to synthesizer manufacturers (MOS Technology was a merchant semiconductor house at the time). SID production was completely consumed by the Commodore 64, and by the time chips were readily available he had left Commodore and never had the opportunity to improve the chip's fidelity.

**AV: What would you have changed in the SID's design with a bigger budget from Commodore?**

**BY:** The issue wasn't budget — it was development time and chip-size constraints. The schedule for SID, the VIC II and the C64 was incredibly tight. With more time, he would have:

- Developed a proper MOS op-amp, eliminating the signal leakage that occurred when a voice's volume was supposed to be zero (this caused poor SNR and could only be worked around by stopping the oscillator).
- Greatly improved the filter, particularly in achieving high resonance.
- Added an exponential look-up table for direct translation to the equal-tempered scale (skipped because it took too much silicon and was easy to do in software).

**AV: The SID is very complex for its time. Why didn't you settle with an easier design?**

**BY:** He thought the sound chips on the market — including those in the Atari computers — were primitive and obviously designed by people who knew nothing about music. He was attempting to create a synthesizer chip usable in professional synthesizers.

**AV: Do you still own a C64 (or another SID-equipped computer)?**

**BY:** Yes, several including the portable, but he hadn't turned them on in years.

**AV: Did Commodore ever plan to build an improved successor to the SID?**

**BY:** He didn't know. After he left, he didn't think anyone there knew enough about music synthesis to do more than improve the yield of the SID chip. He would have liked to improve SID before production release, but doubts it would have made any difference to the success of the C64.

---

## Internal architecture overview

**AV: Can you give us a short overview of the SID internal architecture?**

> Yannes describes the design as "pretty brute-force" — he didn't have time to be elegant.

Each **voice** consists of:

- An **Oscillator**
- A **Waveform Generator**
- A **Waveform Selector**
- A **Waveform D/A converter**
- A **Multiplying D/A converter** for amplitude control
- An **Envelope Generator** for modulation

The analog output of each voice can be sent through a **Multimode Analog Filter** or bypass it. A final **Multiplying D/A converter** provides overall manual volume control.

---

### Oscillator

- **24-bit phase-accumulating** design.
- The **lower 16 bits** are programmable for pitch control.
- The accumulator output goes directly to a D/A converter through a waveform selector.
- Normally a phase-accumulating oscillator's output would index a wavetable in memory, but SID had to be entirely self-contained — there was no room on the chip for a wavetable.

---

### Waveform generation

#### Sawtooth

Created by sending the **upper 12 bits** of the accumulator to the 12-bit Waveform D/A.

#### Triangle

- Uses the **MSB of the accumulator** to invert the remaining upper 11 accumulator bits via EXOR gates.
- These 11 bits are then **left-shifted** (discarding the MSB) and sent to the Waveform D/A.
- Resolution of triangle is **half** that of sawtooth, but amplitude and frequency are the same.

#### Pulse

- The upper 12 bits of the accumulator are sent to a **12-bit digital comparator**.
- The comparator outputs a single bit (1 or 0).
- That single output is fanned out to all 12 bits of the Waveform D/A.

#### Noise

- Generated by a **23-bit pseudo-random sequence generator** (a shift register with specific outputs fed back through combinatorial logic).
- The shift register is **clocked by one of the intermediate bits of the accumulator** to keep the noise's frequency content roughly aligned with the pitched waveforms.
- The **upper 12 bits** of the shift register are sent to the Waveform D/A.

#### Waveform selection / mixing

- All waveforms are digital bits, so the Waveform Selector consists of multiplexers selecting which waveform bits go to the Waveform D/A.
- The multiplexers are **single transistors** and don't provide a "lock-out" — combinations of waveforms can be selected.
- Combining waveforms results in a **logical AND** of their bits, producing unpredictable results.
- Yannes did not encourage this, especially because it could **lock up the pseudo-random sequence generator by filling it with zeroes**.

---

### Amplitude control (DCA)

- The Waveform D/A output (an analog voltage) feeds the **reference input of an 8-bit multiplying D/A**, creating a **DCA** (digitally-controlled amplifier).
- The digital control word that modulates the waveform's amplitude comes from the Envelope Generator.

---

### Envelope generator

- An **8-bit up/down counter**, triggered by the **Gate bit**:
  - Counts **0 → 255** at the Attack rate.
  - Counts **255 → Sustain value** at the Decay rate.
  - Holds at the Sustain value until Gate is cleared.
  - Counts **Sustain value → 0** at the Release rate.

- A **programmable frequency divider** sets the rates. Yannes didn't recall whether it was 12 or 16 bits.
- A small **look-up table** translates the 16 register-programmable rate values into the appropriate divider load value. The state (A, D, or R) selects which register is used.
- Individual bit control of the divider would have given better resolution, but he didn't have enough silicon area for that many register bits.
- Cramming a wide range of rates into 4 bits allowed the **ADSR to be defined in two bytes instead of eight**.
- The actual numbers in the look-up table were arrived at **subjectively**: he set up typical patches on a **Sequential Circuits Pro-1** and measured the envelope times **by ear** — which is why the available rates seem strange.

#### Exponential decay approximation

- Another look-up table on the Envelope Generator output **divides the clock by two at specific counts** during Decay and Release.
- This produces a **piece-wise linear approximation of an exponential** decay.
- Yannes was particularly happy with how well this worked given the simplicity of the circuitry.
- The **Attack is linear**, but it sounded fine.

#### Sustain comparator

- A **digital comparator** is used for Sustain.
- The **upper four bits** of the up/down counter are compared to the programmed Sustain value, stopping the Envelope Generator clock when the counter reaches Sustain.
- This produces **16 linearly-spaced sustain levels** without needing a look-up table between the 4-bit register and the 8-bit envelope output.
- Sustain levels are therefore adjustable in **steps of 16**.

#### Behaviour at Gate clear and Sustain change

- When Gate is cleared, the clock is re-enabled and the counter counts down to zero.
- Like an analog envelope generator, SID's tracks the Sustain level if it's lowered during the Sustain phase.
- However, it does **not count UP** if Sustain is set to a higher value.

#### Output mixing

- The **8-bit Envelope Generator output** drives the Multiplying D/A to modulate the selected Oscillator waveform's amplitude.
- Technically the waveform is modulating the envelope output, but the result is the same.

---

### Hard Sync

Implemented by **clearing the accumulator of an Oscillator** based on the accumulator MSB of the previous oscillator.

### Ring Modulation

Implemented by **substituting the previous oscillator's accumulator MSB** into the EXOR function of the triangle waveform generator (replacing the current oscillator's MSB).

> This is why the **triangle waveform must be selected to use Ring Modulation**.

---

### Filter

- Classic **multi-mode (state-variable) VCF** design.
- No variable transconductance amplifier was possible in MOS's NMOS process, so **FETs are used as voltage-controlled resistors** to set the cutoff frequency.
- An **11-bit D/A converter** generates the FET control voltage. (It's actually a 12-bit D/A, but the LSB had no audible effect so it was disconnected.)
- **Resonance** is controlled by a **4-bit weighted resistor ladder**: each bit switches in one of the weighted resistors, feeding a portion of the output back to the input.
- The state-variable topology provides simultaneous **low-pass, band-pass and high-pass** outputs.
- **Analog switches** select which combination of outputs goes to the final amplifier.
  - A **notch** is created by enabling both high-pass and low-pass simultaneously.

#### Why the filter is the worst part of SID

- Yannes states bluntly that the filter is the **worst part of SID**.
- He could not create high-gain op-amps in NMOS, which were essential to a resonant filter.
- The **FET resistance varied considerably with processing**, so different lots of SID chips had different cutoff frequency characteristics.
- He knew it wouldn't work very well, but it was better than nothing — he didn't have time to make it better.

---

### Final amplifier and routing

- Analog switches route each Oscillator either through or around the filter to the final amplifier.
- The final amp is a **4-bit multiplying D/A converter** providing master volume control.
- By **stopping an Oscillator**, a DC voltage can be applied to this D/A. Audio can then be created by writing the **Final Volume register** in real time from the CPU.
  - This is the technique used by games to synthesize speech or play "sampled" sounds.
- An **external audio input** can also be mixed in at the final amp or processed through the filter.

---

### Modulation registers

- Probably **never used**, since they could easily be simulated in software without giving up a voice.
- For novice programmers they offered a way to create vibrato or filter sweeps without much code: read the value from the modulation register and write it back to the frequency register.
- They give the microprocessor access to the **upper 8 bits of the instantaneous waveform and envelope values of Voice 3**.
- An **analog switch** disables the audio output of Voice 3 so that the modulation source isn't heard in the output mix.

---

## Anecdotes

**AV: Any other interesting tidbits or anecdotes?**

**BY:** The funniest thing he remembered was a batch of C64 video games written in Japan. The developers were so obsessed with technical specs that they wrote their code strictly to a SID spec sheet that Yannes himself had written **before any SID prototypes existed**. The specs were not accurate. Rather than correct the obvious errors in their code, the developers shipped games with out-of-tune sounds and filter settings that produced only quiet, muffled output. As far as they were concerned, the code was correct according to the spec — and that was all that mattered.

---

## Quick reference summary (for implementation)

A condensed cheat-sheet pulling together the implementation-critical details from the interview:

| Block | Key facts |
|-------|-----------|
| **Oscillator** | 24-bit phase accumulator; lower 16 bits programmable for pitch |
| **Sawtooth** | Upper 12 bits of accumulator → Waveform D/A |
| **Triangle** | MSB inverts upper 11 bits via EXOR, then left-shift, → D/A. Half the resolution of saw |
| **Pulse** | Upper 12 bits of accumulator → 12-bit comparator → fanned to all 12 D/A bits |
| **Noise** | 23-bit LFSR clocked by an intermediate accumulator bit; upper 12 bits → D/A |
| **Waveform mixing** | Single-transistor muxes; combinations produce a logical AND of bits; can lock up the LFSR by filling it with zeroes |
| **DCA** | Waveform D/A → ref input of 8-bit multiplying D/A; envelope provides control word |
| **Envelope** | 8-bit up/down counter; rate divider (12 or 16 bits) loaded via 16-entry LUT per state |
| **ADSR encoding** | 4-bit fields → 2 bytes total; rate values tuned by ear vs. a Sequential Pro-1 |
| **Exp decay** | LUT halves the envelope clock at specific counts during D and R; Attack is linear |
| **Sustain** | Upper 4 bits of counter compared to 4-bit Sustain register; 16 linearly-spaced steps of 16 |
| **Sustain quirks** | Tracks downward changes; does **not** count up if Sustain is raised |
| **Hard Sync** | Clears destination accumulator on previous oscillator's MSB |
| **Ring Mod** | Previous oscillator's MSB substituted into triangle EXOR — requires triangle selected |
| **Filter** | State-variable multimode; FETs as VCRs for cutoff; 11 effective bits of cutoff D/A (12 with LSB disconnected); 4-bit weighted-R ladder for resonance; LP/BP/HP simultaneous outputs; notch = LP+HP |
| **Filter caveats** | NMOS prevented high-gain op-amps; FET R varies per lot → chip-to-chip cutoff variation |
| **Final amp** | 4-bit multiplying D/A; writing the volume register with stopped oscillators is the "digi" / sampled-sound trick |
| **External in** | Mixable at final amp or routable through the filter |
| **Mod registers** | Upper 8 bits of Voice 3 waveform & envelope exposed to CPU; analog switch can mute Voice 3 output |

---

*End of interview.*
