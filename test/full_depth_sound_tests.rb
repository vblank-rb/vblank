# frozen_string_literal: true

require "all/vblank/audio/test_wav_import"

# A RECORDING OF SIXTEEN BITS, played at all sixteen. A game gives `sample` 16-bit sound (a 16-bit
# WAV, or `pcm:` with `bits: 16`), and a build for a computer (C, JavaScript, Ruby) mixes every bit
# of it, where a console's build keeps what that console holds, the high byte, as it always has.
# What a computer build mixes is `full_depth_sound`; the interpreter works it out too, and the
# game as C, JavaScript and Ruby are checked against it on every frame. No console's cartridge
# holds it, so this is played by the interpreter and the game as C, JavaScript and Ruby, and not
# in test/all/. The cartridge's side, that it sounds as it did, is
# test/lowering/gba/vblank/builder/test_sample_full_depth_cartridge.rb.
module FullDepthSoundTests
  include WavFiles

  # A level whose low byte is most of it: 300 is 1 in eight bits, and 300 in sixteen.
  QUIET = 300

  # A game that plays +recordings+ (each a hash of `sample`'s settings, by name) on a loop from its
  # first frame, together.
  private def looping_game(recordings)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      played = recordings.map { |name, settings| sample(name, **settings) }
      played.each { |recording| recording.play(loop: true) }
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # Every level heard after the first slice with sound in it.
  private def levels_heard(program, frames: 4)
    slices = game_player.run(program, frames: frames).full_depth_sound
    slices.drop_while { |slice| slice.all?(&:zero?) }.flatten
  end

  def test_a_quiet_16_bit_recording_is_heard_at_its_own_level
    heard = levels_heard(looping_game(hum: { pcm: [QUIET] * 64, bits: 16, rate: 8192 }))

    refute_empty heard
    assert_equal [QUIET], heard.uniq, "a recording at full plays its own level, the low byte kept"
  end

  def test_a_16_bit_ramp_keeps_the_steps_eight_bits_flatten
    ramp = (0...256).map { |step| step * 3 }
    heard = levels_heard(looping_game(ramp: { pcm: ramp, bits: 16, rate: 8192 }))

    assert_operator heard.uniq.size, :>, 64, "eight bits would hold the ramp at three levels"
    assert(heard.any? { |level| level % 256 != 0 })
  end

  # An 8-bit recording in a game that mixes at sixteen is its sample shifted up eight bits: 2 is 512.
  def test_an_8_bit_recording_beside_a_16_bit_one_is_heard_shifted_up
    heard = levels_heard(looping_game(hum: { pcm: [QUIET] * 64, bits: 16, rate: 8192 },
                                      buzz: { pcm: [2] * 64, rate: 8192 }))

    assert_equal [QUIET + 512], heard.uniq
  end

  # A stereo 16-bit WAV is the average of its two sides, at all sixteen bits: 1000 and 601 are 800.
  def test_a_16_bit_wav_is_heard_at_sixteen_bits
    with_wav(wav_bytes(samples: [1000, 601] * 64, rate: 8192, bits: 16, channels: 2)) do |path|
      heard = levels_heard(looping_game(hum: { from: path }))

      assert_equal [800], heard.uniq
    end
  end

  # A recording cut to a length plays that many of its sixteen-bit samples, and loops round them.
  def test_a_16_bit_recording_cut_to_a_length_plays_that_many
    heard = levels_heard(looping_game(hum: { pcm: ([QUIET] * 32) + ([5000] * 32), bits: 16, length: 32, rate: 8192 }))

    assert_equal [QUIET], heard.uniq
  end

  # An instrument of sixteen bits, played as a song's note, is heard at sixteen too.
  def test_a_16_bit_instrument_in_a_song_keeps_its_low_byte
    score = VBlank::Audio::Score
    tune = score.new(tempo: 150, length: 48, parts: [score::Part.new(plays: :hum, notes: [score::Note.new(at: 0, key: :C4, length: 48)])])
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :hum, pcm: [QUIET] * 64, bits: 16, rate: 8192, note: :C4, holds_from: 0
      music = songs :music, [tune]
      music.play 0
      game_loop { wait_vblank }
    end
    b.finalize_program
    heard = levels_heard(b.program, frames: 8)

    refute_empty heard
    assert(heard.any? { |level| level != 0 && level % 256 != 0 }, "the note keeps the low byte eight bits drop")
  end

  # A game of 8-bit recordings alone mixes as it always has, full depth or not.
  def test_a_game_of_8_bit_recordings_mixes_its_bytes
    heard = levels_heard(looping_game(buzz: { pcm: [2] * 64, rate: 8192 }))

    assert_equal [2], heard.uniq
  end
end
