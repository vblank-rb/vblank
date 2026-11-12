# THE PLAYSTATION'S SOUND CHIP, for a game built as a console whose voices read loops out of sound
# memory (RG_VOICES_READ_SOUND_MEMORY). The rules are native/runtime/rg_spu.c's, rule for rule; that
# file says how the chip plays the game's four voices, what Beetle PSX and psx-spx each rule comes from,
# and the layout of @rg_game_spu_rules, @rg_game_spu_loops and @rg_game_spu_memory, which this one reads
# the same way. Ruby's >> rounds down as the C's does on a number below nought, so the shifts are the C's.

RG_SPU_GAME_VOICES = 4 # The game's four voices, then one for each of the mixer's (rg_spu.c says why)
RG_SPU_RECORDING_VOICES = 16
RG_SPU_VOICES = RG_SPU_GAME_VOICES + RG_SPU_RECORDING_VOICES
RG_SPU_RING = 32 # The decoder's ring of samples
RG_SPU_DECODE_WHEN = 11 # Fewer than this left in the ring, and it decodes four more
RG_SPU_PLAY_DELAY = 4 # The samples a voice started waits before it plays
RG_ENVELOPE_RELEASE = 0
RG_ENVELOPE_ATTACK = 1
RG_ENVELOPE_DECAY = 2
RG_ENVELOPE_SUSTAIN = 3
RG_SPU_HISS_AT = 4 # Where the hiss's loop is in @rg_game_spu_loops
RG_SPU_RATTLE_AT = 5 # ...the rattle's
RG_SPU_WAVEFORMS_AT = 6 # ...and how many waveforms there are
RG_SPU_GAUSS_AT = 12 # Where the Gaussian table starts in @rg_game_spu_rules, after a recording's full and a shape's shift
RG_SPU_SLIDE_FRAMES_MOST = 1 << 20
RG_BLOCK_LOOP_END = 1
RG_BLOCK_LOOP_REPEAT = 2
RG_BLOCK_LOOP_START = 4
RG_FILTER_WEIGHTS = Ractor.make_shareable([[0, 0], [60, 0], [115, -52], [98, -55], [122, -60], *Array.new(11) { [0, 0] }])
RG_SQUARE_LOOP_OF_EIGHTHS = [0, 0, 1, 1, 2, 2, 3, 3, 3].freeze
RG_SPU_GENERAL_NUMBERS = 13
RG_SPU_CARRY_AT = 6
RG_SPU_VOICE_FIELDS = 24

# One of the chip's voices (rg_spu.c's spu_voice says what each holds).
class RgSpuVoice
  attr_accessor :start, :loop, :loop_held, :pitch, :volume, :heard, :address, :flags, :shift, :filter, :older, :newer, :ring,
                :write_at, :read_at, :decoded, :delay, :phase, :level, :divider, :stage, :keyed, :loop_start

  def initialize
    @start = @loop = @loop_held = @pitch = @address = @flags = @shift = @filter = @older = @newer = 0
    @volume = [0, 0]
    @heard = [0, 0]
    @ring = Array.new(RG_SPU_RING, 0)
    @write_at = @read_at = @decoded = @delay = @phase = @level = @divider = @keyed = @loop_start = 0
    @stage = RG_ENVELOPE_RELEASE
  end

  # Its fields as the state image holds them, without its ring.
  def fields
    [@start, @loop, @loop_held, @pitch, @volume[0], @volume[1], @heard[0], @heard[1], @address, @flags, @shift, @filter, @older,
     @newer, @write_at, @read_at, @decoded, @delay, @phase, @level, @divider, @stage, @keyed, @loop_start]
  end

  def fields=(numbers)
    @start, @loop, @loop_held, @pitch, volume_left, volume_right, heard_left, heard_right, @address, @flags, @shift, @filter, @older,
      @newer, @write_at, @read_at, @decoded, @delay, @phase, @level, @divider, @stage, @keyed, @loop_start = numbers
    @volume = [volume_left, volume_right]
    @heard = [heard_left, heard_right]
  end
