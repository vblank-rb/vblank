/*
 * THE PLAYSTATION'S SOUND CHIP (the SPU), for a game built as a console whose voices read loops out of
 * sound memory (RG_VOICES_READ_SOUND_MEMORY, from Console::Description#voices_read_sound_memory). It is
 * joined into rg_sound.c, after the four voices, and reads them: what each of the game's voices is
 * told to play is kept there as on every console, and here it is played the way the PlayStation
 * program plays it (Backends::PS1::SPUWrites says which writes each sound means), so a desktop build
 * made as the PlayStation sounds like the PlayStation and not like a Game Boy.
 *
 * THE GAME'S FOUR VOICES ARE FOUR OF THE CHIP'S. Each reads a loop out of sound memory, the same
 * loops the PlayStation program copies there (Backends::PS1::SoundMemory): a square of each width, a
 * waveform seven times over, the hiss and the rattle. How fast it reads is its pitch, 1000h for
 * 44100 samples a second. Its loudness is a volume for each speaker, a voice's volume 0 to 15 being
 * so many fifteenths of 1000h; a fade or a swell moves that volume a step at a time, once a frame,
 * as the program's runtime does (Backends::PS1::Runtime::Sound#emit_fades).
 *
 * ONCE A FRAME, where the PlayStation program's wait ends, the tune plays its frame, the fades move a
 * frame on, and the voices struck are started from their loops' starts (key on) and those with nothing
 * to play let go (key off); the rest take their new pitch, loudness and shape as they play.
 *
 * THE GAME'S OWN SOUNDS ARE A FRAME BEHIND THE TUNE'S, as in the program. A beep, a hit or a wave
 * writes its voice's pitch and loudness the moment the pass makes it, early in the frame, and the
 * voice is started where the pass's wait ends, a frame later; so for that frame a voice still playing
 * plays on at the new pitch and loudness, and a fade set by the pass is first counted at that wait's
 * end, not at the one before. A song's notes are played where the wait ends, and are started there.
 *
 * WHAT THE CHIP DOES WITH THAT, a sample at a time, 44100 times a second, as Beetle PSX does it
 * (mednafen/psx/spu.c, SPU_UpdateFromCDC, SPU_RunDecoder, SPU_RunEnvelope, CalcVCDelta; psx-spx,
 * "Sound Processing Unit (SPU)"):
 *
 *   - THE DECODER turns the loop's blocks of 16 bytes back into samples, four at a time into a ring
 *     of 32, whenever fewer than 11 are left: a block's first halfword holds its shift, its filter
 *     and its flags, and each sample is its four bits moved to the top and shifted down, plus the
 *     filter's share of the two samples before it (in 64ths: (0, 0), (60, 0), (115, -52), (98, -55),
 *     (122, -60)). A block flagged as the loop's start marks where the voice goes back to; one
 *     flagged as its end sends it there.
 *   - THE PITCH COUNTER moves on by the pitch each sample, in 4096ths of a sample, and the sample
 *     heard is four from the ring weighed by where the counter is between them (the chip's Gaussian
 *     table, psx-spx "SPU Gaussian Interpolation", handed over in rg_game_spu_rules).
 *   - THE ENVELOPE scales it (attack, decay, sustain, release, from the two halfwords the program
 *     gives every game voice: up to full in three samples, held, and gone in two when let go).
 *   - THE VOLUMES scale it for each speaker, a sample after they are written, and the voices are
 *     added up, held to 16 bits, and scaled by the main volume.
 *   - A voice started waits four samples before it plays, and key on and key off are taken after the
 *     sample they arrive in.
 *
 * The chip makes 44100 samples a second and the desktop's speaker takes RG_SOUND_RATE; each of the
 * speaker's samples holds the chip's newest.
 *
 * WHAT THE LOWERING WRITES for it (Computer::Sound#spu_tables, from Backends::PS1::SPUTables):
 *
 * rg_game_spu_rules: the chip's samples a second; the two halfwords of the envelope; a voice's volume
 * at its loudest; the main volume; the pitch that reads 44100 samples a second, and the highest the
 * chip reads at; the samples one wave of a square holds, and one wave of a waveform; where in sound
 * memory the game's loops start, in halfwords; a recording's loudness at full and the shift a shape's
 * level scales it by; and the 512 numbers of the Gaussian table.
 *
 * rg_game_spu_loops: where each loop starts, in the 8-byte steps the chip's start register counts:
 * the squares high for 1, 2, 4 and 6 eighths, the hiss and the rattle (nought for a game that makes
 * no noise), then how many waveforms there are and where each starts, in rg_game_waveforms's order.
 *
 * rg_game_spu_memory: how many halfwords of sound memory the loops fill, and those halfwords.
 *
 * rg_game_spu_recordings: how many recordings the game declares, in the mixer's numbering, then three
 * numbers each: where it starts played once through, how far back it reads when it holds, and where
 * it starts played holding, in 8-byte steps; -1 for a way the game never plays it (PS1::SPUTables).
 *
 * RECORDINGS play on the chip's voices past the game's four, one for each of the mixer's
 * (runtime_features/mix): the mixer keeps the interpreter's count of each, which voice plays what and
 * how loud its shape has it, and once a frame the chip is told from it (spu_tell_recording), as the
 * program's Runtime::Recordings tells its voices from the same count. The mixer's own slice is not
 * heard: the chip plays the recordings.
 *
 * A game of any other console keeps the chip's fields, all nought, so a state image reads on a build
 * of any console; the chip itself is left out of its build.
 */

