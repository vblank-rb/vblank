# frozen_string_literal: true

require "test_helper"

# `drawing_for_local_player`: the one place a game may ask which player this machine's person is,
# since the answer is different on each machine of a match and so may change only what is drawn.
# The game as a match plays it, machine against machine, is test/lowering/ruby/vblank/network/
# test_local_view_in_a_match.rb.
class TestLocalView < Minitest::Test
  RED = VBlank::Graphics::Color.resolve(:red)
  BLUE = VBlank::Graphics::Color.resolve(:blue)

  private def game(&block)
    VBlank.game("VIEW", consoles: %i[gba], players: 4, &block)
  end

  # The game as a computer builds it, played by the interpreter as the person at machine +me+.
  private def seen_by(me, frames: 3, &block)
    interpreter = Reference.new
    interpreter.local_player = me
    interpreter.run(game(&block).checked_program(err: nil, console: :gba), frames: frames)
    interpreter
  end

  private def two_markers
    proc do
      game_loop do
        drawing_for_local_player do |me|
          pixel 5, 5, :red if me == 1
          pixel 6, 6, :blue if me == 2
        end
      end
    end
  end

  def test_the_block_draws_what_the_player_number_chooses
    first = seen_by(1, &two_markers)
    second = seen_by(2, &two_markers)

    assert_equal [RED, 0], [first.screen.pixel(5, 5), second.screen.pixel(5, 5)]
    assert_equal [0, BLUE], [first.screen.pixel(6, 6), second.screen.pixel(6, 6)]
  end

  def test_on_a_cartridge_the_player_is_the_first
    interpreter = Reference.new
    interpreter.run(game(&two_markers).program, frames: 3)

    assert_equal RED, interpreter.screen.pixel(5, 5)
  end

  def test_the_block_may_use_the_variables_of_the_game_to_decide_where_to_draw
    interpreter = seen_by(2) do
      x = var :x, 20
      game_loop do
        drawing_for_local_player { |me| draw_rect_at x, 10, 3, 3, :red if me == 2 }
      end
    end

    assert_equal RED, interpreter.screen.pixel(20, 10)
  end

  def test_a_variable_cannot_be_changed_in_the_block
    error = assert_raises(ArgumentError) do
      game do
        kept = var :kept, 0
        game_loop { drawing_for_local_player { |me| kept.store!(me) } }
      end.checked_program(err: nil, console: :gba)
    end

    assert_match(/can only draw/, error.message)
    assert_match(/test_local_view\.rb/, error.message, "says which line")
  end

  def test_a_variable_cannot_be_added_to_in_an_if_in_the_block
    assert_raises(ArgumentError) do
      game do
        kept = var :kept, 0
        game_loop { drawing_for_local_player { |me| kept += 1 if me == 1 } }
      end.checked_program(err: nil, console: :gba)
    end
  end

  def test_a_random_draw_a_call_and_a_sound_cannot_be_made_in_the_block
    [proc { |_me| rand(0..3) }, proc { |_me| call :helper }, proc { |_me| beep :ping }].each do |line|
      assert_raises(ArgumentError, line.source_location.inspect) do
        game do
          func(:helper) { pixel 0, 0, :red }
          enable_sound
          define_sound :ping, frequency: 440, frames: 4
          game_loop { drawing_for_local_player(&line) }
        end.checked_program(err: nil, console: :gba)
      end
    end
  end

  def test_the_player_number_cannot_be_used_outside_the_block
    error = assert_raises(ArgumentError) do
      game do
        kept = var :kept, 0
        holder = []
        game_loop do
          drawing_for_local_player { |me| holder << me }
          kept.store!(holder.first)
        end
      end.checked_program(err: nil, console: :gba)
    end

    assert_match(/outside that block/, error.message)
  end

  def test_a_block_with_nothing_to_draw_is_a_friendly_error
    error = assert_raises(ArgumentError) { game { game_loop { drawing_for_local_player } }.checked_program(err: nil, console: :gba) }

    assert_match(/needs a block/, error.message)
  end

  def test_the_game_builds_for_every_console_with_the_block_in_it
    %i[gba gbc snes genesis].each do |console|
      VBlank.build("VIEW", console: console, out: StringIO.new, err: StringIO.new) do
        game_loop { drawing_for_local_player { |me| pixel 1, 1, :red if me == 1 } }
      end
    end
  end
end
