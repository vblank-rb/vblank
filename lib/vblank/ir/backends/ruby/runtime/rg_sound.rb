# THE GAME'S SOUND: the four voices the game's own sounds play on (and a song's notes, when the game
# has the music feature), and the log of what was played. The rules are native/runtime/rg_sound.c's,
# rule for rule, and that file says every one of them and the layout of every table the lowering
# writes (@rg_game_beeps, ...); this one reads them the same way. Where the C keeps a pointer into
# one of those tables, this keeps the place in it. The music player and the mixer are sound
# features (runtime_features/music, runtime_features/mix): a game takes them
# in only when its steps need them, and this file calls them through the sound hooks.
#
# THE VOICES ARE A SOUND CHIP'S, not one console's: two square waves, a voice that loops a
# waveform of 32 steps, and a hiss from a row of bits. The Game Boy Advance and the Game Boy Color
# carry the same chip, and nothing here knows which of them the game was built for. Every number
# that belongs to a console comes in the game's own tables: how fast each voice's clock ticks
# (@rg_game_sound_rules), how long a frame is (RG_CONSOLE_TICKS_A_FRAME), and whether there is a
# mixer for recordings at all (the mix feature).
#
# The voices are worked out a sample at a time when a driver asks for a frame's sound
# (rg_sound_render_frame): the windowless one writes it to a file for a test. Nothing else needs
# the samples, so a driver that does not ask spends nothing on them.

RG_SOUND_RATE = 48000 # Samples a second, whatever the console: the speaker's rate, not the chip's
RG_SOUND_FRAME_MOST = 1024
RG_SQUARE_VOICES = 2
RG_WAVE_VOICE = 3
RG_NOISE_VOICE = 4

RG_FADE_STEP_BITS = 7 # A note's fade (Audio::NoteFade#bits): the 64ths of a second a step lasts
RG_FADE_UP = 8        # A note's fade: set when it swells
RG_SLIDE_DOWN = 8     # A slide's bits: set when it slides down
RG_SLIDE_SHIFT_BITS = 7 # A slide's bits: the shift
RG_SLIDE_EVERY_AT = 4 # A slide's bits: the 128ths of a second a step waits, above them
RG_SLIDE_EVERY_BITS = 7 # A slide's bits: the wait takes three bits
RG_PITCH_COUNT_TOP = 2048 # The square voices keep a pitch as this less its ticks a wave
RG_PAN_LEFT = 1 # The left speaker alone
RG_PAN_RIGHT = 2 # The right speaker alone; nought is both
RG_SLIDE_TICK_SAMPLES = RG_SOUND_RATE / 128 # The slide clock ticks 128 times a second
RG_NUMBERS_PER_BEEP = 4
RG_NUMBERS_PER_WAVE = 3
RG_NUMBERS_PER_HIT = 4
RG_BEEP_VOICE = 2
RG_WAVE_STEPS = 32
RG_VOLUMES = 16

# How much one step of loudness moves the speaker, and one step of the mixer's byte: two voices at
# their loudest swing through half of what a sample holds, and so does the mixer at its loudest.
RG_STEP_SIZE = 1092
RG_MIX_STEP = 128

# A loudness that fades, or swells: 0 to 15 now, the samples it holds each step for (0 never
# fades), the samples left until the next step, and whether it counts up. +fade+ is the voice's
# four bits of it (rg_sound.c's volume_from says how).
class RgFading
  attr_accessor :volume, :hold_samples, :left, :up

  # Where the voices read sound memory a step is counted a frame at a time (rg_spu.rb), in 256ths of
  # a 64th of a second from nought (rg_sound.c's volume_from says why).
  def initialize(volume, fade)
    @volume = volume
    @up = fade.anybits?(RG_FADE_UP)
    if RG_VOICES_READ_SOUND_MEMORY
      @hold_samples = (fade & RG_FADE_STEP_BITS) * 256
      @left = 0
    else
      @hold_samples = (fade & RG_FADE_STEP_BITS) * RG_SOUND_RATE / 64
      @left = @hold_samples
    end
  end

  # One sample has gone by.
  def fade_one_sample
    return if @hold_samples == 0

    @left -= 1
    return if @left > 0

    @left = @hold_samples
    @volume += 1 if @up && @volume < RG_VOLUMES - 1
    @volume -= 1 if !@up && @volume > 0
  end

  # Silent for good: at no volume, and not swelling out of it.
  def stays_silent? = @volume == 0 && !@up