/* The game's four voices, then one for each of the mixer's voices (Console::Description#
 * recordings_at_once), as Backends::PS1::Runtime::Recordings plays the game's recordings: the mixer's
 * voice N is the chip's voice SPU_GAME_VOICES + N. */
#define SPU_GAME_VOICES 4
#define SPU_RECORDING_VOICES 16
#define SPU_VOICES (SPU_GAME_VOICES + SPU_RECORDING_VOICES)
#define SPU_RING 32      /* the decoder's ring of samples */
#define SPU_DECODE_WHEN 11 /* fewer than this left in the ring, and it decodes four more */
#define SPU_PLAY_DELAY 4  /* the samples a voice started waits before it plays */

/* The envelope's phases (Beetle PSX, ADSR_ATTACK and the rest). */
/* Released is nought, so a voice never started is let go and silent, as every voice is once the program
 * has switched the chip on (Beetle PSX lets every voice go while the chip is off). */
enum { ENVELOPE_RELEASE, ENVELOPE_ATTACK, ENVELOPE_DECAY, ENVELOPE_SUSTAIN };

/* One of the chip's voices: its registers, its decoder, its pitch counter and its envelope. Addresses
 * are in halfwords of sound memory, as the chip counts them. */
typedef struct {
  int32_t start;        /* where a key on starts it */
  int32_t loop;         /* where a loop's end sends it */
  int32_t loop_held;    /* the loop was written, so a block flagged as a loop's start leaves it alone */
  int32_t pitch;
  int32_t volume[2];    /* the volume registers, left and right */
  int32_t heard[2];     /* ...and the volumes the next sample is scaled by, a sample behind them */
  int32_t address;      /* the next halfword the decoder reads */
  int32_t flags, shift, filter; /* the block being decoded */
  int32_t older, newer; /* the two samples decoded last */
  int32_t ring[SPU_RING];
  int32_t write_at, read_at, decoded; /* where the next four go, where the four heard start, how many are left */
  int32_t delay;        /* samples still to wait after a key on */
  int32_t phase;        /* the pitch counter's 4096ths of a sample */
  int32_t level, divider, stage; /* the envelope */
  int32_t keyed;        /* started and not let go since */
  int32_t loop_start;   /* the loop it was started on or last sent to (a square's width, a waveform) */
} spu_voice;

static spu_voice spu[SPU_VOICES];
static int32_t spu_struck;         /* the voices a song's notes struck this frame, a bit each */
static int32_t spu_struck_by_game; /* ...the game's own sounds struck in the pass, started at the next wait's end */
static int32_t spu_struck_waiting; /* ...and those of the pass before, started at this one */
static int32_t spu_set_by_game;    /* the voices whose loudness the pass set, not counted on at this wait's end */
static int32_t spu_stopped_by_game; /* the recordings' voices the game stopped in the pass, let go a frame later */
static int32_t spu_keys_on;        /* the voices to start after the chip's next sample... */
static int32_t spu_keys_off;       /* ...and the ones to let go */
static int32_t spu_carry;          /* the chip's samples owed to the speaker, in its samples times the speaker's rate */
static int32_t spu_out[2];         /* the chip's newest sample, left and right */
static int32_t spu_waveform;       /* the waveform the wave voice was last given, by its number */
static int32_t spu_slide_frame[RG_SQUARE_VOICES]; /* the frames since each square voice's note started */

/* A square voice's note started: its slide, if it has one, counts its frames from here. */
static inline void spu_slide_started(int32_t voice) { spu_slide_frame[voice - 1] = 0; }

/* A song's note started +voice+ (1 to 4): the voice is started from its loop's start where the
 * frame's wait ends, as the program's runtime gathers it (Runtime::Sound#emit_key). */
static inline void voice_struck(int32_t voice) { spu_struck |= 1 << (voice - 1); }

/* The game's own beep, hit or wave started +voice+: its pitch and loudness are written now, and it is
 * started a frame later (see above). */
