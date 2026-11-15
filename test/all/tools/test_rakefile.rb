# frozen_string_literal: true

require "test_helper"
require "open3"

# THE SUITE RUNS EVERY TEST IN A RACTOR OF ITS OWN, and naming one test must not quietly stop
# that. Rake's test task reads TESTOPTS INSTEAD of the options the task was given, not as well
# as them, so a Rakefile that only put `--ractor` in the task's own options lost it the moment
# anybody picked a test by name: that one test then ran on plain threads, where something the
# suite refuses passes, and nothing but a missing word in "Run options" said so.
#
# Each case runs the GBA lowering's real run (`rake test:lowering:gba`, the run that plays tests
# in Ractors) over one quick test of another file, so it cannot run itself again. (One real
# test and not none: the Ractor runner stops a run with nothing in it.)
class TestRakefile < Minitest::Test
  # Starts child processes, which Ruby cannot do from inside a Ractor — the spawn waits for
  # ever — so on the main Ractor, not in the pool. See test_helper.
  runs_on_the_main_ractor!

  ROOT = VBlank.root.to_s

  private def run_options(testopts)
    # The plain GBA run whichever run this test is in: a native run's own settings (the
    # lowering, one test a process) are left out of the one it starts.
    plain = { "TESTOPTS" => testopts, VBlank::Testing::Lowering::SETTING => nil,
              VBlank::Testing::Lowering::PLAYED_AS_SETTING => nil, "MT_CPU" => nil, "TEST_PROCESSES" => nil }
    out, = Open3.capture2e(plain, "bundle", "exec", "rake", "test:lowering:gba",
                           "TEST=test/all/vblank/graphics/test_color.rb", chdir: ROOT)
    out[/^Run options: .*$/] or flunk("rake test:lowering:gba printed no run options:\n#{out}")
  end

  def test_naming_a_test_keeps_every_test_in_its_own_ractor
    assert_match(/(^| )--ractor( |$)/, run_options("--name=/test_rgb_packs_channels/"))
  end

  # A pattern that happens to contain the word is not the flag. (Quoted, because rake hands
  # the options to a shell.)
  def test_a_name_holding_the_word_ractor_still_gets_the_flag
    assert_match(/(^| )--ractor( |$)/, run_options("--name='/test_rgb_packs_channels|ractor/'"))
  end

  # THE GBA RUN BUILDS EVERY EMULATOR ITS TESTS OPEN. Its reader's tests play a Super Nintendo
  # cartridge in bsnes and a PlayStation program in Beetle PSX (test/lowering/gba/), so in a
  # checkout that never built those, a run that did not build them first failed those tests.
  def test_the_gba_run_builds_each_emulator_its_tests_play
    assert_equal %w[compile_emulator compile_ps1_core compile_snes_core],
                 prerequisites("test:lowering:gba").grep(/\Acompile_/).sort
  end

  def test_the_playthroughs_run_builds_the_super_nintendos_emulator
    assert_includes prerequisites("test:playthroughs"), "compile_snes_core"
  end

  # What rake -P lists under +task+.
  private def prerequisites(task)
    out, status = Open3.capture2e("bundle", "exec", "rake", "-P", chdir: ROOT)
    assert status.success?, out
    listed = out.lines.map(&:chomp).slice_before { |line| line.start_with?("rake ") }
    found = listed.find { |lines| lines.first == "rake #{task}" } or flunk("rake -P has no #{task}:\n#{out}")
    found.drop(1).map(&:strip)
  end

  # Somebody who asks for plain threads gets them.
  def test_asking_for_no_ractors_is_left_alone
    refute_match(/(^| )--ractor( |$)/, run_options("--no-ractor --name=/test_rgb_packs_channels/"))
  end
end
