# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"
require "shell_tests"

# WRITING A SHELL'S PROGRAMS AS RUBY (Live::Shell.from). How the shell plays is tested where the Ruby
# lowering's run plays it, test/lowering/ruby/vblank/live/test_shell.rb.
class TestLiveShell < Minitest::Test
  include ShellTests

  # Writing a big port's game and its unpacking as Ruby each take a while, so each is a phase.
  def test_writing_a_shell_as_ruby_names_each_phase
    Dir.mktmpdir do |folder|
      built = VBlank::Original::Shell.build(port_without_copy(folder), err: nil)
      said = StringIO.new
      progress = VBlank::Messages::Progress.to(said)
      VBlank::Live::Shell.from(built, progress: progress)
      progress.done

      assert_match(/\A  Writing game as Ruby +[\d.]+s\n/, said.string)
      assert_match(%r{^  Writing unpacking as Ruby +[\d.]+s +1/1$}, said.string)
    end
  end
end
