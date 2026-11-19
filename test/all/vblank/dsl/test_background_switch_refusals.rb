# frozen_string_literal: true

require "test_helper"

# `hide` and `show` on a background as far as every console agrees: where they are refused, and in
# what words. What they do is test/background_switch_tests.rb, played by each console that can
# leave a layer out.
class TestBackgroundSwitchRefusals < Minitest::Test
  private def switched_build(console, err: StringIO.new)
    VBlank.build("SWITCHED", console: console, out: StringIO.new, err: err) do
      screen :tiled
      image(:tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      sword = background :sword, tiles: :set, map: ["#" * 8]
      passes = var :passes, 0
      game_loop do
        passes += 1
        sword.hide if passes == 5
        sword.show if passes == 10
      end
    end
  end

  def test_a_console_whose_build_does_not_switch_a_background_off_refuses_in_plain_words
    %i[gbc genesis].each do |console|
      said = StringIO.new
      assert_raises(VBlank::BuildError, console.to_s) { switched_build(console, err: said) }

      assert_match(/`hide`/, said.string, console.to_s)
    end
  end

  def test_the_advance_builds_it
    assert_kind_of ROM, switched_build(:gba)
  end

  # Two backgrounds switched off on one screen take no window each, as a box does.
  def test_the_advance_builds_two_hidden_backgrounds_on_one_screen
    rom = VBlank.build("SWITCHED", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      near = background :near, tiles: :set, map: ["#" * 8]
      far = background :far, tiles: :set, map: ["#" * 8]
      game_loop do
        near.hide
        far.hide
      end
    end

    assert_kind_of ROM, rom
  end

  def test_a_background_on_a_bitmap_screen_is_refused
    b = Builder.new
    error = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :bitmap
        image(:tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
        tiles :set, "#" => :tile
        background(:painted, tiles: :set, map: ["#" * 8]).hide
      end
    end

    assert_match(/background :painted.*screen :bitmap/, error.message)
    assert_match(/hide/, error.message)
  end
end
