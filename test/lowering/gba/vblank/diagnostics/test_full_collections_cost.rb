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

  private def runs_of(rom)
    runs = 0
    real = Profiler.method(:run)
    Profiler.singleton_class.remove_method(:run)
    Profiler.define_singleton_method(:run) do |*args, **options|
      runs += 1
      real.call(*args, **options)
    end
    yield rom
    runs
  ensure
    Profiler.singleton_class.remove_method(:run)
    Profiler.define_singleton_method(:run, real)
  end

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
