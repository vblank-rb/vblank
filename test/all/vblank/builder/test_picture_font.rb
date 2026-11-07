# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"

# A FONT MADE OF THE GAME'S OWN PICTURES (`font :name, pictures: { "0" => :zero, ... }`): draw_text
# and draw_number draw each character as its picture, in all the picture's colours, on a bitmap
# screen and a tiled one, with everything draw_number does in any font — a field of digits:,
# leading noughts dropped or written out, :left / :center / :right. A font can also be cut from one
# strip of pictures (`strip:`), and its pictures can come from a data pack's tiles.
#
# Each numeral here is 4x3 and says its digit in its own pixels, so a wrong digit, a wrong column
# or a picture drawn in one colour shows: the top row is the digit in binary, red for a one and
# blue for a nought, then a row of green, then the binary again the other way round. The space is
# all green, which no numeral is. Three colours, so a Color sprite holds each one.
class TestPictureFont < Minitest::Test
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

  # The same numerals as one strip, 0 to 9 side by side, and a font cut from it.
  def self.declare_numeral_strip(builder)
    rows = (0...NUMERAL_H).flat_map do |row|
      ("0".."9").flat_map { |digit| numeral_pixels(digit)[row * NUMERAL_W, NUMERAL_W] }
    end
    builder.image :numeral_strip, width: NUMERAL_W * 10, height: NUMERAL_H, data: rows
    builder.font :numerals, strip: :numeral_strip, characters: "0123456789"
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

  # A made-up original holding ten 8x8 numeral tiles, the way a cartridge keeps its own: the colours
  # at DIGIT_PALETTE_AT, then the tiles, two pixels a byte. Tile d's top row is d in binary, two
  # pixels a bit, red (place 1) for a one and blue (place 3) for a nought; its last row is the same
  # the other way round; the rows between are green (place 2). Three places, so a Color sprite
  # holds each, and every console shows the three colours exactly.
  DIGIT_PALETTE = [0x0000, Color.resolve(:red), Color.resolve(:green), Color.resolve(:blue), *Array.new(12, 0)].freeze
  DIGIT_PALETTE_AT = 0x00
  DIGIT_TILES_AT = 0x20

  def self.digit_tile_places(digit)
    bits = (0...4).flat_map { |i| [(digit >> (3 - i)) & 1] * 2 }.map { |bit| bit == 1 ? 1 : 3 }
    bits + Array.new(48, 2) + bits.reverse
  end

  DIGIT_COPY = begin
    bytes = ("\0" * 0x200).b
    bytes[DIGIT_PALETTE_AT, 32] = DIGIT_PALETTE.pack("v*")
    tiles = (0..9).flat_map { |digit| digit_tile_places(digit) }
    packed = tiles.each_slice(2).map { |left, right| left | (right << 4) }.pack("C*")
    bytes[DIGIT_TILES_AT, packed.bytesize] = packed
    bytes.freeze
  end

  # A game whose pack holds the ten numeral tiles, built on +mode+'s screen. The block is given
  # the pack and draws with it.
  private def digit_pack_game(folder, mode, &draw)
    path = File.join(folder, "digits.gba")
    File.binwrite(path, DIGIT_COPY)
    game = VBlank::Original::Game.new(title: "Made Up Digits", setting: "MADE_UP_DIGITS", env: { "MADE_UP_DIGITS" => path },
                                      settings_file: File.join(folder, "digits.yml"),
                                      releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(DIGIT_COPY),
                                                              "size" => DIGIT_COPY.bytesize } })
    b = Builder.new
    b.screen mode
    pack = b.data_pack(from: game, version: "1") do |slots|
      slots.colors :palette, at: DIGIT_PALETTE_AT, count: 16
      slots.tiles :digits, at: DIGIT_TILES_AT, count: 10
    end
    b.instance_eval do
      clear_screen :black if mode == :bitmap
      instance_exec(pack, &draw)
      game_loop { wait_vblank }
    end
    b.finalize_program
    game_player.run(b.program, frames: 3).screen
  end

  # Every pixel of numeral tile +digit+ at (x, y).
  private def assert_digit_tile(screen, digit, x, y)
    want = TestPictureFont.digit_tile_places(digit).map { |place| DIGIT_PALETTE[place] }
    got = (0...8).flat_map { |dy| (0...8).map { |dx| screen.pixel(x + dx, y + dy) } }
    assert_equal want, got, "the numeral tile #{digit} at (#{x}, #{y})"
  end

  def test_a_live_number_in_a_strip_cut_from_a_data_pack_draws_every_digit
    Dir.mktmpdir do |folder|
      s = digit_pack_game(folder, :bitmap) do |pack|
        image :digit_strip, width: 80, height: 8, colors: pack[:palette], places: pack[:digits].tiles(0, across: 10)
        font :pack_digits, strip: :digit_strip, characters: "0123456789"
        draw_number var(:shown, 1_234_567_890), 24, 32, digits: 10, font: :pack_digits
      end
      [1, 2, 3, 4, 5, 6, 7, 8, 9, 0].each_with_index { |digit, at| assert_digit_tile(s, digit, 24 + (at * 8), 32) }
    end
  end

  def test_on_a_tiled_screen_a_live_number_in_pack_pictures_shows_every_digit
    Dir.mktmpdir do |folder|
      s = digit_pack_game(folder, :tiled) do |pack|
        pictures = ("0".."9").to_h do |digit|
          image :"pack_#{digit}", width: 8, height: 8, colors: pack[:palette], places: pack[:digits].tile(digit.to_i)
          [digit, :"pack_#{digit}"]
        end
        font :pack_digits, pictures: pictures
        draw_number var(:shown, 1_234_567_890), 24, 32, digits: 10, font: :pack_digits
      end
      [1, 2, 3, 4, 5, 6, 7, 8, 9, 0].each_with_index { |digit, at| assert_digit_tile(s, digit, 24 + (at * 8), 32) }
    end
  end

  # --- a strip cut into a font, and noughts written out ---

  def test_a_font_cut_from_a_strip_draws_its_pieces
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      TestPictureFont.declare_numeral_strip(self)
      draw_number var(:score, 407), 20, 30, digits: 4, font: :numerals
      game_loop { wait_vblank }
    end
    b.finalize_program
    s = game_player.run(b.program, frames: 2).screen
    assert_no_numeral(s, 20, 30, BLACK)
    assert_numeral(s, "4", 24, 30)
    assert_numeral(s, "0", 28, 30)
    assert_numeral(s, "7", 32, 30)
  end

  def test_a_strip_that_does_not_cut_evenly_is_refused
    err = refusal do
      image :odd_strip, width: 9, height: 3, data: Array.new(27, :red)
      font :odd, strip: :odd_strip, characters: "01"
    end
    assert_match(/9 pixels wide/, err.message)
  end

  def test_leading_zeros_draw_the_nought_picture_in_every_place
    prog = bitmap_game(space: true) do
      draw_number var(:minutes, 7), 20, 30, digits: 3, font: :numerals, leading_zeros: true
      draw_number 5, 20, 40, digits: 2, font: :numerals, leading_zeros: true
    end
    s = game_player.run(prog, frames: 2).screen
    assert_numeral(s, "0", 20, 30)
    assert_numeral(s, "0", 24, 30)
    assert_numeral(s, "7", 28, 30)
    assert_numeral(s, "0", 20, 40)
    assert_numeral(s, "5", 24, 40)
  end

  def test_on_a_tiled_screen_leading_zeros_show_the_nought_picture
    prog = tiled_game { draw_number var(:minutes, 7), 20, 30, digits: 3, font: :numerals, leading_zeros: true }
    s = game_player.run(prog, frames: 3).screen
    assert_numeral(s, "0", 20, 30)
    assert_numeral(s, "0", 24, 30)
    assert_numeral(s, "7", 28, 30)
  end

  def test_leading_zeros_in_a_font_of_glyphs_draw_the_glyph_for_nought
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      draw_number var(:minutes, 7), 40, 20, :white, digits: 3, leading_zeros: true
      draw_text "007", 40, 40, :white
      game_loop { wait_vblank }
    end
    b.finalize_program
    s = game_player.run(b.program, frames: 2).screen
    width = b.text_width("007")
    rows = ->(top) { (0...7).map { |dy| (0...width).map { |dx| s.pixel(40 + dx, top + dy) } } }
    assert_equal rows.call(40), rows.call(20)
    assert_includes rows.call(20).flatten, Color.resolve(:white)
  end

  def test_leading_zeros_must_be_true_or_false
    err = refusal { draw_number var(:score, 1), 20, 30, font: :numerals, leading_zeros: 2 }
    assert_match(/true or false/, err.message)
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
