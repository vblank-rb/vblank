# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "made_up_original"

# A FONT MADE OF THE GAME'S OWN PICTURES (`font :name, pictures: { "0" => :zero, ... }`): draw_text
# and draw_number draw each character as its picture, in all the picture's colours, on a bitmap
# screen and a tiled one, with everything draw_number does in any font — a field of digits:,
# leading noughts dropped, :left / :center / :right.
#
# Each numeral here is 4x3 and says its digit in its own pixels, so a wrong digit, a wrong column
# or a picture drawn in one colour shows: the top row is the digit in binary, red for a one and
# blue for a nought, then a row of green, then the binary again the other way round. The space is
# all green, which no numeral is. Three colours, so a Color sprite holds each one.
class TestPictureFont < Minitest::Test
  include MadeUpOriginal

  RED = Color.resolve(:red)
  BLUE = Color.resolve(:blue)
  GREEN = Color.resolve(:green)
  BLACK = Color.resolve(:black)
  NUMERAL_W = 4
  NUMERAL_H = 3

  # The pixels of the numeral for +digit+, row by row (" " is the space).
  def self.numeral_pixels(digit)
    return Array.new(NUMERAL_W * NUMERAL_H, :green) if digit == " "

    bits = (0...NUMERAL_W).map { |i| (digit.to_i >> (NUMERAL_W - 1 - i)) & 1 == 1 }
    bits.map { |on| on ? :red : :blue } + Array.new(NUMERAL_W, :green) + bits.reverse.map { |on| on ? :red : :blue }
  end

  # Declare the numerals and a font of them, in +builder+'s game. +space:+ adds the green space.
  def self.declare_numerals(builder, space: false, spacing: 0)
    chars = ("0".."9").to_a + (space ? [" "] : [])
    pictures = chars.to_h do |char|
      name = char == " " ? :numeral_space : :"numeral_#{char}"
      builder.image name, width: NUMERAL_W, height: NUMERAL_H, data: numeral_pixels(char)
      [char, name]
    end
    builder.font :numerals, pictures: pictures, spacing: spacing
  end

  private def bitmap_game(space: false, spacing: 0, &draw)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      TestPictureFont.declare_numerals(self, space: space, spacing: spacing)
      instance_eval(&draw)
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  private def tiled_game(space: false, &declare)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      TestPictureFont.declare_numerals(self, space: space)
      instance_eval(&declare)
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # Every pixel of +char+'s numeral, at (x, y).
  private def assert_numeral(screen, char, x, y)
    want = TestPictureFont.numeral_pixels(char).map { |name| Color.resolve(name) }
    got = (0...NUMERAL_H).flat_map { |dy| (0...NUMERAL_W).map { |dx| screen.pixel(x + dx, y + dy) } }
    assert_equal want, got, "the numeral #{char.inspect} at (#{x}, #{y})"
  end

  # No pixel of any numeral or the space at (x, y): the column shows what is behind it.
  private def assert_no_numeral(screen, x, y, behind)
    got = (0...NUMERAL_H).flat_map { |dy| (0...NUMERAL_W).map { |dx| screen.pixel(x + dx, y + dy) } }
    assert_equal [behind] * got.length, got, "nothing drawn at (#{x}, #{y})"
  end

  # --- a bitmap screen ---

  def test_a_live_number_draws_each_digit_as_its_numeral
    prog = bitmap_game { draw_number var(:score, 407), 20, 30, digits: 4, font: :numerals }
    s = game_player.run(prog, frames: 2).screen
    assert_no_numeral(s, 20, 30, BLACK) # the thousands: a leading nought, dropped
    assert_numeral(s, "4", 24, 30)
    assert_numeral(s, "0", 28, 30) # a nought inside the number stays
    assert_numeral(s, "7", 32, 30)
  end

  def test_a_live_number_follows_its_variable
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      TestPictureFont.declare_numerals(self)
      score = var :score, 8
      game_loop do
        clear_screen :black
        draw_number score, 20, 30, digits: 2, font: :numerals
        score += 1
        wait_vblank
      end
    end
    b.finalize_program
    s = game_player.run(b.program, frames: 4).screen
    assert_numeral(s, "1", 20, 30)
    assert_numeral(s, "1", 24, 30) # 8, 9, 10, 11
  end

  def test_a_font_with_a_space_draws_it_for_each_leading_nought
    prog = bitmap_game(space: true) { draw_number var(:score, 5), 20, 30, digits: 3, font: :numerals }
    s = game_player.run(prog, frames: 2).screen
    assert_numeral(s, " ", 20, 30)
    assert_numeral(s, " ", 24, 30)
    assert_numeral(s, "5", 28, 30)
  end

  def test_nought_shows_as_a_nought
    prog = bitmap_game { draw_number var(:score, 0), 20, 30, digits: 2, font: :numerals }
    s = game_player.run(prog, frames: 2).screen
    assert_no_numeral(s, 20, 30, BLACK)
    assert_numeral(s, "0", 24, 30)
  end

  def test_the_field_is_placed_by_name_and_spaced_by_spacing
    prog = bitmap_game(spacing: 2) { draw_number var(:score, 36), :right, 30, digits: 3, within: 0...40, font: :numerals }
    s = game_player.run(prog, frames: 2).screen
    # Three columns of 4 and two gaps of 2 make 16, so the field starts at 24.
    assert_numeral(s, "3", 30, 30)
    assert_numeral(s, "6", 36, 30)
  end

  def test_a_fixed_number_and_words_draw_their_numerals
    prog = bitmap_game do
      draw_number 9, 20, 30, digits: 2, font: :numerals
      draw_text "21", 20, 40, font: :numerals
    end
    s = game_player.run(prog, frames: 2).screen
    assert_no_numeral(s, 20, 30, BLACK)
    assert_numeral(s, "9", 24, 30)
    assert_numeral(s, "2", 20, 40)
    assert_numeral(s, "1", 24, 40)
  end

  def test_text_width_and_height_measure_the_pictures
    b = Builder.new
    b.screen :bitmap
    TestPictureFont.declare_numerals(b, spacing: 1)
    assert_equal 14, b.text_width("123", font: :numerals)
    assert_equal NUMERAL_H, b.text_height(font: :numerals)
  end

  # --- a tiled screen: each character is a sprite showing its picture ---

  def test_on_a_tiled_screen_a_live_number_shows_its_numerals
    prog = tiled_game { draw_number var(:score, 407), 20, 30, digits: 4, font: :numerals }
    s = game_player.run(prog, frames: 3).screen
    assert_numeral(s, "4", 24, 30)
    assert_numeral(s, "0", 28, 30)
    assert_numeral(s, "7", 32, 30)
    refute_includes (0...NUMERAL_W).map { |dx| s.pixel(20 + dx, 30) }, RED, "the leading nought is dropped"
    refute_includes (0...NUMERAL_W).map { |dx| s.pixel(20 + dx, 31) }, GREEN, "the leading nought is dropped"
  end

  def test_on_a_tiled_screen_words_and_a_space_show_their_numerals
    prog = tiled_game(space: true) do
      draw_number var(:score, 6), 20, 30, digits: 2, font: :numerals
      draw_text "38", 20, 40, font: :numerals
    end
    s = game_player.run(prog, frames: 3).screen
    assert_numeral(s, " ", 20, 30)
    assert_numeral(s, "6", 24, 30)
    assert_numeral(s, "3", 20, 40)
    assert_numeral(s, "8", 24, 40)
  end

  # --- pictures made from a data pack's slots ---

  # The two tiles of the made-up original as pictures, a font of them as "0" and "1", and what
  # +draw+ does with them. Drawn on the 8-pixel grid, so each tile is a square of the Color's
  # screen of its own, and compared with the same pictures drawn the plain way, so a console that
  # keeps fewer shades of grey than the original shows the same picture both ways.
  private def pack_font_game(folder, mode, &draw)
    b = Builder.new
    b.screen mode
    pack = made_up_pack(b, folder)
    b.instance_eval do
      clear_screen :black if mode == :bitmap
      image :zero, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
      image :one, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(1)
      font :binary, pictures: { "0" => :zero, "1" => :one }
      instance_eval(&draw)
      game_loop { wait_vblank }
    end
    b.finalize_program
    game_player.run(b.program, frames: 3).screen.to_a
  end

  def test_words_in_a_font_of_pictures_from_a_data_pack_draw_those_pictures
    Dir.mktmpdir do |folder|
      blits = pack_font_game(folder, :bitmap) do
        blit :one, 24, 32
        blit :zero, 32, 32
      end
      assert_equal blits, pack_font_game(folder, :bitmap) { draw_text "10", 24, 32, font: :binary }
    end
  end

  def test_on_a_tiled_screen_a_font_of_pictures_from_a_data_pack_shows_those_pictures
    Dir.mktmpdir do |folder|
      # Tile 0 alone: tile 1 counts into the pack's colours past the three a Color sprite keeps.
      sprites = pack_font_game(folder, :tiled) { sprite :zero, at: [24, 32] }
      assert_equal sprites, pack_font_game(folder, :tiled) { draw_text "0", 24, 32, font: :binary }
    end
  end

  # --- friendly errors ---

  private def refusal(&game)
    assert_raises(ArgumentError) { bitmap_game(&game) }
  end

  def test_a_character_the_font_lacks_is_refused
    err = refusal { draw_text "1A", 20, 30, font: :numerals }
    assert_match(/font :numerals has no "A"/, err.message)
  end

  def test_a_colour_with_a_picture_font_is_refused
    err = refusal { draw_number var(:score, 1), 20, 30, :white, font: :numerals }
    assert_match(/takes no colour/, err.message)
  end

  def test_a_font_of_a_picture_not_declared_is_refused
    err = refusal { font :odd, pictures: { "X" => :nowhere } }
    assert_match(/:nowhere/, err.message)
  end

  def test_a_font_of_pictures_of_two_heights_is_refused
    err = refusal do
      image :tall, width: 4, height: 5, data: Array.new(20, :red)
      font :odd, pictures: { "0" => :numeral_0, "1" => :tall }
    end
    assert_match(/one height/, err.message)
  end

  def test_a_number_in_a_font_without_every_digit_is_refused
    err = refusal do
      font :few, pictures: { "0" => :numeral_0, "1" => :numeral_1 }
      draw_number var(:score, 1), 20, 30, font: :few
    end
    assert_match(/"2"/, err.message)
  end

  def test_words_with_no_colour_in_a_plain_font_are_refused
    err = refusal { draw_text "HI", 20, 30 }
    assert_match(/colou?r/, err.message)
  end
end
