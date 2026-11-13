# frozen_string_literal: true

# THE MUSIC PLAYER (`play_song`, `play_sound_effect`, `stop_music`, `hold_music`): songs walked a
# frame at a time, the sound effects that are songs walked by the same player, the voices claimed by
# rank, the music volume followed, and the pitch wobble, swell and shape stepping that only notes do.
# Joined into the runtime's class after rg_sound.rb (and after the mix, for a game that has both)
# for a game that has a song. The rules are runtime_features/music/rg_music.c's, rule for rule, and
# that file says every one of them and the layout of every table the lowering writes
# (@rg_game_music, @rg_game_effects); this one reads them the same way.
#
# The sound runtime calls it through three hooks: rg_music_sound_frame as a frame begins,
# rg_music_voice_taken_by_game when the game's own beep or wave takes a voice, and
# rg_music_moment_printed when a windowless run prints a moment.

RG_PARTS_MOST = 20
RG_NUMBERS_PER_NOTE = 6
RG_HAS_FADE = 16      # A note's flags: set when the note or its part set a fade
RG_HAS_SLIDE = 32     # A note's flags: set when the note or its part set a slide
RG_SLIDE_AT = 6       # A slide's seven bits (Audio::PitchSlide#bits), above the flags
RG_SLIDE_BITS = 0x7F
RG_HAS_VIBRATO = 1 << 13 # In a note, set when it or its part set a wobble
RG_VIBRATO_AT = 14 # A vibrato's sixteen bits (Audio::Vibrato#bits), above the flag
RG_VIBRATO_BITS = 0xFFFF
RG_VIBRATO_FOUR_BITS = 0xF # A vibrato's bits: the depth, four bits
RG_VIBRATO_SPEED_AT = 4 # A vibrato's bits: the speed, above the depth
RG_VIBRATO_AFTER_AT = 8 # A vibrato's bits: the wait, above the speed
RG_PAN_AT = 30 # At the top of a note, its speaker (Audio::Pan.bits_of)
RG_PAN_BITS = 3
RG_HAS_DUTY = 1 << 8 # A note's sixth number: set when it or its part set its shapes
RG_DUTY_BITS = 0xFF # A note's eight shape bits (Audio::Duty#bits), under the flag
RG_CARRIES_VIBRATO = 1 << 9 # Above the shapes: set when the vibrato carries its swing on
RG_GLIDES = 1 << 10 # Set on a recorded note that carries on the one sounding
RG_VIBRATO_CARRIES_LOGGED = 1 << 16 # The same flag as the log writes it, above the vibrato's bits
RG_NUMBERS_PER_NOTE_SOUND = 8

RG_PART_SQUARE = 0
RG_PART_WAVE = 1
RG_PART_NOISE = 2
RG_PART_RECORDED = 3

RG_WAVE_QUARTERS = 6 # Where the wave voice's loudness for each volume starts in @rg_game_sound_rules
RG_SONG_STARTS = 1
RG_NUMBERS_PER_SONG = 5
RG_NUMBERS_PER_PART = 6
RG_EFFECT_ROWS = 2
RG_NUMBERS_PER_EFFECT = 6
RG_EFFECT_SONG = 0
RG_EFFECT_NOTES = 1
RG_EFFECT_RANK = 2
RG_EFFECT_GROUP = 3
RG_EFFECT_PRIORITY = 4
RG_EFFECT_KEEPS_VOICES = 5
RG_EFFECTS_MOST = 512

# One part of a song as the player walks it: where its notes start in @rg_game_music, how many,
# the next to play, its kind and the voice it plays on, which of its song's parts it is, and the
# two numbers for what its voice sounds like.
RgPartWalk = Struct.new(:notes, :count, :next_note, :kind, :voice, :number, :tone, :fade)

# A note the player holds while the game keeps a music volume, so a change of volume sounds it
# again: the voice (0 for a recorded part, then its lane), its written volume, and what a square
# note needs to start again, how it fades included.
RgHeldNote = Struct.new(:voice, :lane, :volume, :wave_ticks, :eighths_high, :fade)

# Every instance variable the player uses is set here, as the game starts: none is set later.
def rg_music_setup
  @rg_wobbles = Array.new(RG_WAVE_VOICE + 1) { RgWobble.new(0, 0, 0, false, 0, 0) } # by voice (rg_music.c's wobbles)
  @rg_shapes = Array.new(RG_SQUARE_VOICES + 1) { RgShapeWalk.new(0, 0, false) } # by voice (rg_music.c's shapes)
  @rg_swells = Array.new(RG_NOISE_VOICE + 1) { RgSwellWalk.new(false) } # by voice (rg_music.c's swells)
  # whether the game has a mixer for recordings: a song with none never has a recorded part
  @rg_music_mixes = respond_to?(:rg_mix_release_all_music, true)
  @rg_wanted = -1
  @rg_playing = -1
  @rg_ended = -1
  @rg_stops = 0
  @rg_stops_seen = 0
  @rg_music_held = false # the game called hold_music: the tune stays where it is
  @rg_song = 0 # where the playing song's numbers start in @rg_game_music
  @rg_song_frame = 0
  @rg_part_count = 0
  @rg_parts = Array.new(RG_PARTS_MOST)
  @rg_level_variable = nil # reads the game's music volume, for a game that keeps one
  @rg_level = -1
  @rg_holding = []
  # who holds each console voice, by rank, and the voices in the order they were first claimed
  @rg_holders = [0, 0, 0, 0, 0]
  @rg_holder_order = []
  # the sound effects
  @rg_effect_asked = Array.new(RG_EFFECTS_MOST, false)
  @rg_effect_asked_now = Array.new(RG_EFFECTS_MOST, false)
  @rg_effect_stopping = Array.new(RG_EFFECTS_MOST, false)
  @rg_effect_running = Array.new(RG_EFFECTS_MOST, false)
  @rg_effect_frame = Array.new(RG_EFFECTS_MOST, 0)
  @rg_effect_cursors = Array.new(RG_EFFECTS_MOST)
end

# The game's own beep, wave or stop_wave took +voice+: a note held there wobbles no more and steps
# its shapes no more (Reference::Player#game_sound_on).
def rg_music_voice_taken_by_game(voice)
  rg_wobble_stop(voice)
  rg_shape_stop(voice)
end

# A windowless run prints a moment (rg_headless.rb): the tune the player is on, by the number the
# log names it by, -1 for none (Reference#music_playing).
def rg_music_moment_printed
  $stdout.write("music_playing #{@rg_playing}\n")
end

def rg_full_level = @rg_game_sound_rules[4]
def rg_level_shift = @rg_game_sound_rules[5]
def rg_order_mask = @rg_game_sound_rules[RG_WAVE_QUARTERS + RG_VOLUMES]
def rg_counted_a_frame = @rg_game_sound_rules[RG_WAVE_QUARTERS + RG_VOLUMES + 1]
def rg_song_count = @rg_game_music[0]
def rg_effect_count = @rg_game_effects[0]
def rg_effects_play_wave = @rg_game_effects[1]

# --- the player ---

def rg_music_request(number)
  rg_fault("there is no song number #{number}") if number < 0 || number >= rg_song_count
  @rg_wanted = number
end

def rg_music_request_one_of(songs, count, which)
  rg_music_request(songs[which]) if which >= 0 && which < count
end

def rg_music_stop
  @rg_wanted = -1
  @rg_stops += 1
end

# The tune stays where it is, or carries on (Reference::Player#hold).
def rg_music_hold(held)
  @rg_music_held = held != 0
end

# Is the note on +voice+ the held tune's? A sound effect on a voice keeps moving.
def rg_held_still?(voice) = @rg_music_held && (@rg_holders[voice] & rg_order_mask) == 0

def rg_music_follow_level(variable)
  @rg_level_variable = variable
end

# Where song number +number+'s numbers start, from its length on.
def rg_song_numbers(number) = @rg_game_music[RG_SONG_STARTS + number]

