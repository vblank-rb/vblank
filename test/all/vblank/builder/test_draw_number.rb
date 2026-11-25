# frozen_string_literal: true

require "test_helper"

# draw_number: draw a score/counter, live or fixed, right-aligned with no leading
# zeros. It renders each digit through the same font as draw_text, so the test of
# correctness is "the digits it draws are the glyphs draw_text would draw" — the
# runtime digit machinery must land the same pixels as the trusted text path, in
# every run. The same check on the Advance's cartridge, and the ARM it emits for a run-time
# digit, are in test/lowering/gba/vblank/builder/test_draw_number_cartridge.rb.
class TestDrawNumber < Minitest::Test
  W = Builder::Text::GLYPH_WIDTH # 6px per digit column

  private def interpret_screen(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    game_player.run(builder.program).screen
  end

  private def tree(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  private def built(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder
  end

  # The variables a game made that it did not name.
  private def hidden_numbers(builder) = builder.variables - %i[score]

  # +lines+ numbers worked out from the score in the game loop, as many in a routine it calls, one
  # of the score itself and one with leading zeros. Public, as the game's block calls it.
  def many_number_lines(game, lines:)
    game.instance_eval do
      screen :bitmap
      score = var :score, 37
      func(:more_lines) { lines.times { |k| draw_number score * 2 + k, 120, 8 + (k * 9), :yellow } }
      game_loop do
        clear_screen :black
        lines.times { |k| draw_number score + k, 8, 8 + (k * 9), :white }
        draw_number :score, 60, 8, :white
        draw_number score - 30, 60, 17, :white, leading_zeros: true
        call :more_lines
        wait_vblank
      end
    end
  end

  # The picture of #many_number_lines, drawn as words.
  private def numbers_as_text(lines:)
    tree do
      screen :bitmap
      game_loop do
        clear_screen :black
        lines.times do |k|
          draw_text (37 + k).to_s, 8 + (2 * W), 8 + (k * 9), :white
          draw_text (74 + k).to_s, 120 + (2 * W), 8 + (k * 9), :yellow
        end
        draw_text "37", 60 + (2 * W), 8, :white
        draw_text "0007", 60, 17, :white
        wait_vblank
      end
    end
  end

  # Assert two horizontal bands of pixels are identical — the way to say "these
  # rendered the same glyphs" without pinning exact font pixels.
  private def assert_bands_match(screen, x:, w:, y1:, y2:, h: 7)
    h.times do |dy|
      w.times do |dx|
        a = screen.pixel(x + dx, y1 + dy)
        b = screen.pixel(x + dx, y2 + dy)
        assert_equal a, b, "pixel (#{x + dx}, #{y1 + dy}) != (#{x + dx}, #{y2 + dy})"
      end
    end
  end

  private def assert_region_is(screen, x, y, w, h, color)
    want = Color.resolve(color)
    h.times do |dy|
      w.times { |dx| assert_equal want, screen.pixel(x + dx, y + dy), "(#{x + dx},#{y + dy}) not #{color}" }
    end
  end

  # ---- the digits it draws are the glyphs draw_text would draw ----

  def test_a_live_number_renders_its_digits
    # score 42 in a 4-wide field is right-aligned, so it starts one column in
    # (thousands blank), i.e. at x + 2*W. draw_text "42" placed there is the oracle.
    fb = interpret_screen do
      screen :bitmap
      clear_screen :black
      var :score, 42
      draw_number :score, 40, 20, :white, digits: 4
      draw_text "42", 40 + 2 * W, 40, :white
    end
    assert_bands_match(fb, x: 40 + 2 * W, w: 2 * W, y1: 20, y2: 40)
  end

  def test_a_middle_zero_is_kept
    # 102 must show its middle zero (only *leading* zeros are dropped).
    fb = interpret_screen do
      screen :bitmap
      clear_screen :black
      var :score, 102
      draw_number :score, 40, 20, :white, digits: 4
      draw_text "102", 40 + 1 * W, 40, :white
    end
    assert_bands_match(fb, x: 40 + 1 * W, w: 3 * W, y1: 20, y2: 40)
  end

  def test_an_expression_is_evaluated
    fb = interpret_screen do
      screen :bitmap
      clear_screen :black
      score = var :score, 41
      draw_number score + 1, 40, 20, :white, digits: 4
      draw_text "42", 40 + 2 * W, 40, :white
    end
    assert_bands_match(fb, x: 40 + 2 * W, w: 2 * W, y1: 20, y2: 40)
  end

  # ---- natural, not zero-padded ----

  def test_leading_columns_are_blank_not_zero
    fb = interpret_screen do
      screen :bitmap
      clear_screen :black
      var :score, 5
      draw_number :score, 40, 20, :white, digits: 4
      draw_text "5", 40 + 3 * W, 40, :white # the ones column
    end
    # the three leading columns show background, not "000"
    assert_region_is(fb, 40, 20, 3 * W, 7, :black)
    # and the ones column is a real "5"
    assert_bands_match(fb, x: 40 + 3 * W, w: W, y1: 20, y2: 40)
  end

  def test_zero_shows_a_zero
    fb = interpret_screen do
      screen :bitmap
      clear_screen :black
      var :score, 0
      draw_number :score, 40, 20, :white, digits: 4
      draw_text "0", 40 + 3 * W, 40, :white
    end
    assert_region_is(fb, 40, 20, 3 * W, 7, :black) # no leading zeros
    assert_bands_match(fb, x: 40 + 3 * W, w: W, y1: 20, y2: 40)
  end

  # ---- what it keeps while it draws ----

  # Many lines drawing numbers the game works out, in the game loop and in a routine it calls:
  # each line keeps its number, a digit and whether a digit has shown only while it draws, so the
  # lines of one routine share where they keep them. Eight lines in each draw what draw_text draws
  # there, and keep no more hidden numbers than one line in each.
  def test_many_lines_keep_the_hidden_numbers_of_one_line_a_routine
    test = self
    many = built { test.many_number_lines(self, lines: 8) }
    one = built { test.many_number_lines(self, lines: 1) }

    assert_equal game_player.run(numbers_as_text(lines: 8), frames: 3).screen.to_a,
                 game_player.run(many.program, frames: 3).screen.to_a
    assert_equal hidden_numbers(one).length, hidden_numbers(many).length
    assert_equal hidden_numbers(many).length, many.hidden_variable_notes.length,
                 "the hidden variables report lists every number draw_number keeps"
  end

  # A line keeps its number and a digit, and without leading zeros whether a digit has shown. With
  # them every column draws, so nothing need be kept for that.
  def test_leading_zeros_keep_no_flag_for_a_digit_shown
    blanked = built do
      screen :bitmap
      var :score, 42
      draw_number :score, 8, 8, :white
    end
    zeros = built do
      screen :bitmap
      score = var :score, 42
      draw_number score, 8, 8, :white, leading_zeros: true
    end

    assert_equal 3, hidden_numbers(blanked).length
    assert_equal 2, hidden_numbers(zeros).length
  end

  # ---- guardrails ----

  def test_draw_text_rejects_a_number
    err = assert_raises(ArgumentError) { tree { draw_text 42, 0, 0, :white } }
    assert_match(/draw_number/, err.message)
  end

  def test_draw_number_rejects_a_non_number
    err = assert_raises(ArgumentError) { tree { draw_number "42", 0, 0, :white } }
    assert_match(/draw_number draws a number/, err.message)
  end

  def test_draw_number_rejects_a_bad_digit_count
    err = assert_raises(ArgumentError) { tree { draw_number :score, 0, 0, :white, digits: 0 } }
    assert_match(/positive number of digits/, err.message)
  end

  # The place and the width of the field are settled while the game is built, so a
  # variable in one of them is refused, and the message names the variable the author wrote rather
  # than printing a Ruby object.
  def test_draw_number_given_a_variable_for_its_left_edge_names_it
    err = assert_raises(ArgumentError) { tree { left = var(:left, 3); draw_number 5, left, 0, :white } }
    assert_match(/draw_number/, err.message)
    assert_match(/`left`/, err.message)
    refute_match(/#</, err.message, "the message prints no Ruby object")
  end

  def test_draw_number_given_a_variable_for_its_top_edge_names_it
    %i[bitmap tiled].each do |kind|
      err = assert_raises(ArgumentError) do
        tree { screen kind; top = var(:top, 3); draw_number 5, 8, top, :white }
      end
      assert_match(/draw_number/, err.message, "on a #{kind} screen")
      assert_match(/`top`/, err.message, "on a #{kind} screen")
      refute_match(/#</, err.message, "the message prints no Ruby object")
    end
  end

  def test_draw_number_given_a_variable_for_its_digits_names_it
    err = assert_raises(ArgumentError) { tree { wide = var(:wide, 3); draw_number 5, 0, 0, :white, digits: wide } }
    assert_match(/digits/, err.message)
    assert_match(/`wide`/, err.message)
    refute_match(/#</, err.message, "the message prints no Ruby object")
  end
end
