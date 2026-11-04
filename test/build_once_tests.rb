# frozen_string_literal: true

require "test_helper"

# WHAT A CARTRIDGE BUILD DOES ONCE, held on each console that builds one: what a build works out
# from the program alone is worked out once however many tries it takes (BuildCache), and a routine
# is made once when it fits a bank (RoutineCuts#sections). Included by the Color's, the Super
# Nintendo's and the Genesis's test_*_build_once.rb, each naming its backend as BACKEND.
#
# The counts are read by counting the calls themselves while a test asks, so these tests change
# the whole process: each class including this says `runs_on_the_main_ractor!`.
module BuildOnceTests
  Backends = VBlank::IR::Backends
  Build = VBlank::IR::Build

  # The calls counted while a test asks (#counted), by what was called.
  module Counts
    def self.now = Thread.current[:build_once_counts]

    def self.add(what)
      counts = now
      counts[what] += 1 if counts
    end
  end

  Backends::LoweringPlan.prepend(Module.new do
    def initialize(...)
      Counts.add(:plans)
      super
    end
  end)

  VBlank::IR::SceneHandover.singleton_class.prepend(Module.new do
    def of(...)
      Counts.add(:handovers)
      super
    end
  end)

  # Each routine's size measured before it is made, beside what its one section came to, while a
  # test asks (#sizes_measured_and_made).
  Backends::RoutineCuts.prepend(Module.new do
    def sections(label, statements, &section)
      pairs = Thread.current[:build_once_sizes]
      return super unless pairs

      measured = @measure.call(statements)
      made = super
      pairs << [measured, made.length == 1 ? made.first.size - @return_bytes : nil]
      made
    end
  end)

  [Backends::GBC::Lowering, Backends::SNES::Lowering, Backends::Genesis::Lowering].each do |lowering|
    lowering.prepend(Module.new do
      def bytes_of(list)
        Counts.add(:measured)
        super
      end
    end)
  end

  # A small game for +console+ with a routine of its own and a scene, and a timer +with_timer+, every
  # routine of it well inside a bank.
  private def small_game(console, with_timer: true)
    timer = with_timer ? [Build.on_timer(:tick, Build.add(:ticks, 1)), Build.timer_start(:tick, 60)] : []
    program = Build.program(Build.func(:score, Build.add(:points, 1)), Build.func(:title, Build.add(:seen, 1)),
                            *timer, Build.set(:state, 0),
                            Build.loop_(Build.call(:score),
                                        Build.case_(:state, 0 => :title),
                                        Build.wait_vblank))
    program.console = console
    program
  end

  # The calls the block made of what Counts counts.
  private def counted
    Thread.current[:build_once_counts] = Hash.new(0)
    yield
    Thread.current[:build_once_counts]
  ensure
    Thread.current[:build_once_counts] = nil
  end

  # [measured, made] for each routine the block's build made: its size measured before it was made,
  # and the size of the one section it was made as, or nil where it was cut into parts.
  private def sizes_measured_and_made
    Thread.current[:build_once_sizes] = []
    yield
    Thread.current[:build_once_sizes]
  ensure
    Thread.current[:build_once_sizes] = nil
  end

  # A game of a routine for each of +counts+, that many additions each.
  private def game_of_additions(counts)
    funcs = counts.each_with_index.map { |count, which| Build.func(:"adds#{which}", *Array.new(count) { Build.add(:x, 1) }) }
    calls = counts.each_index.map { |which| Build.call(:"adds#{which}") }
    program = Build.program(*funcs, *calls, Build.loop_(Build.wait_vblank))
    program.console = self.class::CONSOLE
    program
  end

  # The bytes one addition comes to on this console: two routines a hundred additions apart.
  private def addition_bytes
    sizes = sizes_measured_and_made { self.class::BACKEND.new.build(game_of_additions([100, 200])) }
    larger, smaller = sizes.map(&:first).max(2)
    (larger - smaller) / 100
  end

  def test_a_build_makes_one_plan_and_one_handover
    counts = counted { self.class::BACKEND.new.build(small_game(self.class::CONSOLE)) }

    assert_equal 1, counts[:plans]
    assert_equal 1, counts[:handovers]
  end

  def test_a_routine_that_fits_a_bank_is_never_measured
    counts = counted { self.class::BACKEND.new.build(small_game(self.class::CONSOLE, with_timer: false)) }

    assert_equal 0, counts[:measured]
  end

  # A timer's handler is made inside code of its own that runs it once a tick, so its size is not one
  # section's (RoutineCuts#fit): it is measured once, and made once.
  def test_a_timers_handler_is_measured_once
    counts = counted { self.class::BACKEND.new.build(small_game(self.class::CONSOLE)) }

    assert_equal 1, counts[:measured]
  end

  # Whether a routine is cut is one rule, whichever way its size was found: measured before it is
  # made, or read off the section it was made as. So the two agree on routines a few bytes either
  # side of the limit, and a routine is cut exactly when what it measures is past it.
  def test_a_routine_measured_and_made_comes_to_the_same_bytes_near_the_limit
    most = self.class::BACKEND::Lowering::MOST_ROUTINE_BYTES
    fill = most / addition_bytes
    sizes = sizes_measured_and_made { self.class::BACKEND.new.build(game_of_additions((-2..2).map { |step| fill + step })) }

    assert sizes.any? { |measured, _| measured <= most && measured > most - (3 * addition_bytes) }, "a routine just under the limit"
    assert sizes.any? { |measured, _| measured > most }, "a routine just over the limit"
    sizes.each do |measured, made|
      assert_equal measured, made if made
      assert_equal measured <= most, !made.nil?
    end
  end
end
