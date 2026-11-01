# frozen_string_literal: true

require "test_helper"

# A fade or a tint on a Genesis: the colour memory is written again in the blank, with the colours of the
# game each moved toward black, white or a colour (Genesis::Runtime::Tint). Each test plays the game on the
# cartridge and the interpreter together (Genesis::CheckedRun), which compares the picture, the backdrop
# included, on every pass, so a colour that is a step out, or a frame late, fails it.
class TestGenesisFade < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  # Eight by eight tiles of two colours, so a fade has a picture, and a sprite, so it has colours in both
  # kinds of palette.
  TILES = "#######.\n" * 8

  def test_a_fade_toward_black_stepped_over_the_whole_way_agrees_on_every_pass
    checked(frames: 40) do
      level = var :level, 0
      game_loop do
        level += 3
        fade :black, level
      end
    end
  end

  def test_a_fade_toward_white_agrees_on_every_pass
    checked(frames: 40) do
      level = var :level, 0
      game_loop do
        level += 3
        fade :white, level
      end
    end
  end

  def test_a_tint_toward_a_colour_agrees_on_every_pass
    checked(frames: 40) do
      level = var :level, 0
      game_loop do
        level += 3
        tint :blue, level
      end
    end
  end

  def test_a_fade_that_goes_down_and_comes_back_leaves_the_picture_as_it_was
    run = checked(frames: 60) do
      level = var :level, 0
      frames = var :frames, 0
      game_loop do
        frames += 1
        level = frames * 4
        level = 200 - (frames * 4) if frames > 25
        fade :black, level
      end
    end

    assert_equal shown(:red), run.screen.pixel(2, 2)
  end

  def test_a_fade_counted_with_a_fraction_agrees_on_every_pass
    checked(frames: 40) do
      level = var :level, 0.0
      game_loop do
        level += 2.5
        fade :white, level
      end
    end
  end

  def test_a_fade_beside_a_list_the_game_recolours_agrees_on_every_pass
    checked(frames: 30) do
      colors :slot, [:transparent, :red, :green]
      colors :cold, [:transparent, :cyan, :blue]
      colors :warm, [:transparent, :yellow, :orange]
      ship = sprite :ship, at: [60, 60]
      ship.draw_with :slot
      step = 0
      game_loop do
        step += 1
        recolor :slot, %i[warm cold], showing: step % 3
        fade :black, step * 3
      end
    end
  end

  def test_a_fade_on_a_painted_screen_agrees_on_every_pass
    program = program_of(screen_kind: :bitmap) do
      clear_screen :blue
      fill_rect 40, 30, 60, 40, :yellow
      level = var :level, 0
      game_loop do
        level += 4
        fade :black, level
        tint :red, level - 40
      end
    end
    Genesis::CheckedRun.new.run(program, frames: 30)
  end

  # The fades of test_screen_fade.rb, over a screen painted once: there a game clears it every pass,
  # which takes this build many frames a pass, so those skip here.
  def test_flashes_and_a_fade_there_and_back_agree_on_every_pass
    program = program_of(screen_kind: :bitmap) do
      clear_screen :red
      frame = var :frame, 0
      game_loop do
        frame += 1
        flash_screen :green, frames: 4 if frame == 2
        flash_screen :blue, frames: 4 if frame == 10
        flash_screen :black, frames: 4 if frame == 18
        fade_out :white, frames: 6 if frame == 26
        fade_in if frame == 40
      end
    end
    Genesis::CheckedRun.new.run(program, frames: 60)
  end

  # Forty-eight colours in use, in twelve tiles of four: more than the blank has time to work out, so they are
  # worked out as the pass ends (Runtime::Tint), and the four of a tile are a step apart, which the console
  # shows as one colour and a fade moves apart.
  def test_forty_eight_colours_fading_and_lifting_agree_on_every_pass
    pixels = Array.new(12) do |n|
      Array.new(64) { |at| VBlank::Graphics::Color.rgb(8 * (n % 4) + (at % 4), 8 * (n / 4) + 2, 5 + (n * 2)) }
    end
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      pixels.each_with_index { |data, n| image :"art#{n}", width: 8, height: 8, data: data }
      tiles :set, **(0...12).to_h { |n| [(97 + n).chr, :"art#{n}"] }
      background :field, tiles: :set, map: Array.new(20) { ("a".."l").to_a.cycle.first(30).join }
      frame = var :frame, 0
      game_loop do
        frame += 1
        fade :black, 50 if frame == 2
        fade :white, 20 if frame == 4
        fade :black, 0 if frame == 6
      end
    end
    builder.finalize_program
    Genesis::CheckedRun.new.run(builder.program.copy.tap { |program| program.console = :genesis }, frames: 9)
  end

  def test_a_fade_placed_in_a_layer_is_refused_in_words
    error = assert_raises(Genesis::LoweringError) do
      Genesis.new.build(program_of do
        layers :world, :ui
        game_loop { fade :black, 50, under: :ui }
      end)
    end

    assert_match(/fades part of the screen, and a Sega Genesis cannot/, error.message)
  end

  private

  def shown(color) = VBlank::Testing.shown(color)

  def program_of(screen_kind: :tiled, &game)
    art = TILES
    builder = Builder.new
    builder.instance_eval do
      screen screen_kind
      if screen_kind == :tiled
        image(:wall, "#" => :red, "." => :blue) { art }
        image :ship, width: 8, height: 8, data: Array.new(64) { |i| (i % 8) < 4 ? :red : :green }, colors: %i[transparent red green]
        tiles :set, "#" => :wall
        background :field, tiles: :set, map: Array.new(20) { "#" * 30 }
      end
      instance_eval(&game)
    end
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end

  def checked(frames:, &game) = Genesis::CheckedRun.new.run(program_of(&game), frames: frames)
end
