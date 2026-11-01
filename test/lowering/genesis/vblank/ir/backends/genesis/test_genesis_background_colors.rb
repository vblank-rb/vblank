# frozen_string_literal: true

require "test_helper"

# A background drawn with other colours (`draw_with`) on a Genesis: every list its tiles were drawn from keeps a
# palette of its own, which the cartridge writes the colours of the list the game names over, in the blank, with
# its tiles made of places in their own list. Each test plays the game on the cartridge and the interpreter
# together (Genesis::CheckedRun).
class TestGenesisBackgroundColors < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  OWN = %i[transparent red green].freeze

  # A tile of two colours, the left half the first place of its list and the right half the second.
  BAR = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  def test_a_wall_told_to_draw_with_other_lists_in_turn_shows_each_on_the_frame_the_game_says
    run = checked(frames: 10) do
      colors :warm, [:transparent, :yellow, :orange]
      colors :cold, [:transparent, :cyan, :blue]
      tiles :wall, "#" => :bar
      rays = background :rays, tiles: :wall, map: Array.new(20) { "#" * 30 }
      step = 0
      game_loop do
        step += 1
        rays.draw_with %i[warm cold], showing: step % 4
      end
    end

    # Pass 10 said 10 % 4 = 2, which names no list: the wall's own.
    assert_equal shown(:red), run.screen.pixel(1, 1)
    assert_equal shown(:green), run.screen.pixel(5, 1)
  end

  def test_the_lists_a_wall_is_drawn_from_are_stepped_together
    run = checked(frames: 8) do
      colors :sea, %i[transparent red green]
      colors :sky, %i[transparent blue white]
      colors :sea0, %i[transparent orange yellow]
      colors :sky0, %i[transparent yellow orange]
      image :water, width: 8, height: 8, data: BAR, colors: :sea
      image :cloud, width: 8, height: 8, data: BAR.map { |c| c == :red ? :blue : :white }, colors: :sky
      tiles :scenery, "~" => :water, "o" => :cloud
      backdrop = background :backdrop, tiles: :scenery, map: Array.new(20) { ("~" * 15) + ("o" * 15) }
      game_loop do
        backdrop.draw_with({ sea: %i[sea0], sky: %i[sky0] }, showing: 0)
      end
    end

    assert_equal [shown(:orange), shown(:yellow)], [run.screen.pixel(1, 1), run.screen.pixel(121, 1)]
  end

  def test_a_wall_in_a_scene_of_its_own_is_drawn_with_the_list_the_scene_names
    checked(frames: 9) do
      colors :warm, [:transparent, :yellow, :orange]
      tiles :wall, "#" => :bar
      state = var :state, 0
      tick = var :tick, 0
      scene :hall do
        rays = background :rays, tiles: :wall, map: Array.new(20) { "#" * 30 }
        rays.draw_with :warm
      end
      scene :cellar do
        rays = background :rays, tiles: :wall, map: Array.new(20) { "# " * 15 }
        rays.draw_with :own
      end
      game_loop do
        tick += 1
        state = 1 if tick == 4
        state = 0 if tick == 7
        case_var(:state) do
          when_val 0, :hall
          when_val 1, :cellar
        end
      end
    end
  end

  def test_more_lists_than_a_genesis_has_palettes_for_are_refused_in_words
    error = assert_raises(VBlank::IR::Backends::NotMadeYet) do
      Genesis.new.build(program_of do
        names = %i[l0 l1 l2 l3 l4]
        names.zip(%i[blue yellow cyan orange magenta]).each_with_index do |(name, color), n|
          colors name, [:transparent, color]
          colors :"alt#{n}", [:transparent, :red]
          image :"tile#{n}", width: 8, height: 8, data: Array.new(64) { color }, colors: name
        end
        tiles :wall, **names.each_index.to_h { |n| [(97 + n).chr, :"tile#{n}"] }
        rays = background :rays, tiles: :wall, map: Array.new(20) { "abcde" * 6 }
        rays.draw_with(names.each_with_index.to_h { |name, n| [name, [:"alt#{n}"]] }, showing: 0)
        game_loop { nil }
      end)
    end

    assert_match(/more than the four a Genesis holds/, error.message)
  end

  private

  def shown(color) = VBlank::Testing.shown(color)

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :bar, width: 8, height: 8, data: BAR, colors: OWN
      instance_eval(&game)
    end
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end

  def checked(frames:, &game) = Genesis::CheckedRun.new.run(program_of(&game), frames: frames)
end
