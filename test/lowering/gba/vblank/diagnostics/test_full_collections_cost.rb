# frozen_string_literal: true

require "test_helper"

require "ractor_workers"

# What asking about full collections costs a build: one more run of a scene, however many
# collections the game has. Each run plays the scene in the emulator, so a run a collection is
# minutes of every build of a game with dozens of them, and every cold test cartridge too.
class TestFullCollectionsCost < Minitest::Test
  # Counts the runs by wrapping the profiler's own method, which changes the whole process.
  runs_on_the_main_ractor!
  include RactorWorkers

  Profiler = VBlank::Diagnostics::Profiler

  def setup = require_emulator!

  # How many times the profiler runs while the block measures +rom+.
  #
  # The stand-in counts only on the main Ractor, in that Ractor's own storage. The workers playing
  # the other files run beside this class and measure builds of their own while it is in place.
  # RactorWorkers#while_swapped says how the swap keeps the run callable from every Ractor.
  private def runs_of(rom)
    Ractor.current[CountedRuns::COUNT] = 0
    while_swapped(Profiler, :run, CountedRuns::STAND_IN) { yield rom }
    Ractor.current[CountedRuns::COUNT]
  end

  # The stand-in #runs_of gives the profiler, made in a module so the block's self is one every
  # Ractor may share.
  module CountedRuns
    COUNT = :counted_profiler_runs

    STAND_IN = Ractor.make_shareable(lambda do |*args, **options|
      Ractor.current[COUNT] += 1 if Ractor.main?
      VBlank::Diagnostics::Profiler.__real_run(*args, **options)
    end)
  end

  # Two divides a slot, since a pass must fall behind once the lists are full for this to count.
  def test_a_scene_behind_when_full_costs_one_run_however_many_collections_it_has
    rom = VBlank.build("FULL", console: :gba, out: nil, err: nil) do
      screen :bitmap
      lists = Array.new(6) { |i| list :"walked_#{i}", capacity: 448 }
      total = 0
      lists.each { |xs| xs.push 1 }
      game_loop do
        lists.each do |xs|
          xs.each do |x|
            total += (x * 7) / (total + 3)
            total += (x * 5) / (total + 7)
          end
        end
      end
    end

    growths = nil
    runs = runs_of(rom) { |built| growths = Profiler.survey_scenes(built, frames: 10).growths }

    assert_equal 1, growths.size
    assert_equal 2, runs, "the scene as it stands, and the scene with everything full"
  end
end
