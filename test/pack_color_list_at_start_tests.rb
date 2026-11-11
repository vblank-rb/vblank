# frozen_string_literal: true

require "tmpdir"
require "all/vblank/builder/test_pack_color_lists"
require "pack_at_start_tests"

# A LIST OF COLOURS FROM THE PACK, ITS PACK LEFT OUT: the games of PackColorListGames
# (test/all/vblank/builder/test_pack_color_lists.rb) built with `pack_at_start: true` and handed the
# pack file the all-in-one build made show what the all-in-one build shows. The answer key is the
# all-in-one build on the interpreter, and the made-up original's own palette.
#
# Only a build for a computer leaves its pack out, so these are played by the interpreter and the
# game as C, JavaScript and Ruby, and are not in test/all/ (PackAtStartTests says more).
module PackColorListAtStartTests
  include PackColorListGames
  include WrittenOutSearch

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  private def assert_plays_alike(whole, left_out, file, frames:)
    frames.each do |count|
      shown = game_player.run(whole, frames: count).screen.to_a
      assert_equal shown, game_player.hand_file(file).run(left_out, frames: count).screen.to_a,
                   "after #{count} frames the game handed its pack shows what the all-in-one build shows"
    end
  end

  # A sprite recoloured through three banks, and a backdrop that shows the first colour of a
  # bank's list: place 0 keeps the slot's own colour.
  def test_a_sprite_recolored_through_banks_read_at_start_shows_as_the_all_in_one_build
    Dir.mktmpdir do |folder|
      from = layout_original(folder, GENESIS)
      whole, file = recoloring_game_and_file(banks_from_pack(from))
      left_out, = recoloring_game_and_file(banks_from_pack(from), options: LEFT_OUT)
      passed = game_player.hand_file(file).run(left_out, frames: 2 + framework_drawing_lag).screen

      assert_equal BANKS.fetch(2).drop(1).map { |color| shown(color) },
                   STRIPES.map { |column| passed.pixel(SHIP_AT.first + 2 + column, SHIP_AT.last + 1) }, "pass 2 shows bank 2"
      assert_equal shown(BANKS.fetch(3).first), passed.pixel(*BACKDROP_AT), "the backdrop is the first color of bank 3"
      assert_plays_alike(whole, left_out, file, frames: 1..6)
    end
  end

  def test_a_sprite_drawn_with_a_whole_slot_read_at_start_shows_as_the_all_in_one_build
    Dir.mktmpdir do |folder|
      from = layout_original(folder, GENESIS)
      whole, file = whole_slot_game_and_file(from)
      left_out, = whole_slot_game_and_file(from, options: LEFT_OUT)

      assert_plays_alike(whole, left_out, file, frames: [1, 3])
    end
  end

  # A GAME THAT WALKS A LIST FROM THE PACK UP FROM WHITE: a ship drawn in a list of the game's own
  # and with a list that holds each step of the walk in turn, a pass a step. The steps are made
  # from the list's colours, which a build that leaves its pack out learns as the game starts.
  WALK_STEPS = 6

  private def walking_game_and_file(from, options: VBlank::Cartridge::Options.new)
    test = self
    builder = Builder.new(options: options)
    builder.instance_eval do
      screen :tiled
      pack = test.palette_pack_of(self, from)
      colors :shown, [:transparent, :red, :green, :blue]
      colors :bank_2, pack[:palette].bank(2, size: BANK_SIZE)
      image :ship, width: 8, height: 8, colors: :shown, places: SHIP
      ship = sprite :ship, at: SHIP_AT
      ship.draw_with :shown
      walk = color_walk(:bank_2, from: :white, steps: WALK_STEPS)
      step = var :step, 0
      game_loop do
        recolor :shown, walk, showing: step
        step.store!(step + 1)
      end
    end
    builder.finalize_program
    [builder.program, builder.made_data_pack_file]
  end

  def test_a_walk_of_a_list_read_at_start_shows_each_step_as_the_all_in_one_build
    Dir.mktmpdir do |folder|
      from = layout_original(folder, GENESIS)
      whole, file = walking_game_and_file(from)
      left_out, = walking_game_and_file(from, options: LEFT_OUT)
      last = game_player.hand_file(file).run(left_out, frames: WALK_STEPS + 1 + framework_drawing_lag).screen

      assert_equal BANKS.fetch(2).drop(1).map { |color| shown(color) },
                   STRIPES.map { |column| last.pixel(SHIP_AT.first + column, SHIP_AT.last + 1) }, "the walk's last step is the list's own colors"
      assert_plays_alike(whole, left_out, file, frames: 1..(WALK_STEPS + 2))
    end
  end

  # A picture drawn in a list from the pack and blitted, where no sprite or `recolor` is.
  private def blitting_game_and_file(from, options: VBlank::Cartridge::Options.new)
    test = self
    builder = Builder.new(options: options)
    builder.instance_eval do
      screen :bitmap
      pack = test.palette_pack_of(self, from)
      colors :bank_1, pack[:palette].bank(1, size: BANK_SIZE)
      image :ship, width: 8, height: 8, colors: :bank_1, places: SHIP
      game_loop do
        clear_screen :black
        blit :ship, 20, 20
        blit mirror(:ship), 40, 20
        wait_vblank
      end
    end
    builder.finalize_program
    [builder.program, builder.made_data_pack_file]
  end

  def test_a_picture_drawn_in_a_list_read_at_start_is_blitted_as_the_all_in_one_build
    Dir.mktmpdir do |folder|
      from = layout_original(folder, GENESIS)
      whole, file = blitting_game_and_file(from)
      left_out, = blitting_game_and_file(from, options: LEFT_OUT)
      screen = game_player.hand_file(file).run(left_out, frames: 2).screen

      assert_equal BANKS.fetch(1).drop(1).map { |color| shown(color) }, STRIPES.map { |column| screen.pixel(20 + column, 21) }
      assert_plays_alike(whole, left_out, file, frames: [2])
    end
  end

  # A picture given as colours holds no places, so no place of a list read at start can be found
  # for its pixels: refused as the game is built, saying how to give the places.
  def test_a_picture_of_colors_drawn_in_a_list_read_at_start_is_refused
    Dir.mktmpdir do |folder|
      builder = Builder.new(options: LEFT_OUT)
      pack = palette_pack(builder, layout_original(folder, GENESIS))
      builder.colors :bank_1, pack[:palette].bank(1, size: BANK_SIZE)
      error = assert_raises(ArgumentError) do
        builder.image :ship, width: 2, height: 1, colors: :bank_1, data: %i[red green]
      end

      assert_includes error.message, "image :ship"
      assert_includes error.message, "places:"
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