# The part of song number +number+ written at +part+ (a place in @rg_game_music), as a walk of its
# notes, and where the song's next part is written. +squares_met+ counts the square parts so far.
def rg_read_part(number, part, again, squares_met)
  music = @rg_game_music
  kind = music[part]
  first = music[part + 4]
  after = music[part + 5]
  first_notes = part + RG_NUMBERS_PER_PART
  after_notes = first_notes + (RG_NUMBERS_PER_NOTE * first)
  voice = case kind
          when RG_PART_WAVE then RG_WAVE_VOICE
          when RG_PART_NOISE then RG_NOISE_VOICE
          when RG_PART_RECORDED then 0
          else squares_met[0] += 1
          end
  if squares_met[0] > RG_SQUARE_VOICES
    rg_fault("song number #{number} has more parts on the square wave than the #{RG_SQUARE_VOICES} there are")
  end
  walk = RgPartWalk.new(again ? after_notes : first_notes, again ? after : first, 0, kind, voice, music[part + 1],
                        music[part + 2], music[part + 3])
  [walk, after_notes + (RG_NUMBERS_PER_NOTE * after)]
end

def rg_start_walks(again)
  part = @rg_song + RG_NUMBERS_PER_SONG
  squares_met = [0]
  @rg_part_count.times do |i|
    walk, part = rg_read_part(@rg_playing, part, again, squares_met)
    @rg_parts[i] = walk
  end
end

def rg_scaled_volume(volume) = (volume * @rg_level) >> rg_level_shift

def rg_wave_quarters_at(volume) = @rg_game_sound_rules[RG_WAVE_QUARTERS + volume.clamp(0, RG_VOLUMES - 1)]

def rg_log_held_loudness(note)
  if note.voice == 0
    rg_sound_log("mixer_loudness #{note.lane} #{rg_scaled_volume(note.volume)}")
  else
    rg_sound_log("loudness #{note.voice} #{rg_scaled_volume(note.volume)}")
  end
end

def rg_hold_note(note)
  at = @rg_holding.index { |held| held.voice == note.voice && (note.voice != 0 || held.lane == note.lane) }
  @rg_holding[at || @rg_holding.length] = note
  rg_log_held_loudness(note)
end

def rg_follow_level(now)
  return if now == @rg_level

  @rg_level = now
  @rg_holding.each do |note|
    next if note.volume <= 0
    next if note.voice == 0 && rg_mix_rescale_music(note.lane, rg_scaled_volume(note.volume)) == 0

    rg_log_held_loudness(note)
    next if note.voice == 0

    if note.voice == RG_WAVE_VOICE
      rg_wave_set_loudness(rg_wave_quarters_at(rg_scaled_volume(note.volume)))
    else
      rg_square_start(note.voice, note.wave_ticks, note.eighths_high, rg_scaled_volume(note.volume), note.fade, 0)
    end
  end
end

# --- a pitch that wobbles (rg_sound.c's own section says how) ---

RgWobble = Struct.new(:vibrato, :wait, :left, :rising, :steps, :ticks)

def rg_note_vibrato(note)
  flags = @rg_game_music[note + 4]
  flags.anybits?(RG_HAS_VIBRATO) ? (flags >> RG_VIBRATO_AT) & RG_VIBRATO_BITS : 0
end

def rg_wobble_start(voice, note)
  return if voice > RG_WAVE_VOICE

  vibrato = @rg_game_music[note + 1] == 0 ? 0 : rg_note_vibrato(note)
  was = @rg_wobbles[voice]
  if (vibrato & RG_VIBRATO_FOUR_BITS).zero?
    was.vibrato = 0
    was.steps = 0
    return
  end
  carries = @rg_game_music[note + 5].anybits?(RG_CARRIES_VIBRATO)
  @rg_wobbles[voice] = RgWobble.new(vibrato, vibrato >> RG_VIBRATO_AFTER_AT, carries ? was.left : 0, carries ? was.rising : false,
                                    0, @rg_game_music[note + 3])
end

def rg_wobble_stop(voice)
  @rg_wobbles[voice].vibrato = 0 if voice <= RG_WAVE_VOICE
end

def rg_step_wobbles
  (1..RG_WAVE_VOICE).each do |voice|
    moving = @rg_wobbles[voice]
    depth = moving.vibrato & RG_VIBRATO_FOUR_BITS
    next if depth == 0 || rg_held_still?(voice)
    next moving.wait -= 1 if moving.wait > 0

    if moving.left == 0
      moving.rising = !moving.rising
      moving.left = ((moving.vibrato >> RG_VIBRATO_SPEED_AT) & RG_VIBRATO_FOUR_BITS) + 1 # kept less one
      steps = moving.rising ? (depth + 1) / 2 : -(depth / 2)
      rg_sound_log("wobble #{voice} #{steps}") unless steps == moving.steps
      moving.steps = steps
    end
    moving.left -= 1
    count = (RG_PITCH_COUNT_TOP - moving.ticks + moving.steps).clamp(0, RG_PITCH_COUNT_TOP - 1)
    if voice == RG_WAVE_VOICE
      @rg_wave.wave_ticks = RG_PITCH_COUNT_TOP - count unless @rg_wave.wave_ticks == 0
    elsif @rg_squares[voice - 1].wave_ticks != 0
      @rg_squares[voice - 1].slid_ticks = RG_PITCH_COUNT_TOP - count
    end
  end
end

# A SQUARE NOTE'S SHAPES, by its voice: rg_sound.c's shape_walk, and its other shape functions.
RgShapeWalk = Struct.new(:bits, :frame, :steps)
RG_EIGHTHS_OF_SHAPE = [1, 2, 4, 6].freeze

def rg_shape_at(bits, frame) = (bits >> (2 * (frame % 4))) & 3

def rg_note_eighths(part, note)
  flags = @rg_game_music[note + 5]
  flags.anybits?(RG_HAS_DUTY) ? RG_EIGHTHS_OF_SHAPE[rg_shape_at(flags, 0)] : part.tone
end

def rg_shape_start(voice, note)
  rg_swell_stop(voice)
  return if voice > RG_SQUARE_VOICES

  flags = @rg_game_music[note + 5]
  bits = @rg_game_music[note + 1] != 0 && flags.anybits?(RG_HAS_DUTY) ? flags & RG_DUTY_BITS : 0
  @rg_shapes[voice] = RgShapeWalk.new(bits, 0, (1..3).any? { |frame| rg_shape_at(bits, frame) != rg_shape_at(bits, 0) })
end

def rg_shape_stop(voice)
  @rg_shapes[voice].steps = false if voice <= RG_SQUARE_VOICES
  rg_swell_stop(voice)
end

# A SONG'S SWELLING NOTE HELD UNDER THE MUSIC VOLUME, by its voice: rg_sound.c's swell_walk, and its
# other swell functions.
RgSwellWalk = Struct.new(:active, :step, :volume, :counted, :swelling, :wave_ticks, :eighths_high)
RG_LOUDEST = RG_VOLUMES - 1

def rg_swell_stop(voice)
  @rg_swells[voice].active = false
end

def rg_swell_strike(voice, swell, volume, fade)
  return rg_noise_start(swell.wave_ticks, swell.eighths_high, volume, fade) if voice == RG_NOISE_VOICE

  rg_square_start(voice, swell.wave_ticks, swell.eighths_high, volume, fade, 0)
end

def rg_swell_start(voice, note, eighths_high, volume, fade)
  return if @rg_game_music[note + 1] == 0 || fade.nobits?(RG_FADE_UP) || fade.nobits?(RG_FADE_STEP_BITS)

  @rg_swells[voice] = RgSwellWalk.new(true, fade & RG_FADE_STEP_BITS, volume, 0, true, @rg_game_music[note + 3], eighths_high)
end

