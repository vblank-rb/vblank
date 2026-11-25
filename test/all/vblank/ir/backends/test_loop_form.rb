# frozen_string_literal: true

require "test_helper"

# Which `while` loops are counted (Backends::LoopForm#counted_while), and that a game whose loops are
# lowered as counted ones does what the interpreter does on every run: the loop's variable after it,
# the turns made, a routine called after reading the variable, and loops that look counted and are not.
class TestLoopForm < Minitest::Test
  include VBlank::IR::Build

  CONSOLES = %i[gba gbc snes genesis ps1 dos].freeze

  # The repeat a `while` in +game+'s routine +name+ became.
  private def while_in(program, name)
    routine = program.walk.find { |node| node.kind == :func && node.name == name }
    routine.walk.find { |node| node.kind == :repeat }
  end

  private def counted_while(game, name)
    program = game.program(console: :genesis)
    VBlank::IR::Backends::LoopForm.new(program).counted_while(while_in(program, name))
  end

  private def loops_game
    VBlank.game("COUNTED WHILES", consoles: CONSOLES) do
      screen :bitmap
      words = list :words, capacity: 16, full_of: 3
      i = 0
      j = 0
      n = 5
      s = 0
      seen = 0
      func(:from_nought) do
        i = 0
        while i < 10
          s += words[i]
          i += 1
        end
      end
      func(:from_where_it_is) do
        while j < n
          s += 1
          j += 1
        end
      end
      func(:writes_its_variable) do
        i = 0
        while i < 10
          i += 2
          i += 1
        end
      end
      func(:reads_after) { seen = i }
      func(:calls_a_reader) do
        i = 0
        while i < 4
          call :reads_after
          i += 1
        end
      end
      game_loop do
        call :from_nought
        call :from_where_it_is
        call :writes_its_variable
        call :calls_a_reader
        j -= 7
        n = (n + 3) & 15
      end
    end
  end

  def test_a_while_counting_one_up_to_a_limit_is_counted
    counted = counted_while(loops_game, :from_nought)

    assert_equal :i, counted.variable
    assert_equal 0, counted.starts_at
    assert_equal 10, counted.limit.value
  end

  def test_a_while_from_where_its_variable_is_to_a_variable_is_counted_from_nowhere_known
    counted = counted_while(loops_game, :from_where_it_is)

    assert_equal :j, counted.variable
    assert_nil counted.starts_at
    assert_equal :n, counted.limit.name
  end

  def test_a_while_whose_body_writes_its_variable_otherwise_is_not_counted
    assert_nil counted_while(loops_game, :writes_its_variable)
  end

  def test_a_counted_while_plays_as_the_interpreter
    game_player.run(loops_game.program(console: VBlank::Testing.console), frames: 12)
  end

  # Started below and at its limit, and ending just as the routine called in it reads it.
  def test_a_counted_while_with_no_turns_and_one_whose_variable_a_routine_reads_play_as_the_interpreter
    game = VBlank.game("NO TURNS", consoles: CONSOLES) do
      screen :bitmap
      i = 0
      k = 0
      seen = 0
      t = 0
      func(:look) { seen += k * 3 + i }
      game_loop do
        t += 1
        i = 9
        while i < 9
          seen += 100
          i += 1
        end
        k = t - 3
        while k < 2
          call :look
          k += 1
        end
      end
    end
    game_player.run(game.program(console: VBlank::Testing.console), frames: 8)
  end
end
