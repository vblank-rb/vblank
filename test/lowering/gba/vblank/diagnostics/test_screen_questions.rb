# frozen_string_literal: true

require "test_helper"

# The questions asked of a whole screen in Ruby give the Advance's emulator's answers. The C in the
# Advance's emulator (RubyGBAEmulator::Screen) is the answer key: every question is asked of both,
# about made-up screens chosen to reach each corner of the answer, and the two must agree. Here, since
# only the Advance's run has that emulator to hold the Ruby to.
class TestScreenQuestions < Minitest::Test
  Ruby = VBlank::Diagnostics::ScreenQuestions

  def setup
    VBlank::Diagnostics::Emulator.load!
    @key = RubyGBAEmulator::Screen
  end

  WIDTH = 16
  HEIGHT = 12
  BITS = [5, 8].freeze # The precisions a colour is asked at: what a console shows, and all the emulator holds

  # A screen of +colors+, one 0xBBGGRR number a pixel, with a byte of nothing after each.
  private def screen_of(colors) = colors.pack("V*")

  private def random_screen(random) = screen_of(Array.new(WIDTH * HEIGHT) { random.rand(0x1000000) })

  # A blue field with a white box, and the same with the box's pixels changed only below five bits,
  # and the same with a red pixel at (5, 3) and another at (11, 8).
  private def field = Array.new(WIDTH * HEIGHT) { |at| (at % WIDTH).between?(4, 7) && (at / WIDTH).between?(2, 5) ? 0xFFFFFF : 0xF80000 }
  private def field_low_bits = field.map { |px| px == 0xFFFFFF ? 0xFCFDFE : px }

  private def field_marked
    marked = field
    marked[(3 * WIDTH) + 5] = 0x0000F8
    marked[(8 * WIDTH) + 11] = 0x0000F8
    marked
  end

  private def screens
    random = Random.new(7)
    [screen_of(field), screen_of(field_low_bits), screen_of(field_marked), random_screen(random), random_screen(random),
     screen_of([0] * (WIDTH * HEIGHT)), screen_of([0x070707] * (WIDTH * HEIGHT))]
  end

  def test_one_screen_questions_agree
    screens.each do |screen|
      assert_equal @key.colors(screen), Ruby.colors(screen)
      assert_equal @key.color_list(screen), Ruby.color_list(screen)
      assert_equal @key.without_commonest_color(screen), Ruby.without_commonest_color(screen)
      BITS.each do |bits|
        assert_equal_or_nil @key.only_color(screen, bits), Ruby.only_color(screen, bits)
        assert_equal @key.brightness(screen, bits), Ruby.brightness(screen, bits)
      end
    end
  end

  def test_two_screen_questions_agree
    looked_at = Array.new(WIDTH * HEIGHT) { |at| at % WIDTH > 8 ? 1 : 0 }.pack("C*")
    screens.product(screens).each do |one, other|
      assert_equal @key.same?(one, other), Ruby.same?(one, other)
      assert_equal_or_nil @key.difference(one, other, WIDTH), Ruby.difference(one, other, WIDTH)
      assert_equal_or_nil @key.difference(one, other, WIDTH, looked_at), Ruby.difference(one, other, WIDTH, looked_at)
    end
  end

  # Two colours as common as each other: the one that got there first is taken out.
  def test_of_two_commonest_colours_the_first_reached_is_taken_out
    screen = screen_of([0xF80000, 0x00F800, 0x00F800, 0xF80000])

    assert_equal @key.without_commonest_color(screen), Ruby.without_commonest_color(screen)
  end

  def test_a_screen_of_no_pixels
    assert_nil Ruby.only_color("")
    assert_equal @key.without_commonest_color(""), Ruby.without_commonest_color("")
    assert_equal 0, Ruby.brightness("")
  end

  def test_a_wrong_screen_is_refused_as_the_emulator_refuses_it
    [-> { Ruby.colors("abc") }, -> { Ruby.same?("abcd", "abcdabcd") }, -> { Ruby.only_color("abcd", 6) },
     -> { Ruby.difference("abcdabcd", "abcdabcd", 3) }, -> { Ruby.difference("abcdabcd", "abcdabcd", 2, "\1") }].each do |asked|
      assert_raises(ArgumentError, &asked)
    end
    error = assert_raises(ArgumentError) { Ruby.colors("abc") }

    assert_match "bytes for each pixel", error.message
  end

  private def assert_equal_or_nil(expected, actual)
    expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
  end
end