def rg_step_swells
  ceiling = (RG_LOUDEST * @rg_level) >> rg_level_shift
  (1..RG_NOISE_VOICE).each do |voice|
    swell = @rg_swells[voice]
    next unless swell.active

    if swell.swelling ? swell.volume >= ceiling && ceiling < RG_LOUDEST : swell.volume > ceiling
      swell.volume = ceiling
      swell.counted = 0
      swell.swelling = false
      rg_sound_log("loudness #{voice} #{ceiling}")
      rg_swell_strike(voice, swell, ceiling, 0)
    elsif !swell.swelling && swell.volume < ceiling
      swell.counted = 0
      swell.swelling = true
      rg_sound_log("loudness #{voice} #{swell.volume} #{RG_FADE_UP | swell.step}")
      rg_swell_strike(voice, swell, swell.volume, RG_FADE_UP | swell.step)
    end
    next unless swell.swelling && swell.volume < RG_LOUDEST

    swell.counted += rg_counted_a_frame
    while swell.counted >= swell.step * 256 && swell.volume < RG_LOUDEST
      swell.counted -= swell.step * 256
      swell.volume += 1
    end
  end
end

def rg_step_shapes
  (1..RG_SQUARE_VOICES).each do |voice|
    walk = @rg_shapes[voice]
    next if !walk.steps || rg_held_still?(voice)

    now = rg_shape_at(walk.bits, walk.frame)
    rg_sound_log("duty #{voice} #{now}") if walk.frame > 0 && now != rg_shape_at(walk.bits, walk.frame - 1)
    @rg_squares[voice - 1].eighths_high = RG_EIGHTHS_OF_SHAPE[now]
    walk.frame += 1
  end
end

def rg_silence_voice(voice)
  rg_wobble_stop(voice)
  rg_shape_stop(voice)
  case voice
  when RG_WAVE_VOICE then rg_wave_set_loudness(0)
  when RG_NOISE_VOICE then rg_noise_start(0, @rg_hiss.bits, 0, 0)
  else rg_square_start(voice, 0, 0, 0, 0, 0)
  end
end

def rg_rest_on(part)
  rg_silence_voice(part.voice) if part.kind != RG_PART_RECORDED
end

# --- who holds a console voice ---

def rg_claim_voice(voice, rank, sounds)
  return false if @rg_holders[voice] > rank

  @rg_holder_order << voice unless @rg_holder_order.include?(voice)
  @rg_holders[voice] = sounds ? rank : 0
  true
end

def rg_note_sounds(kind, pitch, volume, fade)
  return false if pitch == 0
  return true if fade.anybits?(RG_FADE_UP) && fade.anybits?(RG_FADE_STEP_BITS) && [RG_PART_SQUARE, RG_PART_NOISE].include?(kind)
  return false if volume <= 0

  kind != RG_PART_WAVE || rg_wave_quarters_at(volume) != 0
end

def rg_wave_put_in(which)
  rg_wave_load(which) unless which == @rg_loaded_waveform
end

def rg_silence_song
  rg_sound_log("stop_music")
  @rg_part_count.times do |i|
    part = @rg_parts[i]
    next if part.kind == RG_PART_RECORDED || (@rg_holders[part.voice] & rg_order_mask) != 0

    rg_rest_on(part)
  end
  (1..RG_NOISE_VOICE).each { |voice| @rg_holders[voice] = 0 if (@rg_holders[voice] & rg_order_mask) == 0 }
  @rg_holding = []
  rg_mix_release_all_music if @rg_music_mixes
end

# Catches up with the tune the game asked for. True when it changed to another, or to none.
def rg_switch_to_wanted_song
  if @rg_ended >= 0
    if @rg_wanted == @rg_ended && @rg_stops == @rg_stops_seen
      rg_silence_song if @rg_playing >= 0
      @rg_playing = -1
      return false
    end
    @rg_ended = -1
  end
  return false if @rg_wanted == @rg_playing && @rg_stops == @rg_stops_seen

  @rg_stops_seen = @rg_stops
  @rg_music_held = false
  rg_silence_song if @rg_playing >= 0
  @rg_playing = @rg_wanted
  @rg_song_frame = 0
  @rg_part_count = 0
  return true if @rg_playing < 0

  @rg_song = rg_song_numbers(@rg_playing)
  @rg_part_count = @rg_game_music[@rg_song + 4]
  if @rg_part_count > RG_PARTS_MOST
    rg_fault("song number #{@rg_playing} has #{@rg_part_count} parts, and the most is #{RG_PARTS_MOST}")
  end
  rg_start_walks(false)
  return true if rg_effects_play_wave != 0

  wave_part = @rg_parts.first(@rg_part_count).find { |part| part.kind == RG_PART_WAVE }
  rg_wave_load(wave_part.tone) if wave_part
  true
end

def rg_play_recorded_note(part, note)
  music = @rg_game_music
  pitch = music[note + 1]
  loudness = music[note + 2]
  sound = music[note + 3]
  if pitch == 0 || loudness <= 0
    rg_mix_release_music(-1, part.tone)
  else
    numbers = 1 + (sound * RG_NUMBERS_PER_NOTE_SOUND)
    heard = if music[note + 5].anybits?(RG_GLIDES)
              rg_mix_glide_music_note(-1, part.tone, numbers)
            else
              rg_mix_start_music_note(-1, part.tone, music[@rg_song + 3], numbers,
                                      @rg_level_variable ? rg_scaled_volume(loudness) : loudness)
            end
    return if heard == 0
  end
  rg_sound_log("note #{@rg_playing} #{pitch}")
  rg_hold_note(RgHeldNote.new(0, part.tone, pitch == 0 ? 0 : loudness, 0, 0, 0)) if @rg_level_variable
end

# How a note on a square or the noise voice fades or swells (rg_sound.c's note_fade says how).
def rg_note_fade(part, note)
  flags = @rg_game_music[note + 4]
  return flags & (RG_FADE_UP | RG_FADE_STEP_BITS) if flags.anybits?(RG_HAS_FADE)

  part.kind == RG_PART_NOISE ? part.fade : 0
end

# How a note on the first square voice slides its pitch, or 0 to hold it (rg_sound.c's note_slide).
def rg_note_slide(note) = (@rg_game_music[note + 4] >> RG_SLIDE_AT) & RG_SLIDE_BITS

# The speaker a note plays from: RG_PAN_LEFT, RG_PAN_RIGHT, or nought for both.
def rg_note_pan(note) = (@rg_game_music[note + 4] >> RG_PAN_AT) & RG_PAN_BITS

# The log's line for a note setting its voice, with the note's fade when it set one, and its
# slide, its wobble, its speaker and its shapes after that when it set them — with -1, for none,
# before one set after it.
def rg_log_voice_set(voice, who, pitch, volume, note)
  flags = @rg_game_music[note + 4]
  told = [flags.anybits?(RG_HAS_FADE) ? flags & (RG_FADE_UP | RG_FADE_STEP_BITS) : -1,
          flags.anybits?(RG_HAS_SLIDE) ? rg_note_slide(note) : -1,
          flags.anybits?(RG_HAS_VIBRATO) ? rg_note_vibrato(note) | (@rg_game_music[note + 5].anybits?(RG_CARRIES_VIBRATO) ? RG_VIBRATO_CARRIES_LOGGED : 0) : -1,
          rg_note_pan(note).positive? ? rg_note_pan(note) : -1,
          @rg_game_music[note + 5].anybits?(RG_HAS_DUTY) ? @rg_game_music[note + 5] & RG_DUTY_BITS : -1]
  told.pop while !told.empty? && told.last.negative?
  rg_sound_log(["voice #{voice} #{who} #{pitch} #{volume}", *told].join(" "))
end