end

def rg_spu_setup
  @rg_spu = Array.new(RG_SPU_VOICES) { RgSpuVoice.new }
  @rg_spu_struck = 0 # the voices a song's notes struck this frame, a bit each
  @rg_spu_struck_by_game = 0 # ...the game's own sounds struck in the pass
  @rg_spu_struck_waiting = 0 # ...and those of the pass before
  @rg_spu_set_by_game = 0 # the voices whose loudness the pass set
  @rg_spu_stopped_by_game = 0 # the recordings' voices the game stopped in the pass
  @rg_spu_keys_on = 0
  @rg_spu_keys_off = 0
  @rg_spu_carry = 0
  @rg_spu_out = [0, 0]
  @rg_spu_waveform = 0
  @rg_spu_slide_frame = [0, 0]
end

def rg_spu_slide_started(voice)
  @rg_spu_slide_frame[voice - 1] = 0
end

def rg_voice_struck(voice)
  @rg_spu_struck |= 1 << (voice - 1)
end

def rg_game_voice_struck(voice)
  @rg_spu_struck_by_game |= 1 << (voice - 1)
  @rg_spu_set_by_game |= 1 << (voice - 1)
end

def rg_spu_waveform_put_in(which)
  @rg_spu_waveform = which
end

def rg_spu_recording_struck(place, by_game)
  if by_game
    @rg_spu_struck_by_game |= 1 << (RG_SPU_GAME_VOICES + place)
  else
    @rg_spu_struck |= 1 << (RG_SPU_GAME_VOICES + place)
  end
end

def rg_spu_recording_stopped_by_game(place)
  @rg_spu_stopped_by_game |= 1 << (RG_SPU_GAME_VOICES + place)
end

def rg_spu_memory_at(address)
  at = address - @rg_game_spu_rules[9]
  at >= 0 && at < @rg_game_spu_memory[0] ? @rg_game_spu_memory[1 + at] : 0
end

def rg_held_to_16_bits(sample)
  if sample < -32_768 then -32_768
  elsif sample > 32_767 then 32_767
  else sample
  end
end

# A number of 16 bits read as signed.
def rg_signed_16_bits(value) = ((value & 0xFFFF) ^ 0x8000) - 0x8000

# --- the decoder ---

def rg_spu_decode(voice)
  return if voice.decoded >= RG_SPU_DECODE_WHEN

  if (voice.address & 7).zero?
    if voice.flags.anybits?(RG_BLOCK_LOOP_END)
      voice.address = voice.loop & ~7
      unless voice.flags.anybits?(RG_BLOCK_LOOP_REPEAT)
        voice.stage = RG_ENVELOPE_RELEASE
        voice.level = 0
      end
    end
    header = rg_spu_memory_at(voice.address)
    voice.shift = header & 0xF
    voice.filter = (header >> 4) & 0xF
    voice.flags = (header >> 8) & 0xFF
    voice.loop = voice.address if voice.flags.anybits?(RG_BLOCK_LOOP_START) && voice.loop_held.zero?
    voice.address = (voice.address + 1) & 0x3FFFF
  end

  coded = rg_spu_memory_at(voice.address)
  shift = voice.shift
  if shift > 12
    shift = 8
    coded &= 0x8888
  end
  newer_weight, older_weight = RG_FILTER_WEIGHTS[voice.filter]
  ring = voice.ring
  4.times do |i|
    nibble = (coded >> (4 * i)) & 0xF
    sample = ((nibble >= 8 ? nibble - 16 : nibble) * 4096) >> shift
    sample += (voice.older * older_weight) >> 6
    sample += (voice.newer * newer_weight) >> 6
    sample = rg_held_to_16_bits(sample)
    ring[(voice.write_at + i) & (RG_SPU_RING - 1)] = sample
    voice.older = voice.newer
    voice.newer = sample
  end
  voice.write_at = (voice.write_at + 4) & (RG_SPU_RING - 1)
  voice.decoded += 4
  voice.address = (voice.address + 1) & 0x3FFFF
