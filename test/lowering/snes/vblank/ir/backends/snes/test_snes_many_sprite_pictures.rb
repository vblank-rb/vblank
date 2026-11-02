# frozen_string_literal: true

require "test_helper"

# MORE SPRITE PICTURES THAN ONE BANK OF THE CARTRIDGE CAN LIST. A picture is a list of the pieces
# it is cut into, and a game with many pictures has more of those lists than a bank holds, however
# little art they share out between them. A game's own screen is a long way from running out then,
# so the lists go in banks of their own.
class TestSNESManySpritePictures < Minitest::Test
  PICTURES = 900

  # A picture of 32 by 32 pixels, with a red square at a corner of its own that says which it is.
  private def many_pictures_game
    count = PICTURES
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      colors :ink, %i[transparent red green]
      names = Array.new(count) do |n|
        name = :"pose#{n}"
        image name, width: 32, height: 32, colors: :ink, places: Array.new(32 * 32) { |at| (at % 32) < 8 && (at / 32) < 8 && n == count - 1 ? 1 : 2 }
        name
      end
      hero = sprite :hero, at: [40, 40], facing: names.to_h { |name| [name, name] }
      hero.face names.last
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  def test_the_last_picture_reads_its_pieces_from_where_they_went
    screen = VBlank::IR::Backends::SNES::CheckedRun.new.run(many_pictures_game, frames: 4).screen

    assert_equal VBlank::Testing.shown(:red), screen.pixel(44, 44), "the square that says which picture it is"
    assert_equal VBlank::Testing.shown(:green), screen.pixel(60, 60)
  end
end
