# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# ONE CROWDED SCREEN CUTS ITS OWN SPRITES SMALL. A picture cut into squares of 16×16 takes four
# tiles side by side, and one row of the sprite table; cut small it takes only the tiles it draws,
# and a row for each. A screen whose pictures fit only cut small must not cost another screen its
# squares, or that screen's words can run out of the table's 128 rows.
class TestSNESSmallPiecesByScreen < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  CROWD =165 # pictures of three tiles of their own: 495 tiles cut small, and 660 in squares

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

  # The crowded screen shown from the start, with a hero beside the crowd whose four quarters are
  # all drawn and all different, as a game's character is, and one of the crowd. +err+ takes
  # what the build says.
  private def crowded_game(err)
    crowd = CROWD
    VBlank.build("PIECES", console: :snes, out: StringIO.new, err: err) do
      screen :tiled
      colors :ink, %i[transparent red green]
      random = Random.new(9)
      image :word, width: 16, height: 16, colors: :ink, places: Array.new(256) { 1 }
      image :hero, width: 16, height: 16, colors: :ink, places: Array.new(256) { random.rand(1..2) }
      names = Array.new(crowd) do |n|
        name = :"crowd#{n}"
        image name, width: 16, height: 16, colors: :ink,
                    places: Array.new(256) { |at| (at / 16 >= 8) && ((at % 16) >= 8) ? 0 : random.rand(1..2) }
        name
      end
      var :state, 1
      scene(:title) { sprite :word, at: [40, 40] }
      scene(:crowded) do
        sprite :hero, at: [40, 40]
        sprite :far, at: [80, 80], facing: names.to_h { |name| [name, name] }
        sprite :last, at: [120, 80], image: names.last
      end
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :crowded
        end
      end
    end
  end

  SCREENS = 4

  # SCREENS screens, each crowded as the one above, shown in turn a pass each.
  private def crowded_screens_game
    crowd = CROWD
    screens = SCREENS
    VBlank.game("SCREENS", consoles: %i[snes]) do
      screen :tiled
      colors :ink, %i[transparent red green]
      random = Random.new(9)
      screens.times do |screen_number|
        names = Array.new(crowd) do |n|
          name = :"crowd#{screen_number}_#{n}"
          image name, width: 16, height: 16, colors: :ink,
                      places: Array.new(256) { |at| (at / 16 >= 8) && ((at % 16) >= 8) ? 0 : random.rand(1..2) }
          name
        end
        scene(:"crowded#{screen_number}") do
          sprite :"far#{screen_number}", at: [80, 80], facing: names.to_h { |name| [name, name] }
        end
      end
      state = 0
      game_loop do
        case_var(:state) do
          screens.times { |screen_number| when_val screen_number, :"crowded#{screen_number}" }
        end
        state += 1
        state = 0 if state == screens
      end
    end
  end

  # A try finds every crowded screen before it stops. So the build takes a try that finds the
  # sprites need each screen's tiles to themselves, one that finds every crowded screen, one with
  # each keeping only the squares that waste nothing, and one spending the tiles left free: not a
  # try for each screen.
  def test_several_crowded_screens_build_in_a_few_tries
    snes = SNES.new
    snes.build(crowded_screens_game.program(console: :snes))

    assert_operator snes.tries, :<=, 4
  end

  def test_several_crowded_screens_play_as_the_interpreter_plays_them
    game_player.run(crowded_screens_game.program(console: :snes), frames: SCREENS * 2)
  end

  private def rows_shown(rom)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "pieces.sfc")
      rom.write(path)
      core = VBlank::Diagnostics::Emulator.open_snes(path, save_dir: dir)
      12.times { core.run_frame }
      rows = (0...128).count { |row| core.oam.getbyte((row * 4) + 1) < 224 }
      core.destroy
      rows
    end
  end

  def test_the_uncrowded_screen_keeps_its_squares
    assert_equal 1, rows_shown(game), "a picture of 16 by 16 is one row of the table"
  end

  # The console takes squares of 16×16 and pieces of 8×8 on one screen, a size bit on each row.
  # So where the crowd's squares do not all fit, the hero, whose square wastes no tile, keeps it;
  # the first of the crowd keep theirs in the tiles that leaves free, though their blank quarter
  # wastes one; and only the last are cut into the three quarters they draw.
  def test_the_crowded_screen_keeps_the_squares_that_fit
    assert_equal 1 + 1 + 3, rows_shown(crowded_game(StringIO.new)),
                 "the hero and the first of the crowd one row each, the last of the crowd its three quarters"
  end

  def test_the_crowded_screen_says_which_pictures_lost_their_squares
    err = StringIO.new
    crowded_game(err)

    assert_match(/scene :crowded/, err.string)
    assert_match(/\d+ pictures are drawn in pieces of 8×8/, err.string)
    assert_match(/\d+ more rows/, err.string)
    refute_match(/:hero\b|:crowd0\b/, err.string)
  end
end
