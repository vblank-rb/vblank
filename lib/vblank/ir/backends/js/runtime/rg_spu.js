/*
 * THE PLAYSTATION'S SOUND CHIP, for a game built as a console whose voices read loops out of sound
 * memory (RG_VOICES_READ_SOUND_MEMORY). A port of the native runtime's rg_spu.c, function for function;
 * that file says how the chip plays the game's four voices, what Beetle PSX and psx-spx each rule comes
 * from, and the layout of rg_game_spu_rules, rg_game_spu_loops and rg_game_spu_memory, which this one
 * reads the same way. It is joined into the script after rg_sound.js and reads that file's voices.
 *
 * Every number here is a whole number the C keeps in 32 bits, and every product of two fits in one
 * (a sample of 16 bits times a weight or a volume of 15), so JavaScript's shifts, which work in 32
 * bits, give the C's answers.
 */

const SPU_GAME_VOICES = 4, SPU_RECORDING_VOICES = 16;
const SPU_VOICES = SPU_GAME_VOICES + SPU_RECORDING_VOICES;
const SPU_RING = 32;
const SPU_DECODE_WHEN = 11;
const SPU_PLAY_DELAY = 4;
const ENVELOPE_RELEASE = 0, ENVELOPE_ATTACK = 1, ENVELOPE_DECAY = 2, ENVELOPE_SUSTAIN = 3;
const SPU_HISS_AT = 4, SPU_RATTLE_AT = 5, SPU_WAVEFORMS_AT = 6;
const SPU_SLIDE_FRAMES_MOST = 1 << 20;
const BLOCK_LOOP_END = 1, BLOCK_LOOP_REPEAT = 2, BLOCK_LOOP_START = 4;
const SPU_GAUSS_AT = 12;

function SPU_HZ() { return rg_game_spu_rules[0]; }
function SPU_ADSR_LOW() { return rg_game_spu_rules[1]; }
function SPU_ADSR_HIGH() { return rg_game_spu_rules[2]; }
function SPU_LOUDEST() { return rg_game_spu_rules[3]; }
function SPU_MAIN_VOLUME() { return rg_game_spu_rules[4]; }
function SPU_PITCH_ONE() { return rg_game_spu_rules[5]; }
function SPU_PITCH_TOP() { return rg_game_spu_rules[6]; }
function SPU_SQUARE_SAMPLES() { return rg_game_spu_rules[7]; }
function SPU_WAVE_SAMPLES() { return rg_game_spu_rules[8]; }
function SPU_MEMORY_BASE() { return rg_game_spu_rules[9]; }
function SPU_MIX_FULL() { return rg_game_spu_rules[10]; }
function SPU_SHAPE_SCALE() { return rg_game_spu_rules[11]; }

function silent_spu_voice() {
  return { start: 0, loop: 0, loop_held: 0, pitch: 0, volume: [0, 0], heard: [0, 0], address: 0, flags: 0, shift: 0, filter: 0,
           older: 0, newer: 0, ring: new Int32Array(SPU_RING), write_at: 0, read_at: 0, decoded: 0, delay: 0, phase: 0,
           level: 0, divider: 0, stage: ENVELOPE_RELEASE, keyed: 0, loop_start: 0 };
}

const spu = Array.from({ length: SPU_VOICES }, silent_spu_voice);
let spu_struck = 0, spu_struck_by_game = 0, spu_struck_waiting = 0, spu_set_by_game = 0;
let spu_stopped_by_game = 0;
let spu_keys_on = 0, spu_keys_off = 0, spu_carry = 0, spu_waveform = 0;
const spu_out = [0, 0];
const spu_slide_frame = [0, 0];

function spu_slide_started(voice) { spu_slide_frame[voice - 1] = 0; }
function voice_struck(voice) { spu_struck |= 1 << (voice - 1); }
function game_voice_struck(voice) {
  spu_struck_by_game |= 1 << (voice - 1);
  spu_set_by_game |= 1 << (voice - 1);
}
function spu_waveform_put_in(which) { spu_waveform = which; }
function spu_recording_struck(place, by_game) {
  if (by_game) spu_struck_by_game |= 1 << (SPU_GAME_VOICES + place);
  else spu_struck |= 1 << (SPU_GAME_VOICES + place);
}
function spu_recording_stopped_by_game(place) { spu_stopped_by_game |= 1 << (SPU_GAME_VOICES + place); }

