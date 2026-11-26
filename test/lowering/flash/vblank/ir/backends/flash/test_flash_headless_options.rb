# frozen_string_literal: true

require "test_helper"
require "open3"

# An option the C and JavaScript programs take and the Flash movie does not yet is refused by name, so a check that
# hands one over fails rather than playing the game without it.
class TestFlashHeadlessOptions < Minitest::Test
  Flash = VBlank::IR::Backends::Flash

  def setup
    game = VBlank.game("small", consoles: %i[gba]) { game_loop { clear_screen :black } }
    @swf = Flash.new.build_headless(VBlank::IR::Backends::Computer::CheckedProgram.build(game, console: :gba, err: StringIO.new))
  end

  %w[--start-file --sound-out --state-in --state-out].each do |option|
    define_method(:"test_#{option.delete_prefix('--').tr('-', '_')}_is_refused_by_name") do
      _, complaint, status = Open3.capture3(VBlank::Diagnostics::FlashPlayer.harness_path, @swf, "--headless", "2", option, "somewhere",
                                            stdin_data: "0\n0\n")

      refute status.success?
      assert_includes complaint, option
    end
  end
end
