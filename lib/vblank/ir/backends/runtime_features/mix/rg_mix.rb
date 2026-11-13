# frozen_string_literal: true

# THE MIXER: several recordings sounding at once, added together a frame at a time into one stream
# of sound, the way a console that mixes in software does it. The arithmetic is runtime_features/
# mix/rg_mix.c's, kept to the bit, and that file says it and the layout of @rg_game_mix and
# @rg_game_recordings. Joined into the runtime's class for a game that has a recording. A console
# with no mixer has none of this to do: its game's @rg_game_mix starts with nought, and every
# frame here then does nothing.
#
# The sound runtime calls it through the sound hooks: rg_mix_sound_frame as a frame begins,
# rg_mix_sound_frame_ended after the tune has played, and rg_mix_mixed_slice and
# rg_mix_mixed_sample_shift for the render.
#
# The interpreter's numbers are Ruby's whole numbers, and so are these, so a product too big for
# 32 bits is exact here as it is there.

RG_MIX_VOICES_MOST = 16
RG_NUMBERS_PER_RECORDING = 7

# Which part of its shape a note is in, and the frame after it has fallen to nothing.
RG_SHAPE_CLIMBING = 0
RG_SHAPE_HOLDING = 1
RG_SHAPE_FALLING = 2
RG_SHAPE_DONE = 3

# Whose a voice is: the game's own sound, a part of the song playing, or a part of a sound effect.
RG_MIX_GAME = 0
RG_MIX_SONG = 1
RG_MIX_EFFECT = 2

# One voice of the mixer (the fields are rg_mix.c's mix_voice's, and mean the same things).
class RgMixVoice
  attr_accessor :sounding, :owner, :effect, :lane, :rank, :loops, :ticket, :recording, :position, :fraction, :step,
                :back, :loudness, :gain, :ramp, :shaped, :level, :phase, :attack, :decay, :sustain, :release

  def initialize
    @sounding = false
    @owner = RG_MIX_GAME
    @effect = 0
    @lane = 0
    @rank = 0
    @loops = 0
    @ticket = 0
    @recording = 0
    @position = 0
    @fraction = 0
    @step = 0
    @back = 0
    @loudness = 0
    @gain = 0
    @ramp = 0
    @shaped = 0
    @level = 0
    @phase = RG_SHAPE_CLIMBING
    @attack = 0
    @decay = 0
    @sustain = 0
    @release = 0
  end

  def releasing? = @owner != RG_MIX_GAME && (@phase == RG_SHAPE_FALLING || @phase == RG_SHAPE_DONE)

  # Its numbers in the state image, in the order rg_mix.c's mix_voice keeps them.
  def state_numbers
    [@sounding ? 1 : 0, @owner, @effect, @lane, @rank, @loops, @ticket, @recording, @position, @fraction, @step, @back,
     @loudness, @gain, @ramp, @shaped, @level, @phase, @attack, @decay, @sustain, @release]
  end

  def state_numbers=(numbers)
    sounding, @owner, @effect, @lane, @rank, @loops, @ticket, @recording, @position, @fraction, @step, @back,
      @loudness, @gain, @ramp, @shaped, @level, @phase, @attack, @decay, @sustain, @release = numbers
    @sounding = sounding != 0
  end
end

def rg_mix_setup
  @rg_mix_voices = Array.new(RG_MIX_VOICES_MOST) { RgMixVoice.new }
  @rg_mix_slice = nil # one frame's slice, made the game's length the first time a frame is mixed
  @rg_mix_slices_made = 0
  @rg_mix_peak = 0
  @rg_mix_drop_count = 0 # plays that found every voice busy
  @rg_mix_drops_music = 0 # the most voices the music held at one of those moments
  @rg_mix_tickets = 0
  @rg_slices_printed = 0 # the slices a windowless run has printed (rg_mix_moment_printed)
end

