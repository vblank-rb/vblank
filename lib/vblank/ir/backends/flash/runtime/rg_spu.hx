/*
 * The PlayStation's sound chip, for a game built as a console whose voices read loops out of sound memory
 * (RG_VOICES_READ_SOUND_MEMORY). A port of the JavaScript runtime's rg_spu.js, function for function; the native
 * runtime's rg_spu.c says how the chip plays the game's four voices, what Beetle PSX and psx-spx each rule comes from,
 * and the layout of rg_game_spu_rules, rg_game_spu_loops and rg_game_spu_memory, which this one reads the same way. It
 * is joined into the script after rg_sound.hx and reads that file's voices.
 *
 * A game on another console never asks it, but it is part of every movie (its four tables are empty there, written
 * ahead of the runtime by Flash::Lowering#console_text), so a call from rg_sound.hx needs no test of the console.
 *
 * Left out: the recordings and waveforms a game fills from the start file (rg_spu_fill_*), and the state image.
 */

static inline var SPU_GAME_VOICES:Int = 4;
static inline var SPU_RECORDING_VOICES:Int = 16;
static inline var SPU_VOICES:Int = 20; // SPU_GAME_VOICES + SPU_RECORDING_VOICES
static inline var SPU_RING:Int = 32;
static inline var SPU_DECODE_WHEN:Int = 11;
static inline var SPU_PLAY_DELAY:Int = 4;
static inline var ENVELOPE_RELEASE:Int = 0;
static inline var ENVELOPE_ATTACK:Int = 1;
static inline var ENVELOPE_DECAY:Int = 2;
static inline var ENVELOPE_SUSTAIN:Int = 3;
static inline var SPU_HISS_AT:Int = 4;
static inline var SPU_RATTLE_AT:Int = 5;
static inline var SPU_WAVEFORMS_AT:Int = 6;
static inline var SPU_SLIDE_FRAMES_MOST:Int = 1 << 20;
static inline var BLOCK_LOOP_END:Int = 1;
static inline var BLOCK_LOOP_REPEAT:Int = 2;
static inline var BLOCK_LOOP_START:Int = 4;
static inline var SPU_GAUSS_AT:Int = 12;

static function SPU_HZ():Int { return rg_game_spu_rules[0]; }
static function SPU_ADSR_LOW():Int { return rg_game_spu_rules[1]; }
static function SPU_ADSR_HIGH():Int { return rg_game_spu_rules[2]; }
static function SPU_LOUDEST():Int { return rg_game_spu_rules[3]; }
static function SPU_MAIN_VOLUME():Int { return rg_game_spu_rules[4]; }
static function SPU_PITCH_ONE():Int { return rg_game_spu_rules[5]; }
static function SPU_PITCH_TOP():Int { return rg_game_spu_rules[6]; }
static function SPU_SQUARE_SAMPLES():Int { return rg_game_spu_rules[7]; }
static function SPU_WAVE_SAMPLES():Int { return rg_game_spu_rules[8]; }
static function SPU_MEMORY_BASE():Int { return rg_game_spu_rules[9]; }
static function SPU_WHOLE_GAIN_SHIFT():Int { return rg_game_spu_rules[10]; }
static function SPU_GAIN_TO_VOLUME_SHIFT():Int { return rg_game_spu_rules[11]; }

static var spu:Array<RgSpuVoice> = [for (i in 0...SPU_VOICES) new RgSpuVoice()];
static var spu_struck:Int = 0;
static var spu_struck_by_game:Int = 0;
static var spu_struck_waiting:Int = 0;
static var spu_set_by_game:Int = 0;
static var spu_stopped_by_game:Int = 0;
static var spu_keys_on:Int = 0;
static var spu_keys_off:Int = 0;
static var spu_carry:Int = 0;
static var spu_waveform:Int = 0;
static var spu_out_left:Int = 0;
static var spu_out_right:Int = 0;
static var spu_slide_frame:Array<Int> = [0, 0];