def rg_play_note(part, note)
  return rg_play_recorded_note(part, note) if part.kind == RG_PART_RECORDED

  music = @rg_game_music
  pitch = music[note + 1]
  volume = music[note + 2]
  ticks = music[note + 3]
  return unless rg_claim_voice(part.voice, music[@rg_song + 3], rg_note_sounds(part.kind, pitch, volume, rg_note_fade(part, note)))

  written = pitch == 0 ? 0 : volume
  sounded = @rg_level_variable ? rg_scaled_volume(written) : written
  fade = rg_note_fade(part, note)
  rg_sound_log("note #{@rg_playing} #{pitch}")
  rg_log_voice_set(part.voice, @rg_playing, pitch, volume, note)
  rg_wobble_start(part.voice, note)
  rg_shape_start(part.voice, note)
  @rg_sides[part.voice] = rg_note_pan(note)
  case part.kind
  when RG_PART_WAVE
    rg_hold_note(RgHeldNote.new(part.voice, 0, written, 0, 0, 0)) if @rg_level_variable
    if pitch == 0
      rg_sound_log("stop_wave")
      rg_rest_on(part)
    else
      rg_sound_log("part_wave #{@rg_playing} #{part.number} #{pitch}")
      rg_wave_put_in(part.tone) if rg_effects_play_wave != 0
      rg_wave_start(ticks, rg_wave_quarters_at(sounded))
      rg_voice_struck(RG_WAVE_VOICE)
    end
  when RG_PART_NOISE
    rg_sound_log("loudness #{part.voice} #{sounded}") if @rg_level_variable
    if pitch == 0
      rg_sound_log("noise_rest")
      rg_rest_on(part)
    else
      rg_sound_log("part_noise #{@rg_playing} #{part.number} #{pitch}")
      rg_noise_start(ticks, part.tone, sounded, fade)
      rg_voice_struck(RG_NOISE_VOICE)
      rg_swell_start(part.voice, note, part.tone, sounded, fade) if @rg_level_variable
    end
  else
    # A note that fades, swells or slides by itself is left to it (rg_sound.c's play_note says why).
    if @rg_level_variable && ((fade & RG_FADE_STEP_BITS) != 0 || rg_note_slide(note) != 0)
      rg_drop_held_note(part.voice)
      rg_sound_log("loudness #{part.voice} #{sounded}")
    elsif @rg_level_variable
      rg_hold_note(RgHeldNote.new(part.voice, 0, written, ticks, rg_note_eighths(part, note), fade))
    end
    rg_square_start(part.voice, ticks, rg_note_eighths(part, note), sounded, fade, rg_note_slide(note))
    rg_voice_struck(part.voice) if pitch != 0
    rg_swell_start(part.voice, note, rg_note_eighths(part, note), sounded, fade) if @rg_level_variable && rg_note_slide(note) == 0
  end
end

# --- sound effects ---

def rg_effect_field(effect, field) = @rg_game_effects[RG_EFFECT_ROWS + (effect * RG_NUMBERS_PER_EFFECT) + field]

def rg_effect_pending(effect) = @rg_effect_asked[effect] || (@rg_effect_running[effect] && !@rg_effect_stopping[effect])

def rg_refuse_too_many_effects
  return unless rg_effect_count > RG_EFFECTS_MOST

  rg_fault("the game has #{rg_effect_count} sound effects, and the most is #{RG_EFFECTS_MOST}")
end

def rg_request_effect(effect)
  rg_refuse_too_many_effects
  group = rg_effect_field(effect, RG_EFFECT_GROUP)
  if group >= 0
    rg_effect_count.times do |other|
      next if rg_effect_field(other, RG_EFFECT_GROUP) != group || !rg_effect_pending(other)
      return if rg_effect_field(effect, RG_EFFECT_PRIORITY) < rg_effect_field(other, RG_EFFECT_PRIORITY)

      @rg_effect_asked[other] = false
      @rg_effect_stopping[other] = true
      break
    end
  end
  @rg_effect_asked[effect] = true
end

def rg_effect_request_one_of(effects, count, which)
  rg_request_effect(effects[which]) if which >= 0 && which < count
end

def rg_drop_held_note(voice)
  @rg_holding = @rg_holding.reject { |note| note.voice == voice }
end

def rg_finish_effect(effect)
  number = rg_effect_field(effect, RG_EFFECT_SONG)
  rank = rg_effect_field(effect, RG_EFFECT_RANK)
  @rg_effect_running[effect] = false
  @rg_holder_order.each do |voice|
    next if @rg_holders[voice] != rank

    @rg_holders[voice] = 0
    rg_sound_log("note #{number} 0")
    rg_sound_log("voice #{voice} #{number} 0 0")
    rg_sound_log("noise_rest") if voice == RG_NOISE_VOICE
    rg_sound_log("stop_wave") if voice == RG_WAVE_VOICE
    rg_silence_voice(voice)
  end

  numbers = rg_song_numbers(rg_effect_field(effect, RG_EFFECT_NOTES))
  part = numbers + RG_NUMBERS_PER_SONG
  squares_met = [0]
  @rg_game_music[numbers + 4].times do
    walk, part = rg_read_part(number, part, false, squares_met)
    rg_sound_log("note #{number} 0") if walk.kind == RG_PART_RECORDED && rg_mix_release_music(effect, walk.tone) != 0
  end
end

def rg_play_effect_note(effect, part, note)
  music = @rg_game_music
  number = rg_effect_field(effect, RG_EFFECT_SONG)
  rank = rg_effect_field(effect, RG_EFFECT_RANK)
  pitch = music[note + 1]
  volume = music[note + 2]
  sounds = rg_note_sounds(part.kind, pitch, volume, rg_note_fade(part, note))

  if part.kind == RG_PART_RECORDED
    sound = music[note + 3]
    numbers = 1 + (sound * RG_NUMBERS_PER_NOTE_SOUND)
    heard = if !sounds
              rg_mix_release_music(effect, part.tone)
            elsif music[note + 5].anybits?(RG_GLIDES)
              rg_mix_glide_music_note(effect, part.tone, numbers)
            else
              rg_mix_start_music_note(effect, part.tone, rank, numbers, volume)
            end
    rg_sound_log("note #{number} #{pitch}") if heard != 0
    return
  end
  return unless rg_claim_voice(part.voice, rank, sounds || rg_effect_field(effect, RG_EFFECT_KEEPS_VOICES) == 1)

  ticks = music[note + 3]
  fade = rg_note_fade(part, note)
  rg_drop_held_note(part.voice)
  rg_sound_log("note #{number} #{pitch}")
  rg_log_voice_set(part.voice, number, pitch, volume, note)
  rg_wobble_start(part.voice, note)
  rg_shape_start(part.voice, note)
  @rg_sides[part.voice] = rg_note_pan(note)
  case part.kind
  when RG_PART_WAVE
    if pitch == 0
      rg_sound_log("stop_wave")
      rg_silence_voice(part.voice)
    else
      rg_sound_log("part_wave #{number} #{part.number} #{pitch}")
      rg_wave_put_in(part.tone)
      rg_wave_start(ticks, rg_wave_quarters_at(volume))
      rg_voice_struck(RG_WAVE_VOICE)
    end
  when RG_PART_NOISE
    if pitch == 0
      rg_sound_log("noise_rest")
      rg_silence_voice(part.voice)
    else
      rg_sound_log("part_noise #{number} #{part.number} #{pitch}")
      rg_noise_start(ticks, part.tone, volume, fade)
      rg_voice_struck(RG_NOISE_VOICE)
    end
  else
    rg_square_start(part.voice, ticks, rg_note_eighths(part, note), pitch == 0 ? 0 : volume, fade, rg_note_slide(note))
    rg_voice_struck(part.voice) if pitch != 0
  end
end

def rg_play_effect_frame(effect)
  number = rg_effect_field(effect, RG_EFFECT_SONG)
  numbers = rg_song_numbers(rg_effect_field(effect, RG_EFFECT_NOTES))
  if @rg_effect_stopping[effect]
    @rg_effect_stopping[effect] = false
    rg_finish_effect(effect)
  end
  if @rg_effect_asked_now[effect]
    @rg_effect_running[effect] = true
    @rg_effect_frame[effect] = 0
    @rg_effect_cursors[effect] = Array.new(RG_PARTS_MOST, 0)
    rg_sound_log("sound_effect #{effect}")
  elsif @rg_effect_running[effect] && @rg_effect_frame[effect] >= @rg_game_music[numbers]
    rg_finish_effect(effect)
  end
  return unless @rg_effect_running[effect]

  part_total = @rg_game_music[numbers + 4]
  rg_fault("a sound effect has #{part_total} parts, and the most is #{RG_PARTS_MOST}") if part_total > RG_PARTS_MOST
  part = numbers + RG_NUMBERS_PER_SONG
  squares_met = [0]
  cursors = @rg_effect_cursors[effect]
  part_total.times do |i|
    walk, part = rg_read_part(number, part, false, squares_met)
    next if cursors[i] >= walk.count

    note = walk.notes + (RG_NUMBERS_PER_NOTE * cursors[i])
    next if @rg_game_music[note] != @rg_effect_frame[effect]

    cursors[i] += 1
    rg_play_effect_note(effect, walk, note)
  end
  @rg_effect_frame[effect] += 1