static inline void game_voice_struck(int32_t voice) {
  spu_struck_by_game |= 1 << (voice - 1);
  spu_set_by_game |= 1 << (voice - 1);
}

/* The waveform number +which+ is in the wave voice now. */
static inline void spu_waveform_put_in(int32_t which) { spu_waveform = which; }

/* The mixer's voice +place+ started a recording: the game's own play (+by_game+) is started a frame
 * later, where the pass's wait ends, and a song's or an effect's note where the tune plays it
 * (Runtime::Recordings#emit_take writes the voice at once and starts it at the frame boundary). */
static inline void spu_recording_struck(int32_t place, int32_t by_game) {
  if (by_game) {
    spu_struck_by_game |= 1 << (SPU_GAME_VOICES + place);
  } else {
    spu_struck |= 1 << (SPU_GAME_VOICES + place);
  }
}

/* The game stopped the recording on the mixer's voice +place+: the program frees its place at once and
 * lets its voice go where the pass's wait ends, so the voice sounds on to the end of the frame. */
static inline void spu_recording_stopped_by_game(int32_t place) { spu_stopped_by_game |= 1 << (SPU_GAME_VOICES + place); }

static inline void spu_tell_recording(int32_t place, int32_t sounding, int32_t recording, int32_t back, int32_t step,
                                      int32_t loudness, int32_t level);

#if RG_VOICES_READ_SOUND_MEMORY
extern const int32_t rg_game_spu_rules[];
extern const int32_t rg_game_spu_loops[];
extern const int32_t rg_game_spu_memory[];
extern const int32_t rg_game_spu_recordings[];

/* Where things are in rg_game_spu_rules (see the layout above). */
#define SPU_HZ (rg_game_spu_rules[0])
#define SPU_ADSR_LOW (rg_game_spu_rules[1])
#define SPU_ADSR_HIGH (rg_game_spu_rules[2])
#define SPU_LOUDEST (rg_game_spu_rules[3])
#define SPU_MAIN_VOLUME (rg_game_spu_rules[4])
#define SPU_PITCH_ONE (rg_game_spu_rules[5])
#define SPU_PITCH_TOP (rg_game_spu_rules[6])
#define SPU_SQUARE_SAMPLES (rg_game_spu_rules[7])
#define SPU_WAVE_SAMPLES (rg_game_spu_rules[8])
#define SPU_MEMORY_BASE (rg_game_spu_rules[9])
#define SPU_MIX_FULL (rg_game_spu_rules[10])
#define SPU_SHAPE_SCALE (rg_game_spu_rules[11])
#define SPU_GAUSS (&rg_game_spu_rules[12])

/* Where things are in rg_game_spu_loops. */
#define SPU_HISS_AT 4
#define SPU_RATTLE_AT 5
#define SPU_WAVEFORMS_AT 6

/* How much of a 64th of a second a frame lasts, in 256ths (IR::Tunes::COUNTED_A_FRAME, in
 * rg_game_sound_rules after the wave voice's sixteen loudnesses and the order mask). */
#define COUNTED_A_FRAME_OF_SOUND (rg_game_sound_rules[6 + VOLUMES + 1])

/* The most frames a slide's count goes up to: far past any note's end, and short of where the frames'
 * 128ths of a second would run past what a number holds. */
#define SPU_SLIDE_FRAMES_MOST (1 << 20)

/* The flags of a block (Backends::PS1::ADPCM). */
#define BLOCK_LOOP_END 1
#define BLOCK_LOOP_REPEAT 2
#define BLOCK_LOOP_START 4

/* A halfword of sound memory, nought outside the game's loops. */
static int32_t spu_memory_at(int32_t address) {
  int32_t at = address - SPU_MEMORY_BASE;
  return at >= 0 && at < rg_game_spu_memory[0] ? rg_game_spu_memory[1 + at] : 0;
}

/* A WAVE READ FROM THE START FILE, written into its loop of sound memory (rg_sound.h). The loop was
 * made of a stand-in as the game was built (PS1::SoundMemory, waves_from_file:): the waveform's 32
 * steps seven times over, in 8 blocks of 28 samples. Each step is a four-bit level at shift 0 and
 * filter 0, as SoundMemory makes every waveform, so each block's samples are the steps less 8 as they
 * are, four to a halfword with the first in the lowest bits; a block's header keeps its flags (where
 * the loop starts and ends) and is set to shift 0 and filter 0. +memory+ is the game's own,
 * written as it starts; +waveforms+ already holds the steps (rg_music_fill_wave). */
#define SPU_WAVE_LOOP_BLOCKS 8
#define SPU_BLOCK_SAMPLES 28
#define SPU_BLOCK_HALFWORDS 8

