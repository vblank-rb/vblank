# frozen_string_literal: true

require "test_helper"

# THE TABLE A CONSOLE'S SONG PLAYER READS, read here as numbers, with no emulator. The Super Nintendo
# and the Genesis write different chips and lay a song out alike.
class TestSongTable < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Genesis = VBlank::IR::Backends::Genesis

  private def tune_program(console)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: console))
    b.instance_eval do
      enable_sound
      song(:tune) do
        tempo 450
        voice(:lead) do
          note :A4, :quarter
          note :C5, :quarter
        end
        voice(:bass) { note :A3, :half }
      end
      game_loop { play_song :tune if pressed(:a) }
    end
    b.finalize_program
    b.program
  end

  # The numbers in the song's record and each of its parts' entries that do not depend on what the
  # groups hold: its length, how many parts, and how many notes each part has.
  private def layout(music, voicing)
    numbers = Hash.new { |known, entry| known[entry] = known.size + 1 }
    words = music.words(voicing) { |entry| numbers[entry] }
    list = music.class
    record = words[words[list::SONGS_AT / 2] / 2] / 2
    parts = words[record + (list::PART_COUNT / 2)]
    entries = Array.new(parts) { |part| record + (list::RECORD_BYTES / 2) + (part * list::PART_BYTES / 2) }
    { length: words[record + (list::LENGTH / 2)], parts: parts,
      notes: entries.map { |entry| words[entry + (list::NOTE_COUNT / 2)] } }
  end

  private def snes_layout
    music = SNES::Music.new(tune_program(:snes))
    layout(music, SNES::DSPWrites::Voicing.new(waves: [], parts: music.parts, effects: music.effect_names))
  end

  private def genesis_layout
    music = Genesis::Music.new(tune_program(:genesis))
    layout(music, Genesis::ChipWrites::Voicing.new(parts: music.parts, effects: music.effect_names))
  end

  def test_a_song_is_laid_out_as_its_parts_and_their_notes
    table = snes_layout

    assert_equal 2, table[:parts]
    assert_equal [2, 1], table[:notes].sort.reverse
    assert_operator table[:length], :>, 0
  end

  def test_both_consoles_lay_a_song_out_alike
    assert_equal snes_layout, genesis_layout
  end
end
