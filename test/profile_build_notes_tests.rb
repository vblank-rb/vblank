# frozen_string_literal: true

require "json"
require "stringio"

# What `rom.profile` tells of a build besides the measured frames: the hidden variables, the counted
# loops and the instance variable numbers (Diagnostics::BuildNotes), and the game's routines by size
# (Diagnostics::RoutineSizes). Each console's file includes this module and gives `console`.
module ProfileBuildNotesTests
  # A game with one hidden variable (the item `shift` takes off a plain Array) and one counted loop.
  private def notes_rom
    VBlank.build("NOTES", console: console, out: nil, err: nil) do
      trail = Array.new(capacity: 8)
      trail << 3
      total = 0
      game_loop do
        item = trail.shift
        total += item
        trail << item
        3.times { total += 1 }
      end
    end
  end

  # What +rom+'s profile prints for people.
  private def human_profile(rom)
    out = StringIO.new
    rom.profile(out: out, frames: 10)
    out.string
  end

  def test_the_profile_lists_the_hidden_number_and_the_routine_sizes
    printed = human_profile(notes_rom)

    assert_includes printed, "hidden variables: 1"
    assert_includes printed, "item = trail.shift"
    assert_includes printed, "counted loops:"
    assert_includes printed, "Your routines by size:"
    assert_includes printed, "In all:"
    assert_operator printed.index("hidden variables:"), :<, printed.index("Your routines by size:")
  end

  def test_the_json_profile_carries_the_notes_and_sizes
    out = StringIO.new
    notes_rom.profile(format: :json, out: out, frames: 10)
    report = JSON.parse(out.string)

    assert_operator report.dig("hidden_variables", "count"), :>=, 1
    refute_empty report.dig("counted_loops", "lines")
    refute_empty report.fetch("routine_sizes")
  end
end