end

# --- the frame ---

def rg_effects_by_rank = RG_EFFECT_ROWS + (rg_effect_count * RG_NUMBERS_PER_EFFECT)

# The player's frame: the tune caught up with, then every effect that outranks the tune, the tune,
# and the effects below it.
def rg_music_sound_frame
  @rg_level = rg_full_level if @rg_level < 0
  rg_refuse_too_many_effects
  rg_switch_to_wanted_song
  rg_effect_count.times do |effect|
    @rg_effect_asked_now[effect] = @rg_effect_asked[effect]
    @rg_effect_asked[effect] = false
  end
  tune = @rg_playing >= 0 ? @rg_game_music[@rg_song + 3] : -1
  by_rank = rg_effects_by_rank
  at = 0
  while at < rg_effect_count && rg_effect_field(@rg_game_effects[by_rank + at], RG_EFFECT_RANK) > tune
    rg_play_effect_frame(@rg_game_effects[by_rank + at])
    at += 1
  end
  rg_play_song_frame if @rg_playing >= 0
  while at < rg_effect_count
    rg_play_effect_frame(@rg_game_effects[by_rank + at])
    at += 1
  end
  rg_step_swells
  rg_step_wobbles
  rg_step_shapes
end

def rg_music_start_here
  @rg_level = rg_full_level if @rg_level < 0
  rg_play_song_frame if rg_switch_to_wanted_song && @rg_playing >= 0
end

def rg_effect_start_here_one_of(effects, count, which)
  return if which < 0 || which >= count

  asked = effects[which]
  rg_request_effect(asked)
  return unless @rg_effect_asked[asked]

  by_rank = rg_effects_by_rank
  rg_effect_count.times do |at|
    effect = @rg_game_effects[by_rank + at]
    if effect == asked
      @rg_effect_asked[asked] = false
      @rg_effect_asked_now[asked] = true
      rg_play_effect_frame(asked)
      @rg_effect_asked_now[asked] = false
    elsif @rg_effect_stopping[effect]
      @rg_effect_stopping[effect] = false
      rg_finish_effect(effect)
    end
  end
end

def rg_music_start_here_one_of(songs, count, which)
  return if which < 0 || which >= count

  rg_music_request(songs[which])
  rg_music_start_here
end

def rg_play_song_frame
  rg_follow_level(@rg_level_variable.call) if @rg_level_variable
  return if @rg_music_held

  @rg_part_count.times do |i|
    part = @rg_parts[i]
    next if part.next_note >= part.count

    note = part.notes + (RG_NUMBERS_PER_NOTE * part.next_note)
    next if @rg_game_music[note] != @rg_song_frame

    rg_play_note(part, note)
    part.next_note += 1
  end

  @rg_song_frame += 1
  return if @rg_song_frame < @rg_game_music[@rg_song]

  if @rg_game_music[@rg_song + 2] != 0
    @rg_ended = @rg_playing
    return
  end
  @rg_song_frame = @rg_game_music[@rg_song + 1]
  rg_start_walks(true)
end

# --- the state image (rg_music.c says what each field holds) ---

RG_WOBBLE_NUMBERS = 6
RG_SWELL_NUMBERS = 7
RG_SHAPE_NUMBERS = 3
RG_EFFECT_STATE_NUMBERS = 5 + RG_PARTS_MOST

# "music": the tune wanted, playing and ended, the stops asked and seen, whether it is held, how
# far into the tune, the volume its notes were set at, and how many notes and voices are held.
RgMusicFields = Data.define(:wanted, :playing, :ended, :stops, :stops_seen, :held, :song_frame, :level, :held_notes,
                           :held_voices)

# "music.parts", one a part of the playing tune: whether it walks its notes after the first time
# through, and which comes next. The rest of a part is the song's, read again from it.
RgPartFields = Data.define(:after_first, :next_note)

# rg_hook_visit_sound_state (rg_music.c's rg_music_visit_sound_state).
def rg_music_visit_sound_state
  fields = rg_state_record("music", RgMusicFields.new(
                                     wanted: @rg_wanted, playing: @rg_playing, ended: @rg_ended, stops: @rg_stops,
                                     stops_seen: @rg_stops_seen, held: rg_state_flag(@rg_music_held),
                                     song_frame: @rg_song_frame, level: @rg_level, held_notes: @rg_holding.length,
                                     held_voices: @rg_holder_order.length
                                   ))
  songs = (-1...rg_song_count)
  unless [fields.wanted, fields.playing, fields.ended].all? { |song| songs.cover?(song) } &&
         fields.held_notes.between?(0, RG_PARTS_MOST) && fields.held_voices.between?(0, RG_NOISE_VOICE)
    rg_state_refuse_damaged("the music holds more than it can")
  end
  @rg_wanted = fields.wanted
  @rg_playing = fields.playing
  @rg_ended = fields.ended
  @rg_stops = fields.stops
  @rg_stops_seen = fields.stops_seen
  @rg_music_held = fields.held != 0
  @rg_song_frame = fields.song_frame
  @rg_level = fields.level
  rg_visit_part_walks
  rg_visit_held_notes(fields.held_notes)
  rg_visit_music_voices(fields.held_voices)
  rg_visit_effects
end

def rg_visit_part_walks
  if rg_state_reading
    @rg_song = @rg_playing >= 0 ? rg_song_numbers(@rg_playing) : 0
    @rg_part_count = @rg_playing >= 0 ? @rg_game_music[@rg_song + 4] : 0
    rg_state_refuse_damaged("the song has more parts than a song can") if @rg_part_count > RG_PARTS_MOST
  end
  squares_met = [0]
  written = @rg_song + RG_NUMBERS_PER_SONG
  part_fields = Array.new(rg_state_reading ? 0 : @rg_part_count) do |i|
    first, written = rg_read_part(@rg_playing, written, false, squares_met)
    part = @rg_parts[i]
    RgPartFields.new(after_first: rg_state_flag(part.notes != first.notes || part.count != first.count), next_note: part.next_note)
  end
  part_fields = rg_state_records("music.parts", part_fields, RgPartFields, @rg_part_count)
  return unless rg_state_reading

  squares_met = [0]
  written = @rg_song + RG_NUMBERS_PER_SONG
  part_fields.each_with_index do |fields, i|
    walk, written = rg_read_part(@rg_playing, written, fields.after_first != 0, squares_met)
    rg_state_refuse_damaged("a part of the song is past its last note") unless fields.next_note.between?(0, walk.count)
    walk.next_note = fields.next_note
    @rg_parts[i] = walk
  end
end

def rg_visit_held_notes(count)
  @rg_holding = rg_state_records("music.holding", @rg_holding, RgHeldNote, count)
  return if @rg_holding.all? { |note| note.voice.between?(0, RG_NOISE_VOICE) }

  rg_state_refuse_damaged("a held note is on a voice there is not")
end

