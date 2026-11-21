# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "all/vblank/builder/test_hold_music"

# The music held where it is, on the Advance's own cartridge: what its first square voice is set
# to, frame by frame, read in the emulator. What every run plays is in
# test/all/vblank/builder/test_hold_music.rb, which keeps the games both files play.
class TestHoldMusicCartridge < Minitest::Test
  include HoldMusicGames

  VOICE = VBlank::Console::Hardware::REG_SOUND1CNT_H

  # What the first square voice's register says on each frame.
  private def voice_by_frame(program, name, frames:)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "held.gba")
      assemble_rom(program, name: name).write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      seen = Array.new(frames) do
        probe.step(1)
        probe.read32(VOICE) & 0xFFFF
      end
      probe.close
      seen
    end
  end

  private def volumes(seen) = seen.map { |value| value >> 12 }.chunk_while { |a, b| a == b }.map(&:first).drop_while(&:zero?)
  private def shape_at(value) = (value >> 6) & 3

  def test_the_voice_stays_on_the_note_held
    game = held_game { |pass| hold_music if pass == 30 }

    assert_equal [12, 8], volumes(voice_by_frame(game, "HOLD", frames: 130))
  end

  def test_released_music_carries_on_from_the_next_note
    game = held_game do |pass|
      hold_music if pass == 30
      release_music if pass == 40
    end

    assert_equal [12, 8, 4, 15], volumes(voice_by_frame(game, "RELEASE", frames: 110)).first(4)
  end

  def test_a_held_note_stops_stepping_its_shapes
    seen = voice_by_frame(held_game(lead: proc { duty %i[eighth half] }) { |pass| hold_music if pass == 30 },
                          "SHAPES", frames: 60)

    assert_operator seen[10..28].map { |value| shape_at(value) }.uniq.size, :>, 1, "it stepped before"
    assert_equal 1, seen[34..].map { |value| shape_at(value) }.uniq.size, "and not since"
  end

  # A sound effect outranking the tune, on its voice, stepping shapes of its own over the hold.
  def test_a_sound_effect_keeps_stepping_its_shapes_while_the_music_is_held
    effect = Score.new(tempo: 150, priority: 1, parts: [Part.new(notes: [Note.new(at: 0, key: :A5), Note.new(at: 20, key: 0)],
                                                                 duty: %i[eighth half])])
    seen = voice_by_frame(held_with_effect(effect) { |pass| pass == 40 }, "EFFECT", frames: 60)

    assert_operator seen[44..56].map { |value| shape_at(value) }.uniq.size, :>, 1
  end
end
