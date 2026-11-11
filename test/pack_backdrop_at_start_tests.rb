# frozen_string_literal: true

require "digest"
require "tmpdir"
require "all/vblank/builder/test_pack_backdrops"
require "pack_at_start_tests"

# A SCREEN'S BACKDROP FROM THE PACK, ITS PACK LEFT OUT: the games of PackBackdropGames
# (test/all/vblank/builder/test_pack_backdrops.rb) built with `pack_at_start: true` and handed the
# pack file the all-in-one build made show what the all-in-one build shows. The answer key is the
# all-in-one build on the interpreter.
#
# Only a build for a computer leaves its pack out, so these are played by the interpreter and the
# game as C, JavaScript and Ruby, and are not in test/all/ (PackAtStartTests says more). A scene's
# own backdrop is test/console/gba/vblank/builder/test_pack_backdrops_at_start_on_the_advance.rb's.
module PackBackdropAtStartTests
  include PackBackdropGames
  include WrittenOutSearch

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # The game whose `screen` line is given what +screen_options+ makes of the pack, built both ways,
  # shows one picture after each of +frames+, and the backdrop +color+ where no tile draws.
  private def assert_backdrop_plays_alike(color, frames: [1, 3], &screen_options)
    Dir.mktmpdir do |folder|
      from = backdrop_original(folder)
      whole = game_with_backdrop(from, &screen_options)
      left_out = game_with_backdrop(from, options: LEFT_OUT, &screen_options)
      file = backdrop_pack_file(from)

      frames.each do |count|
        shown = game_player.run(whole, frames: count).screen
        assert_equal shown(color), shown.pixel(*EMPTY), "the all-in-one build shows the backdrop where no tile draws"
        assert_equal shown.to_a, game_player.hand_file(file).run(left_out, frames: count).screen.to_a,
                     "after #{count} frames the game handed its pack shows what the all-in-one build shows"
      end
    end
  end

  # The game's one cell is a background read at start too, so each of these is a pack background
  # and a pack backdrop on one screen.
  def test_a_backdrop_from_a_slot_read_at_start_shows_as_the_all_in_one_build
    assert_backdrop_plays_alike(BANKS[0][0]) { |pack| { backdrop: pack[:palette] } }
  end

  def test_a_backdrop_from_a_bank_read_at_start_shows_as_the_all_in_one_build
    assert_backdrop_plays_alike(BANKS[1][0]) { |pack| { backdrop: pack[:palette].bank(1) } }
  end

  def test_a_backdrop_place_read_at_start_shows_as_the_all_in_one_build
    assert_backdrop_plays_alike(BANKS[1][3]) { |pack| { backdrop: pack[:palette], backdrop_place: 19 } }
  end

  def test_a_place_of_a_bank_read_at_start_shows_as_the_all_in_one_build
    assert_backdrop_plays_alike(BANKS[1][7]) { |pack| { backdrop: pack[:palette].bank(1), backdrop_place: 7 } }
  end

  # The slot's size is the game's own word, so a place past it is refused as the game is built,
  # whichever way it is built.
  def test_a_place_the_slot_does_not_have_is_refused_with_the_pack_left_out
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_with_backdrop(backdrop_original(folder), options: LEFT_OUT) { |pack| { backdrop: pack[:palette].bank(1), backdrop_place: 16 } }
      end

      assert_includes error.message, "backdrop_place: 16"
      assert_includes error.message, "0 to 15"
    end
  end

  def test_a_slot_that_does_not_hold_colors_is_refused_with_the_pack_left_out
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_with_backdrop(backdrop_original(folder), options: LEFT_OUT) { |pack| { backdrop: pack[:map] } }
      end

      assert_includes error.message, "a slot of colors"
    end
  end

  # A GENESIS ORIGINAL keeps a colour in nine bits, high byte first, so its backdrop is read in
  # that layout: sixteen made-up colours, none of them black, and a screen that shows nothing else.
  GENESIS_COLORS_AT = 0x10
  GENESIS_COLORS = Ractor.make_shareable(Array.new(16) { |at| (((at * 3) % 8) << 1) | ((7 - (at % 8)) << 5) | (((at + 2) % 8) << 9) })
  GENESIS_PLACE = 5

  # The game and the pack file its build made (nil for a build that leaves its pack out).
  private def genesis_backdrop_game(folder, options: VBlank::Cartridge::Options.new)
    copy = "\0".b * (GENESIS_COLORS_AT + 32)
    copy[GENESIS_COLORS_AT, 32] = GENESIS_COLORS.pack("n*")
    path = File.join(folder, "made_up_genesis.bin")
    File.binwrite(path, copy)
    from = VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :genesis,
                                      settings_file: File.join(folder, "made_up.yml"),
                                      releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
    b = Builder.new(options: options)
    b.instance_eval do
      pack = data_pack(from: from, version: "1") { |slots| slots.colors :palette, at: GENESIS_COLORS_AT, count: 16 }
      screen :tiled, backdrop: pack[:palette], backdrop_place: GENESIS_PLACE
      game_loop { wait_vblank }
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  def test_a_genesis_originals_backdrop_read_at_start_shows_as_the_all_in_one_build
    Dir.mktmpdir do |folder|
      whole, file = genesis_backdrop_game(folder)
      left_out, = genesis_backdrop_game(folder, options: LEFT_OUT)
      shown = game_player.run(whole, frames: 2).screen

      refute_equal 0, shown.pixel(*EMPTY), "the all-in-one build shows the backdrop"
      assert_equal shown.to_a, game_player.hand_file(file).run(left_out, frames: 2).screen.to_a
    end
  end

  # The game as the block writes it out (as C, JavaScript or Ruby) holds the backdrop's colour
  # when built all-in-one, and does not built with its pack left out. A lowering's test file calls this.
  private def assert_backdrop_written_without_the_originals_color
    Dir.mktmpdir do |folder|
      from = backdrop_original(folder)
      whole = game_with_backdrop(from) { |pack| { backdrop: pack[:palette] } }
      left_out = game_with_backdrop(from, options: LEFT_OUT) { |pack| { backdrop: pack[:palette] } }

      assert_includes number_runs_in(yield(whole)).fetch(:numbers).first, BANKS[0][0], "the all-in-one build holds the colour"
      refute_includes number_runs_in(yield(left_out)).fetch(:numbers).first, BANKS[0][0], "the build with its pack left out holds it"
    end
  end
end
