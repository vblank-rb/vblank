# frozen_string_literal: true

require "test_helper"

# A PICTURE THAT STOPS EARLY (`screen :bitmap, shown_rows:`): the rows given up at the top and the
# bottom are black, and the rest of the picture is as the game paints it. Every run that plays games
# as the Super Nintendo plays these, so the cartridge, and the game as C, JavaScript and Ruby, are
# each held to the interpreter pass by pass. What the rows given up gain the cartridge is
# test/lowering/snes/vblank/ir/backends/snes/test_snes_shown_rows.rb.
class TestScreenShownRowsOnTheSuperNintendo < Minitest::Test
  BLUE = VBlank::Graphics::Color.resolve(:blue)

  # A band of stripes that moves down a row each pass, over the rows given up and back, cleared to
  # blue: the rows given up stay black whatever is painted there.
  private def striped_game(rows:)
    VBlank.game("SHORTPICTURE", consoles: %i[snes]) do
      screen :bitmap, shown_rows: rows
      step = var :step, 0
      stripe = var :stripe, 0
      game_loop do
        step += 1
        stripe = (step * 7) % 200
        clear_screen :blue
        draw_rect_at 0, stripe, 256, 12, :red
        fill_rect 40, 0, 8, 224, :white
      end
    end
  end

  private def rows_seen(screen, column) = (0...224).map { |row| screen.pixel(column, row) }

  def test_the_rows_given_up_are_black_and_the_rest_as_painted
    run = game_player.run(striped_game(rows: 32...192).program(console: :snes), frames: 40)
    seen = rows_seen(run.screen, 100)

    assert_equal [0], (seen[0, 32] + seen[192..]).uniq, "the rows given up are black"
    assert_includes seen[32...192], BLUE
    assert_operator run[:step], :>=, 30, "thirty passes or more were checked"
  end

  # Rows given up at the top alone, a number of them that is not a whole row of tiles.
  def test_rows_given_up_at_the_top_alone
    run = game_player.run(striped_game(rows: 21...224).program(console: :snes), frames: 30)
    seen = rows_seen(run.screen, 44)

    assert_equal [0], seen[0, 21].uniq
    assert_equal [VBlank::Graphics::Color.resolve(:white)], seen[21..].uniq
  end

  # A fade to black is the display's brightness on the console, which the rows kept follow.
  def test_a_fade_to_black_dims_the_rows_kept
    game = VBlank.game("SHORTFADE", consoles: %i[snes]) do
      screen :bitmap, shown_rows: 40...180
      started = var :started, 0
      game_loop do
        started += 1
        clear_screen :blue
        fill_rect 0, 60, 256, 20, :red
        fade_out frames: 15 if started == 4
      end
    end
    run = game_player.run(game.program(console: :snes), frames: 30)

    assert_equal [0], rows_seen(run.screen, 10).uniq, "black once faded"
  end

  # A Super FX cartridge takes a band the game names in place of the one it works out from the rows
  # painted.
  def test_a_super_fx_cartridge_gives_up_the_rows_named
    game = VBlank.game("CHIPSHORT", consoles: %i[snes], variants: { snes: :superfx }) do
      screen :bitmap, shown_rows: 24...200
      game_loop { clear_screen :blue }
    end
    seen = rows_seen(game_player.run(game.program(console: :snes, variant: :superfx), frames: 12).screen, 9)

    assert_equal [0], (seen[0, 24] + seen[200..]).uniq
    assert_equal [BLUE], seen[24...200].uniq
  end

  # A tint changes the colours the console shows; the rows given up stay black under it.
  def test_a_tint_leaves_the_rows_given_up_black
    game = VBlank.game("SHORTTINT", consoles: %i[snes]) do
      screen :bitmap, shown_rows: 24...200
      game_loop do
        clear_screen :blue
        tint :white, 50
      end
    end
    seen = rows_seen(game_player.run(game.program(console: :snes), frames: 10).screen, 10)

    assert_equal [0], (seen[0, 24] + seen[200..]).uniq
    refute_includes seen[24...200], 0
  end
end