# Each voice's wobble, swell and shapes, who holds it, and the voices in the order first held.
def rg_visit_music_voices(holder_count)
  numbers = []
  (1..RG_WAVE_VOICE).each do |v|
    w = @rg_wobbles[v]
    numbers.push(w.vibrato, w.wait, w.left, rg_state_flag(w.rising), w.steps, w.ticks)
  end
  (1..RG_NOISE_VOICE).each do |v|
    s = @rg_swells[v]
    numbers.push(rg_state_flag(s.active), s.step || 0, s.volume || 0, s.counted || 0, rg_state_flag(s.swelling),
                 s.wave_ticks || 0, s.eighths_high || 0)
  end
  (1..RG_SQUARE_VOICES).each { |v| numbers.push(@rg_shapes[v].bits, @rg_shapes[v].frame, rg_state_flag(@rg_shapes[v].steps)) }
  numbers.concat(@rg_holders[1..], Array.new(RG_NOISE_VOICE) { |i| @rg_holder_order[i] || 0 })
  numbers = rg_state_numbers("music.voices", numbers)

  at = 0
  (1..RG_WAVE_VOICE).each do |v|
    n = numbers[at, RG_WOBBLE_NUMBERS]
    @rg_wobbles[v] = RgWobble.new(n[0], n[1], n[2], n[3] != 0, n[4], n[5])
    at += RG_WOBBLE_NUMBERS
  end
  (1..RG_NOISE_VOICE).each do |v|
    n = numbers[at, RG_SWELL_NUMBERS]
    @rg_swells[v] = RgSwellWalk.new(n[0] != 0, n[1], n[2], n[3], n[4] != 0, n[5], n[6])
    at += RG_SWELL_NUMBERS
  end
  (1..RG_SQUARE_VOICES).each do |v|
    n = numbers[at, RG_SHAPE_NUMBERS]
    @rg_shapes[v] = RgShapeWalk.new(n[0], n[1], n[2] != 0)
    at += RG_SHAPE_NUMBERS
  end
  @rg_holders = [0, *numbers[at, RG_NOISE_VOICE]]
  @rg_holder_order = numbers[at + RG_NOISE_VOICE, holder_count]
  return if @rg_holder_order.all? { |voice| voice.between?(1, RG_NOISE_VOICE) }

  rg_state_refuse_damaged("a voice is held that there is not")
end

def rg_visit_effects
  numbers = Array.new(rg_effect_count) do |e|
    [rg_state_flag(@rg_effect_asked[e]), rg_state_flag(@rg_effect_asked_now[e]), rg_state_flag(@rg_effect_stopping[e]),
     rg_state_flag(@rg_effect_running[e]), @rg_effect_frame[e], *(@rg_effect_cursors[e] || Array.new(RG_PARTS_MOST, 0))]
  end
  numbers = rg_state_numbers("music.effects", numbers.flatten)
  numbers.each_slice(RG_EFFECT_STATE_NUMBERS).with_index do |n, e|
    @rg_effect_asked[e], @rg_effect_asked_now[e], @rg_effect_stopping[e], @rg_effect_running[e] = n[0, 4].map { |flag| flag != 0 }
    @rg_effect_frame[e] = n[4]
    @rg_effect_cursors[e] = n[5, RG_PARTS_MOST]
  end
end

# --- a part's notes in the file (rg_music.h, rg_music_fill_notes; rg_music.c says each step) ---

RG_NOTES_AT = 0
RG_NOTES_TICKS = 1
RG_NOTES_FIRST_ROOM = 2
RG_NOTES_RECORDS_AT = 4
RG_NOTES_RECORDS = 5
RG_NOTES_SONG_AT = 6
RG_NOTES_COMES_ROUND = 7
RG_NOTES_REST_LAST = 8
RG_NOTES_FLAGS = 9
RG_NOTES_SHAPES = 10
RG_NOTES_INSTRUMENTS = 11
RG_NOTES_RECORDED = 12
RG_NOTES_SIDE_FLAGS = 13
RG_NOTES_CLOCKS = 16
RG_NOTES_RECORD_BYTES = 17
RG_NOTES_HEADER_NUMBERS = 18
RG_NOTE_SIDES = 3
RG_NOTE_KEYS = 128
RG_NOTE_VOLUMES = 16
RG_NOTE_VOICED_BYTES = 32
RG_NOTE_NUMBERS = 6
# rg_music.c's voiced record settings and the bits they take in a note's fifth and sixth numbers.
RG_NAMES_PITCH = 1
RG_NAMES_FADE = 2
RG_NAMES_DUTY = 4
RG_NAMES_VIBRATO = 8
RG_NAMES_SLIDE = 16
RG_NAMES_SHADE = 32
RG_NAMES_CARRIES = 64
RG_NOTE_MOST_PITCH = 2047
RG_NOTE_MOST_FADE = 15
RG_NOTE_MOST_SLIDE = 127
RG_NOTE_SHADE_WHOLE = 64
RG_NOTE_SHADE_CODES = 4 + 64
RG_FLAG_FADE_BITS = 0x1F
RG_FLAG_HAS_FADE = 16
RG_FLAG_SLIDE_BITS = 0x1FE0
RG_FLAG_HAS_SLIDE = 32
RG_FLAG_SLIDE_AT = 6
RG_FLAG_HAS_VIBRATO = 1 << 13
RG_FLAG_VIBRATO_AT = 14
RG_SHAPE_DUTY_BITS = 0x1FF
RG_SHAPE_HAS_DUTY = 1 << 8
RG_SHAPE_CARRIES = 1 << 9
RG_NAMES_HZ = 128
RG_NAMES_GLIDES = 256
RG_NOTE_MOST_HZ = 524_288 * 16
RG_HZ_RECORDED = 2
RG_NOISE_RUNGS = 8 * 14
RG_NOTE_SOUND_NUMBERS = 8
RG_HZ_LIST_NUMBERS = 8
RG_NOTE_GLIDES = 1 << 10

# rg_music.c's start_file_double.
def rg_start_file_double(high, low) = [high, low].pack("l>l>").unpack1("G")

# rg_music.c's start_file_hz_rules: where a voiced part's rules for a pitch between keys start.
def rg_start_file_hz_rules(rules)
  instruments = rules[RG_NOTES_INSTRUMENTS]
  same_recording = RG_NOTES_HEADER_NUMBERS + RG_NOTE_VOLUMES + 1
  clock_pitches = same_recording + instruments + RG_NOTE_KEYS + ((rules[RG_NOTES_RECORDED].zero? ? 1 : instruments + 1) * RG_NOTE_KEYS)
  voiced = clock_pitches + (2 * rules[RG_NOTES_CLOCKS])
  voiced + 2 + (2 * rules[voiced + 1])
end

# rg_music.c's start_file_noise_hz_ticks.
def rg_start_file_noise_hz_ticks(rules, hz_rules, hz)
  wanted = hz / 16.0
  nearest = 0
  ticks = 0
  RG_NOISE_RUNGS.times do |r|
    at = hz_rules + 1 + (r * 3)
    away = (rg_start_file_double(rules[at], rules[at + 1]) - wanted).abs
    if r.zero? || away < nearest
      nearest = away
      ticks = rules[at + 2]
    end
  end
  ticks
end

# rg_music.c's start_file_hz_row: a recorded note between keys written into row +row+.
def rg_start_file_hz_row(note_sounds, row, rules, hz_rules, list, hz)
  entry = hz_rules + 5 + (list * RG_HZ_LIST_NUMBERS)
  mix_rate = rg_start_file_double(rules[hz_rules + 1], rules[hz_rules + 2])
  rate = if rules[entry + 1] != 0
           width = rules[entry + 3]
           number = @rg_start_file.byteslice(rules[entry + 2], width).unpack1(RG_LENGTH_NUMBER_READS.fetch(width)[rules[entry + 4]])
           top = 1 << ((width * 8) - 1)
           read = rules[entry + 5] == 1 && number >= top ? number - (top * 2) : number
           [read, 1].max.to_f
         else
           rg_start_file_double(rules[entry + 2], rules[entry + 3])
         end
  ratio = (hz / 16.0) / rg_start_file_double(rules[entry + 6], rules[entry + 7])
  step = ((rate / mix_rate) * ratio) * 65_536
  into = 1 + (row * RG_NOTE_SOUND_NUMBERS)
  from = 1 + (rules[entry] * RG_NOTE_SOUND_NUMBERS)
  RG_NOTE_SOUND_NUMBERS.times { |i| note_sounds[into + i] = note_sounds[from + i] }
  note_sounds[into + 1] = step < 1 ? 1 : [(step + 0.5).floor, 2_147_483_647].min
end

