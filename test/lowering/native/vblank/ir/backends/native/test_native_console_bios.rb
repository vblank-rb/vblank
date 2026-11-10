# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"
require "console_bios_cases"

# WHICH GAME BOY ADVANCE BIOS THE DESKTOP BUILD PLAYS THE START-UP FROM (runtime/rg_console_bios.h).
# A built game and `vblank run` find the same file, so the C rule gives the Ruby one's answer, word for
# word, on every row of the table. Every file is made up: no BIOS is needed.
class TestNativeConsoleBIOS < Minitest::Test
  include ConsoleBIOSCases

  HARNESS = Ractor.make_shareable(File.expand_path("console_bios_harness.c", __dir__))
  Zig = VBlank::IR::Backends::Native::Zig
  Computer = VBlank::IR::Backends::Computer
  ConsoleBIOS = VBlank::Live::ConsoleBIOS

  def test_the_c_rule_gives_the_ruby_rules_answers
    Dir.mktmpdir("vblank-bios") do |dir|
      rows = CASES.each_with_index.map do |(told, _answer), index|
        console_bios_places(File.join(dir, index.to_s), told)
      end
      lines = rows.map do |places|
        "#{[places[:environment], places[:setting], places[:shared_folder], KNOWN_SHA1].map { |v| word(v) }.join("\t")}\n"
      end
      exe = Zig.compile_without_sdl([HARNESS], mode: :checked)
      answers = Computer::ProgramRun.run(exe, input: lines.join).lines.map(&:chomp)

      assert_equal rows.map { |places| ruby_answer(places) }, answers
    end
  end

  def test_the_retail_checksum_is_the_ruby_rules
    exe = Zig.compile_without_sdl([HARNESS], mode: :checked)
    Dir.mktmpdir("vblank-bios") do |dir|
      places = console_bios_places(dir, { shared: :unknown })
      answer = Computer::ProgramRun.run(exe, input: "-\t-\t#{places[:shared_folder]}\t#{ConsoleBIOS::KNOWN_SHA1.first}\n")

      assert_includes answer, "SHA-1 checksum #{ConsoleBIOS::KNOWN_SHA1.first}."
    end
    header = File.read(File.join(Zig::RUNTIME_DIR, "rg_console_bios.h"))

    assert_includes header, "#define RG_CONSOLE_BIOS_RETAIL_SHA1 \"#{ConsoleBIOS::KNOWN_SHA1.first}\""
  end

  private def ruby_answer(places)
    found = ConsoleBIOS.find(environment: places[:environment], setting: places[:setting],
                             shared_folder: places[:shared_folder], known_sha1: [KNOWN_SHA1])
    case found
    when nil then "none"
    when ConsoleBIOS::Found then "found\t#{found.path}"
    else "refused\t#{found.path}\t#{found.message}"
    end
  end

  private def word(value)
    return "-" if value.nil?

    value.empty? ? "empty" : value
  end
end
