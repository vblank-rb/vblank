# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/original/shell_check_tasks"
require "made_up_original"

# A port checks its shell with one rake task, given the game's file as `vblank run` takes it.
class TestShellCheckTasks < Minitest::Test
  # Every test defines rake tasks and loads a game file into the registry, which the whole process shares.
  runs_on_the_main_ractor!

  include MadeUpOriginal

  # A game file declaring a port of the made-up original, whose copy is +copy+ (nil: none named).
  private def game_file(folder, copy)
    path = File.join(folder, "port.rb")
    File.write(path, <<~RUBY)
      from = VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => #{copy.inspect} }.compact,
                                        settings_file: #{File.join(folder, 'made_up.yml').inspect},
                                        releases: { "Test" => { "sha1" => #{SHA1.inspect}, "size" => #{COPY_SIZE} } })
      VBlank.game("MADE UP", consoles: %i[gba]) do
        data_pack(from: from, version: "1") { |slots| slots.colors :palette, at: #{PALETTE_AT}, count: 16 }
        game_loop { wait_vblank }
      end
    RUBY
    path
  end

  private def check_task(file)
    Rake.application = Rake::Application.new
    VBlank::Original::ShellCheckTasks.new { |t| t.game_file = file }
    Rake::Task["shell:check"]
  end

  def test_the_task_checks_the_shell_of_the_game_the_file_declares
    Dir.mktmpdir do |folder|
      copy = File.join(folder, "made_up.gba").tap { |path| File.binwrite(path, COPY) }
      task = check_task(game_file(folder, copy))
      out, = capture_io { task.invoke }

      assert_match "plays as its all-in-one build does", out
    end
  end

  def test_the_task_fails_saying_how_to_name_a_copy_when_none_is_named
    Dir.mktmpdir do |folder|
      task = check_task(game_file(folder, nil))
      _, err = capture_io { assert_raises(SystemExit) { task.invoke } }

      assert_match "MADE_UP_ROM", err
    end
  end
end
