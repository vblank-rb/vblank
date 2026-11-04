# frozen_string_literal: true

require "test_helper"

# How every cartridge lowering turns a routine into sections (RoutineCuts#sections): made once
# when it fits a bank, and taken back, measured and cut when it does not. RoutineCuts is shared by
# the cartridge lowerings and plays no game, so its tests are with the Color's, whose builds cut the
# most routines; test/all/ is for what a game does, asked through game_player.
class TestRoutineCuts < Minitest::Test
  include VBlank::IR::Build

  RoutineCuts = VBlank::IR::Backends::RoutineCuts
  Section = VBlank::IR::Backends::Sections::Section

  # A lowering whose statements come to the bytes +sizes+ gives each, and whose return
  # instruction is one byte. It counts what RoutineCuts asks of it.
  class CountingLowering
    attr_reader :made, :measured, :restored

    def initialize(sizes)
      @sizes = sizes
      @made = []
      @measured = []
      @restored = 0
    end

    def section(label, statements)
      @made << label
      bytes = statements.sum { |node| node.is_a?(RoutineCuts::PartCall) ? 3 : @sizes.fetch(node) } + 1
      Section.new(name: label, bytes: "\0" * bytes, labels: {}, fixups: [], home: :banked, holds: nil)
    end

    def measure(statements)
      @measured << statements
      statements.sum { |node| @sizes.fetch(node) }
    end

    def snapshot
      lowering = self
      Object.new.tap { |undo| undo.define_singleton_method(:restore!) { lowering.restore! } }
    end

    def restore! = @restored += 1
  end

  def test_a_routine_that_fits_is_made_once_and_never_measured
    statements = [wait_vblank, wait_vblank]
    lowering = CountingLowering.new(statements.to_h { |node| [node, 40] }.compare_by_identity)

    made = cuts_for(lowering).sections("small", statements) { |label, held| lowering.section(label, held) }

    assert_equal ["small"], made.map(&:name)
    assert_equal ["small"], lowering.made
    assert_empty lowering.measured
    assert_equal 0, lowering.restored
  end

  def test_a_routine_too_big_is_taken_back_and_cut_into_parts_that_fit
    statements = Array.new(4) { wait_vblank }
    lowering = CountingLowering.new(statements.to_h { |node| [node, 60] }.compare_by_identity)

    made = cuts_for(lowering).sections("big", statements) { |label, held| lowering.section(label, held) }

    assert_equal 1, lowering.restored
    assert_operator made.length, :>, 1
    made.each { |section| assert_operator section.size - 1, :<=, 200 }
  end

  def test_a_routine_an_earlier_try_cut_is_measured_before_it_is_made
    statements = Array.new(4) { wait_vblank }
    sizes = statements.to_h { |node| [node, 60] }.compare_by_identity
    found = Set.new
    first = CountingLowering.new(sizes)
    cuts_for(first, found).sections("big", statements) { |label, held| first.section(label, held) }

    later = CountingLowering.new(sizes)
    cuts_for(later, found).sections("big", statements) { |label, held| later.section(label, held) }

    assert_equal 0, later.restored
    assert_equal first.made.length - 1, later.made.length # nothing made only to be thrown away
  end

  def test_a_statement_whose_size_was_noted_is_not_measured_again
    statements = Array.new(4) { wait_vblank }
    lowering = CountingLowering.new(statements.to_h { |node| [node, 60] }.compare_by_identity)
    cuts = cuts_for(lowering)
    noting = lowering.method(:measure)
    lowering.define_singleton_method(:measure) do |list|
      list.each { |node| cuts.note_size(node, 60) } if list.length > 1
      noting.call(list)
    end

    cuts.sections("big", statements) { |label, held| lowering.section(label, held) }

    assert_equal [statements], lowering.measured
  end

  private def cuts_for(lowering, found = Set.new)
    RoutineCuts.new(plan: nil, most_routine_bytes: 200, most_part_bytes: 130, return_bytes: 1,
                    measure: ->(list) { lowering.measure(list) }, snapshot: -> { lowering.snapshot },
                    found_too_big: found)
  end
end