function spu_memory_at(address) {
  const at = address - SPU_MEMORY_BASE();
  return at >= 0 && at < rg_game_spu_memory[0] ? rg_game_spu_memory[1 + at] : 0;
}

/* A wave read from the start file, written into its loop of sound memory (rg_spu.c says each step). */
const SPU_WAVE_LOOP_BLOCKS = 8, SPU_BLOCK_SAMPLES = 28, SPU_BLOCK_HALFWORDS = 8;

function rg_spu_fill_wave(memory, waveforms, which) {
  const steps = 1 + which * SPU_WAVE_SAMPLES();
  const loop = 1 + rg_game_spu_loops[SPU_WAVEFORMS_AT + 1 + which] * 4 - SPU_MEMORY_BASE();
  for (let block = 0; block < SPU_WAVE_LOOP_BLOCKS; block++) {
    const header = loop + block * SPU_BLOCK_HALFWORDS;
    memory[header] &= 0xff00;
    for (let half = 1; half < SPU_BLOCK_HALFWORDS; half++) {
      let coded = 0;
      for (let i = 0; i < 4; i++) {
        const sample = block * SPU_BLOCK_SAMPLES + (half - 1) * 4 + i;
        coded |= ((waveforms[steps + (sample % SPU_WAVE_SAMPLES())] - 8) & 0xf) << (4 * i);
      }
      memory[header + half] = coded;
    }
  }
}

/* --- the encoder (rg_spu.c's, PS1::ADPCM.encode), for a recording laid out as the game starts --- */

const SPU_ENCODE_WEIGHTS = [[0, 0], [60, 0], [115, -52], [98, -55], [122, -60]];
const SPU_LARGEST_SHIFT = 12, SPU_MOST_LOOP_SAMPLES = 0x10000;

/* rg_spu.c's spu_try_block: [error, nibbles, older, newer]. */
function spu_try_block(samples, at, filter, shift, older, newer) {
  const [first, second] = SPU_ENCODE_WEIGHTS[filter];
  let error = 0;
  const nibbles = new Array(SPU_BLOCK_SAMPLES);
  for (let i = 0; i < SPU_BLOCK_SAMPLES; i++) {
    const predicted = ((older * second) >> 6) + ((newer * first) >> 6);
    const scaled = (samples[at + i] - predicted) * 2 ** shift;
    let nibble = scaled < 0 ? -Math.floor((-scaled + 2048) / 4096) : Math.floor((scaled + 2048) / 4096);
    nibble = Math.min(Math.max(nibble, -8), 7);
    const decoded = Math.min(Math.max(((nibble * 4096) >> shift) + predicted, -0x8000), 0x7fff);
    error += (decoded - samples[at + i]) ** 2;
    older = newer;
    newer = decoded;
    nibbles[i] = nibble;
  }
  return [error, nibbles, older, newer];
}

/* rg_spu.c's spu_encode */
function spu_encode(samples, loop_block, memory, halves) {
  let older = 0, newer = 0;
  const blocks = samples.length / SPU_BLOCK_SAMPLES;
  for (let b = 0; b < blocks; b++) {
    const flags = (b === loop_block ? 4 : 0) | (b === blocks - 1 ? 3 : 0);
    const filters = b === 0 || b === loop_block ? 1 : SPU_ENCODE_WEIGHTS.length;
    let best = null, best_filter = 0, best_shift = 0;
    for (let filter = 0; filter < filters && !(best && best[0] === 0); filter++) {
      for (let shift = 0; shift <= SPU_LARGEST_SHIFT && !(best && best[0] === 0); shift++) {
        const tried = spu_try_block(samples, b * SPU_BLOCK_SAMPLES, filter, shift, older, newer);
        if (best === null || tried[0] < best[0]) {
          best = tried;
          best_filter = filter;
          best_shift = shift;
        }
      }
    }
    older = best[2];
    newer = best[3];
    const at = halves + b * SPU_BLOCK_HALFWORDS;
    memory[at] = (best_shift | (best_filter << 4)) | (flags << 8);
    for (let half = 1; half < SPU_BLOCK_HALFWORDS; half++) {
      let coded = 0;
      for (let i = 0; i < 4; i++) coded |= (best[1][(half - 1) * 4 + i] & 0xf) << (4 * i);
      memory[at + half] = coded;
    }
  }
}