end

# A square voice: ticks one wave lasts (0 has nothing to play), how many eighths of it are high,
# its loudness, which eighth it is in, and how far through it in ticks times samples a second. And
# how its pitch slides (0 holds it), the slide clock's ticks until its next step, and the wave a
# slide has moved it to, which it takes up at its next eighth (rg_sound.c's own section says how).
class RgSquare
  attr_accessor :wave_ticks, :eighths_high, :loudness, :eighth, :eighth_progress, :slide, :slide_left, :slid_ticks

  # A voice is at the top of its wave once, when it is made; #start leaves its place alone.
  def initialize
    @eighth = 0
    @eighth_progress = 0
    start(0, 0, 0, 0, 0)
  end

  # A note starts where the voice is in its wave, as the chip does (rg_sound.c's square_start says
  # why).
  def start(wave_ticks, eighths_high, volume, fade, slide)
    @wave_ticks = wave_ticks != 0 && RgSquare.slide_runs_out?(wave_ticks, slide) ? 0 : wave_ticks
    @slid_ticks = wave_ticks
    @eighths_high = eighths_high
    @loudness = RgFading.new(volume, fade)
    @slide = slide
    @slide_left = RgSquare.slide_step_ticks(slide)
  end

  # The slide clock has ticked.
  def slide_one_tick
    return if RgSquare.slide_step_ticks(@slide) == 0 || @wave_ticks == 0 || (@slide_left -= 1) > 0

    @slide_left = RgSquare.slide_step_ticks(@slide)
    return if (@slide & RG_SLIDE_SHIFT_BITS) == 0

    @slid_ticks = RgSquare.slid_wave_ticks(@slid_ticks, @slide)
    @wave_ticks = 0 if @slid_ticks == 0 || RgSquare.slide_runs_out?(@slid_ticks, @slide)
  end

  def self.slide_step_ticks(slide) = (slide >> RG_SLIDE_EVERY_AT) & RG_SLIDE_EVERY_BITS

  def self.slid_wave_ticks(wave_ticks, slide)
    count = RG_PITCH_COUNT_TOP - wave_ticks
    by = count >> (slide & RG_SLIDE_SHIFT_BITS)
    following = slide.anybits?(RG_SLIDE_DOWN) ? count - by : count + by
    following >= RG_PITCH_COUNT_TOP ? 0 : RG_PITCH_COUNT_TOP - following
  end

  def self.slide_runs_out?(wave_ticks, slide)
    (slide & RG_SLIDE_SHIFT_BITS) != 0 && !slide.anybits?(RG_SLIDE_DOWN) && slid_wave_ticks(wave_ticks, slide) == 0
  end
end

# The wave voice: the waveform it loops, whether it is switched on, ticks all its steps last,
# its loudness in quarters of each step, every step at that loudness added up, which step it is
# on, and how far through it.
class RgWave
  attr_accessor :steps, :switched_on, :wave_ticks, :quarters, :cut_sum, :step, :step_progress

  def initialize
    @steps = Array.new(RG_WAVE_STEPS, 0)
    @switched_on = false
    @wave_ticks = 0
    @quarters = 0
    @cut_sum = 0
    @step = 0
    @step_progress = 0
  end
end