def rg_mixes = @rg_game_mix[0]
def rg_slice_samples = @rg_game_mix[1]
def rg_mix_shapes = @rg_game_mix[2]
def rg_slide_share = @rg_game_mix[3]
def rg_mix_voice_count = @rg_game_mix[4]
def rg_vol_shift = @rg_game_mix[5]
def rg_step_shift = @rg_game_mix[6]
def rg_gain_fraction = @rg_game_mix[7]
def rg_ramp_split = @rg_game_mix[8]
def rg_shape_full = @rg_game_mix[9]
def rg_shape_scale = @rg_game_mix[10]
def rg_loudness_to_gain = @rg_game_mix[11]
def rg_whole_gain_shift = @rg_game_mix[12]
def rg_mix_full_depth_shift = @rg_game_mix[13]

# Where recording number +recording+'s numbers start in @rg_game_recordings.
def rg_recording_numbers(recording)
  rg_fault("there is no recording number #{recording}") if recording < 0 || recording >= @rg_game_recordings[0]
  1 + (recording * RG_NUMBERS_PER_RECORDING)
end

# The voices the game has, refused past the most there is room for.
def rg_mix_voices_in_use
  if rg_mix_voice_count > RG_MIX_VOICES_MOST
    rg_fault("the mixer has #{rg_mix_voice_count} voices, and the most is #{RG_MIX_VOICES_MOST}")
  end
  @rg_mix_voices.first(rg_mix_voice_count)
end

def rg_mix_record_peak
  now = @rg_mix_voices.first(rg_mix_voice_count).count(&:sounding)
  @rg_mix_peak = now if now > @rg_mix_peak
end

def rg_mix_record_drop
  music = @rg_mix_voices.first(rg_mix_voice_count).count { |voice| voice.sounding && voice.owner != RG_MIX_GAME }
  @rg_mix_drop_count += 1
  @rg_mix_drops_music = music if music > @rg_mix_drops_music
end

def rg_mix_free_voice = rg_mix_voices_in_use.index { |voice| !voice.sounding } || -1

def rg_mix_quietest_releasing_voice
  found = -1
  rg_mix_voice_count.times do |i|
    voice = @rg_mix_voices[i]
    next unless voice.sounding && voice.releasing?

    found = i if found < 0 || voice.level < @rg_mix_voices[found].level
  end
  found
end

def rg_mix_lowest_ranked_voice_below(rank)
  found = -1
  rg_mix_voice_count.times do |i|
    voice = @rg_mix_voices[i]
    next if !voice.sounding || voice.rank >= rank

    if found >= 0
      best = @rg_mix_voices[found]
      next if voice.rank > best.rank
      next if voice.rank == best.rank && (voice.loops > best.loops || (voice.loops == best.loops && voice.ticket >= best.ticket))
    end
    found = i
  end
  found
end

# A voice at the top of +recording+, shaped by the five numbers of +shape+ from +at+ (whether it
# has one, then its four numbers).
def rg_mix_start_voice(voice_at, recording, step, back, loudness, shape, at)
  rg_recording_numbers(recording)
  shaped = shape[at]
  voice = RgMixVoice.new
  voice.sounding = true
  voice.rank = -1
  voice.recording = recording
  voice.step = step
  voice.back = back
  voice.loudness = loudness
  voice.gain = shaped != 0 ? 0 : loudness << rg_loudness_to_gain
  voice.shaped = shaped
  voice.level = shaped != 0 ? 0 : rg_shape_full
  voice.attack = shape[at + 1]
  voice.decay = shape[at + 2]
  voice.sustain = shape[at + 3]
  voice.release = shape[at + 4]
  @rg_mix_voices[voice_at] = voice
end

def rg_mix_play(recording, step, loudness, back, loops)
  rg_sound_log("sample #{recording}")
  at = rg_mix_free_voice
  at = rg_mix_quietest_releasing_voice if at < 0
  return rg_mix_record_drop if at < 0

  rg_mix_start_voice(at, recording, step, back, loudness, @rg_game_recordings, rg_recording_numbers(recording) + 2)
  @rg_mix_voices[at].loops = loops
  @rg_mix_voices[at].ticket = (@rg_mix_tickets += 1)
  rg_spu_recording_struck(at, true)
  rg_mix_record_peak
end

