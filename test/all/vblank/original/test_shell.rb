# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "shell_tests"

# BUILDING A SHELL (Original::Shell.build): what a port must be for its shell to be made at all.
# How each runtime plays a shell is tested in that runtime's folder (test_shell.rb under
# test/lowering/ruby/vblank/live/, and the web page's and the desktop program's).
class TestOriginalShell < Minitest::Test
  include ShellTests

  # A port whose code depends on what the copy holds cannot be a shell: the build stops, naming
  # the line that read the copy.
  def test_a_port_that_reads_the_copy_as_it_is_built_is_refused_as_a_shell
    Dir.mktmpdir do |folder|
      from = original(folder)
      game = VBlank.game("READS COPY", consoles: %i[gba]) do
        data_pack(from: from, version: "1") { |slots| slots.colors :palette, at: PALETTE_AT, count: 16 }
        from.copy
        game_loop { wait_vblank }
      end
      refused = assert_raises(VBlank::BuildError) { VBlank::Original::Shell.build(game, err: nil) }

      assert_match "cannot be built as a shell", refused.message
      assert_match "test_shell.rb:", refused.message
    end
  end
end