function spu_gcd(a, b) { return b === 0 ? a : spu_gcd(b, a % b); }

/* A recording whose hold is read from the start file, laid out and encoded into its loop (rg_sound.h,
 * rg_spu_fill_held_recording). */
function rg_spu_fill_held_recording(memory, recordings, recording_samples, rules) {
  const [number, start, length, room] = rules;
  const back = Math.min(Math.max(recordings[1 + number * 3 + 1], 1), length);
  const from = length - back;
  const aligned = Math.ceil(from / SPU_BLOCK_SAMPLES) * SPU_BLOCK_SAMPLES;
  const times = SPU_BLOCK_SAMPLES / spu_gcd(back, SPU_BLOCK_SAMPLES);
  const body = back * times <= SPU_MOST_LOOP_SAMPLES ? back * times : back + ((SPU_BLOCK_SAMPLES - (back % SPU_BLOCK_SAMPLES)) % SPU_BLOCK_SAMPLES);
  const count = aligned + body;
  const laid = new Int32Array(Math.ceil(count / SPU_BLOCK_SAMPLES) * SPU_BLOCK_SAMPLES);
  const turn = (aligned - from) % back;
  for (let i = 0; i < count; i++) {
    const held = i < from ? i : i < aligned ? from + ((i - from) % back) : from + (((i - aligned) % back + turn) % back);
    laid[i] = recording_samples[start + held] * 256;
  }
  spu_encode(laid, aligned / SPU_BLOCK_SAMPLES, memory, 1 + room * 4 - SPU_MEMORY_BASE());
}

/* --- the decoder --- */

const filter_weights = [[0, 0], [60, 0], [115, -52], [98, -55], [122, -60], [0, 0], [0, 0], [0, 0],
                        [0, 0], [0, 0], [0, 0], [0, 0], [0, 0], [0, 0], [0, 0], [0, 0]];

function held_to_16_bits(sample) { return sample < -32768 ? -32768 : sample > 32767 ? 32767 : sample; }

function spu_decode(voice) {
  if (voice.decoded >= SPU_DECODE_WHEN) return;

  if ((voice.address & 7) === 0) {
    if (voice.flags & BLOCK_LOOP_END) {
      voice.address = voice.loop & ~7;
      if (!(voice.flags & BLOCK_LOOP_REPEAT)) {
        voice.stage = ENVELOPE_RELEASE;
        voice.level = 0;
      }
    }
    const header = spu_memory_at(voice.address);
    voice.shift = header & 0xF;
    voice.filter = (header >> 4) & 0xF;
    voice.flags = (header >> 8) & 0xFF;
    if ((voice.flags & BLOCK_LOOP_START) && !voice.loop_held) voice.loop = voice.address;
    voice.address = (voice.address + 1) & 0x3FFFF;
  }

  let coded = spu_memory_at(voice.address), shift = voice.shift;
  if (shift > 12) {
    shift = 8;
    coded &= 0x8888;
  }
  const weights = filter_weights[voice.filter];
  for (let i = 0; i < 4; i++) {
    const nibble = (coded >> (4 * i)) & 0xF;
    let sample = ((nibble >= 8 ? nibble - 16 : nibble) * 4096) >> shift;
    sample += (voice.older * weights[1]) >> 6;
    sample += (voice.newer * weights[0]) >> 6;
    sample = held_to_16_bits(sample);
    voice.ring[(voice.write_at + i) & (SPU_RING - 1)] = sample;
    voice.older = voice.newer;
    voice.newer = sample;
  }
  voice.write_at = (voice.write_at + 4) & (SPU_RING - 1);
  voice.decoded += 4;
  voice.address = (voice.address + 1) & 0x3FFFF;
}