def rg_mix_sounding_voice(effect, lane)
  owner = effect < 0 ? RG_MIX_SONG : RG_MIX_EFFECT
  rg_mix_voice_count.times do |i|
    voice = @rg_mix_voices[i]
    next if !voice.sounding || voice.owner != owner || voice.lane != lane || voice.releasing?
    return i if owner == RG_MIX_SONG || voice.effect == effect
  end
  -1
end

def rg_mix_start_release(voice)
  return false if voice.shaped == 0

  voice.phase = RG_SHAPE_FALLING
  true
end

# Reference::Mixer#glide_music_note: the note sounding reads on at the row's pitch. 1 when there was one.
def rg_mix_glide_music_note(effect, lane, sound)
  at = rg_mix_sounding_voice(effect, lane)
  return 0 if at < 0

  @rg_mix_voices[at].step = @rg_game_note_sounds[sound + 1]
  1
end

# +sound+ is where the note's eight numbers start in @rg_game_note_sounds. 1 when it is heard.
def rg_mix_start_music_note(effect, lane, rank, sound, loudness)
  at = rg_mix_sounding_voice(effect, lane)
  at = -1 if at >= 0 && rg_mix_start_release(@rg_mix_voices[at])
  at = rg_mix_free_voice if at < 0
  at = rg_mix_quietest_releasing_voice if at < 0
  at = rg_mix_lowest_ranked_voice_below(rank) if at < 0
  if at < 0
    rg_mix_record_drop
    return 0
  end

  sounds = @rg_game_note_sounds
  rg_mix_start_voice(at, sounds[sound], sounds[sound + 1], sounds[sound + 2], loudness, sounds, sound + 3)
  voice = @rg_mix_voices[at]
  voice.owner = effect < 0 ? RG_MIX_SONG : RG_MIX_EFFECT
  voice.effect = effect
  voice.lane = lane
  voice.rank = rank
  rg_spu_recording_struck(at, false)
  1
end

# 1 when the part had a note sounding to let go of.
def rg_mix_release_music(effect, lane)
  at = rg_mix_sounding_voice(effect, lane)
  return 0 if at < 0

  @rg_mix_voices[at].sounding = false unless rg_mix_start_release(@rg_mix_voices[at])
  1
end

def rg_mix_release_all_music
  @rg_mix_voices.first(rg_mix_voice_count).each do |voice|
    next if !voice.sounding || voice.owner != RG_MIX_SONG || voice.releasing?

    voice.sounding = false unless rg_mix_start_release(voice)
  end
end

# 1 when the song's part had a note sounding to make louder or quieter.
def rg_mix_rescale_music(lane, loudness)
  at = rg_mix_sounding_voice(-1, lane)
  return 0 if at < 0

  voice = @rg_mix_voices[at]
  voice.loudness = loudness
  voice.gain = loudness << rg_loudness_to_gain if voice.shaped == 0
  1
end

def rg_mix_stop(recording)
  @rg_mix_voices.first(rg_mix_voice_count).each_with_index do |voice, i|
    next unless voice.sounding && voice.owner == RG_MIX_GAME && (recording < 0 || voice.recording == recording)

    voice.sounding = false
    rg_spu_recording_stopped_by_game(i)
  end
  rg_sound_log("stop_sample")
end

# Each voice told to the sound chip that plays recordings on voices of its own (rg_mix.c says when).
def rg_mix_recordings_told
  @rg_mix_voices.first(rg_mix_voice_count).each_with_index do |voice, i|
    rg_spu_tell_recording(i, voice.sounding, voice.recording, voice.back, voice.step, voice.loudness, voice.level)
  end
end

