# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "shell_tests"

# The C file a desktop shell's facts are written to (Native::ShellData), and the files beside it.
class TestNativeShellData < Minitest::Test
  include ShellTests

  Native = VBlank::IR::Backends::Native
  ShellData = Native::ShellData

  # A port whose pack names many pieces has a long header after its SHA-1, and the printer keeps a
  # table of bytes that long in a file of its own that the C embeds. The compiler stops on an embed
  # whose file was never written, and zig reports only that it could not read its dependency file.
  # The made-up port's header is short, so its facts are given a header longer than the printer
  # writes out as numbers.
  def test_every_file_the_shell_data_embeds_is_written_beside_it
    Dir.mktmpdir do |folder|
      shell = VBlank::Original::Shell.build(port_without_copy(folder), err: nil)
      long_header = (0..Native::Printer::MOST_WRITTEN_AS_NUMBERS).map { |at| at % 256 }.pack("C*")
      shell = shell.with(facts: shell.facts.with(pack_after_sha1: long_header))

      files = ShellData.source_files(shell)
      embedded = files.fetch(ShellData::FILE).scan(/^#embed "([^"]+)"/).flatten

      refute_empty embedded, "the long header is embedded from a file"
      embedded.each { |name| assert_equal long_header, files[name], "#{name} is written beside #{ShellData::FILE}" }
    end
  end

  def test_a_build_that_is_no_shell_is_one_file
    assert_equal [ShellData::FILE], ShellData.source_files.keys
  end
end
