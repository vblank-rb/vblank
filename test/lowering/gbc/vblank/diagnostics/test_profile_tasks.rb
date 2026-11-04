# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"
require "tmpdir"
require "vblank/diagnostics/profile_tasks"

# A GAME'S `rake profile TAPE=... FRAMES=...`: the tapes in its folder played on the cartridge its
# Rakefile names, each frame asked for read by itself.
class TestProfileTasks < Minitest::Test
  # The task is defined in a rake application of the test's own.
  runs_on_the_main_ractor!

  def setup
    @rake_before = Rake.application
    Rake.application = Rake::Application.new
  end

  def teardown
    Rake.application = @rake_before
    FileUtils.rm_rf(@scratch) if @scratch
  end

  def test_rake_profile_reads_each_frame_of_the_named_tape
    tape_file("roulette", PRESSES)

    said = with_env("TAPE" => "roulette", "FRAMES" => "43..46") { capture_io { Rake::Task["profile"].invoke }.first }

    assert_match(/Frames 43 to 46 of the tape/, said)
    assert_match(/The busiest frame was 4\d/, said)
    assert_match(/yours: .*spin/, said)
  end

  def test_the_profile_comes_as_data_too
    tape_file("roulette", PRESSES)
    out = StringIO.new

    tasks.profile(tape_name: "roulette", frames: "45..46", format: :json, out: out)

    assert_equal [45, 46], JSON.parse(out.string).fetch("frames").map { |frame| frame.fetch("frame") }
  end

  def test_without_a_tape_it_is_the_profile_standing_still
    result = tasks.profile(frames: "20", out: StringIO.new)

    assert_equal 20, result.frames
  end

  def test_a_tape_that_is_not_there_is_named_with_the_tapes_there_are
    tape_file("roulette", PRESSES)

    error = assert_raises(SystemExit) { capture_io { tasks.profile(tape_name: "boss") } }
    assert_match(/no tape called boss/, error.message)
    assert_match(/roulette/, error.message)
  end

  # A game whose count jumps on the pass after A goes down.
  TAPED = VBlank.game("TAPED", consoles: %i[gbc]) do
    total = 0
    func(:spin) { repeat(200) { total += 3 } }
    game_loop { call :spin if pressed(:a) }
  end

  # A down on frame 44 alone.
  PRESSES = <<~TAPE
    vblank tape 1
    recorded on: TAPED 0x00000000
    starts from: power-on

    43 -
    1 a
    10 -
  TAPE

  private def scratch = @scratch ||= Dir.mktmpdir("profile-tasks-test")

  private def tasks
    rom = TAPED.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    VBlank::Diagnostics::ProfileTasks.new do |t|
      t.tapes = File.join(scratch, "tapes")
      t.cartridge = -> { rom }
    end
  end

  private def tape_file(name, text)
    FileUtils.mkdir_p(File.join(scratch, "tapes"))
    File.write(File.join(scratch, "tapes", "#{name}.tape"), text)
    tasks
  end

  private def with_env(values)
    before = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    before.each { |key, value| ENV[key] = value }
  end
end