# The noise voice: ticks one step of the hiss lasts, the bits in its row, the row, which way the
# last bit to fall off left the voice and which way it stood when the speaker was last handed it,
# its loudness, and how far through a step and to the next hand-over.
class RgHiss
  attr_accessor :step_ticks, :bits, :row, :high, :heard_high, :loudness, :row_progress, :hand_progress

  def initialize = start(0, 0, 0, 0)

  def start(step_ticks, bits, volume, fade)
    @step_ticks = step_ticks
    @bits = bits
    @row = (1 << bits) - 1
    @high = 0
    @heard_high = 0
    @loudness = RgFading.new(volume, fade)
    @row_progress = 0
    @hand_progress = 0
  end
end

def rg_sound_setup
  @rg_squares = Array.new(RG_SQUARE_VOICES) { RgSquare.new }
  @rg_wave = RgWave.new
  @rg_hiss = RgHiss.new
  @rg_heard_only = 0 # a test listening to one voice: its number, or 0 for every voice
  @rg_sides = [0] * (RG_NOISE_VOICE + 1) # each voice's speaker: RG_PAN_LEFT, RG_PAN_RIGHT, or 0 for both
  @rg_sample_carry = 0 # the part of a sample left over from the last frame, in console cycles
  @rg_slide_clock = 0  # samples since the slide clock last ticked (rg_sound.c's slide_clock)
  @rg_loaded_waveform = -1 # the waveform a song's part put in the wave voice, or -1 when none did
  rg_spu_setup
end

def rg_square_clock_hz = @rg_game_sound_rules[0]
def rg_wave_clock_hz = @rg_game_sound_rules[1]
def rg_noise_clock_hz = @rg_game_sound_rules[2]
def rg_output_hz = @rg_game_sound_rules[3]

# C's division, which drops the fraction toward nought: Ruby's rounds down, which differs for a
# sample below nought.
def rg_sound_quotient(numerator, denominator)
  numerator < 0 ? -(-numerator / denominator) : numerator / denominator
end

# --- the square voices ---

def rg_square_start(voice, wave_ticks, eighths_high, volume, fade, slide)
  @rg_squares[voice - 1].start(wave_ticks, eighths_high, volume, fade, slide)
  rg_spu_slide_started(voice)
end

# Which of the eight parts of a wave are high, for each tone, in the chip's own order.
def rg_eighth_is_high(eighths_high, eighth)
  case eighths_high
  when 1 then eighth == 7
  when 2 then eighth == 0 || eighth == 7
  when 4 then eighth == 0 || eighth >= 5
  else eighth >= 1 && eighth <= 6
  end
end

# One sample of a square voice, high and low set either side of nought by how long each lasts.
def rg_square_sample(square)
  return 0 if square.wave_ticks == 0 || square.loudness.stays_silent?

  high = rg_eighth_is_high(square.eighths_high, square.eighth)
  sample = rg_sound_quotient(RG_STEP_SIZE * square.loudness.volume * (high ? 8 - square.eighths_high : -square.eighths_high), 8)

  eighth_length = square.wave_ticks * RG_SOUND_RATE
  square.eighth_progress += rg_square_clock_hz * 8
  while square.eighth_progress >= eighth_length
    square.eighth_progress -= eighth_length
    square.eighth = (square.eighth + 1) & 7
    square.wave_ticks = square.slid_ticks
    eighth_length = square.wave_ticks * RG_SOUND_RATE
  end
  square.loudness.fade_one_sample
  sample
end

# --- the wave voice ---

def rg_wave_step_cut(step) = step * @rg_wave.quarters / 4

def rg_wave_set_loudness(quarters)
  @rg_wave.quarters = quarters
  @rg_wave.cut_sum = @rg_wave.steps.sum { |step| rg_wave_step_cut(step) }
end