void rg_spu_fill_wave(int32_t *memory, const int32_t *waveforms, int32_t which) {
  const int32_t *steps = waveforms + 1 + (which * SPU_WAVE_SAMPLES);
  int32_t *loop = memory + 1 + ((rg_game_spu_loops[SPU_WAVEFORMS_AT + 1 + which] * 4) - SPU_MEMORY_BASE);
  for (int32_t block = 0; block < SPU_WAVE_LOOP_BLOCKS; block++) {
    int32_t *halves = loop + (block * SPU_BLOCK_HALFWORDS);
    halves[0] &= 0xFF00;
    for (int32_t half = 1; half < SPU_BLOCK_HALFWORDS; half++) {
      int32_t coded = 0;
      for (int32_t i = 0; i < 4; i++) {
        int32_t sample = (block * SPU_BLOCK_SAMPLES) + ((half - 1) * 4) + i;
        coded |= ((steps[sample % SPU_WAVE_SAMPLES] - 8) & 0xF) << (4 * i);
      }
      halves[half] = coded;
    }
  }
}

/* --- the decoder (Beetle PSX, SPU_RunDecoder) --- */

static const int32_t filter_weights[16][2] = {{0, 0}, {60, 0}, {115, -52}, {98, -55}, {122, -60}};

static int32_t held_to_16_bits(int32_t sample) { return sample < -32768 ? -32768 : sample > 32767 ? 32767 : sample; }

static void spu_decode(spu_voice *voice) {
  if (voice->decoded >= SPU_DECODE_WHEN) return;

  if ((voice->address & 7) == 0) {
    if (voice->flags & BLOCK_LOOP_END) {
      voice->address = voice->loop & ~7;
      if (!(voice->flags & BLOCK_LOOP_REPEAT)) { /* a sound that ends goes quiet */
        voice->stage = ENVELOPE_RELEASE;
        voice->level = 0;
      }
    }
    int32_t header = spu_memory_at(voice->address);
    voice->shift = header & 0xF;
    voice->filter = (header >> 4) & 0xF;
    voice->flags = (header >> 8) & 0xFF;
    if ((voice->flags & BLOCK_LOOP_START) && !voice->loop_held) voice->loop = voice->address;
    voice->address = (voice->address + 1) & 0x3FFFF;
  }

  int32_t coded = spu_memory_at(voice->address), shift = voice->shift;
  if (shift > 12) { /* a shift no encoder writes, read as Beetle reads it */
    shift = 8;
    coded &= 0x8888;
  }
  const int32_t *weights = filter_weights[voice->filter];
  for (int32_t i = 0; i < 4; i++) {
    int32_t nibble = (coded >> (4 * i)) & 0xF;
    int32_t sample = ((nibble >= 8 ? nibble - 16 : nibble) * 4096) >> shift;
    sample += (voice->older * weights[1]) >> 6;
    sample += (voice->newer * weights[0]) >> 6;
    sample = held_to_16_bits(sample);
    voice->ring[(voice->write_at + i) & (SPU_RING - 1)] = sample;
    voice->older = voice->newer;
    voice->newer = sample;
  }
  voice->write_at = (voice->write_at + 4) & (SPU_RING - 1);
  voice->decoded += 4;
  voice->address = (voice->address + 1) & 0x3FFFF;
}

/* --- the envelope (Beetle PSX, CalcVCDelta and SPU_RunEnvelope) --- */

/* How far a step of a rate moves the level, and how fast steps come (+divide+, added to a count each
 * sample; a step when it reaches 8000h). */
static void envelope_rate(int32_t floor, int32_t speed, int32_t exponential, int32_t falling, int32_t inverted, int32_t current,
                          int32_t *step, int32_t *divide) {
  *step = 7 - (speed & 3);
  if (inverted) *step = ~*step;
  *divide = 32768;
  if (speed < 0x2C) *step = (int32_t)((uint32_t)*step << ((0x2F - speed) >> 2));
  if (speed >= 0x30) *divide >>= (speed - 0x2C) >> 2;
  if (exponential) {
    if (falling) {
      *step = (current * *step) >> 15;
    } else if ((current & 0x7FFF) >= 0x6000) {
      if (speed < 0x28) {
        *step >>= 2;
      } else if (speed >= 0x2C) {
        *divide >>= 2;
      } else {
        *step >>= 1;
        *divide >>= 1;
      }
    }
  }
  if (*divide == 0 && speed < floor) *divide = 1;
}

/* The envelope's halfwords (Beetle PSX, SPU_CacheEnvelope): the low one holds the sustain level in
 * bits 0-3, the decay rate in 4-7, the attack rate in 8-14 and whether the attack is exponential in
 * 15; the high one the release rate in 0-4, whether it is exponential in 5, the sustain rate in 6-12,
 * whether the sustain falls in 14 and whether it is exponential in 15. */
