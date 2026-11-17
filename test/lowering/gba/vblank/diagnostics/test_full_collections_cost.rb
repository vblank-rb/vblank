# frozen_string_literal: true

require "test_helper"

# WHAT ASKING ABOUT FULL COLLECTIONS COSTS A BUILD: one more run of a scene, however many
# collections the game has. Each run plays the scene in the emulator, so a run a collection is
# minutes of every build of a game with dozens of them, and every cold test cartridge too.
class TestFullCollectionsCost < Minitest::Test
  # Counts the runs by wrapping the profiler's own method, which changes the whole process.
  runs_on_the_main_ractor!

  Profiler = VBlank::Diagnostics::Profiler

  def setup = require_emulator!

  # How many times the profiler runs while the block measures +rom+. The real run is put back by
  # name after: a method defined again from another method's handle could not be called from any
  # other Ractor for the rest of the run.
  #
  # The stand-in counts only on the main Ractor. The workers playing the other files run beside
  # this class and measure builds of their own while it is in place; a stand-in made from a block
  # nobody made shareable would stop them with "defined with an un-shareable Proc in a different
  # Ractor", so it is made shareable (CountedRuns) and keeps its count in the main Ractor's own
  # storage.
  private def runs_of(rom)
    Ractor.current[CountedRuns::COUNT] = 0
    Profiler.singleton_class.alias_method(:__real_run, :run)
    Profiler.singleton_class.remove_method(:run)
    Profiler.define_singleton_method(:run, CountedRuns::STAND_IN)
    yield rom
    Ractor.current[CountedRuns::COUNT]
  ensure
    Profiler.singleton_class.remove_method(:run)
    Profiler.singleton_class.alias_method(:run, :__real_run)
    Profiler.singleton_class.remove_method(:__real_run)
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
