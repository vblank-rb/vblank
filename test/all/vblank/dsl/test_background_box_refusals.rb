# frozen_string_literal: true

require "test_helper"

# `show_only_inside` as far as every console agrees: where it is refused, and in what words. What
# it does is test/background_box_tests.rb, played by each console that can hold a layer to a box.
class TestBackgroundBoxRefusals < Minitest::Test
  private def boxed_build(console, err: StringIO.new)
    VBlank.build("BOXED", console: console, out: StringIO.new, err: err) do
      screen :tiled
      image(:tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      dialogue = background :dialogue, tiles: :set, map: ["#" * 8]
      game_loop { dialogue.show_only_inside 8, 8, 64, 32 }
    end
  end

  def test_a_console_that_cannot_hold_a_background_to_a_box_refuses_in_plain_words
    %i[gbc genesis snes].each do |console|
      said = StringIO.new
      assert_raises(VBlank::BuildError, console.to_s) { boxed_build(console, err: said) }

      assert_match(/show_only_inside/, said.string, console.to_s)
    end
  end

  def test_the_advance_builds_it
    assert_kind_of ROM, boxed_build(:gba)
  end

  def test_a_background_on_a_bitmap_screen_is_refused
    b = Builder.new
    error = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :bitmap
        image(:tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
        tiles :set, "#" => :tile
        background(:painted, tiles: :set, map: ["#" * 8]).show_only_inside 0, 0, 8, 8
      end
    end

    assert_match(/background :painted.*screen :bitmap/, error.message)
    assert_match(/blit/, error.message)
  end

  def test_a_status_bar_is_refused
    b = Builder.new
    error = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :tiled
        image(:tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
        tiles :set, "#" => :tile
        status_bar(:score, tiles: :set, map: ["#" * 8], top: 140).show_only_inside 0, 0, 8, 8
      end
    end

    assert_match(/status_bar :score/, error.message)
    assert_match(/move_to/, error.message)
  end
end
