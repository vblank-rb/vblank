# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# One side of a film, opened: a cartridge brought to the moment before the film's first frame,
# from power-on, after a tape, or from a saved state, in a save folder of its own. Each start is
# checked by the picture it leads to: the same picture as playing there from power-on.
class TestFilmCartridge < Minitest::Test
  # The emulator's save states are files the probe writes and reads; and the game's picture is
  # compared as PNG files. Neither is shared, but the reader is the emulator's, opened on the main
  # Ractor like the rest of this folder's film tests.
  runs_on_the_main_ractor!

  FilmCartridge = VBlank::Diagnostics::FilmCartridge
  RIGHT = VBlank::IR::Buttons.mask(:right)
  # The lowerings a side is shown on beside its cartridge.
  LOWERINGS = %w[interpreter ruby].freeze

  def setup
    require_emulator!
  end

  def teardown
    FileUtils.rm_rf(@scratch) if @scratch
  end

  # Five frames with right down on the tape, then one more: the square where six frames from
  # power-on, five of them with right down, leave it.
  def test_a_side_after_a_tape_starts_where_the_tape_ends
    tape = File.join(scratch, "walk.tape")
    File.write(tape, "vblank tape 1\nrecorded on: FILMED 0x00000000\nstarts from: power-on\n\n5 right\n")

    filmed = FilmCartridge.open(game, tape: tape)
    shown = picture_after(filmed, 1, "filmed")
    expected = picture_after(VBlank::Diagnostics::Verifier.new(game, frames: 0).step(5, keys: RIGHT), 1, "expected")

    assert_equal File.binread(expected), File.binread(shown)
    refute_equal File.binread(picture_after(VBlank::Diagnostics::Verifier.new(game, frames: 0), 6, "still")),
                 File.binread(shown), "the tape's presses moved the square"
  end

  def test_a_side_from_a_saved_state_starts_where_the_state_was_saved
    path = File.join(scratch, "walk.gba")
    game.write(path)
    state = File.join(scratch, "walk.ss1")
    probe = VBlank::Diagnostics::Emulator.probe(path, save_dir: Dir.mktmpdir("state-save", scratch))
    probe.step(7, keys: RIGHT)
    probe.save_state(state)
    probe.close

    shown = picture_after(FilmCartridge.open(path, state: state), 1, "filmed")
    expected = picture_after(VBlank::Diagnostics::Verifier.new(game, frames: 0).step(7, keys: RIGHT), 1, "expected")

    assert_equal File.binread(expected), File.binread(shown)
  end

  def test_each_side_has_a_save_folder_of_its_own_taken_away_on_close
    one = FilmCartridge.open(game)
    other = FilmCartridge.open(game)
    one.step(1)

    refute_equal one.save_dir, other.save_dir
    assert File.directory?(one.save_dir)
    one.close
    other.close
    refute File.exist?(one.save_dir), "closing took the save folder away"
    refute File.exist?(other.save_dir)
  end

  def test_a_tape_and_a_state_together_are_refused
    error = assert_raises(ArgumentError) { FilmCartridge.open(game, tape: "a.tape", state: "a.ss1") }
    assert_match(/one of them only/, error.message)
  end

  # A film file's `start_from` takes the frame of the tape to start after, and the folder its
  # snapshots are kept in, for every cartridge side it opens.
  def test_a_film_file_starts_its_sides_after_a_frame_of_the_tape_from_a_snapshot
    tape = File.join(scratch, "walk.tape")
    File.write(tape, "vblank tape 1\nrecorded on: FILMED 0x00000000\nstarts from: power-on\n\n5 right\nmoment walked\n5 -\n")
    snapshots = File.join(scratch, "snapshots")
    film = File.join(scratch, "walk.rb")
    File.write(film, "parts 1..2\nstart_from tape: #{tape.inspect}, starting_after: :walked, snapshots: #{snapshots.inspect}\n")
    plan = VBlank::Diagnostics::FilmScript.read(film, sides: { "ours" => game })

    shown = picture_after(plan.side_openers.fetch("ours").call, 1, "filmed")
    expected = picture_after(VBlank::Diagnostics::Verifier.new(game, frames: 0).step(5, keys: RIGHT), 1, "expected")

    assert_equal File.binread(expected), File.binread(shown)
    assert_equal 1, Dir.glob(File.join(snapshots, "*.state")).size
  end

  # A snapshot is the emulator's, so a film file's start from one reaches a side shown as a lowering
  # as a start played to: the film opens, and the lowering side shows what the cartridge side does.
  def test_a_lowering_side_plays_to_a_start_the_cartridge_side_takes_from_a_snapshot
    film = start_film("starting_after: :walked, snapshots: #{File.join(scratch, 'snapshots').inspect}")
    cartridge = VBlank::Diagnostics::FilmScript.read(film, sides: { "ours" => game }).side_openers.fetch("ours").call
    lowered = VBlank::Diagnostics::FilmScript.read(film, sides: { "ours" => game }, lowering: "ruby")
                                             .side_openers.fetch("ours").call
    3.times do |frame|
      shown = [cartridge, lowered].map { |side| File.binread(side.step(1).screenshot(File.join(scratch, "side.png"))) }
      assert_equal shown.first, shown.last, "frame #{frame + 1} after the start"
    end
  ensure
    cartridge&.close
    lowered&.close
  end

  # What cannot start is refused as the film file is read, before any side opens.
  def test_a_start_a_film_file_cannot_use_is_refused_as_it_is_read
    {
      "starting_after: :nowhere" => /nowhere/,
      "starting_after: 99" => /99/,
      "starting_after: -1" => /whole number 1 or more/,
    }.each do |start, says|
      error = assert_raises(ArgumentError) { VBlank::Diagnostics::FilmScript.read(start_film(start), sides: { "ours" => game }) }
      assert_match(says, error.message)
    end
    no_tape = File.join(scratch, "no_tape.rb")
    File.write(no_tape, "parts 1..2\nstart_from starting_after: 3\n")
    assert_raises(ArgumentError) { VBlank::Diagnostics::FilmScript.read(no_tape, sides: { "ours" => game }) }
    assert_match(/tape:/, assert_raises(ArgumentError) { FilmCartridge.open(game, starting_after: 3) }.message)
  end

  # A film file showing two frames after the walk tape's +start+ (the words after `tape:`).
  private def start_film(start)
    tape = File.join(scratch, "walk.tape")
    File.write(tape, "vblank tape 1\nrecorded on: FILMED 0x00000000\nstarts from: power-on\n\n5 right\nmoment walked\n5 -\n")
    File.join(scratch, "start.rb").tap { |film| File.write(film, "parts 1..2\nstart_from tape: #{tape.inspect}, #{start}\n") }
  end

  def test_a_tape_recorded_from_a_save_is_refused
    tape = File.join(scratch, "saved.tape")
    File.write(tape, "vblank tape 1\nrecorded on: FILMED 0x00000000\nstarts from: a save 0x12345678\n\n5 right\n")

    error = assert_raises(ArgumentError) { FilmCartridge.open(game, tape: tape) }
    assert_match(/from power-on/, error.message)
  end

  # A game to build, with no console said, is built for the first console it names, as before.
  def test_a_game_is_built_for_its_first_console_unless_the_side_says
    shown = picture_after(FilmCartridge.open(game_file), 6, "built")
    expected = picture_after(VBlank::Diagnostics::Verifier.new(game, frames: 0), 6, "expected")

    assert_equal File.binread(expected), File.binread(shown)
  end

  # The cartridge and the game played as a lowering, filmed side by side, show the same pass on every
  # frame: a sprite the framework draws for the game (a frame behind what the game says) and a square
  # the game paints itself, with right held on some frames.
  def test_the_cartridge_and_a_lowering_show_the_same_frame
    [game, painted_game].each do |built|
      LOWERINGS.each do |lowering|
        cartridge = FilmCartridge.open(built)
        lowered = FilmCartridge.open(built, lowering: lowering)
        (1..12).each do |frame|
          keys = frame.between?(4, 8) ? RIGHT : 0
          shown = [cartridge, lowered].map do |side|
            File.binread(side.step(1, keys: keys).screenshot(File.join(scratch, "side.png")))
          end
          assert_equal shown.first, shown.last, "#{built.header_title} on #{lowering}, frame #{frame}"
        end
      ensure
        cartridge&.close
        lowered&.close
      end
    end
  end

  private def scratch = @scratch ||= Dir.mktmpdir("film-cartridge-test")

  # A square the game paints itself, walking right while right is down.
  private def painted_game
    VBlank.build("PAINTED", console: :gba, out: StringIO.new, err: StringIO.new) do
      x = var :x, 16
      game_loop do
        x += 1 if held(:right)
        clear_screen :blue
        draw_rect_at x, 16, 8, 8, :red
      end
    end
  end

  # The square game as a game file names it, to be built by the side.
  private def game_file
    VBlank.game("FILMED", consoles: %i[gba]) do
      screen :tiled
      image(:dot, "#" => :red) { "########\n" * 8 }
      dot = sprite :dot, at: [16, 24]
      game_loop { dot.x += 1 if held(:right) }
    end
  end

  # A square that walks right while the right button is down.
  private def game
    @game ||= VBlank.build("FILMED", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:dot, "#" => :red) { "########\n" * 8 }
      dot = sprite :dot, at: [16, 24]
      game_loop { dot.x += 1 if held(:right) }
    end
  end

  # The picture after +frames+ more frames with nothing down, written as a PNG named +name+.
  private def picture_after(running, frames, name)
    running.step(frames, keys: 0)
    running.screenshot(File.join(scratch, "#{name}.png"))
  ensure
    running.close
  end
end
