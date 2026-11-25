# frozen_string_literal: true

require "test_helper"

# Where in its frame a sound effect starts on a Genesis. The game asks the sound chip for a note
# through the Z80's mailbox, so everything the 68000 does before sending it moves the note's first
# sample later in the frame. A console's own drivers send a request straight to its effect by
# number, at a fixed cost: how many other effects a game declares, played or not, must not move
# where a note starts.
#
# Measured in sample pairs of the frame the effect is first heard on, with every voice heard.
class TestGenesisEffectOnset < Minitest::Test
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  PLAYED_ON = 20
  HEARD_ABOVE = 400
  FRAMES_LOOKED_AT = PLAYED_ON + 6
  # A Genesis cartridge is loud on its first frames, so the effect is looked for only from here on.
  LOOKED_FOR_FROM = PLAYED_ON - 2

  # One effect played on pass PLAYED_ON, with +unplayed+ others declared beside it that never play,
  # all of +group+ (none for nil).
  private def game(unplayed, group: nil)
    note = ->(key) { Score.new(tempo: 150, priority: 5, group: group, parts: [Part.new(notes: [Note.new(at: 0, key: key, length: 8)])]) }
    effects = { select: note.call(:E5) }
    unplayed.times { |n| effects[:"quiet#{n}"] = note.call(:C4) }
    VBlank.build("ONSET", console: :genesis, out: nil, err: nil) do
      enable_sound
      sfx = sound_effects :sfx, effects
      pass = var :pass, 0
      game_loop do
        pass += 1
        sfx.play :select if pass == PLAYED_ON
      end
    end
  end

  # [the frame the effect is first heard on, the sample pair of that frame it starts at].
  private def onset(cartridge)
    reader = VBlank::Diagnostics::Verifier.new(cartridge, frames: 0)
    reader.hearing(without: [])
    FRAMES_LOOKED_AT.times do |frame|
      reader.step(1)
      next if frame < LOOKED_FOR_FROM
      next unless reader.loudest_by_frame.last > HEARD_ABOVE

      pairs = reader.last_frame_samples.each_slice(2).to_a
      return [frame, pairs.index { |pair| pair.map(&:abs).max > HEARD_ABOVE }]
    end
    flunk "the effect is never heard"
  ensure
    reader&.close
  end

  def test_an_effect_starts_at_the_same_sample_however_many_effects_are_declared
    few = onset(game(1))

    assert_equal few, onset(game(24)), "24 effects declared beside it, against 1"
  end

  # An effect of a group looks for the one of its group sounding before it starts.
  def test_an_effect_of_a_group_starts_at_the_same_sample_however_many_its_group_has
    few = onset(game(1, group: :menu))

    assert_equal few, onset(game(24, group: :menu)), "24 of its group declared beside it, against 1"
  end
end