# Waveform number +which+ goes into the voice, which switches it on and stops what it played.
def rg_wave_load(which)
  rg_fault("there is no waveform number #{which}") if which < 0 || which >= @rg_game_waveforms[0]
  @rg_wave.steps = @rg_game_waveforms[1 + (which * RG_WAVE_STEPS), RG_WAVE_STEPS]
  @rg_loaded_waveform = which
  rg_spu_waveform_put_in(which)
  @rg_wave.switched_on = true
  @rg_wave.wave_ticks = 0
  rg_wave_set_loudness(@rg_wave.quarters)
end

# A note from the top of the waveform, if the voice is switched on.
def rg_wave_start(wave_ticks, quarters)
  @rg_wave.wave_ticks = @rg_wave.switched_on ? wave_ticks : 0
  @rg_wave.step = 0
  @rg_wave.step_progress = 0
  rg_wave_set_loudness(quarters)
end

def rg_wave_switch_off
  @rg_wave.switched_on = false
  @rg_wave.wave_ticks = 0
end

# One sample of the wave voice, each step set either side of the middle of the whole waveform.
def rg_wave_sample
  wave = @rg_wave
  return 0 if wave.wave_ticks == 0

  sample = rg_sound_quotient(RG_STEP_SIZE * ((RG_WAVE_STEPS * rg_wave_step_cut(wave.steps[wave.step])) - wave.cut_sum),
                             RG_WAVE_STEPS)
  step_length = wave.wave_ticks * RG_SOUND_RATE
  wave.step_progress += rg_wave_clock_hz * RG_WAVE_STEPS
  while wave.step_progress >= step_length
    wave.step_progress -= step_length
    wave.step = (wave.step + 1) % RG_WAVE_STEPS
  end
  sample
end

# --- the noise voice ---

# A hit starts with every bit of the row set, which is where the emulator picks the pattern up.
def rg_noise_start(step_ticks, bits, volume, fade) = @rg_hiss.start(step_ticks, bits, volume, fade)

# One step of the hiss: the bit at the end falls off and marks which way the voice stands, and when
# it was set it is stirred back into the two places at the other end.
def rg_noise_step
  hiss = @rg_hiss
  fell = hiss.row & 1
  hiss.row >>= 1
  hiss.row ^= 3 << (hiss.bits - 2) if fell != 0
  hiss.high = fell
end

# One sample of the noise voice. The hiss steps on its own clock, but the speaker is handed it
# only so many times a second, and hears whichever way it stood then until the next time.
def rg_noise_sample
  hiss = @rg_hiss
  return 0 if hiss.step_ticks == 0 || hiss.loudness.stays_silent?

  hiss.hand_progress += rg_output_hz
  while hiss.hand_progress >= RG_SOUND_RATE
    hiss.hand_progress -= RG_SOUND_RATE
    step_length = hiss.step_ticks * rg_output_hz
    hiss.row_progress += rg_noise_clock_hz
    while hiss.row_progress >= step_length
      hiss.row_progress -= step_length
      rg_noise_step
    end
    hiss.heard_high = hiss.high
  end
  sample = rg_sound_quotient(RG_STEP_SIZE * hiss.loudness.volume * (hiss.heard_high != 0 ? 1 : -1), 2)
  hiss.loudness.fade_one_sample
  sample
end

# --- the sound of a frame ---

def rg_sound_hear_only(voice)
  @rg_heard_only = voice
end

# Whether a voice is heard from the left speaker and from the right this frame: every voice is
# heard unless the game hears only one (rg_sound_hear_only), from the sides its pan sets.
def rg_speakers_of(voice)
  heard = @rg_heard_only == 0 || @rg_heard_only == voice
  [heard && @rg_sides[voice] != RG_PAN_RIGHT, heard && @rg_sides[voice] != RG_PAN_LEFT]
end