static function spu_slide_started(voice:Int):Void { spu_slide_frame[voice - 1] = 0; }
static function voice_struck(voice:Int):Void { spu_struck |= 1 << (voice - 1); }
static function game_voice_struck(voice:Int):Void {
  spu_struck_by_game |= 1 << (voice - 1);
  spu_set_by_game |= 1 << (voice - 1);
}
static function spu_waveform_put_in(which:Int):Void { spu_waveform = which; }
static function spu_recording_struck(place:Int, by_game:Int):Void {
  if (by_game != 0) spu_struck_by_game |= 1 << (SPU_GAME_VOICES + place);
  else spu_struck |= 1 << (SPU_GAME_VOICES + place);
}
static function spu_recording_stopped_by_game(place:Int):Void { spu_stopped_by_game |= 1 << (SPU_GAME_VOICES + place); }

static function spu_memory_at(address:Int):Int {
  var at = address - SPU_MEMORY_BASE();
  return at >= 0 && at < rg_game_spu_memory[0] ? rg_game_spu_memory[1 + at] : 0;
}

/* --- the decoder --- */

static var filter_weights:Array<Array<Int>> = [[0, 0], [60, 0], [115, -52], [98, -55], [122, -60], [0, 0], [0, 0], [0, 0],
                                               [0, 0], [0, 0], [0, 0], [0, 0], [0, 0], [0, 0], [0, 0], [0, 0]];

static function held_to_16_bits(sample:Int):Int { return sample < -32768 ? -32768 : (sample > 32767 ? 32767 : sample); }