# One voice's frame added into +totals+. False when its recording ran out partway and it stopped.
def rg_mix_voice_into(voice, totals)
  numbers = rg_recording_numbers(voice.recording)
  data = @rg_game_recordings[numbers]
  length = @rg_game_recordings[numbers + 1]
  samples = @rg_game_recording_samples
  step_shift = rg_step_shift
  step_mask = (1 << step_shift) - 1
  whole = voice.step >> step_shift
  part = voice.step & step_mask
  down = rg_vol_shift + rg_gain_fraction
  high_shift = rg_mix_full_depth_shift
  low_bytes = @rg_game_recording_low_bytes if high_shift != 0
  gain = rg_mix_shapes != 0 ? voice.gain : voice.loudness << rg_loudness_to_gain
  rg_slice_samples.times do |at|
    place = data + voice.position
    sample = low_bytes ? (samples[place] << high_shift) + low_bytes[place] : samples[place]
    totals[at] += (gain * sample) >> down
    gain += voice.ramp
    voice.fraction += part
    voice.position += whole + (voice.fraction >> step_shift)
    voice.fraction &= step_mask
    next if voice.position < length
    return false if voice.back == 0

    voice.position -= voice.back while voice.position >= length
    rg_sound_log("sample #{voice.recording}") if voice.owner == RG_MIX_GAME
  end
  voice.gain = gain
  true
end

def rg_mix_sound_frame
  return if rg_mixes == 0

  # The voices are added up in one Array and the slice kept in another, both the same two every
  # frame, so mixing takes no new memory a frame (see rg_sound_frame_buffers).
  samples = rg_slice_samples
  totals = (@rg_mix_totals ||= Array.new(samples, 0)).fill(0)
  rg_mix_voices_in_use.each do |voice|
    voice.sounding = false if voice.sounding && !rg_mix_voice_into(voice, totals)
  end
  highest = (128 << rg_mix_full_depth_shift) - 1
  slice = @rg_mix_slice
  slice = @rg_mix_slice = Array.new(samples, 0) if slice.nil? || slice.length != samples
  at = 0
  while at < samples
    slice[at] = totals[at].clamp(-highest - 1, highest)
    at += 1
  end
  @rg_mix_slices_made += 1
end

# --- shapes ---

def rg_mix_step_shape(voice)
  case voice.phase
  when RG_SHAPE_CLIMBING
    climbed = voice.level + voice.attack
    if climbed >= rg_shape_full
      voice.level = rg_shape_full
      voice.phase = RG_SHAPE_HOLDING
    else
      voice.level = climbed
    end
  when RG_SHAPE_HOLDING
    if voice.level > voice.sustain
      fallen = (voice.level * voice.decay) >> rg_shape_scale
      voice.level = fallen > voice.sustain ? fallen : voice.sustain
    end
  else
    voice.level = (voice.level * voice.release) >> rg_shape_scale
  end
end

def rg_mix_nearest_whole_gain(gain)
  (gain + (1 << (rg_gain_fraction - 1))) & ~((1 << rg_gain_fraction) - 1)
end

def rg_mix_slide_gain(voice, first)
  level = voice.level
  target = ((voice.loudness * (level + (level >> 7))) >> rg_whole_gain_shift) << rg_gain_fraction
  voice.gain = first ? target : rg_mix_nearest_whole_gain(voice.gain)
  voice.ramp = (((target - voice.gain) >> rg_ramp_split) * rg_slide_share) >> rg_ramp_split
end

def rg_mix_sound_frame_ended
  rg_mix_record_peak
  @rg_mix_voices.first(rg_mix_voice_count).each do |voice|
    next if !voice.sounding || voice.shaped == 0

    if voice.phase == RG_SHAPE_DONE
      voice.sounding = false
      next
    end
    first = voice.phase == RG_SHAPE_CLIMBING && voice.level == 0
    rg_mix_step_shape(voice)
    voice.phase = RG_SHAPE_DONE if voice.level == 0 && voice.phase == RG_SHAPE_FALLING
    rg_mix_slide_gain(voice, first)
  end
end

# --- what a driver reads back ---

def rg_mix_slices_made = @rg_mix_slices_made

# The newest slice's samples, or nil before the first.
def rg_mix_newest_slice = @rg_mix_slices_made > 0 ? @rg_mix_slice : nil

# What voice +voice+ is playing, as [recording, loudness, level, owner, effect, lane], or nil when
# it is not sounding.
def rg_mix_voice_sounding(voice)
  now = @rg_mix_voices[voice]
  return nil unless now.sounding

  [now.recording, now.loudness, now.level, now.owner, now.owner == RG_MIX_EFFECT ? now.effect : -1, now.lane]
end

def rg_mix_peak = @rg_mix_peak
def rg_mix_drops = [@rg_mix_drop_count, @rg_mix_drops_music]