# The sound of the frame that has just been played, as two Arrays of samples, the left speaker's
# and the right's: that frame's share of a second's, by the console's own clock, with the part of a
# sample left over carried to the next frame so no time is lost or made up.
#
# WHAT IS THE SAME FOR THE WHOLE FRAME is worked out once, before its samples: which speakers each
# voice is heard from (the voices heard and the pan are the game's to set, between frames), and
# which voices can sound at all. A voice silent as the frame starts stays silent through it, since
# only the game starts a note, and a pitch slide can stop a voice but never start one; so a silent
# voice is not asked for a sample, which would answer nought and change nothing. A sounding one is
# asked for every sample, heard or not (every voice moves on), and may fall silent on the way.
def rg_sound_render_frame
  return rg_spu_render_frame if RG_VOICES_READ_SOUND_MEMORY # rg_spu.rb

  @rg_sample_carry += RG_SOUND_RATE * RG_CONSOLE_TICKS_A_FRAME
  count = @rg_sample_carry / RG_CONSOLE_TICKS_A_SECOND
  @rg_sample_carry %= RG_CONSOLE_TICKS_A_SECOND

  # The mixer's newest slice (the mix feature's; 0 when the game has none) is stretched over the
  # frame, and heard only with every voice. Asked once a frame, never once a sample.
  mixed = @rg_heard_only == 0 ? rg_hook_mixed_slice(nil) : 0
  mixed_count = mixed == 0 ? 0 : mixed.length
  squares = @rg_squares
  sounding = []
  squares.each_with_index do |square, at|
    sounding << [square, *rg_speakers_of(at + 1)] unless square.wave_ticks == 0 || square.loudness.stays_silent?
  end
  wave_sounds = @rg_wave.wave_ticks != 0
  wave_to_left, wave_to_right = rg_speakers_of(RG_WAVE_VOICE)
  hiss = @rg_hiss
  noise_sounds = hiss.step_ticks != 0 && !hiss.loudness.stays_silent?
  noise_to_left, noise_to_right = rg_speakers_of(RG_NOISE_VOICE)
  left = Array.new(count)
  right = Array.new(count)
  i = 0
  while i < count
    if (@rg_slide_clock += 1) == RG_SLIDE_TICK_SAMPLES
      @rg_slide_clock = 0
      squares.each(&:slide_one_tick)
    end
    on_left = on_right = 0
    s = 0
    while s < sounding.length
      square, to_left, to_right = sounding[s]
      sample = rg_square_sample(square)
      on_left += sample if to_left
      on_right += sample if to_right
      s += 1
    end
    if wave_sounds
      sample = rg_wave_sample
      on_left += sample if wave_to_left
      on_right += sample if wave_to_right
    end
    if noise_sounds
      sample = rg_noise_sample
      on_left += sample if noise_to_left
      on_right += sample if noise_to_right
    end
    if mixed_count > 0 # the recordings play from both
      sample = mixed[i * mixed_count / count] * RG_MIX_STEP
      on_left += sample
      on_right += sample
    end
    left[i] = on_left < -32768 ? -32768 : (on_left > 32767 ? 32767 : on_left)
    right[i] = on_right < -32768 ? -32768 : (on_right > 32767 ? 32767 : on_right)
    i += 1
  end
  [left, right]
end

# --- the log ---

def rg_sound_log(line) = rg_driver_sound_logged(line)

# --- the sounds the game makes itself ---

def rg_sound_enabled
  rg_sound_log("enabled")
  @rg_sides.fill(0)
end

def rg_sound_beep(which)
  rg_fault("there is no beep number #{which}") if which < 0 || which >= @rg_game_beeps[0]
  beep = 1 + (which * RG_NUMBERS_PER_BEEP)
  rg_sound_log("beep #{which}")
  rg_hook_voice_taken_by_game(RG_BEEP_VOICE)
  @rg_sides[RG_BEEP_VOICE] = 0
  rg_square_start(RG_BEEP_VOICE, @rg_game_beeps[beep], @rg_game_beeps[beep + 1], @rg_game_beeps[beep + 2],
                  @rg_game_beeps[beep + 3], 0)
  rg_game_voice_struck(RG_BEEP_VOICE)
