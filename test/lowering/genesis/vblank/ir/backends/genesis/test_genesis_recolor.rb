# frozen_string_literal: true

require "test_helper"

# A sprite drawn in the colours of a list the game changes (`recolor`) on a Genesis: the list keeps a
# palette of its own, which the cartridge writes the new colours over in the blank, on the frame the
# sprite's place and picture are written. Each test plays the game on the cartridge and the interpreter
# together (Genesis::CheckedRun), so a colour that is wrong on the console, or a frame late, fails it.
class TestGenesisRecolor < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  OWN = [:transparent, :red, :green].freeze

  # An 8x8 ship, the left half the first colour of its list and the right half the second.
  SHIP = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  def test_the_colours_a_list_holds_show_on_the_frame_the_game_says_them
    run = checked(frames: 12) do
      colors :slot, OWN
      colors :warm, [:transparent, :yellow, :orange]
      colors :cold, [:transparent, :cyan, :blue]
      ship = sprite :ship, at: [40, 40]
      ship.draw_with :slot
      step = 0
      game_loop do
        step += 1
        recolor :slot, %i[warm cold], showing: step % 3
      end
    end

    # Frame 12 ended a pass that said `step % 3` of 12, which is 0: the warm set.
    assert_equal shown(:yellow), run.screen.pixel(41, 41)
    assert_equal shown(:orange), run.screen.pixel(46, 41)
  end

  def test_a_number_that_names_no_set_is_the_colours_the_list_was_declared_with
    run = checked(frames: 8) do
      colors :slot, OWN
      colors :cold, [:transparent, :cyan, :blue]
      colors :warm, [:transparent, :yellow, :orange]
      ship = sprite :ship, at: [40, 40]
      ship.draw_with :slot
      step = 0
      game_loop do
        step += 1
        recolor :slot, %i[cold warm], showing: step
      end
    end

    assert_equal shown(:red), run.screen.pixel(41, 41)
    assert_equal shown(:green), run.screen.pixel(46, 41)
  end

  def test_a_sprite_drawn_in_a_list_its_picture_was_not_drawn_from_shows_that_list
    run = checked(frames: 6) do
      colors :slot, [:transparent, :blue, :white]
      colors :warm, [:transparent, :yellow, :orange]
      ship = sprite :ship, at: [40, 40]
      ship.draw_with :slot
      game_loop { recolor :slot, :warm }
    end

    assert_equal shown(:yellow), run.screen.pixel(41, 41)
    assert_equal shown(:orange), run.screen.pixel(46, 41)
  end

  def test_a_sprite_told_a_number_past_its_lists_is_drawn_in_its_own_colours_again
    run = checked(frames: 10) do
      colors :warm, [:transparent, :yellow, :orange]
      colors :cold, [:transparent, :cyan, :blue]
      ship = sprite :ship, at: [40, 40]
      step = 0
      game_loop do
        step += 1
        ship.draw_with %i[warm cold], showing: step % 4
      end
    end

    # Pass 10 said 10 % 4 = 2, which names no list: the sprite's own.
    assert_equal shown(:red), run.screen.pixel(41, 41)
    assert_equal shown(:green), run.screen.pixel(46, 41)
  end

  def test_two_sprites_drawn_with_different_lists_each_wear_their_own
    checked(frames: 8) do
      colors :warm, [:transparent, :yellow, :orange]
      colors :cold, [:transparent, :cyan, :blue]
      left = sprite :ship, at: [40, 40]
      right = sprite :ship, at: [100, 40]
      left.draw_with :warm
      right.draw_with :cold
      game_loop { left.x += 1 }
    end
  end

  # A background and a sprite drawn with one list the game changes share that list's palette, so
  # fifteen sets through it cost one of the four. Two pictures of fifteen colours each take two
  # more, and the ship's own colours the last: the game fits only if the background and the
  # sprite are drawn from the one palette.
  def test_a_background_and_a_sprite_drawn_with_one_changing_list_share_its_palette
    checked(frames: 20) do
      colors :slot, OWN
      sets = (0...15).map { |n| colors :"set#{n}", [:transparent, rgb(n, 31 - n, 4), rgb(31 - n, n, 8)] }
      image :plate, width: 8, height: 8, data: SHIP, colors: :slot
      tiles :hull, "#" => :plate
      plates = background :plates, tiles: :hull, map: ["#####"]
      plates.draw_with :slot
      ship = sprite :ship, at: [40, 40]
      ship.draw_with :slot
      [[:busy_a, 0], [:busy_b, 16]].each_with_index do |(name, base), row|
        busy = Array.new(64) { |i| rgb(base + (i % 15), 31 - (i % 15), row * 20) }
        image name, width: 8, height: 8, data: busy
        sprite name, at: [80 + (row * 16), 40]
      end
      step = 0
      game_loop do
        step += 1
        recolor :slot, sets, showing: step % 17
      end
    end
  end

  # A title's picture and the sprite over it, both drawn in the colours of one changing list and
  # with it alone: the sprite keeps no palette for its own colours, which are the list's, so the
  # two take one palette. Three pictures of fifteen colours each take the other three: the game
  # fits only if the background and the sprite are drawn from one.
  def test_a_sprite_drawn_with_a_changing_list_alone_keeps_no_palette_of_its_own
    checked(frames: 20) do
      colors :slot, OWN
      sets = (0...15).map { |n| colors :"set#{n}", [:transparent, rgb(n, 31 - n, 4), rgb(31 - n, n, 8)] }
      image :plate, width: 8, height: 8, data: SHIP, colors: :slot
      image :logo, width: 8, height: 8, data: SHIP, colors: :slot
      tiles :hull, "#" => :plate
      plates = background :plates, tiles: :hull, map: ["#####"]
      plates.draw_with :slot
      logo = sprite :logo, at: [40, 40]
      logo.draw_with :slot
      3.times do |row|
        name = :"busy#{row}"
        # Fifteen colours a Genesis tells apart: it keeps the top three bits of each channel.
        image name, width: 8, height: 8, data: Array.new(64) { |i| rgb((i % 15 % 8) * 4, ((i % 15 / 8) + (row * 2)) * 4, 0) }
        sprite name, at: [80 + (row * 16), 40]
      end
      step = 0
      game_loop do
        step += 1
        recolor :slot, sets, showing: step % 17
      end
    end
  end

  def test_more_lists_than_a_genesis_has_palettes_for_are_refused_in_words
    error = assert_raises(VBlank::IR::Backends::NotMadeYet) do
      Genesis.new.build(program_of do
        ship = sprite :ship, at: [40, 40]
        { a: :blue, b: :yellow, c: :cyan, d: :orange }.each { |name, color| colors name, [:transparent, color, :white] }
        ship.draw_with %i[a b c d], showing: 1
      end)
    end

    assert_match(/more than the four a Genesis holds/, error.message)
    assert_match(/does not swap lists as the game runs yet/, error.message)
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      instance_eval(&game)
    end
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end

  def checked(frames:, &game) = Genesis::CheckedRun.new.run(program_of(&game), frames: frames)
end
