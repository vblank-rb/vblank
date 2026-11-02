# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# ONE CROWDED SCREEN CUTS ITS OWN SPRITES SMALL. A picture cut into squares of 16×16 takes four
# tiles side by side, and one row of the sprite table; cut small it takes only the tiles it draws,
# and a row for each. A screen whose pictures fit only cut small must not cost another screen its
# squares, or that screen's words can run out of the table's 128 rows.
class TestSNESSmallPiecesByScreen < Minitest::Test
  CROWD = 165 # pictures of three tiles of their own: 495 tiles cut small, and 660 in squares

  private def game
    crowd = CROWD
    VBlank.build("PIECES", console: :snes, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      colors :ink, %i[transparent red green]
      image :word, width: 16, height: 16, colors: :ink, places: Array.new(256) { 1 }
      random = Random.new(9)
      names = Array.new(crowd) do |n|
        name = :"crowd#{n}"
        image name, width: 16, height: 16, colors: :ink,
                    places: Array.new(256) { |at| (at / 16 >= 8) && ((at % 16) >= 8) ? 0 : random.rand(1..2) }
        name
      end
      state = 0
      steps = 0
      scene(:title) { sprite :word, at: [40, 40] }
      scene(:crowded) { sprite :far, at: [80, 80], facing: names.to_h { |name| [name, name] } }
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :crowded
        end
        steps += 1
        state = 1 if steps == 1000
      end
    end
  end

  def test_the_uncrowded_screen_keeps_its_squares
    Dir.mktmpdir do |dir|
      path = File.join(dir, "pieces.sfc")
      game.write(path)
      core = VBlank::Diagnostics::Emulator.open_snes(path, save_dir: dir)
      12.times { core.run_frame }
      rows = (0...128).count { |row| core.oam.getbyte((row * 4) + 1) < 224 }
      core.destroy

      assert_equal 1, rows, "a picture of 16 by 16 is one row of the table"
    end
  end
end