end

# --- the envelope ---

# [the step, how fast steps come] for a rate (rg_spu.c's envelope_rate).
def rg_envelope_rate(floor, speed, exponential, falling, inverted, current)
  step = 7 - (speed & 3)
  step = ~step if inverted
  divide = 32_768
  step = rg_signed_32_bits(step << ((0x2F - speed) >> 2)) if speed < 0x2C
  divide >>= (speed - 0x2C) >> 2 if speed >= 0x30
  if exponential
    if falling
      step = (current * step) >> 15
    elsif (current & 0x7FFF) >= 0x6000
      if speed < 0x28
        step >>= 2
      elsif speed >= 0x2C
        divide >>= 2
      else
        step >>= 1
        divide >>= 1
      end
    end
  end
  divide = 1 if divide.zero? && speed < floor
  [step, divide]
end

def rg_signed_32_bits(value) = ((value & 0xFFFF_FFFF) ^ 0x8000_0000) - 0x8000_0000

def rg_spu_run_envelope(voice)
  low = @rg_game_spu_rules[1]
  high = @rg_game_spu_rules[2]
  sustain_level = ((low & 0xF) + 1) << 11
  current = rg_signed_16_bits(voice.level)
  overflow_to = 0
  voice.stage = RG_ENVELOPE_DECAY if voice.stage == RG_ENVELOPE_ATTACK && voice.level == 0x7FFF
  step, divide = case voice.stage
                 when RG_ENVELOPE_ATTACK
                   overflow_to = 0x7FFF
                   rg_envelope_rate(0x7F, (low >> 8) & 0x7F, low[15] == 1, false, false, current)
                 when RG_ENVELOPE_DECAY
                   rg_envelope_rate(0x1F << 2, ((low >> 4) & 0xF) << 2, true, true, true, current)
                 when RG_ENVELOPE_SUSTAIN
                   falls = high[14] == 1
                   overflow_to = falls ? 0 : 0x7FFF
                   rg_envelope_rate(0x7F, (high >> 6) & 0x7F, high[15] == 1, falls, falls, current)
                 else
                   rg_envelope_rate(0x1F << 2, (high & 0x1F) << 2, high[5] == 1, true, true, current)
                 end
  voice.divider += divide
  return unless voice.divider.anybits?(0x8000)

  before = voice.level
  voice.divider = 0
  voice.level = (voice.level + step) & 0xFFFF
  if voice.stage == RG_ENVELOPE_ATTACK
    voice.level = overflow_to if ((before ^ voice.level) & voice.level).anybits?(0x8000)
  elsif voice.level.anybits?(0x8000)
    voice.level = overflow_to
  end
  voice.stage = RG_ENVELOPE_SUSTAIN if voice.stage == RG_ENVELOPE_DECAY && voice.level < sustain_level
end

# --- one sample of the chip ---

def rg_spu_key_on(voice)
  voice.level = 0
  voice.divider = 0
  voice.stage = RG_ENVELOPE_ATTACK
  voice.flags = 0
  voice.write_at = voice.read_at = voice.decoded = 0
  voice.delay = RG_SPU_PLAY_DELAY
  voice.older = voice.newer = 0
  voice.phase = 0
  voice.address = voice.start & ~7
  voice.loop_held = 0
end

