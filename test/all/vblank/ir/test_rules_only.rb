# frozen_string_literal: true

require "test_helper"

# A GAME WITH NOTHING TO SEE OR HEAR plays by its rules all the same, for a bot that plays one long
# run many times. Every pass ends with the same numbers as the whole game, and only the steps that
# touch the screen or the speakers are gone.
class TestRulesOnly < Minitest::Test
  RulesOnly = VBlank::IR::RulesOnly

  # A little of everything a game does as it draws: a routine that draws AND works something out, a
  # sprite that moves and asks whether it touches another, a sound on a press, and random numbers.
  # The list the walk fills is read to decide a score, as a ray walk's depths decide a shot.
  private def game
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :ink, %i[transparent red green]
      image :dot, width: 8, height: 8, colors: :ink, places: Array.new(64, 1)
      tiles :set, "#" => :dot
      ground = background :ground, tiles: :set, map: ["#" * 32] * 4
      enable_sound
      define_sound :ping, frequency: 440
      seed 7
      depths = list :depths, capacity: 4, width: :half, full_of: 0
      hero = sprite :hero, at: [10, 10], facing: { dot: :dot }
      wall = sprite :wall, at: [40, 10], facing: { dot: :dot }
      score = var :score, 0
      touches = var :touches, 0
      luck = var :luck, 0
      func(:walk) do
        repeat(4) do |column|
          depths[column] = (column * 3) + hero.x
          ground.scroll_to column, 0
        end
      end
      draw_number score, 100, 8, :white
      game_loop do
        hero.x += 1 if held(:right)
        beep :ping if pressed(:a)
        call :walk
        score += 1 if depths[2] > 20
        touches += 1 if hero.overlaps?(wall)
        luck += rand(1..6)
      end
    end
    b.finalize_program
    b.program
  end

  private def numbers_of_each_pass(program, frames)
    run = VBlank::IR::Backends::Reference.new
    run.hold(:right)
    seen = []
    run.each_vblank { seen << [run[:score], run[:touches], run[:luck], run.list(:depths).to_a] }
    run.run(program, frames: frames)
    seen
  end

  def test_every_pass_ends_with_the_numbers_of_the_whole_game
    whole = numbers_of_each_pass(game, 60)

    assert_equal whole, numbers_of_each_pass(RulesOnly.of(game), 60)
    assert_operator whole.last.first, :>, 0, "the walk's list has to have decided something"
    assert_operator whole.last[1], :>, 0, "...and the sprites have to have met"
  end

  def test_only_the_steps_that_make_a_picture_or_a_sound_are_gone
    kinds = RulesOnly.of(game).walk.map(&:kind).uniq

    assert_empty kinds & %i[scroll_background beep present_objects background], "all that made a picture or a sound"
    assert_includes kinds, :object, "a sprite is still there to ask about"
    assert_includes kinds, :bitmap, "...and the pictures its overlaps are worked out from"
    assert_includes kinds, :list_set, "a routine that draws keeps everything it works out"
  end

  def test_the_program_it_was_given_is_left_as_it_was
    program = game
    before = program.walk.count

    RulesOnly.of(program)

    assert_equal before, program.walk.count
    assert_includes program.walk.map(&:kind), :scroll_background
  end
end
