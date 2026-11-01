# frozen_string_literal: true

require "test_helper"

# A FADE TO BLACK ON A SUPER NINTENDO IS THE DISPLAY'S BRIGHTNESS, sixteen levels of it, as the
# console's own games do it: nothing in memory changes and nothing is sent, so it costs no time. A
# channel shows level fifteenths of what it holds, to the nearest, so the lowest level is black.
# Every run that plays games as the console plays this, so each is held to it frame by frame.
class TestFadeOnTheSuperNintendo < Minitest::Test
  BLUE = VBlank::Graphics::Color.rgb(0, 0, 31)

  # Every shade of a channel at every level, each on tiles of its own, so the cartridge's checked
  # run compares all of them with what the display does.
  def test_every_shade_dims_as_the_display_dims_it
    tile = "abcdefgh\nabcdefgh\nabcdefgh\nabcdefgh\nabcdefgh\nabcdefgh\nabcdefgh\nabcdefgh"
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    builder.instance_eval do
      screen :tiled
      5.times do |set|
        image(:"art#{set}", "abcdefgh".chars.each_with_index.to_h { |letter, at| [letter, rgb((set * 6) + at, at * 4, 31 - at)] }) { tile }
      end
      tiles :set, Array.new(5) { |set| [set.to_s, :"art#{set}"] }.to_h
      field = background :field, tiles: :set, map: Array.new(32) { |row| Array.new(32) { |column| ((row + column) % 5).to_s }.join }
      field.scroll_to 0, 0
      game_loop { fade_out frames: 15 }
    end
    builder.finalize_program

    assert game_player.run(builder.program, frames: 20).screen
  end

  private def fading_game(frames:)
    tile = (["#" * 8] * 8).join("\n")
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    builder.instance_eval do
      screen :tiled
      image(:art, "#" => rgb(0, 0, 31)) { tile }
      tiles :set, "#" => :art
      field = background :field, tiles: :set, map: Array.new(32) { "#" * 32 }
      field.scroll_to 0, 0
      started = 0
      game_loop do
        started += 1
        fade_out frames: frames if started == 1
      end
    end
    builder.finalize_program
    builder.program
  end

  private def blue_after(prog, frames) = (game_player.run(prog, frames: frames).screen.pixel(4, 4) >> 10) & 0x1F

  # Fifteen levels down from the top, one a frame, and black on the last.
  def test_a_short_fade_to_black_steps_the_brightness_every_frame
    prog = fading_game(frames: 15)
    shown = (1..18).map { |frames| blue_after(prog, frames) }.uniq

    assert_equal [31, 29, 27, 25, 23, 21, 19, 17, 14, 12, 10, 8, 6, 4, 2, 0], shown
  end
end