def rg_spu_tick
  rules = @rg_game_spu_rules
  sum_left = sum_right = 0
  n = 0
  while n < RG_SPU_VOICES
    voice = @rg_spu[n]
    if voice.level.zero? && voice.stage == RG_ENVELOPE_RELEASE && voice.delay.zero? && @rg_spu_keys_on[n].zero?
      n += 1
      next
    end
    voice.loop_held = 0 if voice.delay != 0
    rg_spu_decode(voice)

    at = voice.read_at
    weigh = (voice.phase & 0xFFF) >> 4
    ring = voice.ring
    sample = ((ring[at & 31] * rules[RG_SPU_GAUSS_AT + 0xFF - weigh]) + (ring[(at + 1) & 31] * rules[RG_SPU_GAUSS_AT + 0x1FF - weigh]) +
              (ring[(at + 2) & 31] * rules[RG_SPU_GAUSS_AT + 0x100 + weigh]) + (ring[(at + 3) & 31] * rules[RG_SPU_GAUSS_AT + weigh])) >> 15
    sample = (sample * rg_signed_16_bits(voice.level)) >> 15
    if @rg_heard_only.zero? || @rg_heard_only == n + 1
      sum_left += (sample * voice.heard[0]) >> 15
      sum_right += (sample * voice.heard[1]) >> 15
    end
    voice.heard[0] = (voice.volume[0] & 0x7FFF) << 1
    voice.heard[1] = (voice.volume[1] & 0x7FFF) << 1

    if voice.delay.zero?
      rg_spu_run_envelope(voice)
      moved = voice.phase + (voice.pitch > 0x3FFF ? 0x3FFF : voice.pitch)
      voice.phase = moved & 0xFFF
      voice.decoded -= moved >> 12
      voice.read_at = (voice.read_at + (moved >> 12)) & (RG_SPU_RING - 1)
    else
      voice.delay -= 1
    end
    if @rg_spu_keys_off[n] == 1 && voice.stage != RG_ENVELOPE_RELEASE && voice.delay < 3
      voice.divider = 0
      voice.stage = RG_ENVELOPE_RELEASE
    end
    rg_spu_key_on(voice) if @rg_spu_keys_on[n] == 1
    n += 1
  end
  @rg_spu_keys_on = @rg_spu_keys_off = 0
  main = rules[4] << 1
  @rg_spu_out[0] = rg_held_to_16_bits((rg_held_to_16_bits(sum_left) * main) >> 15)
  @rg_spu_out[1] = rg_held_to_16_bits((rg_held_to_16_bits(sum_right) * main) >> 15)
end

# --- what each game voice is told, once a frame ---

def rg_spu_pitch(clock_hz, samples, ticks)
  over = clock_hz * samples * @rg_game_spu_rules[5]
  under = ticks * @rg_game_spu_rules[0]
  pitch = ((2 * over) + under) / (2 * under)
  pitch.clamp(1, @rg_game_spu_rules[6])
end

def rg_spu_set_volume(voice, value, side)
  voice.volume[0] = side == RG_PAN_RIGHT ? 0 : value
  voice.volume[1] = side == RG_PAN_LEFT ? 0 : value
end

def rg_spu_fade_a_frame(fading)
  return if fading.hold_samples.zero?

  fading.left += @rg_game_sound_rules[6 + RG_VOLUMES + 1]
  while fading.left >= fading.hold_samples
    fading.left -= fading.hold_samples
    if fading.up
      fading.volume += 1
      if fading.volume >= RG_VOLUMES - 1
        fading.volume = RG_VOLUMES - 1
        fading.hold_samples = 0
        return
      end
    else
      fading.volume -= 1
      if fading.volume <= 0
        fading.volume = 0
        fading.hold_samples = 0
        return
      end
    end
  end
end

def rg_spu_tell(n, sounding, loop, pitch, value, side)
  voice = @rg_spu[n]
  struck = (@rg_spu_struck | @rg_spu_struck_waiting)[n] == 1
  waiting = @rg_spu_struck_by_game[n] == 1
  unless sounding
    rg_spu_set_volume(voice, 0, 0)
    @rg_spu_keys_off |= 1 << n if voice.keyed != 0
    voice.keyed = 0
    return
  end
  rg_spu_set_volume(voice, value, side)
  voice.pitch = pitch
  if struck
    voice.start = loop << 2
    voice.loop_start = loop
    voice.keyed = 1
    @rg_spu_keys_on |= 1 << n
    @rg_spu_keys_off &= ~(1 << n)
  elsif loop != voice.loop_start && voice.keyed != 0 && !waiting
    voice.loop = loop << 2
    voice.loop_held = 1
    voice.loop_start = loop
  end
