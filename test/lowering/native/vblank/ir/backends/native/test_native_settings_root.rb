# frozen_string_literal: true

require "test_helper"
require "settings_root_cases"

# WHERE A PLAYER'S SETTINGS FOLDERS ARE (runtime/rg_settings_root.h). A built game and `vblank run`
# share these files, so the C rule answers the same table as the Ruby one.
class TestNativeSettingsRoot < Minitest::Test
  include SettingsRootCases

  HARNESS = Ractor.make_shareable(File.expand_path("settings_root_harness.c", __dir__))
  Zig = VBlank::IR::Backends::Native::Zig

  def test_the_c_rule_answers_the_table
    lines = CASES.map { |told, _folder| "#{word(told[:config_dir])} #{word(told[:xdg])} #{word(told[:home])} #{told[:linux] ? 1 : 0}\n" }
    exe = Zig.compile_without_sdl([HARNESS], mode: :checked)
    answers = Zig.run_program(exe, input: lines.join).lines.map(&:chomp)

    assert_equal CASES.map { |_told, folder| folder || "-" }, answers
  end

  private def word(value)
    return "-" if value.nil?

    value.empty? ? "empty" : value
  end
end
