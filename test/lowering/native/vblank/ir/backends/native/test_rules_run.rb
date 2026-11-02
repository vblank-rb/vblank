# frozen_string_literal: true

require "test_helper"

# A GAME'S RULES AS FAST AS THE MACHINE CAN PLAY THEM. Every pass ends with the numbers the whole game
# ends it with on the interpreter, read a question at a time from a program that says nothing else.
class TestRulesRun < Minitest::Test
  RulesRun = VBlank::IR::Backends::Native::RulesRun

  # Variables, a list, a pool and random numbers, all moved by a button, with drawing among them.
  private def game
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      seed 11
      trail = list :trail, capacity: 8, width: :half, full_of: 0
      dots = pool :dot, x: 0, capacity: 4
      dots.spawn x: 3
      score = var :score, 0
      luck = var :luck, 0
      game_loop do
        clear_screen :black
        score += 1 if held(:a)
        luck += rand(1..6)
        trail[score % 8] = luck
        dots.each { |dot| dot.x += 2 }
        draw_number score, 8, 8, :white
      end
    end
    b.finalize_program
    b.program
  end

  private def presses(frame) = frame.odd? ? [:a] : []

  private def numbers_of_each_pass(run, frames)
    seen = []
    run.input_each_frame do |frame|
      seen << [run[:score], run[:luck], run.list(:trail).to_a, run.pool(:dot, :x).to_a]
      presses(frame)
    end
    run.run(game, frames: frames)
    seen
  end

  def test_every_pass_ends_with_the_numbers_the_interpreter_plays_the_whole_game_to
    assert_equal numbers_of_each_pass(Reference.new, 30), numbers_of_each_pass(RulesRun.new, 30)
  end

  def test_the_numbers_are_there_when_the_run_has_ended
    run = RulesRun.new
    run.hold(:a)
    run.run(game, frames: 5)

    assert_equal 5, run[:score]
  end

  def test_a_game_that_stops_itself_ends_the_run
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      done = var :done, 0
      done += 1
      halt
    end
    b.finalize_program

    assert_equal 1, RulesRun.new.run(b.program, frames: 5)[:done]
  end

  # Two rooms with walls, scenes that hand over, a map put up and a cell changed, and a bend whose
  # block counts: every step here counts as drawing and every one of them changes the numbers.
  private def walled_game
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :ink, %i[transparent red]
      image :dot, width: 8, height: 8, colors: :ink, places: Array.new(64, 1)
      image :floor, width: 8, height: 8, colors: :ink, places: Array.new(64, 0)
      tiles :set, "#" => :dot, "." => :floor, solid: ["#"]
      bends = var :bends, 0
      passes = var :passes, 0
      state = var :state, 0
      reached = var :reached, 0
      room = background :room, tiles: :set,
                               map: { hall: ["..#.........", "............"], cave: ["......#.....", "............"] }
      room.scroll_each_row do |row|
        bends += 1 if row == 0
        0
      end
      hero = sprite :hero, at: [0, 0], facing: { dot: :dot }
      hero.blocked_by(room)
      scene(:walking) do
        hero.move(:right, by: 1)
        reached = hero.x
        room.show_map :cave if passes == 20
      end
      scene(:opening) do
        room.set_tile 6, 0, "."
        hero.move(:right, by: 1)
        reached = hero.x
      end
      game_loop do
        passes += 1
        state = 1 if passes == 60
        case_var(:state) do
          when_val 0, :walking
          when_val 1, :opening
        end
      end
    end
    b.finalize_program
    b.program
  end

  private def walls_and_bends_of_each_pass(run, frames)
    seen = []
    run.input_each_frame do
      seen << [run[:bends], run[:passes], run[:state], run[:reached]]
      []
    end
    run.run(walled_game, frames: frames)
    seen
  end

  def test_walls_maps_scenes_and_bends_stay_in_the_rules
    whole = walls_and_bends_of_each_pass(Reference.new, 90)

    assert_equal whole, walls_and_bends_of_each_pass(RulesRun.new, 90)
    assert_equal 8, whole[15].last, "the hall's wall has to stop the hero"
    assert_equal 40, whole[55].last, "...and the cave's, further along"
    assert_operator whole.last.last, :>, 40, "...and a cell changed has to open it"
    assert_operator whole.last.first, :>, 0, "the bend's block has to have run"
  end

  def test_a_picture_asked_for_is_a_blank_screen
    run = RulesRun.new.run(game, frames: 2)

    assert_equal 0, run.screen.pixel(4, 4)
  end

  def test_what_only_drawing_or_sound_would_say_is_refused_by_name
    run = RulesRun.new.run(game, frames: 2)

    %i[sprites audio recording_sound].each do |question|
      error = assert_raises(VBlank::IR::Backends::Native::HeadlessRun::CannotAnswer) { run.public_send(question) }
      assert_match(/rules alone/, error.message)
    end
  end

  def test_every_variable_can_be_read_in_the_middle_of_a_run
    run = RulesRun.new
    seen = []
    run.input_each_frame do
      seen << run.vars[:score]
      [:a]
    end
    run.run(game, frames: 3)

    assert_equal [0, 1, 2], seen.first(3)
  end

  def test_a_save_is_kept_for_the_next_run
    keeping = lambda do
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        best = save_var :best, 5
        best += 1
        halt
      end
      b.finalize_program
      b.program
    end
    save = SaveImage.new

    RulesRun.new(save: save).run(keeping.call, frames: 3)

    assert_equal 7, RulesRun.new(save: save).run(keeping.call, frames: 3)[:best]
  end

  def test_a_game_that_goes_wrong_says_so
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      slots = list :slots, capacity: 2
      place = var :place, 9
      slots[place] = 1
      halt
    end
    b.finalize_program

    error = assert_raises(VBlank::IR::ProgramError) { RulesRun.new.run(b.program, frames: 2) }
    assert_match(/out of range/, error.message)
  end
end
