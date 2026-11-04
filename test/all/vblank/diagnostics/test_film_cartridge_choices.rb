# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# WHAT A FILM SIDE IS TOLD, and what it refuses: the lowering that shows the game, and the console a
# game to build is built for. Nothing here plays a cartridge in an emulator (test_film_cartridge.rb in
# test/lowering/gba/ does), so every run plays it.
class TestFilmCartridgeChoices < Minitest::Test
  # The game built as Ruby is played by a Ruby of its own: a child process, which hangs inside a
  # Ractor.
  runs_on_the_main_ractor!

  FilmCartridge = VBlank::Diagnostics::FilmCartridge
  RIGHT = VBlank::IR::Buttons.mask(:right)

  def teardown
    FileUtils.rm_rf(@scratch) if @scratch
  end

  # A side told a lowering plays the game that way: built as Ruby, its picture is the interpreter's,
  # frame for frame, and the presses move the square there too.
  def test_a_side_on_a_lowering_plays_the_game_that_way
    as_ruby = picture_after(FilmCartridge.open(game, lowering: "ruby").step(5, keys: RIGHT), 1, "ruby")
    interpreted = picture_after(FilmCartridge.open(game, lowering: "interpreter").step(5, keys: RIGHT), 1, "interpreter")
    still = picture_after(FilmCartridge.open(game, lowering: "interpreter"), 6, "still")

    assert_equal as_ruby, interpreted
    refute_equal still, interpreted, "the presses moved the square"
  end

  # A lowering plays from a tape as the cartridge does.
  def test_a_side_on_a_lowering_starts_where_the_tape_ends
    tape = File.join(scratch, "walk.tape")
    File.write(tape, "vblank tape 1\nrecorded on: FILMED 0x00000000\nstarts from: power-on\n\n5 right\n")

    taped = picture_after(FilmCartridge.open(game, lowering: "interpreter", tape: tape), 1, "taped")
    expected = picture_after(FilmCartridge.open(game, lowering: "interpreter").step(5, keys: RIGHT), 1, "expected")

    assert_equal expected, taped
  end

  # A lowering plays the game the cartridge holds, whether the side is the game or its built
  # cartridge: the game asks `built_for_computer?`, and both sides answer as the cartridge does.
  def test_a_game_and_its_built_cartridge_show_the_same_game_on_a_lowering
    asks = asking_game
    from_game = picture_after(FilmCartridge.open(asks, lowering: "interpreter"), 3, "game")
    built = asks.build_rom(out: nil, err: nil, profile: false)
    from_cartridge = picture_after(FilmCartridge.open(built, lowering: "interpreter"), 3, "cartridge")

    assert_equal from_cartridge, from_game
  end

  def test_an_unknown_lowering_is_refused_with_the_ones_there_are
    error = assert_raises(ArgumentError) { FilmCartridge.open(game, lowering: "gameboy") }
    assert_match(/"gameboy"/, error.message)
    assert_match(/emulator, ruby, js, native and interpreter/, error.message)
  end

  def test_a_way_with_no_picture_is_refused
    error = assert_raises(ArgumentError) { FilmCartridge.open(game, lowering: "logic") }
    assert_match(/no picture/, error.message)
  end

  def test_an_unknown_console_is_refused_with_the_ones_there_are
    error = assert_raises(ArgumentError) { FilmCartridge.open(game, console: :xbox) }
    assert_match(/xbox/, error.message)
    assert_match(/:gba/, error.message)
  end

  # A game is built only for the consoles it names.
  def test_a_console_the_game_does_not_name_is_refused
    error = assert_raises(ArgumentError) { FilmCartridge.open(asking_game, console: :snes) }
    assert_match(/Super Nintendo/, error.message)
  end

  # A cartridge is for one console: a side that names another is refused, saying which.
  def test_a_cartridge_named_as_another_console_is_refused
    error = assert_raises(ArgumentError) { FilmCartridge.open(game, console: :gbc, lowering: "interpreter") }
    assert_match(/Game Boy Advance cartridge/, error.message)
    assert_match(/console: :gba/, error.message)
  end

  # A cartridge file is only its bytes: no game in it to play another way.
  def test_a_cartridge_file_on_a_lowering_is_refused
    path = File.join(scratch, "walk.gba")
    game.write(path)

    error = assert_raises(ArgumentError) { FilmCartridge.open(path, lowering: "ruby") }
    assert_match(/only in the emulator/, error.message)
  end

  # A saved state is the emulator's own, so a lowering cannot start from one.
  def test_a_saved_state_on_a_lowering_is_refused
    error = assert_raises(ArgumentError) { FilmCartridge.open(game, lowering: "ruby", state: "a.ss1") }
    assert_match(/saved state/, error.message)
  end

  private def scratch = @scratch ||= Dir.mktmpdir("film-choices-test")

  # A square that walks right while the right button is down.
  private def game
    @game ||= VBlank.build("FILMED", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:dot, "#" => :red) { "########\n" * 8 }
      dot = sprite :dot, at: [16, 24]
      game_loop { dot.x += 1 if held(:right) }
    end
  end

  # A game that paints itself red where it is built for a computer and blue where it is a cartridge.
  private def asking_game
    VBlank.game("ASKS", consoles: %i[gba]) do
      game_loop do
        if built_for_computer?
          clear_screen :red
        else
          clear_screen :blue
        end
      end
    end
  end

  # The PNG's bytes after +frames+ more frames with nothing down.
  private def picture_after(running, frames, name)
    running.step(frames, keys: 0)
    File.binread(running.screenshot(File.join(scratch, "#{name}.png")))
  ensure
    running.close
  end
end