static function spu_decode(voice:RgSpuVoice):Void {
  if (voice.decoded >= SPU_DECODE_WHEN) return;

  if ((voice.address & 7) == 0) {
    if ((voice.flags & BLOCK_LOOP_END) != 0) {
      voice.address = voice.loop & ~7;
      if ((voice.flags & BLOCK_LOOP_REPEAT) == 0) {
        voice.stage = ENVELOPE_RELEASE;
        voice.level = 0;
      }
    }
    var header = spu_memory_at(voice.address);
    voice.shift = header & 0xF;
    voice.filter = (header >> 4) & 0xF;
    voice.flags = (header >> 8) & 0xFF;
    if ((voice.flags & BLOCK_LOOP_START) != 0 && voice.loop_held == 0) voice.loop = voice.address;
    voice.address = (voice.address + 1) & 0x3FFFF;
  }

  var coded = spu_memory_at(voice.address);
  var shift = voice.shift;
  if (shift > 12) {
    shift = 8;
    coded &= 0x8888;
  }
  var weights = filter_weights[voice.filter];
  for (i in 0...4) {
    var nibble = (coded >> (4 * i)) & 0xF;
    var sample = ((nibble >= 8 ? nibble - 16 : nibble) * 4096) >> shift;
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

static var rate_step:Int = 0;
static var rate_divide:Int = 0;

/* The step and the divider of a stage's rate, left in rate_step and rate_divide. */
static function envelope_rate(floor:Int, speed:Int, exponential:Bool, falling:Bool, inverted:Bool, current:Int):Void {
  var step = 7 - (speed & 3);
  if (inverted) step = ~step;
  var divide = 32768;
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
  if (divide == 0 && speed < floor) divide = 1;
  rate_step = step;
  rate_divide = divide;
}

static function spu_run_envelope(voice:RgSpuVoice):Void {
  var low = SPU_ADSR_LOW();
  var high = SPU_ADSR_HIGH();
  var sustain_level = ((low & 0xF) + 1) << 11;
  var current = (voice.level << 16) >> 16;
  var overflow_to = 0;
  if (voice.stage == ENVELOPE_ATTACK && voice.level == 0x7FFF) voice.stage = ENVELOPE_DECAY;
  if (voice.stage == ENVELOPE_ATTACK) {
    envelope_rate(0x7F, (low >> 8) & 0x7F, ((low >> 15) & 1) != 0, false, false, current);
    overflow_to = 0x7FFF;
  } else if (voice.stage == ENVELOPE_DECAY) {
    envelope_rate(0x1F << 2, ((low >> 4) & 0xF) << 2, true, true, true, current);
  } else if (voice.stage == ENVELOPE_SUSTAIN) {
    var falls = ((high >> 14) & 1) != 0;
    envelope_rate(0x7F, (high >> 6) & 0x7F, ((high >> 15) & 1) != 0, falls, falls, current);
    overflow_to = falls ? 0 : 0x7FFF;
  } else {
    envelope_rate(0x1F << 2, (high & 0x1F) << 2, ((high >> 5) & 1) != 0, true, true, current);
  }
  voice.divider += rate_divide;
  if ((voice.divider & 0x8000) == 0) return;

  var before = voice.level;
  voice.divider = 0;
  voice.level = (voice.level + rate_step) & 0xFFFF;
  if (voice.stage == ENVELOPE_ATTACK) {
    if ((((before ^ voice.level) & voice.level) & 0x8000) != 0) voice.level = overflow_to;
  } else if ((voice.level & 0x8000) != 0) {
    voice.level = overflow_to;
  }
  if (voice.stage == ENVELOPE_DECAY && voice.level < sustain_level) voice.stage = ENVELOPE_SUSTAIN;
}

/* --- one sample of the chip --- */

static function spu_key_on(voice:RgSpuVoice):Void {
  voice.level = 0;
  voice.divider = 0;
  voice.stage = ENVELOPE_ATTACK;
  voice.flags = 0;
  voice.write_at = 0;
  voice.read_at = 0;
  voice.decoded = 0;
  voice.delay = SPU_PLAY_DELAY;
  voice.older = 0;
  voice.newer = 0;
  voice.phase = 0;
  voice.address = voice.start & ~7;
  voice.loop_held = 0;
}

static function spu_tick():Void {
  var sum_left = 0;
  var sum_right = 0;
  for (n in 0...SPU_VOICES) {
    var voice = spu[n];
    if (voice.level == 0 && voice.stage == ENVELOPE_RELEASE && voice.delay == 0 && ((spu_keys_on >> n) & 1) == 0) continue;
    if (voice.delay != 0) voice.loop_held = 0;
    spu_decode(voice);

    var at = voice.read_at;
    var weigh = (voice.phase & 0xFFF) >> 4;
    var ring = voice.ring;
    var sample = (ring[at & 31] * rg_game_spu_rules[SPU_GAUSS_AT + 0xFF - weigh] +
                  ring[(at + 1) & 31] * rg_game_spu_rules[SPU_GAUSS_AT + 0x1FF - weigh] +
                  ring[(at + 2) & 31] * rg_game_spu_rules[SPU_GAUSS_AT + 0x100 + weigh] +
                  ring[(at + 3) & 31] * rg_game_spu_rules[SPU_GAUSS_AT + weigh]) >> 15;
    sample = (sample * ((voice.level << 16) >> 16)) >> 15;
    if (heard(n + 1, 1) != 0) {
      sum_left += (sample * voice.heard[0]) >> 15;
      sum_right += (sample * voice.heard[1]) >> 15;
    }
    voice.heard[0] = (voice.volume[0] & 0x7FFF) << 1;
    voice.heard[1] = (voice.volume[1] & 0x7FFF) << 1;

    if (voice.delay == 0) {
      spu_run_envelope(voice);
      var moved = voice.phase + (voice.pitch > 0x3FFF ? 0x3FFF : voice.pitch);
      voice.phase = moved & 0xFFF;
      voice.decoded -= moved >> 12;
      voice.read_at = (voice.read_at + (moved >> 12)) & (SPU_RING - 1);
    } else {
      voice.delay--;
    }
    if (((spu_keys_off >> n) & 1) != 0 && voice.stage != ENVELOPE_RELEASE && voice.delay < 3) {
      voice.divider = 0;
      voice.stage = ENVELOPE_RELEASE;
    }
    if (((spu_keys_on >> n) & 1) != 0) spu_key_on(voice);
  }
  spu_keys_on = 0;
  spu_keys_off = 0;
  spu_out_left = held_to_16_bits((held_to_16_bits(sum_left) * (SPU_MAIN_VOLUME() << 1)) >> 15);
  spu_out_right = held_to_16_bits((held_to_16_bits(sum_right) * (SPU_MAIN_VOLUME() << 1)) >> 15);
}

/* --- what each game voice is told, once a frame --- */

/* The products here pass 32 bits, so they are worked out as floats, which hold them exactly, and divided as the C's
 * 64-bit numbers are. */
static function spu_pitch(clock_hz:Int, samples:Int, ticks:Int):Int {
  var over:Float = clock_hz;
  over = over * samples * SPU_PITCH_ONE();
  var under:Float = ticks;
  under = under * SPU_HZ();
  var pitch = Std.int(rg_floor((2 * over + under) / (2 * under)));
  return pitch < 1 ? 1 : (pitch > SPU_PITCH_TOP() ? SPU_PITCH_TOP() : pitch);
}

static function spu_set_volume(voice:RgSpuVoice, value:Int, side:Int):Void {
  voice.volume[0] = side == PAN_RIGHT ? 0 : value;
  voice.volume[1] = side == PAN_LEFT ? 0 : value;
}

static function spu_fade_a_frame(fading:RgLoudness):Void {
  if (fading.hold_samples == 0) return;
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

static function spu_tell(n:Int, sounding:Bool, loop:Int, pitch:Int, value:Int, side:Int):Void {
  var voice = spu[n];
  var struck = ((spu_struck | spu_struck_waiting) >> n) & 1;
  var waiting = (spu_struck_by_game >> n) & 1;
  if (!sounding) {
    spu_set_volume(voice, 0, 0);
    if (voice.keyed != 0) spu_keys_off |= 1 << n;
    voice.keyed = 0;
    return;
  }
  spu_set_volume(voice, value, side);
  voice.pitch = pitch;
  if (struck != 0) {
    voice.start = loop << 2;
    voice.loop_start = loop;
    voice.keyed = 1;
    spu_keys_on |= 1 << n;
    spu_keys_off &= ~(1 << n);
  } else if (loop != voice.loop_start && voice.keyed != 0 && waiting == 0) {
    voice.loop = loop << 2;
    voice.loop_held = 1;
    voice.loop_start = loop;
  }
}

static function slide_ticks_in(frame:Int):Int { return Std.int(rg_floor((frame * 1.0 * COUNTED_A_FRAME()) / 128)); }

static function spu_slide_a_frame(square:RgSquare, i:Int):Void {
  var every = slide_step_ticks(square.slide);
  var frame = spu_slide_frame[i];
  if (frame > 0 && every != 0 && (square.slide & SLIDE_SHIFT_BITS) != 0) {
    var steps = Std.int(slide_ticks_in(frame) / every) - Std.int(slide_ticks_in(frame - 1) / every);
    while (steps > 0 && square.wave_ticks != 0) {
      square.slid_ticks = slid_wave_ticks(square.slid_ticks, square.slide);
      if (square.slid_ticks == 0 || slide_runs_out(square.slid_ticks, square.slide)) square.wave_ticks = 0;
      steps--;
    }
  }
  if (frame < SPU_SLIDE_FRAMES_MOST) spu_slide_frame[i] = frame + 1;
}

static var square_loop_of_eighths:Array<Int> = [0, 0, 1, 1, 2, 2, 3, 3, 3];

static function spu_frame_begins():Void {
  for (i in 0...RG_SQUARE_VOICES) spu_slide_a_frame(squares[i], i);
  for (i in 0...RG_SQUARE_VOICES) {
    if (((spu_set_by_game >> i) & 1) == 0) spu_fade_a_frame(squares[i].loudness);
  }
  if (((spu_set_by_game >> (RG_NOISE_VOICE - 1)) & 1) == 0) spu_fade_a_frame(hiss_loudness);

  for (i in 0...RG_SQUARE_VOICES) {
    var square = squares[i];
    var ticks = square.slid_ticks;
    var sounding = square.wave_ticks != 0 && ticks != 0;
    spu_tell(i, sounding, rg_game_spu_loops[square_loop_of_eighths[square.eighths_high & 7]],
             sounding ? spu_pitch(SQUARE_CLOCK_HZ(), SPU_SQUARE_SAMPLES(), ticks) : 0,
             Std.int((square.loudness.volume * SPU_LOUDEST()) / 15), sides[i + 1]);
  }

  var waveforms = rg_game_spu_loops[SPU_WAVEFORMS_AT];
  var wave_sounding = wave_wave_ticks != 0 && spu_waveform >= 0 && spu_waveform < waveforms;
  spu_tell(RG_WAVE_VOICE - 1, wave_sounding, wave_sounding ? rg_game_spu_loops[SPU_WAVEFORMS_AT + 1 + spu_waveform] : 0,
           wave_sounding ? spu_pitch(WAVE_CLOCK_HZ(), SPU_WAVE_SAMPLES(), wave_wave_ticks) : 0,
           Std.int((wave_quarters * SPU_LOUDEST()) / 4), sides[RG_WAVE_VOICE]);

  var hiss_sounding = hiss_step_ticks != 0;
  spu_tell(RG_NOISE_VOICE - 1, hiss_sounding, rg_game_spu_loops[hiss_bits <= 7 ? SPU_RATTLE_AT : SPU_HISS_AT],
           hiss_sounding ? spu_pitch(NOISE_CLOCK_HZ(), 1, hiss_step_ticks) : 0,
           Std.int((hiss_loudness.volume * SPU_LOUDEST()) / 15), sides[RG_NOISE_VOICE]);
  rg_hook_recordings_told();
  spu_struck_waiting = spu_struck_by_game;
  spu_struck = 0;
  spu_struck_by_game = 0;
  spu_set_by_game = 0;
  spu_stopped_by_game = 0;
}

/* The sound of a frame, made by the chip (rg_sound_render_frame's twin). */
static function spu_render_frame(left:Vector<Int>, right:Vector<Int>):Int {
  sample_carry += RG_SOUND_RATE * 1.0 * RG_CONSOLE_TICKS_A_FRAME;
  var count = Std.int(rg_floor(sample_carry / RG_CONSOLE_TICKS_A_SECOND));
  sample_carry = sample_carry % RG_CONSOLE_TICKS_A_SECOND;

  spu_frame_begins();
  for (i in 0...count) {
    spu_carry += SPU_HZ();
    while (spu_carry >= RG_SOUND_RATE) {
      spu_carry -= RG_SOUND_RATE;
      spu_tick();
    }
    left[i] = spu_out_left;
    right[i] = spu_out_right;
  }
  return count;
}

/* What the mixer's voice +place+ plays, told to the chip's voice for it (rg_spu.c's spu_tell_recording): one that
 * +ran_out+ plays to its end, started all the same where it is struck now. */
static function spu_tell_recording(place:Int, sounding:Bool, ran_out:Bool, recording:Int, back:Int, step:Int, loudness:Int, level:Int, shaped:Bool):Void {
  if (!sounding && ((spu_stopped_by_game >> (SPU_GAME_VOICES + place)) & 1) != 0) return;
  if (ran_out) {
    if ((((spu_struck | spu_struck_waiting) >> (SPU_GAME_VOICES + place)) & 1) == 0) return;
    sounding = true;
  }
  var loop = -1;
  if (sounding && recording >= 0 && recording < rg_game_spu_recordings[0]) {
    var ways = 1 + recording * 3;
    loop = back == 0 ? rg_game_spu_recordings[ways] : (back == rg_game_spu_recordings[ways + 1] ? rg_game_spu_recordings[ways + 2] : -1);
  }
  var pitch = (step + 8) >> 4;
  var scaled = loudness * (level + (level >> 7));
  var value = shaped ? (scaled >> SPU_WHOLE_GAIN_SHIFT()) << SPU_GAIN_TO_VOLUME_SHIFT()
    : (scaled << SPU_GAIN_TO_VOLUME_SHIFT()) >> SPU_WHOLE_GAIN_SHIFT();
  spu_tell(SPU_GAME_VOICES + place, loop >= 0, loop, pitch < 1 ? 1 : (pitch > SPU_PITCH_TOP() ? SPU_PITCH_TOP() : pitch), value, 0);
}

/* --- the state image (rg_spu.c says what each field holds) --- */

static inline var SPU_GENERAL_NUMBERS:Int = 13;
static inline var SPU_CARRY_AT:Int = 6;
static inline var SPU_VOICE_FIELDS:Int = 24;

static function rg_spu_visit_state():Void {
  var numbers:Array<Int> = [spu_struck, spu_struck_by_game, spu_struck_waiting, spu_set_by_game, spu_keys_on, spu_keys_off, spu_carry,
    spu_out_left, spu_out_right, spu_waveform, spu_slide_frame[0], spu_slide_frame[1], spu_stopped_by_game];
  for (v in spu) {
    for (number in [v.start, v.loop, v.loop_held, v.pitch, v.volume[0], v.volume[1], v.heard[0], v.heard[1], v.address, v.flags, v.shift,
                    v.filter, v.older, v.newer, v.write_at, v.read_at, v.decoded, v.delay, v.phase, v.level, v.divider, v.stage, v.keyed,
                    v.loop_start]) numbers.push(number);
    for (i in 0...SPU_RING) numbers.push(v.ring[i]);
  }
  rg_state_numbers("sound.spu", numbers);
  if (numbers[SPU_CARRY_AT] < 0 || numbers[SPU_CARRY_AT] >= RG_SOUND_RATE) rg_state_refuse_damaged("the sound chip is somewhere it cannot be");

  spu_struck = numbers[0];
  spu_struck_by_game = numbers[1];
  spu_struck_waiting = numbers[2];
  spu_set_by_game = numbers[3];
  spu_keys_on = numbers[4];
  spu_keys_off = numbers[5];
  spu_carry = numbers[6];
  spu_out_left = numbers[7];
  spu_out_right = numbers[8];
  spu_waveform = numbers[9];
  spu_slide_frame[0] = numbers[10];
  spu_slide_frame[1] = numbers[11];
  spu_stopped_by_game = numbers[12];
  for (n in 0...SPU_VOICES) {
    var v = spu[n];
    var at = SPU_GENERAL_NUMBERS + n * (SPU_VOICE_FIELDS + SPU_RING);
    if (numbers[at + 14] < 0 || numbers[at + 14] >= SPU_RING || numbers[at + 15] < 0 || numbers[at + 15] >= SPU_RING ||
        numbers[at + 21] < ENVELOPE_RELEASE || numbers[at + 21] > ENVELOPE_SUSTAIN || numbers[at + 10] < 0 || numbers[at + 10] > 15 ||
        numbers[at + 11] < 0 || numbers[at + 11] > 15) {
      rg_state_refuse_damaged("a voice of the sound chip is part way through a sound it cannot be");
    }
    v.start = numbers[at];
    v.loop = numbers[at + 1];
    v.loop_held = numbers[at + 2];
    v.pitch = numbers[at + 3];
    v.volume[0] = numbers[at + 4];
    v.volume[1] = numbers[at + 5];
    v.heard[0] = numbers[at + 6];
    v.heard[1] = numbers[at + 7];
    v.address = numbers[at + 8];
    v.flags = numbers[at + 9];
    v.shift = numbers[at + 10];
    v.filter = numbers[at + 11];
    v.older = numbers[at + 12];
    v.newer = numbers[at + 13];
    v.write_at = numbers[at + 14];
    v.read_at = numbers[at + 15];
    v.decoded = numbers[at + 16];
    v.delay = numbers[at + 17];
    v.phase = numbers[at + 18];
    v.level = numbers[at + 19];
    v.divider = numbers[at + 20];
    v.stage = numbers[at + 21];
    v.keyed = numbers[at + 22];
    v.loop_start = numbers[at + 23];
    for (i in 0...SPU_RING) v.ring[i] = numbers[at + SPU_VOICE_FIELDS + i];
  }
}
