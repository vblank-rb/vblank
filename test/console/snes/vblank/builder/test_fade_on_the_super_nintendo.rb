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

  # A game whose fades are not all short counts every fade finer (ScreenFade#fade_amount): one that
  # also has a fade of +long+ frames somewhere, past what any run here reaches.
  private def fading_game_beside_long_fade(frames:, long:)
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
        fade_in frames: long if started == 1000
      end
    end
    builder.finalize_program
    builder.program
  end

  # Each frame's level, none skipped and none held twice, whichever way the game counts its fades.
  def test_a_fade_of_fifteen_frames_moves_a_level_every_frame
    [fading_game(frames: 15), fading_game_beside_long_fade(frames: 15, long: 28)].each do |prog|
      shown = (1..18).map { |frames| blue_after(prog, frames) }
      fading = shown.drop_while { |blue| blue == 31 }.take_while(&:positive?)

      assert_equal [29, 27, 25, 23, 21, 19, 17, 14, 12, 10, 8, 6, 4, 2], fading, "from #{shown.inspect}"
    end
  end

  # ...and one twice as long keeps each level for two.
  def test_a_fade_of_twice_the_levels_holds_each_level_two_frames
    prog = fading_game_beside_long_fade(frames: 30, long: 30)
    shown = (1..35).map { |frames| blue_after(prog, frames) }
    held = shown.chunk_while { |a, b| a == b }.map(&:size)

    assert_equal 16, held.size, "every level shows: #{shown.inspect}"
    assert_equal [2], held[1..-2].uniq, "and each between the ends for two frames: #{shown.inspect}"
  end

  # A game told black from the start, which then comes up: the title of a game on this console.
  private def rising_game(frames:)
    tile = (["#" * 8] * 8).join("\n")
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    builder.instance_eval do
      screen :tiled
      image(:art, "#" => rgb(0, 0, 31)) { tile }
      tiles :set, "#" => :art
      field = background :field, tiles: :set, map: Array.new(32) { "#" * 32 }
      field.scroll_to 0, 0
      started = var :started, 0
      game_loop do
        started += 1
        flash_screen :black, frames: frames if started == 2
      end
    end
    builder.finalize_program
    builder.program
  end

  private def rising_blues(frames) = ((1..(frames + 6)).map { |frame| blue_after(rising_game(frames: frames), frame) })

  # The same way up as down: every level once, from black, none skipped.
  def test_a_fade_up_of_fifteen_frames_moves_a_level_every_frame
    shown = rising_blues(15)

    assert_equal [0, 2, 4, 6, 8, 10, 12, 14, 17, 19, 21, 23, 25, 27, 29, 31], shown.drop_while { |blue| blue == 31 }.uniq,
                 "from #{shown.inspect}"
  end

  # ...and a fade up of twice the levels holds each for two frames, black and full aside.
  def test_a_fade_up_of_twice_the_levels_holds_each_level_two_frames
    shown = rising_blues(30).drop_while { |blue| blue == 31 }
    held = shown.chunk_while { |a, b| a == b }.map(&:size)

    assert_equal 16, held.size, "every level shows: #{shown.inspect}"
    assert_equal [2], held[1..-2].uniq, "and each between the ends for two frames: #{shown.inspect}"
  end

  # Fifteen levels down from the top, one a frame, and black on the last.
  def test_a_short_fade_to_black_steps_the_brightness_every_frame
    prog = fading_game(frames: 15)
    shown = (1..18).map { |frames| blue_after(prog, frames) }.uniq

    assert_equal [31, 29, 27, 25, 23, 21, 19, 17, 14, 12, 10, 8, 6, 4, 2, 0], shown
  end
end