static void spu_run_envelope(spu_voice *voice) {
  int32_t low = SPU_ADSR_LOW, high = SPU_ADSR_HIGH;
  int32_t sustain_level = ((low & 0xF) + 1) << 11;
  int32_t current = (int16_t)voice->level, step = 0, divide = 0, overflow_to = 0;
  if (voice->stage == ENVELOPE_ATTACK && voice->level == 0x7FFF) voice->stage = ENVELOPE_DECAY;
  switch (voice->stage) {
  case ENVELOPE_ATTACK:
    envelope_rate(0x7F, (low >> 8) & 0x7F, (low >> 15) & 1, 0, 0, current, &step, &divide);
    overflow_to = 0x7FFF;
    break;
  case ENVELOPE_DECAY:
    envelope_rate(0x1F << 2, ((low >> 4) & 0xF) << 2, 1, 1, 1, current, &step, &divide);
    break;
  case ENVELOPE_SUSTAIN: {
    int32_t falls = (high >> 14) & 1;
    envelope_rate(0x7F, (high >> 6) & 0x7F, (high >> 15) & 1, falls, falls, current, &step, &divide);
    overflow_to = falls ? 0 : 0x7FFF;
    break;
  }
  default:
    envelope_rate(0x1F << 2, (high & 0x1F) << 2, (high >> 5) & 1, 1, 1, current, &step, &divide);
    break;
  }
  voice->divider += divide;
  if (!(voice->divider & 0x8000)) return;

  int32_t before = voice->level;
  voice->divider = 0;
  voice->level = (voice->level + step) & 0xFFFF;
  if (voice->stage == ENVELOPE_ATTACK) {
    if (((before ^ voice->level) & voice->level) & 0x8000) voice->level = overflow_to;
  } else if (voice->level & 0x8000) {
    voice->level = overflow_to;
  }
  if (voice->stage == ENVELOPE_DECAY && voice->level < sustain_level) voice->stage = ENVELOPE_SUSTAIN;
}

/* --- one sample of the chip (Beetle PSX, SPU_UpdateFromCDC) --- */

static void spu_key_on(spu_voice *voice) {
  voice->level = 0;
  voice->divider = 0;
  voice->stage = ENVELOPE_ATTACK;
  voice->flags = 0;
  voice->write_at = voice->read_at = voice->decoded = 0;
  voice->delay = SPU_PLAY_DELAY;
  voice->older = voice->newer = 0;
  voice->phase = 0;
  voice->address = voice->start & ~7;
  voice->loop_held = 0;
}

/* A voice let go and fallen silent, not waiting to start and not being started, is passed over, as
 * Beetle passes one over (its psx_spu_silent_voice_opt): it adds nothing to the sound, and what its
 * decoder holds is set afresh when it is next started. */
static void spu_tick(void) {
  int32_t sum[2] = {0, 0};
  for (int32_t n = 0; n < SPU_VOICES; n++) {
    spu_voice *voice = &spu[n];
    if (voice->level == 0 && voice->stage == ENVELOPE_RELEASE && !voice->delay && !((spu_keys_on >> n) & 1)) continue;
    if (voice->delay) voice->loop_held = 0;
    spu_decode(voice);

    int32_t at = voice->read_at, weigh = (voice->phase & 0xFFF) >> 4;
    const int32_t *gauss = SPU_GAUSS;
    int32_t sample = (voice->ring[at & 31] * gauss[0xFF - weigh] + voice->ring[(at + 1) & 31] * gauss[0x1FF - weigh] +
                      voice->ring[(at + 2) & 31] * gauss[0x100 + weigh] + voice->ring[(at + 3) & 31] * gauss[weigh]) >> 15;
    sample = (sample * (int16_t)voice->level) >> 15;
    if (heard(n + 1, 1)) {
      sum[0] += (sample * voice->heard[0]) >> 15;
      sum[1] += (sample * voice->heard[1]) >> 15;
    }
    voice->heard[0] = (voice->volume[0] & 0x7FFF) << 1;
    voice->heard[1] = (voice->volume[1] & 0x7FFF) << 1;

    if (!voice->delay) {
      spu_run_envelope(voice);
      int32_t moved = voice->phase + (voice->pitch > 0x3FFF ? 0x3FFF : voice->pitch);
      voice->phase = moved & 0xFFF;
      voice->decoded -= moved >> 12;
      voice->read_at = (voice->read_at + (moved >> 12)) & (SPU_RING - 1);
    } else {
      voice->delay--;
    }
    if ((spu_keys_off >> n) & 1 && voice->stage != ENVELOPE_RELEASE && voice->delay < 3) {
      voice->divider = 0;
      voice->stage = ENVELOPE_RELEASE;
    }
    if ((spu_keys_on >> n) & 1) spu_key_on(voice);
  }
  spu_keys_on = spu_keys_off = 0;
  for (int32_t side = 0; side < 2; side++) {
    spu_out[side] = held_to_16_bits((held_to_16_bits(sum[side]) * (SPU_MAIN_VOLUME << 1)) >> 15);
  }
}