/* --- the envelope --- */

function envelope_rate(floor, speed, exponential, falling, inverted, current) {
  let step = 7 - (speed & 3);
  if (inverted) step = ~step;
  let divide = 32768;
  if (speed < 0x2C) step = step << ((0x2F - speed) >> 2);
  if (speed >= 0x30) divide >>= (speed - 0x2C) >> 2;
  if (exponential) {
    if (falling) {
      step = (current * step) >> 15;
    } else if ((current & 0x7FFF) >= 0x6000) {
      if (speed < 0x28) {
        step >>= 2;
      } else if (speed >= 0x2C) {
        divide >>= 2;
      } else {
        step >>= 1;
        divide >>= 1;
      }
    }
  }
  if (divide === 0 && speed < floor) divide = 1;
  return [step, divide];
}

function spu_run_envelope(voice) {
  const low = SPU_ADSR_LOW(), high = SPU_ADSR_HIGH();
  const sustain_level = ((low & 0xF) + 1) << 11;
  const current = (voice.level << 16) >> 16;
  let rate, overflow_to = 0;
  if (voice.stage === ENVELOPE_ATTACK && voice.level === 0x7FFF) voice.stage = ENVELOPE_DECAY;
  switch (voice.stage) {
    case ENVELOPE_ATTACK:
      rate = envelope_rate(0x7F, (low >> 8) & 0x7F, (low >> 15) & 1, 0, 0, current);
      overflow_to = 0x7FFF;
      break;
    case ENVELOPE_DECAY:
      rate = envelope_rate(0x1F << 2, ((low >> 4) & 0xF) << 2, 1, 1, 1, current);
      break;
    case ENVELOPE_SUSTAIN: {
      const falls = (high >> 14) & 1;
      rate = envelope_rate(0x7F, (high >> 6) & 0x7F, (high >> 15) & 1, falls, falls, current);
      overflow_to = falls ? 0 : 0x7FFF;
      break;
    }
    default:
      rate = envelope_rate(0x1F << 2, (high & 0x1F) << 2, (high >> 5) & 1, 1, 1, current);
      break;
  }
  const [step, divide] = rate;
  voice.divider += divide;
  if (!(voice.divider & 0x8000)) return;

  const before = voice.level;
  voice.divider = 0;
  voice.level = (voice.level + step) & 0xFFFF;
  if (voice.stage === ENVELOPE_ATTACK) {
    if (((before ^ voice.level) & voice.level) & 0x8000) voice.level = overflow_to;
  } else if (voice.level & 0x8000) {
    voice.level = overflow_to;
  }
  if (voice.stage === ENVELOPE_DECAY && voice.level < sustain_level) voice.stage = ENVELOPE_SUSTAIN;
}

/* --- one sample of the chip --- */

function spu_key_on(voice) {
  voice.level = 0;
  voice.divider = 0;
  voice.stage = ENVELOPE_ATTACK;
  voice.flags = 0;
  voice.write_at = voice.read_at = voice.decoded = 0;
  voice.delay = SPU_PLAY_DELAY;
  voice.older = voice.newer = 0;
  voice.phase = 0;
  voice.address = voice.start & ~7;
  voice.loop_held = 0;
}

