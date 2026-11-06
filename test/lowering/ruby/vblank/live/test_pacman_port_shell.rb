# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"
require VBlank.root.join("examples/pacman").to_s
require VBlank.root.join("test/fixtures/pacman_port/pacman_fixture").to_s
require VBlank.root.join("test/fixtures/pacman_port/pacman_port").to_s

# THE PAC-MAN PORT BUILT AS A SHELL, PLAYED AS RUBY. The port (test/fixtures/pacman_port/pacman_port.rb)
# holds none of the data of pacman.gba, the cartridge examples/pacman.rb builds, which stands in for
# a retail original. The shell takes pacman.gba at Load ROM, unpacks it with the port's own routine
# (LZ77 and run-length, as the cartridge packs it), keeps the pack, and plays Pac-Man.
#
# The answer keys: the pack the shell keeps is the cartridge's assets unpacked by a decoder written
# apart from the port's routine (PacmanFixture.unpack_block), slot by slot; and the game it plays is
# examples/pacman, pixel for pixel, over a tape of presses.
class TestPacmanPortShell < Minitest::Test
  Headless = VBlank::Live::Headless
  Session = VBlank::Live::Session
  Shell = VBlank::Live::Shell
  PACK_FILE = VBlank::Original::ShellFacts::PACK_FILE

  CHOOSE_LOAD_ROM = { 2 => [:a] }.freeze

  # How many passes of the game are watched, and the presses: left for a while, then up, long enough
  # for Pac to eat a pellet, be caught, and blink.
  GAME_PASSES = 200
  TAPE = ((10..40).to_h { |pass| [pass, [:left]] }.merge((41..90).to_h { |pass| [pass, [:up]] }).merge((91..110).to_h { |pass| [pass, %i[right down]] })).freeze

  # The port on a machine with no copy of the cartridge: what a shell is built from.
  private def port_without_copy(folder) = PacmanPort.game(PacmanPort.original(env: {}))

  # The port with the cartridge in reach, built all-in-one.
  private def port_with_copy = PacmanPort.game(PacmanPort.original(env: { "PACMAN_ROM" => PacmanFixture::ROM_PATH }))

  private def shell(folder) = Shell.from(VBlank::Original::Shell.build(port_without_copy(folder), err: nil))

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

  def test_the_first_start_plays_pacman_as_the_example_does_pixel_for_pixel
    Dir.mktmpdir do |folder|
      played = play_shell(shell(folder), folder, picked: PacmanFixture::ROM_PATH)

      assert_equal 1, played.times_asked
      assert_empty played.refusals
      assert_equal GAME_PASSES, played.pictures.size
      assert_same_pictures pictures_of(Pacman::GAME.checked_program(err: nil, console: :gba)), played.pictures, "the shell"
    end
  end

  def test_the_pack_the_shell_keeps_is_the_cartridges_assets_unpacked_byte_for_byte
    Dir.mktmpdir do |folder|
      play_shell(shell(folder), folder, picked: PacmanFixture::ROM_PATH)

      assert_equal PacmanFixture.expected_pack, File.binread(File.join(folder, "kept", PACK_FILE))
    end
  end

  def test_the_port_built_all_in_one_plays_pacman_as_the_example_does
    assert_same_pictures pictures_of(Pacman::GAME.checked_program(err: nil, console: :gba)),
                         pictures_of(port_with_copy.checked_program(err: nil, console: :gba)), "the port built all-in-one"
  end

  def test_the_next_start_plays_from_the_kept_pack_with_the_cartridge_out_of_reach
    Dir.mktmpdir do |folder|
      first = play_shell(shell(folder), folder, picked: PacmanFixture::ROM_PATH)
      second = play_shell(shell(folder), folder, picked: nil)

      assert_equal 0, second.times_asked
      assert_empty second.refusals
      assert_same_pictures first.pictures, second.pictures, "the second start"
    end
  end

  def test_a_file_that_is_not_the_cartridge_is_refused
    Dir.mktmpdir do |folder|
      wrong = File.join(folder, "wrong.gba")
      File.binwrite(wrong, File.binread(PacmanFixture::ROM_PATH).reverse)
      played = play_shell(shell(folder), folder, picked: wrong, menu_frames: 40)

      assert_match "not a release of Pac-Man that this game knows", played.refusals.first
      refute File.exist?(File.join(folder, "kept", PACK_FILE))
    end
  end
end