# rg_music.c's start_file_shade_side, start_file_shade_code and start_file_slide_named.
def rg_start_file_shade_side(shade)
  left = shade.negative? ? RG_NOTE_SHADE_WHOLE : RG_NOTE_SHADE_WHOLE - shade
  right = shade.positive? ? RG_NOTE_SHADE_WHOLE : RG_NOTE_SHADE_WHOLE + shade
  return 1 if left >= right * 2
  return 2 if right >= left * 2

  0
end

def rg_start_file_shade_code(shade)
  return 0 if shade.zero?
  return 1 if shade == -RG_NOTE_SHADE_WHOLE
  return 2 if shade == RG_NOTE_SHADE_WHOLE

  RG_NOTE_SHADE_CODES + shade
end

def rg_start_file_slide_named(slide) = slide.zero? || (slide <= RG_NOTE_MOST_SLIDE && (slide >> 4).positive? && (slide & 7).positive?)

# rg_music.c's start_file_event_voice: a voiced +record+'s settings (its bytes) into +event+.
def rg_start_file_event_voice(event, record, takes)
  pitch, fade, duty, vibrato, slide, shade, all_names, hz_low, hz_high = record.byteslice(12, 13).unpack("vCCvCcvvC")
  names = all_names & takes
  if names.anybits?(RG_NAMES_PITCH) && pitch <= RG_NOTE_MOST_PITCH
    event.pitch = pitch
    event.key = 0
  end
  event.fade = fade if names.anybits?(RG_NAMES_FADE) && fade <= RG_NOTE_MOST_FADE
  event.duty = duty if names.anybits?(RG_NAMES_DUTY)
  event.vibrato = (vibrato & 0xF).zero? ? 0 : vibrato | (all_names.anybits?(RG_NAMES_CARRIES) ? 1 << 16 : 0) if names.anybits?(RG_NAMES_VIBRATO)
  event.slide = slide if names.anybits?(RG_NAMES_SLIDE) && rg_start_file_slide_named(slide)
  event.side = rg_start_file_shade_code(shade) if names.anybits?(RG_NAMES_SHADE) && shade.abs <= RG_NOTE_SHADE_WHOLE
  hz = hz_low | (hz_high << 16)
  if names.anybits?(RG_NAMES_HZ) && event.clock.negative? && hz.between?(1, RG_NOTE_MOST_HZ)
    event.hz = hz
    event.key = 0
  end
  return unless names.anybits?(RG_NAMES_GLIDES)

  event.glides = 1
  event.instrument = 0
  event.recording = -1
  event.volume = RG_NOTE_VOLUMES
end

# rg_music.c's start_file_voice_numbers: [fifth, sixth] with +event+'s settings in their places.
def rg_start_file_voice_numbers(flags, shapes, event)
  f = flags
  s = shapes
  f = (f & ~RG_FLAG_FADE_BITS) | RG_FLAG_HAS_FADE | event.fade if event.fade >= 0
  f = (f & ~RG_FLAG_SLIDE_BITS) | RG_FLAG_HAS_SLIDE | (event.slide << RG_FLAG_SLIDE_AT) if event.slide >= 0
  if event.vibrato >= 0
    f = (f & ~(RG_FLAG_HAS_VIBRATO | (0xFFFF << RG_FLAG_VIBRATO_AT))) | RG_FLAG_HAS_VIBRATO | ((event.vibrato & 0xFFFF) << RG_FLAG_VIBRATO_AT)
    s = (s & ~RG_SHAPE_CARRIES) | ((event.vibrato >> 16).positive? ? RG_SHAPE_CARRIES : 0)
  end
  s = (s & ~RG_SHAPE_DUTY_BITS) | RG_SHAPE_HAS_DUTY | event.duty if event.duty >= 0
  slides = f.anybits?(RG_FLAG_HAS_SLIDE) && ((f >> RG_FLAG_SLIDE_AT) & 0x7F) != 0
  wobbles = f.anybits?(RG_FLAG_HAS_VIBRATO) && ((f >> RG_FLAG_VIBRATO_AT) & 0xF) != 0
  if slides && wobbles
    f &= ~(0xFFFF << RG_FLAG_VIBRATO_AT)
    s &= ~RG_SHAPE_CARRIES
  end
  [f, s]
end
RG_NOTE_ENDS_PART = 0xFFFF
RG_NOTE_NO_LOUDNESS = 0xFFFF
RG_NOTE_FULL_LOUDNESS = 512

# rg_music.c's start_file_event_volume.
def rg_start_file_event_volume(volume, loudness, recorded)
  if recorded != 0 && loudness != RG_NOTE_NO_LOUDNESS
    return RG_NOTE_VOLUMES - 1 if loudness >= RG_NOTE_FULL_LOUDNESS

    return loudness.zero? ? 0 : RG_NOTE_VOLUMES + 1 + loudness
  end
  volume < RG_NOTE_VOLUMES ? volume : RG_NOTE_VOLUMES
end

# rg_music.c's start_file_event_side and start_file_event_clock.
def rg_start_file_event_side(pan, recorded) = recorded.zero? && pan < RG_NOTE_SIDES ? pan : RG_NOTE_SIDES

def rg_start_file_event_clock(clock, key, clocks) = key >= 0 && clock < clocks ? clock : -1

# An event of a part (rg_music.c's start_file_event).
RgStartFileEvent = Struct.new(:frame, :key, :instrument, :recording, :volume, :side, :clock, :pitch, :fade, :duty, :vibrato, :slide,
                              :hz, :row, :glides)

# rg_music.c's start_file_keep_event: +event+ after those in +events+.
def rg_start_file_keep_event(events, event, total_frames)
  return if event.frame >= total_frames

  if !events.empty? && events.last.frame == event.frame
    events[-1] = event
  else
    events << event
  end
end

# rg_music.c's start_file_write_note: +event+ as a note's six numbers, from +into+ on in +music+.
def rg_start_file_write_note(music, into, event, rules)
  heard = RG_NOTES_HEADER_NUMBERS
  pitches = heard + RG_NOTE_VOLUMES + 1 + rules[RG_NOTES_INSTRUMENTS]
  lasts = pitches + RG_NOTE_KEYS
  clock_pitches = lasts + ((rules[RG_NOTES_RECORDED].zero? ? 1 : rules[RG_NOTES_INSTRUMENTS] + 1) * RG_NOTE_KEYS)
  clock_lasts = clock_pitches + rules[RG_NOTES_CLOCKS]
  voiced = clock_lasts + rules[RG_NOTES_CLOCKS]
  number_pitches = voiced + 2
  # Only a voiced part's rules go on past the clocks.
  number_lasts = number_pitches + (rules[RG_NOTES_RECORD_BYTES] == RG_NOTE_VOICED_BYTES ? rules[voiced + 1] : 0)
  rest = event.key.negative?
  clocked = event.clock >= 0
  numbered = event.pitch >= 0
  between = event.hz >= 0
  music[into] = event.frame
  music[into + 1] = if rest then 0
                    elsif clocked then rules[clock_pitches + event.clock]
                    elsif numbered then rules[number_pitches + event.pitch]
                    elsif between then -event.hz - 1
                    else rules[pitches + event.key]
                    end
  music[into + 2] = event.volume <= RG_NOTE_VOLUMES ? rules[heard + event.volume] : event.volume - RG_NOTE_VOLUMES - 1
  music[into + 3] = if rest then rules[RG_NOTES_REST_LAST]
                    elsif clocked then rules[clock_lasts + event.clock]
                    elsif numbered then rules[number_lasts + event.pitch]
                    elsif between
                      rules[RG_NOTES_RECORDED].zero? ? rg_start_file_noise_hz_ticks(rules, rg_start_file_hz_rules(rules), event.hz) : event.row
                    else rules[lasts + (event.instrument * RG_NOTE_KEYS) + event.key]
                    end
  side = event.side >= RG_NOTE_SHADE_CODES - RG_NOTE_SHADE_WHOLE ? rg_start_file_shade_side(event.side - RG_NOTE_SHADE_CODES) : event.side
  music[into + 4] = if rest then 0
                    elsif side < RG_NOTE_SIDES then rules[RG_NOTES_SIDE_FLAGS + side]
                    else rules[RG_NOTES_FLAGS]
                    end
  music[into + 5] = rest ? 0 : rules[RG_NOTES_SHAPES]
  return if rest

  music[into + 4], music[into + 5] = rg_start_file_voice_numbers(music[into + 4], music[into + 5], event) if rules[RG_NOTES_RECORD_BYTES] == RG_NOTE_VOICED_BYTES
  music[into + 5] |= RG_NOTE_GLIDES if event.glides == 1