/* --- what each game voice is told, once a frame --- */

/* The pitch register for a loop of +samples+ samples a wave, read so one wave lasts +ticks+ ticks of a
 * +clock_hz+ clock (SPUWrites#pitch_for): rounded to the nearest, and held to what the chip reads. */
static int32_t spu_pitch(int64_t clock_hz, int64_t samples, int64_t ticks) {
  int64_t over = clock_hz * samples * SPU_PITCH_ONE, under = ticks * SPU_HZ;
  int64_t pitch = ((2 * over) + under) / (2 * under);
  return (int32_t)(pitch < 1 ? 1 : pitch > SPU_PITCH_TOP ? SPU_PITCH_TOP : pitch);
}

/* A voice's volume 0 to 15 as its registers hold it (SPUWrites::VOLUME_REGISTER), from the speakers
 * its side lets it (PAN_LEFT, PAN_RIGHT, or nought for both). */
static void spu_set_volume(spu_voice *voice, int32_t value, int32_t side) {
  voice->volume[0] = side == PAN_RIGHT ? 0 : value;
  voice->volume[1] = side == PAN_LEFT ? 0 : value;
}

/* A loudness that fades or swells, a frame on (Runtime::Sound#emit_fades): its count in 256ths of a
 * 64th of a second, a step at every +hold_samples+ of them, until it reaches the top or nought and
 * stops moving. */
static void spu_fade_a_frame(fading_volume *fading) {
  if (fading->hold_samples == 0) return;
  fading->left += COUNTED_A_FRAME_OF_SOUND;
  while (fading->left >= fading->hold_samples) {
    fading->left -= fading->hold_samples;
    if (fading->up) {
      if (++fading->volume >= VOLUMES - 1) {
        fading->volume = VOLUMES - 1;
        fading->hold_samples = 0;
        return;
      }
    } else if (--fading->volume <= 0) {
      fading->volume = 0;
      fading->hold_samples = 0;
      return;
    }
  }
}

/* What the chip's voice +n+ is told this frame: +sounding+ when it has something to play, from loop
 * +loop+ at +pitch+ and volume register +value+, from the speakers +side+ lets it. */
static void spu_tell(int32_t n, int32_t sounding, int32_t loop, int32_t pitch, int32_t value, int32_t side) {
  spu_voice *voice = &spu[n];
  int32_t struck = ((spu_struck | spu_struck_waiting) >> n) & 1, waiting = (spu_struck_by_game >> n) & 1;
  if (!sounding) {
    spu_set_volume(voice, 0, 0);
    if (voice->keyed) spu_keys_off |= 1 << n;
    voice->keyed = 0;
    return;
  }
  spu_set_volume(voice, value, side);
  voice->pitch = pitch;
  if (struck) {
    voice->start = loop << 2;
    voice->loop_start = loop;
    voice->keyed = 1;
    spu_keys_on |= 1 << n;
    spu_keys_off &= ~(1 << n);
  } else if (loop != voice->loop_start && voice->keyed && !waiting) { /* a new width: its loop taken up as the one playing comes round */
    voice->loop = loop << 2;
    voice->loop_held = 1;
    voice->loop_start = loop;
  }
}

/* WHAT THE MIXER'S VOICE +place+ PLAYS, told to the chip's voice for it once a frame: +sounding+, and
 * if so +recording+ (the mixer's number) read +step+ of its samples for each of the mix's, going +back+
 * at its end, at +loudness+ out of the mix's full and its shape at +level+. The voice reads the
 * recording's loop for that way back out of sound memory at a sixteenth of the step (the mix runs at
 * the chip's own 44100 a second, so a step of 65536 is a pitch of 1000h), at a loudness scaled by the
 * level as Runtime::Recordings#emit_loudness scales it: the level's top bit added back, so full is
 * the whole loudness. A way the game never plays it (nowhere in sound memory) is silent. */
static inline void spu_tell_recording(int32_t place, int32_t sounding, int32_t recording, int32_t back, int32_t step,
                                      int32_t loudness, int32_t level) {
  if (!sounding && ((spu_stopped_by_game >> (SPU_GAME_VOICES + place)) & 1)) return; /* let go a frame later */
  int32_t loop = -1;
  if (sounding && recording >= 0 && recording < rg_game_spu_recordings[0]) {
    const int32_t *ways = &rg_game_spu_recordings[1 + (recording * 3)];
    loop = back == 0 ? ways[0] : back == ways[1] ? ways[2] : -1;
  }
  int32_t pitch = (step + 8) >> 4;
  int32_t value = ((level + (level >> 7)) * ((loudness * SPU_LOUDEST) / SPU_MIX_FULL)) >> SPU_SHAPE_SCALE;
  spu_tell(SPU_GAME_VOICES + place, loop >= 0, loop, pitch < 1 ? 1 : pitch > SPU_PITCH_TOP ? SPU_PITCH_TOP : pitch, value, 0);
}