end

def rg_sound_wave(which)
  rg_fault("there is no wave number #{which}") if which < 0 || which >= @rg_game_waves[0]
  said = 1 + (which * RG_NUMBERS_PER_WAVE)
  rg_sound_log("wave #{which}")
  rg_hook_voice_taken_by_game(RG_WAVE_VOICE)
  @rg_sides[RG_WAVE_VOICE] = 0
  rg_wave_load(@rg_game_waves[said])
  rg_wave_start(@rg_game_waves[said + 1], @rg_game_waves[said + 2])
  rg_game_voice_struck(RG_WAVE_VOICE)
  @rg_loaded_waveform = -1
end

def rg_sound_stop_wave
  rg_sound_log("stop_wave")
  rg_hook_voice_taken_by_game(RG_WAVE_VOICE)
  rg_wave_switch_off
  @rg_loaded_waveform = -1
end

def rg_sound_noise(which)
  rg_fault("there is no hit number #{which}") if which < 0 || which >= @rg_game_hits[0]
  hit = 1 + (which * RG_NUMBERS_PER_HIT)
  rg_sound_log("noise #{which}")
  @rg_sides[RG_NOISE_VOICE] = 0
  rg_noise_start(@rg_game_hits[hit], @rg_game_hits[hit + 1], @rg_game_hits[hit + 2], @rg_game_hits[hit + 3])
  rg_game_voice_struck(RG_NOISE_VOICE)
end

# --- the state image (rg_sound.c says what each field holds) ---

# "sound": the part of a sample a frame carried, the slide clock, the waveform a tune last put in
# the wave voice, and which speaker each voice plays from.
RgSoundFields = Data.define(:sample_carry, :slide_clock, :loaded_waveform, :first_square_side, :second_square_side, :wave_side,
                           :noise_side)

# "sound.squares", one a square voice: its wave, the eighth it is in and how far through, its slide,
# then its loudness (now, the samples a step holds, the samples left, whether it swells).
RgSquareFields = Data.define(:wave_ticks, :eighths_high, :eighth, :eighth_progress, :slide, :slide_left, :slid_ticks,
                            :volume, :hold_samples, :samples_left, :swells)

# "sound.noise": a step's ticks, the bits in its row, the row, which way it stands and stood when
# last heard, how far through a step and to the next hand-over, then its loudness.
RgNoiseFields = Data.define(:step_ticks, :bits, :row, :high, :heard_high, :row_progress, :hand_progress,
                           :volume, :hold_samples, :samples_left, :swells)

# A loudness as a record's last four members.
def rg_loudness_members(fading)
  { volume: fading.volume, hold_samples: fading.hold_samples, samples_left: fading.left, swells: rg_state_flag(fading.up) }
end

def rg_loudness_from(fields)
  rg_state_refuse_damaged("a voice is louder than a voice can be") unless fields.volume.between?(0, RG_VOLUMES - 1)
  fading = RgFading.new(0, 0)
  fading.volume = fields.volume
  fading.hold_samples = fields.hold_samples
  fading.left = fields.samples_left
  fading.up = fields.swells != 0
  fading
end

# The console voices' fields, then each sound feature's (rg_hook_visit_sound_state).
def rg_sound_visit_state
  rg_visit_sound_fields
  rg_visit_square_fields
  rg_visit_wave_fields
  rg_visit_noise_fields
  rg_spu_visit_state
  rg_hook_visit_sound_state
end