end

def rg_slide_ticks_in(frame) = (frame * @rg_game_sound_rules[6 + RG_VOLUMES + 1]) >> 7

def rg_spu_slide_a_frame(square, i)
  every = RgSquare.slide_step_ticks(square.slide)
  frame = @rg_spu_slide_frame[i]
  if frame > 0 && every != 0 && (square.slide & RG_SLIDE_SHIFT_BITS) != 0
    steps = (rg_slide_ticks_in(frame) / every) - (rg_slide_ticks_in(frame - 1) / every)
    while steps > 0 && square.wave_ticks != 0
      square.slid_ticks = RgSquare.slid_wave_ticks(square.slid_ticks, square.slide)
      square.wave_ticks = 0 if square.slid_ticks.zero? || RgSquare.slide_runs_out?(square.slid_ticks, square.slide)
      steps -= 1
    end
  end
  @rg_spu_slide_frame[i] = frame + 1 if frame < RG_SPU_SLIDE_FRAMES_MOST
end

def rg_spu_frame_begins
  loops = @rg_game_spu_loops
  loudest = @rg_game_spu_rules[3]
  @rg_squares.each_with_index { |square, i| rg_spu_slide_a_frame(square, i) }
  @rg_squares.each_with_index { |square, i| rg_spu_fade_a_frame(square.loudness) if @rg_spu_set_by_game[i].zero? }
  rg_spu_fade_a_frame(@rg_hiss.loudness) if @rg_spu_set_by_game[RG_NOISE_VOICE - 1].zero?

  @rg_squares.each_with_index do |square, i|
    ticks = square.slid_ticks
    sounding = square.wave_ticks != 0 && ticks != 0
    rg_spu_tell(i, sounding, loops[RG_SQUARE_LOOP_OF_EIGHTHS[square.eighths_high & 7]],
                sounding ? rg_spu_pitch(rg_square_clock_hz, @rg_game_spu_rules[7], ticks) : 0,
                square.loudness.volume * loudest / 15, @rg_sides[i + 1])
  end

  wave = @rg_wave
  wave_sounding = wave.wave_ticks != 0 && @rg_spu_waveform >= 0 && @rg_spu_waveform < loops[RG_SPU_WAVEFORMS_AT]
  rg_spu_tell(RG_WAVE_VOICE - 1, wave_sounding, wave_sounding ? loops[RG_SPU_WAVEFORMS_AT + 1 + @rg_spu_waveform] : 0,
              wave_sounding ? rg_spu_pitch(rg_wave_clock_hz, @rg_game_spu_rules[8], wave.wave_ticks) : 0, wave.quarters * loudest / 4,
              @rg_sides[RG_WAVE_VOICE])

  hiss = @rg_hiss
  hiss_sounding = hiss.step_ticks != 0
  rg_spu_tell(RG_NOISE_VOICE - 1, hiss_sounding, loops[hiss.bits <= 7 ? RG_SPU_RATTLE_AT : RG_SPU_HISS_AT],
              hiss_sounding ? rg_spu_pitch(rg_noise_clock_hz, 1, hiss.step_ticks) : 0, hiss.loudness.volume * loudest / 15,
              @rg_sides[RG_NOISE_VOICE])
  rg_hook_recordings_told
  @rg_spu_struck_waiting = @rg_spu_struck_by_game
  @rg_spu_struck = @rg_spu_struck_by_game = @rg_spu_set_by_game = @rg_spu_stopped_by_game = 0
end

