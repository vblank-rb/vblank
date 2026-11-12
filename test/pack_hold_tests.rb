# frozen_string_literal: true

require "tmpdir"
require "made_up_original"

# A RECORDING'S HOLD READ FROM THE DATA PACK, BUILT ALL-IN-ONE (Builder::SampledAudio#pack_hold_value):
# a number of the pack is the sample a held note reads back to, and one with every bit set is no
# hold, which is how a pack says a recording does not loop. The answer key is the same instrument
# written without `holds_from:`. Played by each console that plays an instrument, its cartridge
# holding what the build read; with the pack left out it is test/pack_sound_tests.rb's.
module PackHoldTests
  include MadeUpOriginal

  # The made-up copy's filler bytes: a recording of 32 samples, a byte of 255 (every bit set) and
  # a byte of 8, a sample inside the recording.
  SOUND_AT = 0x1C0
  SOUND_COUNT = 32
  NO_HOLD_AT = 0x1E4
  HOLD_AT = 0x1F9

  # A game playing an instrument as a song's note far longer than its recording on the A button,
  # its hold +from+ :no_hold (the byte of 255), :hold (the byte of 8) or :written (none given).
  private def hold_game(folder, from:)
    score = VBlank::Audio::Score
    long = score.new(tempo: 150, length: 40, plays_once: true,
                     parts: [score::Part.new(plays: :tone, notes: [score::Note.new(at: 0, key: :C4, length: 30)])])
    copy = original(folder)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      pack = data_pack(from: copy, version: "1") do |slots|
        slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT
        slots.numbers :no_holds, at: NO_HOLD_AT, count: 1, width: :byte, signed: false
        slots.numbers :holds, at: HOLD_AT, count: 1, width: :byte, signed: false
      end
      holds_from = { no_hold: pack[:no_holds].number(0), hold: pack[:holds].number(0), written: nil }.fetch(from)
      # Slow enough that its 32 samples last a few frames, so it is seen sounding.
      instrument :tone, pcm: pack[:bang], rate: 500, note: :C4, holds_from: holds_from
      music = songs :music, [long]
      game_loop do
        wait_vblank
        music.play 0 if pressed(:a)
      end
    end
    b.finalize_program
    b.program
  end

  # The recordings sounding after each frame, the A button pressed on the first. A console whose
  # sound chip plays each recording on a voice of its own has no mix to read, so what sounds is
  # what every console answers alike.
  private def sounding_by_frame(program)
    seen = []
    player = game_player.input_each_frame { |frame| frame == 1 ? [:a] : [] }
    player.each_vblank { |_frame| seen << player.active_samples }
    player.run(program, frames: 20)
    seen
  end

  def test_a_hold_of_every_bit_set_from_the_pack_plays_once_as_no_hold_given
    Dir.mktmpdir do |folder|
      wanted = sounding_by_frame(hold_game(folder, from: :written))
      held = sounding_by_frame(hold_game(folder, from: :hold))

      assert_includes wanted, [:tone], "the instrument sounds"
      assert_equal [], wanted.last, "with no hold it has stopped before its note ends"
      assert_equal [:tone], held.last, "held from sample 8 it goes on past the recording"
      assert_equal wanted, sounding_by_frame(hold_game(folder, from: :no_hold))
    end
  end
end
