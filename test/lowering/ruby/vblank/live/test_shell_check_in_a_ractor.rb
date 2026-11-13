# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"
require "shell_tests"

# Live::ShellCheck run on a core of its own, as a port's own suite runs its test of its shell under
# minitest-ractor. Here the check is started in a Ractor by hand, since the Ruby run plays its
# tests on the main one; the shell's unpacking then starts a Ractor of its own inside that one.
class TestShellCheckInARactor < Minitest::Test
  # The made-up port the shell tests share, checked from inside a Ractor: the lines the check said.
  class PortChecker
    include ShellTests

    def lines_said(folder)
      said = []
      VBlank::Live::ShellCheck.new(port(original(folder)), say: ->(line) { said << line }).run
      said
    end
  end

  def test_the_check_passes_a_port_whose_shell_plays_as_its_all_in_one_build
    Dir.mktmpdir do |folder|
      said = value_raising_its_cause(Ractor.new(folder) { |inside| PortChecker.new.lines_said(inside) })

      assert_match "plays as its all-in-one build does", said.last
    end
  end

  # What +ractor+ ended with, or the error it stopped with raised as it was, so a failure names the
  # line in the check rather than this one.
  private def value_raising_its_cause(ractor)
    ractor.value
  rescue Ractor::RemoteError => e
    raise e.cause, cause: nil
  end
end
