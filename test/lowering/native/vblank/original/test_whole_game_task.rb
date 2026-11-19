# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/original/shell_check_tasks"
require "made_up_original"

# A port checks its whole game, the shell's against the all-in-one build's as C, with one rake task
# beside its shell check, run when asked. On the native run alone: the task builds the game as C.
class TestWholeGameTask < Minitest::Test
  # Every test defines rake tasks and loads a game file into the registry, which the whole process shares.
  runs_on_the_main_ractor!

  include MadeUpOriginal

  # A game file declaring a port of the made-up original whose copy is in +folder+.
  private def game_file(folder)
    copy = File.join(folder, "made_up.gba").tap { |path| File.binwrite(path, COPY) }
    path = File.join(folder, "port.rb")
    File.write(path, <<~RUBY)
      from = VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => #{copy.inspect} },
                                        settings_file: #{File.join(folder, 'made_up.yml').inspect},
                                        releases: { "Test" => { "sha1" => #{SHA1.inspect}, "size" => #{COPY_SIZE} } })
      VBlank.game("MADE UP", consoles: %i[gba]) do
        data_pack(from: from, version: "1") { |slots| slots.colors :palette, at: #{PALETTE_AT}, count: 16 }
        game_loop { wait_vblank }
      end
    RUBY
    path
  end

  private def tape_file(folder)
    File.join(folder, "whole.tape").tap do |path|
      File.write(path, "vblank tape 1\nrecorded on: MADE UP 0x00000000\nstarts from: power-on\n\n200 -\n200 a\n")
    end
  end

  private def whole_game_task(folder, tape: nil, whole_game_tape: nil)
    Rake.application = Rake::Application.new
    VBlank::Original::ShellCheckTasks.new do |t|
      t.game_file = game_file(folder)
      t.tape = tape
      t.whole_game_tape = whole_game_tape
    end
    Rake::Task["shell:whole_game"]
  end

  def test_the_task_plays_the_whole_game_tape
    Dir.mktmpdir do |folder|
      task = whole_game_task(folder, tape: nil, whole_game_tape: tape_file(folder))
      out, = capture_io { task.invoke }

      assert_match "400 passes", out
      assert_match "plays the whole tape as its all-in-one build does", out
    end
  end

  # The shell check's tape is the whole game's too, where the Rakefile names no other.
  def test_the_task_plays_the_shell_checks_tape_when_no_other_is_named
    Dir.mktmpdir do |folder|
      task = whole_game_task(folder, tape: tape_file(folder))
      out, = capture_io { task.invoke }

      assert_match "400 passes", out
    end
  end

  def test_the_task_fails_saying_how_to_name_a_tape_when_none_is_named
    Dir.mktmpdir do |folder|
      task = whole_game_task(folder)
      _, err = capture_io { assert_raises(SystemExit) { task.invoke } }

      assert_match "t.whole_game_tape", err
    end
  end
end