/* THE 128THS OF A SECOND +frame+ FRAMES COME TO, counted from a note's start (SongTable#slide_record):
 * the program's player steps a slide by the frames since its note started, as the song table worked
 * them out, where the Game Boy's voice steps on a clock of its own. */
static int32_t slide_ticks_in(int32_t frame) { return (frame * COUNTED_A_FRAME_OF_SOUND) >> 7; }

/* A square voice's slide a frame on: as many steps as the frame's 128ths of a second hold, each to
 * where the voice's own slide takes it, and the voice off once it runs off the top. */
static void spu_slide_a_frame(square_voice *square, int32_t *frame) {
  int32_t every = slide_step_ticks(square->slide);
  if (*frame > 0 && every != 0 && (square->slide & SLIDE_SHIFT_BITS) != 0) {
    int32_t steps = (slide_ticks_in(*frame) / every) - (slide_ticks_in(*frame - 1) / every);
    for (; steps > 0 && square->wave_ticks != 0; steps--) {
      square->slid_ticks = slid_wave_ticks(square->slid_ticks, square->slide);
      if (square->slid_ticks == 0 || slide_runs_out(square->slid_ticks, square->slide)) square->wave_ticks = 0;
    }
  }
  if (*frame < SPU_SLIDE_FRAMES_MOST) (*frame)++;
}

static void spu_frame_begins(void) {
  for (int32_t i = 0; i < RG_SQUARE_VOICES; i++) spu_slide_a_frame(&squares[i], &spu_slide_frame[i]);
  for (int32_t i = 0; i < RG_SQUARE_VOICES; i++) {
    if (!((spu_set_by_game >> i) & 1)) spu_fade_a_frame(&squares[i].loudness);
  }
  if (!((spu_set_by_game >> (RG_NOISE_VOICE - 1)) & 1)) spu_fade_a_frame(&hiss.loudness);

  static const int32_t square_loop_of_eighths[] = {0, 0, 1, 1, 2, 2, 3, 3, 3};
  for (int32_t i = 0; i < RG_SQUARE_VOICES; i++) {
    const square_voice *square = &squares[i];
    int32_t ticks = square->slid_ticks;
    int32_t sounding = square->wave_ticks != 0 && ticks != 0;
    spu_tell(i, sounding, rg_game_spu_loops[square_loop_of_eighths[square->eighths_high & 7]],
             sounding ? spu_pitch(SQUARE_CLOCK_HZ, SPU_SQUARE_SAMPLES, ticks) : 0,
             (square->loudness.volume * SPU_LOUDEST) / 15, sides[i + 1]);
  }

  int32_t waveforms = rg_game_spu_loops[SPU_WAVEFORMS_AT];
  int32_t wave_sounding = wave.wave_ticks != 0 && spu_waveform >= 0 && spu_waveform < waveforms;
  spu_tell(RG_WAVE_VOICE - 1, wave_sounding, wave_sounding ? rg_game_spu_loops[SPU_WAVEFORMS_AT + 1 + spu_waveform] : 0,
           wave_sounding ? spu_pitch(WAVE_CLOCK_HZ, SPU_WAVE_SAMPLES, wave.wave_ticks) : 0, (wave.quarters * SPU_LOUDEST) / 4,
           sides[RG_WAVE_VOICE]);

  int32_t hiss_sounding = hiss.step_ticks != 0;
  spu_tell(RG_NOISE_VOICE - 1, hiss_sounding, rg_game_spu_loops[hiss.bits <= 7 ? SPU_RATTLE_AT : SPU_HISS_AT],
           hiss_sounding ? spu_pitch(NOISE_CLOCK_HZ, 1, hiss.step_ticks) : 0, (hiss.loudness.volume * SPU_LOUDEST) / 15,
           sides[RG_NOISE_VOICE]);
  rg_hook_recordings_told();
  spu_struck_waiting = spu_struck_by_game;
  spu_struck = spu_struck_by_game = spu_set_by_game = spu_stopped_by_game = 0;
}