function spu_tick() {
  let sum_left = 0, sum_right = 0;
  for (let n = 0; n < SPU_VOICES; n++) {
    const voice = spu[n];
    if (voice.level === 0 && voice.stage === ENVELOPE_RELEASE && !voice.delay && !((spu_keys_on >> n) & 1)) continue;
    if (voice.delay) voice.loop_held = 0;
    spu_decode(voice);

    const at = voice.read_at, weigh = (voice.phase & 0xFFF) >> 4, ring = voice.ring;
    let sample = (ring[at & 31] * rg_game_spu_rules[SPU_GAUSS_AT + 0xFF - weigh] +
                  ring[(at + 1) & 31] * rg_game_spu_rules[SPU_GAUSS_AT + 0x1FF - weigh] +
                  ring[(at + 2) & 31] * rg_game_spu_rules[SPU_GAUSS_AT + 0x100 + weigh] +
                  ring[(at + 3) & 31] * rg_game_spu_rules[SPU_GAUSS_AT + weigh]) >> 15;
    sample = (sample * ((voice.level << 16) >> 16)) >> 15;
    if (heard(n + 1, 1)) {
      sum_left += (sample * voice.heard[0]) >> 15;
      sum_right += (sample * voice.heard[1]) >> 15;
    }
    voice.heard[0] = (voice.volume[0] & 0x7FFF) << 1;
    voice.heard[1] = (voice.volume[1] & 0x7FFF) << 1;

    if (!voice.delay) {
      spu_run_envelope(voice);
      const moved = voice.phase + (voice.pitch > 0x3FFF ? 0x3FFF : voice.pitch);
      voice.phase = moved & 0xFFF;
      voice.decoded -= moved >> 12;
      voice.read_at = (voice.read_at + (moved >> 12)) & (SPU_RING - 1);
    } else {
      voice.delay--;
    }
    if ((spu_keys_off >> n) & 1 && voice.stage !== ENVELOPE_RELEASE && voice.delay < 3) {
      voice.divider = 0;
      voice.stage = ENVELOPE_RELEASE;
    }
    if ((spu_keys_on >> n) & 1) spu_key_on(voice);
  }
  spu_keys_on = spu_keys_off = 0;
  spu_out[0] = held_to_16_bits((held_to_16_bits(sum_left) * (SPU_MAIN_VOLUME() << 1)) >> 15);
  spu_out[1] = held_to_16_bits((held_to_16_bits(sum_right) * (SPU_MAIN_VOLUME() << 1)) >> 15);
}

/* --- what each game voice is told, once a frame --- */

/* The products here pass 32 bits, so they are worked out as JavaScript's numbers, which hold them
 * exactly, and divided as the C's 64-bit numbers are. */
function spu_pitch(clock_hz, samples, ticks) {
  const over = clock_hz * samples * SPU_PITCH_ONE(), under = ticks * SPU_HZ();
  const pitch = Math.floor((2 * over + under) / (2 * under));
  return pitch < 1 ? 1 : pitch > SPU_PITCH_TOP() ? SPU_PITCH_TOP() : pitch;
}

function spu_set_volume(voice, value, side) {
  voice.volume[0] = side === PAN_RIGHT ? 0 : value;
  voice.volume[1] = side === PAN_LEFT ? 0 : value;
}

function spu_fade_a_frame(fading) {
  if (fading.hold_samples === 0) return;
  fading.left += COUNTED_A_FRAME();
  while (fading.left >= fading.hold_samples) {
    fading.left -= fading.hold_samples;
    if (fading.up) {
      if (++fading.volume >= VOLUMES - 1) {
        fading.volume = VOLUMES - 1;
        fading.hold_samples = 0;
        return;
      }
    } else if (--fading.volume <= 0) {
      fading.volume = 0;
      fading.hold_samples = 0;
      return;
    }
  }
}

function spu_tell(n, sounding, loop, pitch, value, side) {
  const voice = spu[n];
  const struck = ((spu_struck | spu_struck_waiting) >> n) & 1, waiting = (spu_struck_by_game >> n) & 1;
  if (!sounding) {
    spu_set_volume(voice, 0, 0);
    if (voice.keyed) spu_keys_off |= 1 << n;
    voice.keyed = 0;
    return;
  }
  spu_set_volume(voice, value, side);
  voice.pitch = pitch;
  if (struck) {
    voice.start = loop << 2;
    voice.loop_start = loop;
    voice.keyed = 1;
    spu_keys_on |= 1 << n;
    spu_keys_off &= ~(1 << n);
  } else if (loop !== voice.loop_start && voice.keyed && !waiting) {
    voice.loop = loop << 2;
    voice.loop_held = 1;
    voice.loop_start = loop;
  }
}

