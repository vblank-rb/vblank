# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# SAVING IN A FILE BESIDE THE PROGRAM. The file holds the same bytes the interpreter's IR::SaveImage holds,
# so a save made by either starts the game on the other. The games in test/all that save play here too;
# these are what is DOS's own: the file itself, the edges of the 32K, and what is refused.
class TestDOSSaves < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  COUNTING_UP = VBlank.game("COUNT", consoles: %i[dos]) do
    screen :bitmap
    best = save_var :best, 5
    game_loop { best += 2 }
  end

  # The program played for a while in a folder of its own, with +files+ put there first, and the folder
  # handed to the block once the machine is shut.
  private def folder_after_playing(files = {})
    Dir.mktmpdir("dos-saves") do |dir|
      files.each { |name, bytes| File.binwrite(File.join(dir, name), bytes) }
      path = File.join(dir, "COUNT.EXE")
      DOS.new.build(COUNTING_UP.program(console: :dos)).write(path)
      core = VBlank::Diagnostics::Emulator.open_dos(path, in_place: true)
      10.times { core.run_frame }
      core.destroy
      yield dir
    end
  end

  private def save_file_in(dir) = File.binread(Dir.children(dir).grep(/\Acount\.sav\z/i).map { |name| File.join(dir, name) }.fetch(0))

  def test_a_game_with_no_save_file_makes_one_beside_itself_of_the_whole_32k
    folder_after_playing do |dir|
      saved = VBlank::IR::SaveImage.from_sav(save_file_in(dir))

      assert_equal VBlank::IR::SaveLayout::SIZE, save_file_in(dir).bytesize
      assert_operator saved.word(VBlank::IR::SaveLayout.save_var_at(0)), :>, 5, "the number the game kept counting"
    end
  end

  # A save the interpreter made starts the DOS game where the interpreter left off.
  def test_a_save_file_the_interpreter_made_is_read_as_the_program_starts
    image = VBlank::IR::SaveImage.new
    Reference.new(save: image).run(COUNTING_UP.program(console: :dos), frames: 100)
    left_off = image.word(VBlank::IR::SaveLayout.save_var_at(0))

    folder_after_playing("COUNT.SAV" => image.to_sav) do |dir|
      saved = VBlank::IR::SaveImage.from_sav(save_file_in(dir))

      assert_operator saved.word(VBlank::IR::SaveLayout.save_var_at(0)), :>, left_off
    end
  end

  # A file cut short (the power going off while it was first written) is made whole again, not written past its end.
  def test_a_save_file_shorter_than_the_32k_is_made_whole
    folder_after_playing("COUNT.SAV" => "\xFF".b * 100) do |dir|
      assert_equal VBlank::IR::SaveLayout::SIZE, save_file_in(dir).bytesize
    end
  end

  # The one reader's way in (Diagnostics::Verifier, through the probe): a save put in its folder under the
  # program's own name is what the program starts from, and what the program keeps is read back from it.
  def test_the_probe_starts_a_program_from_a_save_and_reads_back_what_it_kept
    image = VBlank::IR::SaveImage.new
    Reference.new(save: image).run(COUNTING_UP.program(console: :dos), frames: 100)
    left_off = image.word(VBlank::IR::SaveLayout.save_var_at(0))
    Dir.mktmpdir("dos-saves") do |dir|
      path = File.join(dir, "a-reader's-own-name.exe")
      DOS.new.build(COUNTING_UP.program(console: :dos)).write(path)
      File.binwrite(File.join(dir, "a-reader's-own-name.sav"), image.to_sav)
      probe = VBlank::Diagnostics::DOSProbe.new(path, save_dir: dir)
      probe.step(10)
      kept = VBlank::IR::SaveImage.from_sav(probe.save_memory_file)

      assert_operator kept.word(VBlank::IR::SaveLayout.save_var_at(0)), :>, left_off
    ensure
      probe&.close
    end
  end

  # The last word of the 32K is inside, a word one byte later is not, and neither is a place below nought:
  # the program stops where the interpreter stops, in its words.
  def test_a_place_outside_the_32k_stops_the_game_as_the_interpreter_does
    build = VBlank::IR::Build
    inside = build.program(build.save_write(build.int(0x7FFC), build.int(7)),
                           build.set(:read, build.save_read(build.int(0x7FFC))), build.halt)

    assert_equal 7, DOS::CheckedRun.new.run(inside, frames: 1)[:read]

    [build.save_write(build.int(0x7FFD), build.int(7)), build.set(:read, build.save_read(build.int(-1)))].each do |step|
      outside = build.program(step, build.halt)
      expected = assert_raises(VBlank::IR::ProgramError) { Reference.new.run(outside, frames: 1) }
      error = assert_raises(VBlank::IR::ProgramError) { DOS::HeadlessRun.new.run(outside, frames: 1) }

      assert_equal expected.message, error.message
    end
  end

  def test_each_width_reads_back_as_the_interpreter_reads_it
    build = VBlank::IR::Build
    widths = build.program(build.save_write(build.int(0x2000), build.int(-2)),
                           build.set(:byte, build.save_read(build.int(0x2000), width: :byte)),
                           build.set(:half, build.save_read(build.int(0x2000), width: :half)),
                           build.set(:word, build.save_read(build.int(0x2000), width: :word)),
                           build.save_write(build.int(0x2001), build.int(0x1234_5678), width: :half),
                           build.set(:after, build.save_read(build.int(0x2000), width: :word)), build.halt)

    run = DOS::CheckedRun.new.run(widths, frames: 1)

    assert_equal [0xFE, 0xFFFE, -2, VBlank::IR::Int32.wrap(0xFF56_78FE)], [run[:byte], run[:half], run[:word], run[:after]]
  end

  def test_a_sum_of_save_memory_is_the_interpreters_checksum
    build = VBlank::IR::Build
    sums = build.program(build.save_write(build.int(0x7FFC), build.int(0x0102_03FF)),
                         build.set(:whole, build.save_sum(build.int(0x7FFC), build.int(4))),
                         build.set(:none, build.save_sum(build.int(0x7FFC), build.int(-5))),
                         # From far past the 32K, back to its end: no bytes, so nothing to stop for.
                         build.set(:from_far, build.save_sum(build.int(0x10000), build.int(-0x8000))), build.halt)

    run = DOS::CheckedRun.new.run(sums, frames: 1)

    assert_equal VBlank::IR::SaveLayout.checksum([0xFF, 0x03, 0x02, 0x01]), run[:whole]
    assert_equal 0, run[:none]
    assert_equal 0, run[:from_far]
  end

  def test_save_memory_other_than_32k_of_battery_is_refused_in_plain_words
    game = VBlank.game("FLASHY", consoles: %i[dos], save_memory: 128) do
      screen :bitmap
      best = save_var :best, 5
      game_loop { best += 1 }
    end
    error = assert_raises(DOS::LoweringError) { DOS.new.build(game.program(console: :dos)) }

    assert_match(/saves in a file of 32K/, error.message)
  end

  # A game that keeps nothing carries none of the saving, and writes no file.
  def test_a_game_that_saves_nothing_writes_no_file
    Dir.mktmpdir("dos-saves") do |dir|
      game = VBlank.game("PLAIN", consoles: %i[dos]) do
        screen :bitmap
        halt
      end
      path = File.join(dir, "PLAIN.EXE")
      DOS.new.build(game.program(console: :dos)).write(path)
      core = VBlank::Diagnostics::Emulator.open_dos(path, in_place: true)
      10.times { core.run_frame }
      core.destroy

      assert_equal ["PLAIN.EXE"], Dir.children(dir)
    end
  end
end
