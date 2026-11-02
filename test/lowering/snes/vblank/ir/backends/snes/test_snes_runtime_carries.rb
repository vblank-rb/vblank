# frozen_string_literal: true

require "test_helper"

# WHICH RUNTIME A GAME GETS, read with nothing assembled. A runtime nobody needs is left out, so a
# game that does not use a feature builds the same bytes.
class TestSNESRuntimeCarries < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  private def carries(&game)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval(&game)
    b.finalize_program
    SNES::Runtime::Carries.of(b.program, board: VBlank::Cartridge::SNESROM::PLAIN, screen_colors: false, sprite_colors: false,
                                         sprite_tiles: false, background_tiles: false)
  end

  def test_a_game_that_reads_one_controller_carries_no_second
    refute carries { game_loop { halt if held(:left) } }.second_controller
  end

  def test_a_game_that_names_the_second_player_carries_the_second_controller
    assert carries { game_loop { halt if held(:left, player: 2) } }.second_controller
  end

  def test_a_game_that_asks_about_x_carries_the_extra_buttons
    assert carries { game_loop { halt if pressed(:x) } }.extra_buttons
    refute carries { game_loop { halt if pressed(:a) } }.extra_buttons
  end

  def test_a_game_with_no_sound_carries_no_sound
    silent = carries { game_loop { nil } }

    refute silent.sound
    refute silent.songs
  end

  def test_every_fact_has_to_be_said
    assert_raises(ArgumentError) { SNES::Runtime::Carries.new(board: VBlank::Cartridge::SNESROM::PLAIN) }
  end
end