# rg_hook_mixed_slice: the newest slice for the render of a frame, or 0 before the first.
def rg_mix_mixed_slice(_samples) = @rg_mix_slices_made > 0 ? @rg_mix_slice : 0

# rg_hook_mixed_sample_shift (rg_mix.c's rg_mix_mixed_sample_shift).
def rg_mix_mixed_sample_shift = rg_mix_full_depth_shift

# For a game that mixes recordings, a windowless run prints (rg_headless.rb): the slice made since
# the last moment ("mix" and its samples), each sounding voice's recording, loudness out of 512,
# how far its shape has climbed or fallen, and whose it is — 0 the game's, 1 the song's, 2 a sound
# effect's, then the effect's number and the part's lane ("mixing", six numbers a voice), the most
# voices that ever sounded at once ("mix_peak"), and how many plays found every voice busy with the
# most the music held at one of those moments ("mix_drops"). A game that declares a recording and
# mixes none prints nothing.
def rg_mix_moment_printed
  return if rg_mixes == 0

  if rg_mix_slices_made > @rg_slices_printed
    $stdout.write("mix#{rg_mix_newest_slice.map { |sample| " #{sample}" }.join}\n")
    @rg_slices_printed = rg_mix_slices_made
  end
  sounding = Array.new(rg_mix_voice_count) { |voice| rg_mix_voice_sounding(voice) }.compact
  dropped, music_held = rg_mix_drops
  $stdout.write("mixing#{sounding.flatten.map { |number| " #{number}" }.join}\n" \
                "mix_peak #{rg_mix_peak}\nmix_drops #{dropped} #{music_held}\n")
end

# --- the state image (rg_mix.c says what each field holds) ---

RG_MIX_VOICE_NUMBERS = 22

# rg_hook_visit_sound_state (rg_mix.c's rg_mix_visit_sound_state).
def rg_mix_visit_sound_state
  counts = rg_state_numbers("mix", [@rg_mix_slices_made, @rg_mix_peak, @rg_mix_drop_count, @rg_mix_drops_music, @rg_mix_tickets])
  @rg_mix_slices_made, @rg_mix_peak, @rg_mix_drop_count, @rg_mix_drops_music, @rg_mix_tickets = counts
  @rg_slices_printed = @rg_mix_slices_made # the writer's run printed the newest already

  if rg_mix_voice_count > RG_MIX_VOICES_MOST
    rg_fault("the mixer has #{rg_mix_voice_count} voices, and the most is #{RG_MIX_VOICES_MOST}")
  end
  numbers = rg_state_numbers("mix.voices", @rg_mix_voices.first(rg_mix_voice_count).flat_map(&:state_numbers))
  numbers.each_slice(RG_MIX_VOICE_NUMBERS).with_index do |n, i|
    voice = RgMixVoice.new
    voice.state_numbers = n
    if voice.sounding && (!voice.recording.between?(0, @rg_game_recordings[0] - 1) || voice.position.negative?)
      rg_state_refuse_damaged("the mixer plays a recording the game does not have")
    end
    @rg_mix_voices[i] = voice
  end

  samples = rg_mixes != 0 ? rg_slice_samples : 0
  newest = rg_state_numbers("mix.slice", (@rg_mix_slice || Array.new(samples, 0)).first(samples))
  @rg_mix_slice = newest if samples.positive?
end

# --- a recording's settings in the file (rg_mix.h says what each of these is handed) ---

RG_FILE_NUMBER_NUMBERS = 4
RG_FILE_NUMBER_READS = Ractor.make_shareable({ 1 => %w[C C], 2 => %w[v n], 4 => %w[V N] })

# The number of a recording's setting, from the four numbers of +rules+ at +where+ (rg_mix.c's
# start_file_setting).
def rg_start_file_setting(rules, where)
  width = rules[where + 1]
  number = @rg_start_file.byteslice(rules[where], width).unpack1(RG_FILE_NUMBER_READS.fetch(width)[rules[where + 2]])
  top = 1 << ((width * 8) - 1)
  rules[where + 3] == 1 && number >= top ? number - (top * 2) : number
end

# rg_mix.c's number_of_halves.
def rg_number_of_halves(high, low) = [high, low].pack("l>l>").unpack1("G")

def rg_mix_fill_steps(into, rules)
  rate = [rg_start_file_setting(rules, 0), 1].max
  rest = RG_FILE_NUMBER_NUMBERS
  mix_rate = rg_number_of_halves(rules[rest], rules[rest + 1])
  rules[rest + 2].times do |i|
    entry = rest + 3 + (i * 3)
    step = ((rate.to_f / mix_rate) * rg_number_of_halves(rules[entry + 1], rules[entry + 2])) * 65_536
    into[rules[entry]] = step < 1 ? 1 : [(step + 0.5).floor, 2_147_483_647].min
  end
end

# rg_mix.c's start_file_no_hold: the number's bits, signed or not, all set.
def rg_start_file_no_hold?(rules, where)
  every_bit = (1 << (rules[where + 1] * 8)) - 1
  rg_start_file_setting(rules, where) & every_bit == every_bit
end

# rg_mix.c's start_file_back.
def rg_start_file_back(holds_from, none, length, whole)
  if none
    whole == 1 ? length : 0
  else
    length - holds_from.clamp(0, length - 1)
  end
end

def rg_mix_fill_holds(into, rules)
  rest = RG_FILE_NUMBER_NUMBERS
  back = rg_start_file_back(rg_start_file_setting(rules, 0), rg_start_file_no_hold?(rules, 0), rules[rest], rules[rest + 1])
  rules[rest + 2].times { |i| into[rules[rest + 3 + i]] = back }
end

# rg_mix.c's start_file_length.
def rg_start_file_length(rules) = rg_start_file_setting(rules, 0).clamp(1, rules[RG_FILE_NUMBER_NUMBERS])

def rg_mix_fill_length(into, rules)
  rest = RG_FILE_NUMBER_NUMBERS + 1
  length = rg_start_file_length(rules)
  rules[rest].times { |i| into[rules[rest + 1 + i]] = length }
end

def rg_mix_fill_backs(into, rules)
  length = rg_start_file_length(rules)
  hold = RG_FILE_NUMBER_NUMBERS + 1
  rest = hold + 1 + RG_FILE_NUMBER_NUMBERS + 1
  from_file = rules[hold] != 0
  holds_from = from_file ? rg_start_file_setting(rules, hold + 1) : rules[hold + 1 + RG_FILE_NUMBER_NUMBERS]
  none = from_file ? rg_start_file_no_hold?(rules, hold + 1) : holds_from.negative?
  back = rg_start_file_back(holds_from, none, length, rules[rest])
  rules[rest + 1].times { |i| into[rules[rest + 2 + i]] = back }
end

def rg_mix_fill_shapes(into, rules)
  at = rules[0]
  full = rules[2]
  attack, decay, sustain, release = if rules[1] == 1
                                      rg_chip_closest_envelope(*@rg_start_file.byteslice(at, 3).bytes, full, rules[3], rules[4])
                                    else
                                      @rg_start_file.byteslice(at, 4).bytes
                                    end
  shaped = !(attack == full && sustain == full && release.zero?)
  rules[5].times do |i|
    into[rules[6 + i], 5] = shaped ? [1, attack, decay, sustain, release] : [0, 0, 0, 0, 0]
  end
end

# --- the nearest ordinary envelope to the Super Nintendo chip's three bytes (rg_mix.c's
# chip_closest_envelope, Audio::SNESEnvelope#closest_envelope) ---

RG_CHIP_SAMPLE_RATE = 32_000
RG_CHIP_TOP = 0x7FF
RG_CHIP_ADSR_ON = 0x80
RG_CHIP_BENDS_AT = 0x600
RG_CHIP_MOST_FRAMES = 4096
RG_CHIP_ATTACK = 0
RG_CHIP_DECAY = 1
RG_CHIP_SUSTAIN = 2
RG_CHIP_RATE_SAMPLES = Ractor.make_shareable([0, 2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192, 160, 128, 96, 80, 64,
                                              48, 40, 32, 24, 20, 16, 12, 10, 8, 6, 5, 4, 3, 2, 1])

# rg_mix.c's chip_heard.
def rg_chip_heard(level, full) = (((level >> 4) * full * 2) + 127) / 254

def rg_chip_fallen_by_part(level) = level - 1 - ((level - 1) >> 8)

# rg_mix.c's chip_step: [the level moved to, the rate, the part of the note after].
def rg_chip_step(adsr1, adsr2, gain, level, phase)
  after = phase
  if adsr1.nobits?(RG_CHIP_ADSR_ON)
    mode = gain >> 5
    return [gain * 0x10, 31, phase] if mode < 4

    moved = case mode
            when 4 then level - 0x20
            when 5 then rg_chip_fallen_by_part(level)
            when 6 then level + 0x20
            else level + (level + 0x20 >= RG_CHIP_BENDS_AT ? 0x08 : 0x20)
            end
    rate = gain & 0x1F
  else
    if phase == RG_CHIP_ATTACK
      rate = ((adsr1 & 0x0F) * 2) + 1
      moved = level + (rate < 31 ? 0x20 : 0x400)
    else
      moved = rg_chip_fallen_by_part(level)
      rate = phase == RG_CHIP_DECAY ? ((adsr1 >> 3) & 0x0E) + 0x10 : adsr2 & 0x1F
    end
    after = RG_CHIP_SUSTAIN if phase == RG_CHIP_DECAY && (moved >> 8) == (adsr2 >> 5)
    after = RG_CHIP_DECAY if phase == RG_CHIP_ATTACK && moved > RG_CHIP_TOP
  end
  [moved.clamp(0, RG_CHIP_TOP), rate, after]
end

# rg_mix.c's chip_levels: [the levels frame by frame, whether it settled].
def rg_chip_levels(adsr1, adsr2, gain, full, frame_rate)
  frames = []
  record = lambda do |level, now|
    frames << rg_chip_heard(level, full) while frames.size < RG_CHIP_MOST_FRAMES && ((frames.size + 1) * RG_CHIP_SAMPLE_RATE / frame_rate) < now
  end
  level = 0
  phase = RG_CHIP_ATTACK
  now = 0
  settled = false
  while frames.size < RG_CHIP_MOST_FRAMES
    moved, rate, after = rg_chip_step(adsr1, adsr2, gain, level, phase)
    wait = RG_CHIP_RATE_SAMPLES[rate]
    if after != phase
      now += 1
      phase = after
      record.call(level, now)
      level = moved if wait.positive? && (now % wait).zero?
      next
    end
    if wait.zero? || moved == level
      settled = true
      break
    end
    now = ((now / wait) + 1) * wait
    record.call(level, now)
    level = moved
  end
  frames << rg_chip_heard(level, full) if settled && frames.size < RG_CHIP_MOST_FRAMES
  [frames, settled]
end

# rg_mix.c's chip_closest_attack. Array#sum is the sum the build picks the number by.
def rg_chip_closest_attack(climb, peak, full)
  wanted = climb.map { |level| level * full / peak.to_f }
  levels = ->(number) { (1..wanted.size).map { |frame| [number * frame, full].min } }
  rg_chip_nearest_number(1, full, wanted, levels)
end

# rg_mix.c's chip_closest_decay.
def rg_chip_closest_decay(fall, floor, full, scale)
  return 0 if fall.empty?

  levels = lambda do |number|
    level = full
    fall.map { level = [(level * number) >> scale, floor].max }
  end
  rg_chip_nearest_number(0, full, fall, levels)
end

# The number from +least+ to +most+ whose +levels+ come nearest +wanted+ (Audio::SNESEnvelope#nearest_number).
def rg_chip_nearest_number(least, most, wanted, levels)
  over = (least..most).bsearch { |number| levels.call(number).sum >= wanted.sum } || most
  [over - 1, over].select { |number| number >= least }.min_by do |number|
    levels.call(number).zip(wanted).sum { |level, want| (level - want)**2 }
  end
end

# rg_mix.c's chip_closest_envelope: [attack, decay, sustain, release].
def rg_chip_closest_envelope(adsr1, adsr2, gain, full, scale, frame_rate)
  frames, settled = rg_chip_levels(adsr1, adsr2, gain, full, frame_rate)
  peak = frames.max
  return [0, 0, full, 0] if peak.zero?

  climb = frames.index(peak) + 1
  floor = settled ? frames.last : 0
  [rg_chip_closest_attack(frames.first(climb), peak, full), rg_chip_closest_decay(frames.drop(climb), floor, full, scale), floor, 0]
end

# --- a recording in the Super Nintendo chip's format, decoded as the game starts (rg_mix.c's
# rg_mix_fill_brr, Audio::SNESRecording#decoded) ---

RG_BRR_BLOCK_BYTES = 9
RG_BRR_BLOCK_SAMPLES = 16
RG_BRR_END_BIT = 0x01
RG_BRR_LOOP_BIT = 0x02
RG_BRR_MOST_SHIFT = 12

# rg_mix.c's brr_decode_blocks: +state+ is [older, last, made].
def rg_brr_decode_blocks(at, first, past, state, samples, start, room)
  (first...past).each do |block|
    header, *packed = @rg_start_file.byteslice(at + (block * RG_BRR_BLOCK_BYTES), RG_BRR_BLOCK_BYTES).bytes
    shift = header >> 4
    filter = (header >> 2) & 3
    packed.flat_map { |byte| [byte >> 4, byte & 0xF] }.each do |nibble|
      sample = nibble >= 8 ? nibble - 16 : nibble
      sample = shift <= RG_BRR_MOST_SHIFT ? (sample << shift) >> 1 : (sample.negative? ? -2048 : 0)
      last = state[1]
      older = state[0] >> 1
      sample += case filter
                when 1 then (last >> 1) + ((-last) >> 5)
                when 2 then last - older + (older >> 4) + ((last * -3) >> 6)
                when 3 then last - older + ((last * -13) >> 7) + ((older * 3) >> 4)
                else 0
                end
      kept = (((sample.clamp(-0x8000, 0x7FFF) * 2) + 0x8000) & 0xFFFF) - 0x8000
      state[0] = state[1]
      state[1] = kept
      samples[start + state[2]] = kept >> 8 if state[2] < room
      state[2] += 1
    end
  end
end

def rg_mix_fill_brr(samples, decoded, rules)
  start, room, at, count, entry, most_passes = rules[0, 6]
  loop_at = rules[6] == 1 ? rg_start_file_setting(rules, 8) : rules[7]
  blocks = count / RG_BRR_BLOCK_BYTES
  ends = (0...blocks).find { |block| @rg_start_file.getbyte(at + (block * RG_BRR_BLOCK_BYTES)).anybits?(RG_BRR_END_BIT) }
  taken = ends ? ends + 1 : blocks
  loops = !ends.nil? && @rg_start_file.getbyte(at + (ends * RG_BRR_BLOCK_BYTES)).anybits?(RG_BRR_LOOP_BIT)
  loop_block = ([loop_at, 0].max / RG_BRR_BLOCK_BYTES).clamp(0, taken - 1)
  state = [0, 0, 0]
  hold = -1
  rg_brr_decode_blocks(at, 0, loops ? loop_block : taken, state, samples, start, room)
  if loops
    starts = {}
    loop do
      if starts.key?(state[0, 2])
        hold = starts.fetch(state[0, 2])
        break
      end
      if starts.size == most_passes
        hold = state[2] - ((taken - loop_block) * RG_BRR_BLOCK_SAMPLES)
        break
      end
      starts[state[0, 2]] = state[2]
      rg_brr_decode_blocks(at, loop_block, taken, state, samples, start, room)
    end
  end
  decoded[entry] = [state[2], room].min
  decoded[entry + 1] = hold
end

def rg_mix_fill_decoded_length(into, decoded, rules)
  rules[1].times { |i| into[rules[2 + i]] = decoded[rules[0]] }
end

def rg_mix_fill_decoded_backs(into, decoded, rules)
  length = decoded[rules[0]]
  hold = decoded[rules[0] + 1]
  back = rg_start_file_back(hold, hold.negative?, length, rules[1])
  rules[2].times { |i| into[rules[3 + i]] = back }
end
