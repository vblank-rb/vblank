# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# A reader that is never closed still leaves the machine's temporary files as it found them,
# on every system. Windows refuses to remove a file a program holds open, and the emulator holds
# its cartridge open until it is shut, so the emulator must be shut before its cartridge file is
# removed, on the way out of the process as much as on Verifier#close. A run that got the order
# wrong left a cartridge file behind for every reader, and a warning for each.
#
# The process is a child of its own, with files kept as Windows keeps them
# (test/fixtures/reader_left_open/play.rb), since what is under test is what happens as a
# process ends.
class TestReaderLeftOpen < Minitest::Test
  RUBY = RbConfig.ruby.freeze
  PLAY = VBlank.root.join("test/fixtures/reader_left_open/play.rb").to_s.freeze
  LIB = VBlank.root.join("lib").to_s.freeze

  def test_a_reader_never_closed_leaves_no_files_and_no_warnings
    Dir.mktmpdir("left-open") do |folder|
      said, status = Open3.capture2e({ "TMPDIR" => folder, "TMP" => folder, "TEMP" => folder },
                                     RUBY, "-rbundler/setup", "-I", LIB, PLAY, chdir: VBlank.root.to_s)

      assert status.success?, said
      assert_includes said, "played"
      refute_match(/finalizer|EACCES/, said)
      assert_empty Dir.children(folder), "the run left these in the temporary files"
    end
  end
end
