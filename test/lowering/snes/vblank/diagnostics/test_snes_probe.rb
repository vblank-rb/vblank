# frozen_string_literal: true

require "test_helper"

# THE PICTURE OF A RUNNING SUPER NINTENDO CARTRIDGE as the probe hands it to the reader: four bytes
# a pixel, red first, made again only when bsnes drew a different picture.
class TestSNESProbe < Minitest::Test
  # Each of the console's 32768 colours as the picture's four bytes: every five-bit channel widened
  # to eight by repeating its top bits, red first.
  def test_every_colour_of_the_console_is_the_picture_bytes_it_always_was
    expected = Array.new(32_768) do |color|
      Array.new(3) { |channel| ((color >> (channel * 5)) & 0x1F).then { |five| (five << 3) | (five >> 2) } }.pack("C3x")
    end

    assert_equal expected.join, VBlank::Diagnostics::SNESProbe.picture_bytes((0...32_768).to_a)
  end

  # The picture is read again only when the console drew a different one, and a different one is
  # never missed: the box that moved is where it moved to.
  def test_the_picture_follows_a_box_that_moves
    built = VBlank.build("MOVING", console: :snes, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :field, tiles: :set, map: Array.new(28) { "." * 32 }
      box = sprite :box, at: [40, 60]
      game_loop { box.x += 1 if box.x < 160 }
    end
    reader = VBlank::Diagnostics::Verifier.new(built, frames: 30)
    before = reader.picture
    reader.step(150)

    refute_equal before, reader.picture
    assert reader.white?(164, 64), "the box has moved right"
    assert reader.blue?(41, 64), "the box has left where it was"
  ensure
    reader&.close
  end
end