function slide_ticks_in(frame) { return Math.floor((frame * COUNTED_A_FRAME()) / 128); }

function spu_slide_a_frame(square, i) {
  const every = slide_step_ticks(square.slide);
  const frame = spu_slide_frame[i];
  if (frame > 0 && every !== 0 && (square.slide & SLIDE_SHIFT_BITS) !== 0) {
    let steps = Math.floor(slide_ticks_in(frame) / every) - Math.floor(slide_ticks_in(frame - 1) / every);
    for (; steps > 0 && square.wave_ticks !== 0; steps--) {
      square.slid_ticks = slid_wave_ticks(square.slid_ticks, square.slide);
      if (square.slid_ticks === 0 || slide_runs_out(square.slid_ticks, square.slide)) square.wave_ticks = 0;
    }
  }
  if (frame < SPU_SLIDE_FRAMES_MOST) spu_slide_frame[i] = frame + 1;
}

const square_loop_of_eighths = [0, 0, 1, 1, 2, 2, 3, 3, 3];

function spu_frame_begins() {
  for (let i = 0; i < RG_SQUARE_VOICES; i++) spu_slide_a_frame(squares[i], i);
  for (let i = 0; i < RG_SQUARE_VOICES; i++) {
    if (!((spu_set_by_game >> i) & 1)) spu_fade_a_frame(squares[i].loudness);
  }
  if (!((spu_set_by_game >> (RG_NOISE_VOICE - 1)) & 1)) spu_fade_a_frame(hiss.loudness);

  for (let i = 0; i < RG_SQUARE_VOICES; i++) {
    const square = squares[i];
    const ticks = square.slid_ticks;
    const sounding = square.wave_ticks !== 0 && ticks !== 0;
    spu_tell(i, sounding, rg_game_spu_loops[square_loop_of_eighths[square.eighths_high & 7]],
             sounding ? spu_pitch(SQUARE_CLOCK_HZ(), SPU_SQUARE_SAMPLES(), ticks) : 0,
             Math.trunc((square.loudness.volume * SPU_LOUDEST()) / 15), sides[i + 1]);
  }

  const waveforms = rg_game_spu_loops[SPU_WAVEFORMS_AT];
  const wave_sounding = wave.wave_ticks !== 0 && spu_waveform >= 0 && spu_waveform < waveforms;
  spu_tell(RG_WAVE_VOICE - 1, wave_sounding, wave_sounding ? rg_game_spu_loops[SPU_WAVEFORMS_AT + 1 + spu_waveform] : 0,
           wave_sounding ? spu_pitch(WAVE_CLOCK_HZ(), SPU_WAVE_SAMPLES(), wave.wave_ticks) : 0,
           Math.trunc((wave.quarters * SPU_LOUDEST()) / 4), sides[RG_WAVE_VOICE]);

  const hiss_sounding = hiss.step_ticks !== 0;
  spu_tell(RG_NOISE_VOICE - 1, hiss_sounding, rg_game_spu_loops[hiss.bits <= 7 ? SPU_RATTLE_AT : SPU_HISS_AT],
           hiss_sounding ? spu_pitch(NOISE_CLOCK_HZ(), 1, hiss.step_ticks) : 0,
           Math.trunc((hiss.loudness.volume * SPU_LOUDEST()) / 15), sides[RG_NOISE_VOICE]);
  rg_hook_recordings_told();
  spu_struck_waiting = spu_struck_by_game;
  spu_struck = spu_struck_by_game = spu_set_by_game = spu_stopped_by_game = 0;
}

/* The sound of a frame, made by the chip (rg_sound_render_frame's twin). */
function spu_render_frame(left, right) {
  sample_carry += RG_SOUND_RATE * RG_CONSOLE_TICKS_A_FRAME;
  const count = Math.floor(sample_carry / RG_CONSOLE_TICKS_A_SECOND);
  sample_carry %= RG_CONSOLE_TICKS_A_SECOND;

  spu_frame_begins();
  for (let i = 0; i < count; i++) {
    spu_carry += SPU_HZ();
    while (spu_carry >= RG_SOUND_RATE) {
      spu_carry -= RG_SOUND_RATE;
      spu_tick();
    }
    left[i] = spu_out[0];
    right[i] = spu_out[1];
  }
  return count;
}

