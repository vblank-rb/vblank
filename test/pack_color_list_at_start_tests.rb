# frozen_string_literal: true

require "tmpdir"
require "all/vblank/builder/test_pack_color_lists"
require "pack_at_start_tests"

# A LIST OF COLOURS FROM THE PACK, ITS PACK LEFT OUT: the games of PackColorListGames
# (test/all/vblank/builder/test_pack_color_lists.rb) built with `pack_at_start: true` and handed the
# pack file the all-in-one build made show the made-up original's own palette where each list is
# drawn. That each plays as its all-in-one build on every pass is the registry's
# (PackGames::ColorLists, test/pack_games.rb); these hold the picture to the made-up data itself.
#
# Only a build for a computer leaves its pack out, so these are played by the interpreter and the
# game as C, JavaScript and Ruby, and are not in test/all/ (PackAtStartTests says more).
module PackColorListAtStartTests
  include PackColorListGames
  include WrittenOutSearch

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # A sprite recoloured through three banks, and a backdrop that shows the first colour of a
  # bank's list: place 0 keeps the slot's own colour.
  def test_a_sprite_recolored_through_banks_read_at_start_shows_the_banks_colors
    Dir.mktmpdir do |folder|
      from = layout_original(folder, GENESIS)
      _, file = recoloring_game_and_file(banks_from_pack(from))
      left_out, = recoloring_game_and_file(banks_from_pack(from), options: LEFT_OUT)
      passed = game_player.hand_file(file).run(left_out, frames: 2 + framework_drawing_lag).screen

      assert_equal BANKS.fetch(2).drop(1).map { |color| shown(color) },
                   STRIPES.map { |column| passed.pixel(SHIP_AT.first + 2 + column, SHIP_AT.last + 1) }, "pass 2 shows bank 2"
      assert_equal shown(BANKS.fetch(3).first), passed.pixel(*BACKDROP_AT), "the backdrop is the first color of bank 3"
    end
  end

  def test_a_walk_of_a_list_read_at_start_ends_on_the_lists_own_colors
    Dir.mktmpdir do |folder|
      from = layout_original(folder, GENESIS)
      _, file = walking_game_and_file(from)
      left_out, = walking_game_and_file(from, options: LEFT_OUT)
      last = game_player.hand_file(file).run(left_out, frames: WALK_STEPS + 1 + framework_drawing_lag).screen

      assert_equal BANKS.fetch(2).drop(1).map { |color| shown(color) },
                   STRIPES.map { |column| last.pixel(SHIP_AT.first + column, SHIP_AT.last + 1) }, "the walk's last step is the list's own colors"
    end
  end

  def test_a_picture_drawn_in_a_list_read_at_start_is_blitted_in_the_lists_colors
    Dir.mktmpdir do |folder|
      from = layout_original(folder, GENESIS)
      _, file = blitting_game_and_file(from)
      left_out, = blitting_game_and_file(from, options: LEFT_OUT)
      screen = game_player.hand_file(file).run(left_out, frames: 2).screen

      assert_equal BANKS.fetch(1).drop(1).map { |color| shown(color) }, STRIPES.map { |column| screen.pixel(20 + column, 21) }
    end
  end

  # The game as the block writes it out (as C, JavaScript or Ruby) holds the banks' colours when
  # built all-in-one, and none of them built with its pack left out. A lowering's test file calls this.
  private def assert_lists_written_without_the_originals_colors(&write)
    Dir.mktmpdir do |folder|
      from = layout_original(folder, GENESIS)
      whole, = recoloring_game_and_file(banks_from_pack(from))
      left_out, = recoloring_game_and_file(banks_from_pack(from), options: LEFT_OUT)
      # A row of the ship in each bank's colours, which is how a build holding them keeps them.
      needles = (1..3).map { |bank| SHIP.first(8).map { |place| BANKS.fetch(bank).fetch(place) } }

      ways_holding_needles([["the lists", whole, left_out, needles]], &write)
    end
  end
end
