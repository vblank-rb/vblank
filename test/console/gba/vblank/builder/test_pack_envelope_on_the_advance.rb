# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "made_up_original"

# AN INSTRUMENT'S ENVELOPE READ FROM THE DATA PACK (Builder::PackScores#pack_envelope_value): four
# bytes of a slot, in the order an Audio::Envelope keeps them. Here because a recording's shape is
# refused by the Color and the Genesis. The answer key is the same instrument given those four
# numbers by hand.
class TestPackEnvelopeOnTheAdvance < Minitest::Test
  include MadeUpOriginal

  # The made-up copy's filler bytes: a recording of 32 samples, and four bytes there that make an
  # envelope climbing in two frames and holding loud (153, 190, 227, 8).
  SOUND_AT = 0x1C0
  SOUND_COUNT = 32
  ENVELOPE_AT = 0x1F6

  # A game playing an instrument as a song's note of 48 ticks on the A button, its envelope read from
  # the pack when +from_pack+, or given by hand as the four numbers the copy holds there.
  private def envelope_game(folder, from_pack:)
    attack, decay, sustain, release = COPY.byteslice(ENVELOPE_AT, 4).bytes
    shape = VBlank::Audio::Envelope.new(attack: attack, decay: decay, sustain: sustain, release: release)
    score = VBlank::Audio::Score
    held = score.new(tempo: 150, length: 60, plays_once: true,
                     parts: [score::Part.new(plays: :tone, notes: [score::Note.new(at: 0, key: :E4, length: 48)])])
    from = original(folder)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      pack = data_pack(from: from, version: "1") do |slots|
        slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT
        slots.numbers :shapes, at: ENVELOPE_AT, count: 4, width: :byte, signed: false
      end
      # Held from its start, so the long note sounds past the recording's few milliseconds.
      if from_pack
        instrument :tone, pcm: pack[:bang], rate: 8000, envelope: pack[:shapes].envelope(0), holds_from: 0
      else
        instrument :tone, pcm: pack[:bang], rate: 8000, envelope: shape, holds_from: 0
      end
      music = songs :music, [held]
      game_loop do
        wait_vblank
        music.play 0 if pressed(:a)
      end
    end
    b.finalize_program
    b.program
  end

  def test_an_envelope_read_from_the_pack_sounds_as_the_same_four_numbers_given
    Dir.mktmpdir do |folder|
      wanted = game_player.hold(:a).run(envelope_game(folder, from_pack: false), frames: 20).mixed_sound
      heard = game_player.hold(:a).run(envelope_game(folder, from_pack: true), frames: 20).mixed_sound

      assert wanted.flatten.any? { |level| level != 0 }, "the instrument given its envelope sounds"
      assert_equal wanted, heard
    end
  end

  def test_an_envelope_past_the_end_of_its_slot_is_refused
    Dir.mktmpdir do |folder|
      pack = VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
        slots.numbers :shapes, at: ENVELOPE_AT, count: 4, width: :byte, signed: false
      end
      error = assert_raises(ArgumentError) { pack[:shapes].envelope(1) }

      assert_includes error.message, "no envelope 1"
    end
  end
end