# The sound of a frame, made by the chip (rg_sound_render_frame's twin).
def rg_spu_render_frame
  @rg_sample_carry += RG_SOUND_RATE * RG_CONSOLE_TICKS_A_FRAME
  count = @rg_sample_carry / RG_CONSOLE_TICKS_A_SECOND
  @rg_sample_carry %= RG_CONSOLE_TICKS_A_SECOND

  rg_spu_frame_begins
  chip_hz = @rg_game_spu_rules[0]
  left = Array.new(count)
  right = Array.new(count)
  out = @rg_spu_out
  i = 0
  while i < count
    @rg_spu_carry += chip_hz
    while @rg_spu_carry >= RG_SOUND_RATE
      @rg_spu_carry -= RG_SOUND_RATE
      rg_spu_tick
    end
    left[i] = out[0]
    right[i] = out[1]
    i += 1
  end
  [left, right]
end

# What the mixer's voice +place+ plays, told to the chip's voice for it (rg_spu.c's spu_tell_recording).
def rg_spu_tell_recording(place, sounding, recording, back, step, loudness, level)
  sounding = sounding && sounding != 0
  return if !sounding && @rg_spu_stopped_by_game[RG_SPU_GAME_VOICES + place] == 1

  ways = @rg_game_spu_recordings
  loop = -1
  if sounding && recording >= 0 && recording < ways[0]
    at = 1 + (recording * 3)
    loop = if back.zero? then ways[at]
           elsif back == ways[at + 1] then ways[at + 2]
           else -1
           end
  end
  rules = @rg_game_spu_rules
  pitch = ((step + 8) >> 4).clamp(1, rules[6])
  value = ((level + (level >> 7)) * (loudness * rules[3] / rules[10])) >> rules[11]
  rg_spu_tell(RG_SPU_GAME_VOICES + place, loop >= 0, loop, pitch, value, 0)
end

# --- the state image (rg_spu.c says what each field holds) ---

def rg_spu_visit_state
  general = [@rg_spu_struck, @rg_spu_struck_by_game, @rg_spu_struck_waiting, @rg_spu_set_by_game, @rg_spu_keys_on, @rg_spu_keys_off,
             @rg_spu_carry, *@rg_spu_out, @rg_spu_waveform, *@rg_spu_slide_frame, @rg_spu_stopped_by_game]
  numbers = rg_state_numbers("sound.spu", general + @rg_spu.flat_map { |voice| voice.fields + voice.ring })
  rg_state_refuse_damaged("the sound chip is somewhere it cannot be") unless numbers[RG_SPU_CARRY_AT].between?(0, RG_SOUND_RATE - 1)

  @rg_spu_struck, @rg_spu_struck_by_game, @rg_spu_struck_waiting, @rg_spu_set_by_game, @rg_spu_keys_on, @rg_spu_keys_off,
    @rg_spu_carry, out_left, out_right, @rg_spu_waveform, first_slide, second_slide, @rg_spu_stopped_by_game = numbers[0, RG_SPU_GENERAL_NUMBERS]
  @rg_spu_out = [out_left, out_right]
  @rg_spu_slide_frame = [first_slide, second_slide]
  numbers.drop(RG_SPU_GENERAL_NUMBERS).each_slice(RG_SPU_VOICE_FIELDS + RG_SPU_RING).each_with_index do |slice, n|
    fields = slice[0, RG_SPU_VOICE_FIELDS]
    unless fields[14].between?(0, RG_SPU_RING - 1) && fields[15].between?(0, RG_SPU_RING - 1) &&
           fields[21].between?(RG_ENVELOPE_RELEASE, RG_ENVELOPE_SUSTAIN) && fields[10].between?(0, 15) && fields[11].between?(0, 15)
      rg_state_refuse_damaged("a voice of the sound chip is part way through a sound it cannot be")
    end
    @rg_spu[n].fields = fields
    @rg_spu[n].ring = slice[RG_SPU_VOICE_FIELDS, RG_SPU_RING]
  end
end