def rg_visit_sound_fields
  fields = rg_state_record("sound", RgSoundFields.new(@rg_sample_carry, @rg_slide_clock, @rg_loaded_waveform, *@rg_sides[1..]))
  unless fields.sample_carry.between?(0, RG_CONSOLE_TICKS_A_SECOND - 1) && fields.slide_clock.between?(0, RG_SLIDE_TICK_SAMPLES - 1) &&
         fields.loaded_waveform.between?(-1, @rg_game_waveforms[0] - 1)
    rg_state_refuse_damaged("the sound is somewhere it cannot be")
  end
  sides = [fields.first_square_side, fields.second_square_side, fields.wave_side, fields.noise_side]
  unless sides.all? { |side| [0, RG_PAN_LEFT, RG_PAN_RIGHT].include?(side) }
    rg_state_refuse_damaged("a voice plays from a speaker there is not")
  end
  @rg_sample_carry = fields.sample_carry
  @rg_slide_clock = fields.slide_clock
  @rg_loaded_waveform = fields.loaded_waveform
  @rg_sides = [0, *sides]
end

def rg_visit_square_fields
  square_fields = @rg_squares.map do |s|
    RgSquareFields.new(wave_ticks: s.wave_ticks, eighths_high: s.eighths_high, eighth: s.eighth, eighth_progress: s.eighth_progress,
                      slide: s.slide, slide_left: s.slide_left, slid_ticks: s.slid_ticks, **rg_loudness_members(s.loudness))
  end
  rg_state_records("sound.squares", square_fields, RgSquareFields, RG_SQUARE_VOICES).each_with_index do |fields, i|
    unless fields.eighth.between?(0, 7) && fields.wave_ticks >= 0 && fields.slid_ticks >= 0
      rg_state_refuse_damaged("a square voice is part way through a wave it cannot be")
    end
    square = @rg_squares[i]
    square.wave_ticks = fields.wave_ticks
    square.eighths_high = fields.eighths_high
    square.eighth = fields.eighth
    square.eighth_progress = fields.eighth_progress
    square.slide = fields.slide
    square.slide_left = fields.slide_left
    square.slid_ticks = fields.slid_ticks
    square.loudness = rg_loudness_from(fields)
  end
end

# "sound.wave": the voice's 32 steps, whether it is on, its wave's ticks, its quarters, their sum,
# the step it is on and how far through.
def rg_visit_wave_fields
  wave = @rg_wave
  numbers = rg_state_numbers("sound.wave", [*wave.steps, rg_state_flag(wave.switched_on), wave.wave_ticks, wave.quarters,
                                            wave.cut_sum, wave.step, wave.step_progress])
  switched_on, wave_ticks, quarters, cut_sum, step, step_progress = numbers[RG_WAVE_STEPS..]
  unless step.between?(0, RG_WAVE_STEPS - 1) && wave_ticks >= 0
    rg_state_refuse_damaged("the wave voice is on a step it does not have")
  end
  wave.steps = numbers[0, RG_WAVE_STEPS]
  wave.switched_on = switched_on != 0
  wave.wave_ticks = wave_ticks
  wave.quarters = quarters
  wave.cut_sum = cut_sum
  wave.step = step
  wave.step_progress = step_progress
end

def rg_visit_noise_fields
  hiss = @rg_hiss
  fields = rg_state_record("sound.noise", RgNoiseFields.new(
                                           step_ticks: hiss.step_ticks, bits: hiss.bits, row: hiss.row, high: hiss.high,
                                           heard_high: hiss.heard_high, row_progress: hiss.row_progress,
                                           hand_progress: hiss.hand_progress, **rg_loudness_members(hiss.loudness)
                                         ))
  unless fields.step_ticks >= 0 && (fields.step_ticks.zero? || fields.bits.between?(2, 31)) && fields.row.between?(0, 0xFFFF_FFFF)
    rg_state_refuse_damaged("the noise voice holds a row of bits it cannot")
  end
  hiss.step_ticks = fields.step_ticks
  hiss.bits = fields.bits
  hiss.row = fields.row
  hiss.high = fields.high
  hiss.heard_high = fields.heard_high
  hiss.row_progress = fields.row_progress
  hiss.hand_progress = fields.hand_progress
  hiss.loudness = rg_loudness_from(fields)
end