/* What the mixer's voice +place+ plays, told to the chip's voice for it (rg_spu.c's spu_tell_recording). */
function spu_tell_recording(place, sounding, recording, back, step, loudness, level) {
  if (!sounding && ((spu_stopped_by_game >> (SPU_GAME_VOICES + place)) & 1)) return;
  let loop = -1;
  if (sounding && recording >= 0 && recording < rg_game_spu_recordings[0]) {
    const ways = 1 + recording * 3;
    loop = back === 0 ? rg_game_spu_recordings[ways] : back === rg_game_spu_recordings[ways + 1] ? rg_game_spu_recordings[ways + 2] : -1;
  }
  const pitch = (step + 8) >> 4;
  const value = ((level + (level >> 7)) * Math.trunc((loudness * SPU_LOUDEST()) / SPU_MIX_FULL())) >> SPU_SHAPE_SCALE();
  spu_tell(SPU_GAME_VOICES + place, loop >= 0, loop, pitch < 1 ? 1 : pitch > SPU_PITCH_TOP() ? SPU_PITCH_TOP() : pitch, value, 0);
}

/* --- the state image (rg_spu.c says what each field holds) --- */

const SPU_GENERAL_NUMBERS = 13, SPU_CARRY_AT = 6, SPU_VOICE_FIELDS = 24;

function rg_spu_visit_state() {
  const numbers = [spu_struck, spu_struck_by_game, spu_struck_waiting, spu_set_by_game, spu_keys_on, spu_keys_off, spu_carry,
    spu_out[0], spu_out[1], spu_waveform, spu_slide_frame[0], spu_slide_frame[1], spu_stopped_by_game];
  for (const v of spu) {
    numbers.push(v.start, v.loop, v.loop_held, v.pitch, v.volume[0], v.volume[1], v.heard[0], v.heard[1], v.address, v.flags, v.shift,
      v.filter, v.older, v.newer, v.write_at, v.read_at, v.decoded, v.delay, v.phase, v.level, v.divider, v.stage, v.keyed,
      v.loop_start, ...v.ring);
  }
  rg_state_numbers("sound.spu", numbers);
  if (numbers[SPU_CARRY_AT] < 0 || numbers[SPU_CARRY_AT] >= RG_SOUND_RATE) rg_state_refuse_damaged("the sound chip is somewhere it cannot be");

  [spu_struck, spu_struck_by_game, spu_struck_waiting, spu_set_by_game, spu_keys_on, spu_keys_off, spu_carry, spu_out[0], spu_out[1],
    spu_waveform, spu_slide_frame[0], spu_slide_frame[1], spu_stopped_by_game] = numbers;
  spu.forEach((v, n) => {
    const at = SPU_GENERAL_NUMBERS + n * (SPU_VOICE_FIELDS + SPU_RING);
    const f = numbers.slice(at, at + SPU_VOICE_FIELDS);
    if (f[14] < 0 || f[14] >= SPU_RING || f[15] < 0 || f[15] >= SPU_RING || f[21] < ENVELOPE_RELEASE || f[21] > ENVELOPE_SUSTAIN ||
        f[10] < 0 || f[10] > 15 || f[11] < 0 || f[11] > 15) {
      rg_state_refuse_damaged("a voice of the sound chip is part way through a sound it cannot be");
    }
    [v.start, v.loop, v.loop_held, v.pitch, v.volume[0], v.volume[1], v.heard[0], v.heard[1], v.address, v.flags, v.shift, v.filter,
      v.older, v.newer, v.write_at, v.read_at, v.decoded, v.delay, v.phase, v.level, v.divider, v.stage, v.keyed, v.loop_start] = f;
    v.ring.set(numbers.slice(at + SPU_VOICE_FIELDS, at + SPU_VOICE_FIELDS + SPU_RING));
  });
}
