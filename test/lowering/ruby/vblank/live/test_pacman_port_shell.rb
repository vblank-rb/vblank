# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "vblank/live"
require "shell_tests"

# THE PAC-MAN PORT BUILT AS A SHELL, PLAYED AS RUBY. The port (test/fixtures/pacman_port/pacman_port.rb)
# holds none of the data of pacman.gba, the cartridge examples/pacman.rb builds, which stands in for
# a retail original. The shell takes pacman.gba at Load ROM, unpacks it with the port's own routine
# (LZ77 and run-length, as the cartridge packs it), keeps the pack, and plays Pac-Man.
#
# The answer keys: the pack the shell keeps is the one the port's all-in-one build makes, byte for
# byte; and the game it plays is examples/pacman, pixel for pixel, over a tape of presses.
class TestPacmanPortShell < Minitest::Test
  include PacmanShellTests

  Headless = VBlank::Live::Headless
  Session = VBlank::Live::Session
  Shell = VBlank::Live::Shell
  PACK_FILE = VBlank::Original::ShellFacts::PACK_FILE

  CHOOSE_LOAD_ROM = { 2 => [:a] }.freeze

  private def shell(version: "1") = Shell.from(VBlank::Original::Shell.build(port_without_copy(version: version), err: nil))

  private def pictures_of(program)
    device = Headless.new(frames: GAME_PASSES, buttons: TAPE)
    Session.new(program).play(device)
    device.pictures.map(&:pixels)
  end

  # Two runs' pictures are the same, or the first pass and pixel they differ at. (assert_equal on
  # two hundred pictures would spend minutes working out a diff.)
  private def assert_same_pictures(expected, actual, what)
    assert_equal expected.size, actual.size, "#{what}: passes played"
    expected.each_index do |pass|
      next if expected[pass] == actual[pass]

      pixel = expected[pass].each_index.find { |at| expected[pass][at] != actual[pass][at] }
      flunk "#{what}: pass #{pass + 1} differs, first at pixel #{pixel} (x #{pixel % 240}, y #{pixel / 240}): " \
            "#{expected[pass][pixel]} against #{actual[pass][pixel]}"
    end
  end

  # The shell played once: LOAD ROM picking +picked+ (a path, or nil for nothing), then the game for
  # GAME_PASSES passes on the tape. The pictures and what the player was told.
  Played = Data.define(:pictures, :refusals, :times_asked)

  private def play_shell(shell, folder, picked:, menu_frames: 20_000)
    refusals = []
    asked = 0
    game_device = Headless.new(frames: GAME_PASSES, buttons: TAPE)
    shell.play(Headless.new(frames: menu_frames, buttons: CHOOSE_LOAD_ROM), folder_path: File.join(folder, "kept"),
                                                                       choose_copy: lambda {
                                                                         asked += 1
                                                                         picked
                                                                       }, refused: ->(words) { refusals << words },
                                                                       play_game: ->(game) { Session.new(game: game).play(game_device) })
    Played.new(pictures: game_device.pictures.map(&:pixels), refusals: refusals, times_asked: asked)
  end

  private def kept_pack(folder) = File.binread(File.join(folder, "kept", PACK_FILE))

  private def example_pictures = pictures_of(Pacman::GAME.checked_program(err: nil, console: :gba))

  def test_the_first_start_plays_pacman_as_the_example_does_pixel_for_pixel
    Dir.mktmpdir do |folder|
      played = play_shell(shell, folder, picked: copy_of_the_cartridge(folder))

      assert_equal 1, played.times_asked
      assert_empty played.refusals
      assert_same_pictures example_pictures, played.pictures, "the shell"
    end
  end

  def test_the_pack_the_shell_keeps_is_the_all_in_one_builds_byte_for_byte
    Dir.mktmpdir do |folder|
      play_shell(shell, folder, picked: copy_of_the_cartridge(folder))

      assert_equal all_in_one_pack, kept_pack(folder)
    end
  end

  def test_the_port_built_all_in_one_plays_pacman_as_the_example_does
    assert_same_pictures example_pictures, pictures_of(port_with_copy.checked_program(err: nil, console: :gba)), "the port built all-in-one"
  end

  def test_the_next_start_plays_from_the_kept_pack_with_the_cartridge_out_of_reach
    Dir.mktmpdir do |folder|
      copy = copy_of_the_cartridge(folder)
      play_shell(shell, folder, picked: copy)
      File.delete(copy)
      second = play_shell(shell, folder, picked: nil)

      assert_equal 0, second.times_asked
      assert_empty second.refusals
      assert_same_pictures example_pictures, second.pictures, "the second start"
    end
  end

  def test_a_new_build_of_the_port_asks_for_the_cartridge_again
    Dir.mktmpdir do |folder|
      play_shell(shell, folder, picked: copy_of_the_cartridge(folder))
      second = play_shell(shell(version: "2"), folder, picked: copy_of_the_cartridge(folder))

      assert_equal 1, second.times_asked
      assert_match "not the data pack this build reads", second.refusals.first
      assert_equal all_in_one_pack(version: "2"), kept_pack(folder)
    end
  end

  def test_a_file_that_is_not_the_cartridge_is_refused
    Dir.mktmpdir do |folder|
      wrong = File.join(folder, "wrong.gba")
      File.binwrite(wrong, File.binread(PacmanFixture::ROM_PATH).reverse)
      played = play_shell(shell, folder, picked: wrong, menu_frames: 40)

      assert_match "not a release of Pac-Man that this game knows", played.refusals.first
      refute File.exist?(File.join(folder, "kept", PACK_FILE))
    end
  end

  def test_the_shell_written_as_one_ruby_file_holds_none_of_the_cartridge
    Dir.mktmpdir do |folder|
      path = VBlank::IR::Backends::Ruby.new.build_script(port_without_copy, File.join(folder, "pacman-ruby.rb"), console: :gba,
                                                                                                               err: StringIO.new, shell: true)

      assert_holds_none_of original_pieces, File.binread(path), "the Ruby script"
    end
  end
end