end

def rg_music_fill_notes(music, note_sounds, rules, tick_frames)
  ticks = rules[RG_NOTES_TICKS]
  total_frames = music[rules[RG_NOTES_SONG_AT]]
  loop_frame = music[rules[RG_NOTES_SONG_AT] + 1]
  instruments = rules[RG_NOTES_INSTRUMENTS]
  record_bytes = rules[RG_NOTES_RECORD_BYTES]
  same_recording = RG_NOTES_HEADER_NUMBERS + RG_NOTE_VOLUMES + 1
  clock_pitches = same_recording + instruments + RG_NOTE_KEYS + ((rules[RG_NOTES_RECORDED].zero? ? 1 : instruments + 1) * RG_NOTE_KEYS)
  takes = record_bytes == RG_NOTE_VOICED_BYTES ? rules[clock_pitches + (2 * rules[RG_NOTES_CLOCKS])] : 0
  hz_rules = rg_start_file_hz_rules(rules) if takes != 0
  frame_of = ->(tick) { tick < ticks ? tick_frames[tick] : total_frames }

  # The records before the one that ends the part, in the order of their ticks; those on one tick
  # stay in the file's order. Each is its first twelve bytes read, and its bytes.
  held_bytes = @rg_start_file.byteslice(rules[RG_NOTES_RECORDS_AT], rules[RG_NOTES_RECORDS] * record_bytes)
  records = Array.new(rules[RG_NOTES_RECORDS]) do |at|
    bytes = held_bytes.byteslice(at * record_bytes, record_bytes)
    [*bytes.unpack("vvCCCCvC"), bytes, at]
  end
  records = records.take_while { |record| record[0] != RG_NOTE_ENDS_PART }
  records = records.each_with_index.sort_by { |record, place| [record[0], place] }.map(&:first)

  events = []
  rest_of_part = RgStartFileEvent.new(0, -1, 0, -1, RG_NOTE_VOLUMES, RG_NOTE_SIDES, -1, -1, -1, -1, -1, -1, -1, -1, 0)
  records.each_with_index do |(tick, length, key, instrument, volume, pan, loudness, clock_byte, bytes, place), n|
    named = instrument < instruments
    played = key < RG_NOTE_KEYS ? key : -1
    clock = rg_start_file_event_clock(clock_byte, played, rules[RG_NOTES_CLOCKS])
    event = RgStartFileEvent.new(frame_of.call(tick), clock >= 0 ? 0 : played, named ? instrument + 1 : 0,
                                 named ? rules[same_recording + instrument] : -1,
                                 rg_start_file_event_volume(volume, loudness, rules[RG_NOTES_RECORDED]),
                                 rg_start_file_event_side(pan, rules[RG_NOTES_RECORDED]), clock, -1, -1, -1, -1, -1, -1, -1, 0)
    rg_start_file_event_voice(event, bytes, takes) if takes != 0 && played >= 0
    # A recorded note between keys has a row of its own, one for each record.
    if event.hz >= 0 && rules[hz_rules] == RG_HZ_RECORDED
      event.row = rules[hz_rules + 3] + place
      rg_start_file_hz_row(note_sounds, event.row, rules, hz_rules, event.instrument, event.hz)
    end
    rg_start_file_keep_event(events, event, total_frames)
    ends = tick + length
    next unless length.positive? && !(n + 1 < records.length && records[n + 1][0] <= ends)

    rest = rest_of_part.dup
    rest.frame = frame_of.call(ends)
    rg_start_file_keep_event(events, rest, total_frames)
  end

  comes_round = rules[RG_NOTES_COMES_ROUND] != 0
  split = 0
  silence = false
  strike = false
  if comes_round
    split = events.index { |event| event.frame >= loop_frame } || events.length
    unless split < events.length && events[split].frame == loop_frame
      held = split.positive? ? events[split - 1] : nil
      ending = events.last
      if held && held.key >= 0
        strike = !(ending.key == held.key && ending.recording == held.recording && ending.volume == held.volume &&
                   ending.side == held.side && ending.clock == held.clock && ending.pitch == held.pitch &&
                   ending.fade == held.fade && ending.duty == held.duty && ending.vibrato == held.vibrato &&
                   ending.slide == held.slide && ending.hz == held.hz && ending.glides == held.glides)
      else
        silence = !ending.nil? && ending.key >= 0
      end
    end
  end

  at_loop = (strike ? events[split - 1] : rest_of_part).dup
  at_loop.frame = loop_frame
  first = events.first(split) + (silence ? [at_loop] : []) + events.drop(split)
  again = comes_round ? (silence || strike ? [at_loop] : []) + events.drop(split) : []
  again_at = rules[RG_NOTES_AT] + (rules[RG_NOTES_FIRST_ROOM] * RG_NOTE_NUMBERS)
  first.each_with_index { |event, n| rg_start_file_write_note(music, rules[RG_NOTES_AT] + (n * RG_NOTE_NUMBERS), event, rules) }
  again.each_with_index { |event, n| rg_start_file_write_note(music, again_at + (n * RG_NOTE_NUMBERS), event, rules) }
end

# --- a song's length in the file (rg_music.h, rg_music_fill_song_length; rg_music.c says each step) ---

RG_LENGTH_SONG_AT = 0
RG_LENGTH_TICKS = 1
RG_LENGTH_LONGEST = 2
RG_LENGTH_LENGTH = 3
RG_LENGTH_LOOP = 8
RG_LENGTH_NUMBER_READS = Ractor.make_shareable({ 1 => %w[C C], 2 => %w[v n], 4 => %w[V N] })

# rg_music.c's start_file_tick: the tick the four numbers of +rules+ from +where+ on name.
def rg_start_file_tick(rules, where)
  width = rules[where + 1]
  number = @rg_start_file.byteslice(rules[where], width).unpack1(RG_LENGTH_NUMBER_READS.fetch(width)[rules[where + 2]])
  top = 1 << ((width * 8) - 1)
  tick = rules[where + 3] == 1 && number >= top ? number - (top * 2) : number
  tick.clamp(0, 0x7FFFFFFF)
end

def rg_music_fill_song_length(music, rules, tick_frames)
  song = rules[RG_LENGTH_SONG_AT]
  ticks = rules[RG_LENGTH_TICKS]
  longest = rules[RG_LENGTH_LONGEST]
  frame_of = ->(tick) { tick < ticks ? tick_frames[tick] : longest }
  total = music[song]
  loop_frame = music[song + 1]
  total = frame_of.call(rg_start_file_tick(rules, RG_LENGTH_LENGTH + 1)).clamp(1, longest) if rules[RG_LENGTH_LENGTH] != 0
  loop_frame = frame_of.call(rg_start_file_tick(rules, RG_LENGTH_LOOP + 1)) if rules[RG_LENGTH_LOOP] != 0
  music[song] = total
  music[song + 1] = loop_frame < total ? loop_frame : 0
end

# --- a part's wave in the file (rg_music.h, rg_music_fill_wave; rg_music.c says each step) ---

RG_WAVE_FILL_BYTES = 16
RG_WAVE_FILL_STEPS = 32

def rg_music_fill_wave(waveforms, which, at)
  steps = @rg_start_file.byteslice(at, RG_WAVE_FILL_BYTES).bytes.flat_map { |byte| [byte >> 4, byte & 0xF] }
  waveforms[1 + (which * RG_WAVE_FILL_STEPS), RG_WAVE_FILL_STEPS] = steps
end