/* The sound of a frame, made by the chip (rg_sound_render_frame's twin). */
static int32_t spu_render_frame(int16_t *left, int16_t *right) {
  sample_carry += (uint64_t)RG_SOUND_RATE * RG_CONSOLE_TICKS_A_FRAME;
  int32_t count = (int32_t)(sample_carry / RG_CONSOLE_TICKS_A_SECOND);
  sample_carry %= RG_CONSOLE_TICKS_A_SECOND;

  spu_frame_begins();
  for (int32_t i = 0; i < count; i++) {
    spu_carry += SPU_HZ;
    while (spu_carry >= RG_SOUND_RATE) {
      spu_carry -= RG_SOUND_RATE;
      spu_tick();
    }
    left[i] = (int16_t)spu_out[0];
    right[i] = (int16_t)spu_out[1];
  }
  return count;
}
#else
static inline void spu_tell_recording(int32_t place, int32_t sounding, int32_t recording, int32_t back, int32_t step,
                                      int32_t loudness, int32_t level) {
  (void)place, (void)sounding, (void)recording, (void)back, (void)step, (void)loudness, (void)level;
}
#endif

/* --- the state image --- */

/* The chip's fields (Computer::StateFields "sound.spu"): the strikes, keys, carry, newest sample and
 * waveform, then each voice's. Written on every console, so a build of any console reads an image
 * of another's: where the voices are the Game Boy's, every one of them is nought. */
enum { SPU_GENERAL_NUMBERS = 13, SPU_CARRY_AT = 6, SPU_VOICE_FIELDS = 24, SPU_VOICE_NUMBERS = SPU_VOICE_FIELDS + SPU_RING,
       SPU_STATE_NUMBERS = SPU_GENERAL_NUMBERS + (SPU_VOICES * SPU_VOICE_NUMBERS) };

static void rg_spu_visit_state(void) {
  int32_t *general[SPU_GENERAL_NUMBERS] = {&spu_struck, &spu_struck_by_game, &spu_struck_waiting, &spu_set_by_game, &spu_keys_on,
                                           &spu_keys_off, &spu_carry, &spu_out[0], &spu_out[1], &spu_waveform,
                                           &spu_slide_frame[0], &spu_slide_frame[1], &spu_stopped_by_game};
  int64_t numbers[SPU_STATE_NUMBERS];
  int64_t *at = numbers;
  for (int32_t i = 0; i < SPU_GENERAL_NUMBERS; i++) *at++ = *general[i];
  for (int32_t n = 0; n < SPU_VOICES; n++) {
    const spu_voice *v = &spu[n];
    int64_t fields[SPU_VOICE_FIELDS] = {v->start,    v->loop,     v->loop_held, v->pitch,  v->volume[0], v->volume[1],
                                        v->heard[0], v->heard[1], v->address,   v->flags,  v->shift,     v->filter,
                                        v->older,    v->newer,    v->write_at,  v->read_at, v->decoded,  v->delay,
                                        v->phase,    v->level,    v->divider,   v->stage,  v->keyed,     v->loop_start};
    for (int32_t i = 0; i < SPU_VOICE_FIELDS; i++) *at++ = fields[i];
    for (int32_t i = 0; i < SPU_RING; i++) *at++ = v->ring[i];
  }
  rg_state_numbers("sound.spu", numbers, SPU_STATE_NUMBERS);
  if (numbers[SPU_CARRY_AT] < 0 || numbers[SPU_CARRY_AT] >= RG_SOUND_RATE) rg_state_refuse_damaged("the sound chip is somewhere it cannot be");

  at = numbers;
  for (int32_t i = 0; i < SPU_GENERAL_NUMBERS; i++) *general[i] = (int32_t)*at++;
  for (int32_t n = 0; n < SPU_VOICES; n++) {
    spu_voice *v = &spu[n];
    int32_t f[SPU_VOICE_FIELDS];
    for (int32_t i = 0; i < SPU_VOICE_FIELDS; i++) f[i] = (int32_t)*at++;
    if (f[14] < 0 || f[14] >= SPU_RING || f[15] < 0 || f[15] >= SPU_RING || f[21] < ENVELOPE_RELEASE || f[21] > ENVELOPE_SUSTAIN ||
        f[10] < 0 || f[10] > 15 || f[11] < 0 || f[11] > 15)
      rg_state_refuse_damaged("a voice of the sound chip is part way through a sound it cannot be");
    *v = (spu_voice){.start = f[0], .loop = f[1], .loop_held = f[2], .pitch = f[3], .volume = {f[4], f[5]}, .heard = {f[6], f[7]},
                     .address = f[8], .flags = f[9], .shift = f[10], .filter = f[11], .older = f[12], .newer = f[13], .write_at = f[14],
                     .read_at = f[15], .decoded = f[16], .delay = f[17], .phase = f[18], .level = f[19], .divider = f[20], .stage = f[21],
                     .keyed = f[22], .loop_start = f[23]};
    for (int32_t i = 0; i < SPU_RING; i++) v->ring[i] = (int32_t)*at++;
  }
}
