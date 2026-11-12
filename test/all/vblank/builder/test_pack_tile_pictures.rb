# frozen_string_literal: true

require "test_helper"
require "pack_background_tests"

# The games these tests play, shared with the registry of games that read a data pack
# (test/pack_games.rb), which plays them with the pack left out too.
module PackTilePictureGames
  include PackBackgroundGames

  # The pictures the slot :belt holds, one tile each.
  BELT = [PLACES[3], PLACES[1], PLACES[2]].freeze
  # Cell 0 a still tile; the others name tile 2, which takes turns through BELT, plain, mirrored,
  # and upside down in bank 1.
  WORDS = [ADVANCE_CELL.(1), ADVANCE_CELL.(2), ADVANCE_CELL.(2, mirrored: true), ADVANCE_CELL.(2, bank: 1, upside_down: true)].freeze
  GENESIS_WORDS = [GENESIS_CELL.(1), GENESIS_CELL.(2), GENESIS_CELL.(2, mirrored: true),
                   GENESIS_CELL.(2, bank: 1, upside_down: true)].freeze
  BELT_AT = TILES_AT + (PLACES.length * 32)

  # A LAIR AFTER A TITLE, EACH SCENE IN COLOURS OF ITS OWN, as a Genesis game's scenes are: three lists
  # the game changes take three of a Genesis's four palettes for good, so each scene's backgrounds
  # have the fourth, and the two scenes' together need two. The lair's map draws from four banks,
  # two of its cells naming tile 2 (in bank 0, and bank 1 upside down), which takes turns through
  # the belt's pictures; its other cells are still tiles of banks 0, 2 and 3. The lair's tiles draw
  # fourteen colours of its banks, and its belt's pictures no colour the still tile they stand for
  # does not, so the lair fits its one palette with the belt as without it.
  LAIR_MAP_AT = 0x20
  TITLE_MAP_AT = 0x30
  LAIR_COLORS_AT = 0x40
  TITLE_COLORS_AT = 0xC0
  LAIR_BANKS = 4
  TITLE_BANKS = 2
  LAIR_WORDS = [GENESIS_CELL.(1), GENESIS_CELL.(2), GENESIS_CELL.(3, bank: 2), GENESIS_CELL.(2, bank: 1, upside_down: true),
                GENESIS_CELL.(1, bank: 3)].freeze
  TITLE_WORDS = [GENESIS_CELL.(1), GENESIS_CELL.(3, bank: 1)].freeze
  # The passes the title is up for, and the lair's pass that shows the belt's second picture.
  TITLE_PASSES = 3
  LAIR_BELT_TURNS = 4

  # The blue level of each scene's colours, which keeps the lair's and the title's apart.
  SCENE_BLUES = { lair: 1, title: 2 }.freeze

  # The levels of place +place+ of bank +bank+ of +scene+'s colours slot: each its own red and
  # green, the Genesis's three bits, and black at place 0.
  def self.scene_bank_levels(scene, bank, place)
    return [0, 0, 0] if place.zero?

    number = (bank * 16) + place
    [number % 8, (number / 8) % 8, SCENE_BLUES.fetch(scene)]
  end

  def self.widened(levels)
    widen = MadeUpOriginalLayouts::WIDEN
    red, green, blue = levels
    widen.(red) | (widen.(green) << 5) | (widen.(blue) << 10)
  end

  def self.scene_color(scene, bank, place) = widened(scene_bank_levels(scene, bank, place))

  # The three lists the game changes, each a sprite's, and the set each is told to hold on even passes.
  CHANGING_LISTS = { sky: [5, 6], sea: [6, 6], sun: [7, 6] }.freeze

  constants(false).each { |name| Ractor.make_shareable(const_get(name)) }

  # The made-up Genesis original of the lair and the title: their maps, their banks and the tiles.
  private def lair_original(folder)
    tiles = [*PLACES, *BELT].map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    copy[LAIR_MAP_AT, LAIR_WORDS.length * 2] = LAIR_WORDS.pack("n*")
    copy[TITLE_MAP_AT, TITLE_WORDS.length * 2] = TITLE_WORDS.pack("n*")
    { lair: [LAIR_COLORS_AT, LAIR_BANKS], title: [TITLE_COLORS_AT, TITLE_BANKS] }.each do |scene, (at, banks)|
      levels = (0...banks).flat_map { |bank| (0...16).map { |place| PackTilePictureGames.scene_bank_levels(scene, bank, place) } }
      copy[at, banks * 32] = GENESIS_COLORS.(levels)
    end
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :genesis,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The title, then the lair with its belt, which shows its second picture from the lair's
  # LAIR_BELT_TURNS-th pass on.
  private def lair_game_and_file(folder, options: VBlank::Cartridge::Options.new)
    from = lair_original(folder)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: PLACES.length
        slots.tiles :belt, at: BELT_AT, count: BELT.length
        slots.numbers :lair_map, at: LAIR_MAP_AT, count: LAIR_WORDS.length, width: :half, signed: false
        slots.numbers :title_map, at: TITLE_MAP_AT, count: TITLE_WORDS.length, width: :half, signed: false
        slots.colors :lair_colors, at: LAIR_COLORS_AT, count: LAIR_BANKS * 16
        slots.colors :title_colors, at: TITLE_COLORS_AT, count: TITLE_BANKS * 16
      end
      CHANGING_LISTS.each_with_index do |(list, (red, blue)), at|
        colors list, [:black, PackTilePictureGames.widened([red, 1, blue]), PackTilePictureGames.widened([red, 3, blue])]
        colors :"#{list}_dusk", [:black, PackTilePictureGames.widened([red, 5, blue]), PackTilePictureGames.widened([red, 7, blue])]
        image list, width: 8, height: 8, data: Array.new(64) { |i| PackTilePictureGames.widened([red, (i % 8) < 4 ? 1 : 3, blue]) },
                    colors: list
        sprite(list, at: [100 + (at * 16), 40]).draw_with list
      end
      state = var :state, 0
      pass = var :pass, 0
      tick = var :tick, 0
      # Before both scenes: the title draws from the slot :video too, and is declared first.
      conveyor = tile_pictures :conveyor, tiles: { pack[:video].tile(2) => pack[:belt].tiles(0, across: BELT.length) }
      scene(:title) do
        background :sign, tiles: pack[:video], map: pack[:title_map], colors: pack[:title_colors], across: TITLE_WORDS.length
      end
      scene(:lair) do
        background :machine, tiles: pack[:video], map: pack[:lair_map], colors: pack[:lair_colors], across: LAIR_WORDS.length
        tick += 1
        conveyor.show 1 if tick == LAIR_BELT_TURNS
      end
      game_loop do
        pass += 1
        CHANGING_LISTS.each_key { |list| recolor list, [:"#{list}_dusk"], showing: pass % 2 }
        state = 1 if pass == TITLE_PASSES
        case_var(:state) do
          when_val 0, :title
          when_val 1, :lair
        end
      end
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  # A game of the made-up original for +platform+ whose map is +words+, its tile 2 taking turns
  # through the slot :belt. +step+ is run every pass, handed the group and a count of passes. With
  # +in_scene+ the background is declared in the scene that shows it, the group outside it. With
  # +second_key+ tile 3 takes turns too, through the same pictures one further on.
  private def belt_game_and_file(folder, platform: :gba, words: WORDS, options: VBlank::Cartridge::Options.new, in_scene: false,
                                 second_key: false, &step)
    layout = platform == :genesis ? MadeUpOriginalLayouts::HIGH_HALF_FIRST : LOW_HALF_FIRST
    from = original(folder, platform, [*PLACES, *BELT].map(&layout).join, words)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: PLACES.length
        slots.tiles :belt, at: BELT_AT, count: BELT.length
        slots.numbers :map, at: MAP_AT, count: words.length, width: :half, signed: false
        slots.colors :palette, at: COLORS_AT, count: 32
      end
      keys = { pack[:video].tile(2) => pack[:belt].tiles(0, across: BELT.length) }
      keys[pack[:video].tile(3)] = Array.new(BELT.length) { |at| pack[:belt].tile((at + 1) % BELT.length) } if second_key
      belt = tile_pictures :belt, tiles: keys
      tick = var :tick, 0
      show = lambda do
        screen :tiled
        background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: words.length
      end
      if in_scene
        var :where, 0
        scene :play do
          instance_exec(&show)
          tick += 1
          instance_exec(belt, tick, &step)
        end
        game_loop { case_var(:where) { when_val 0, :play } }
      else
        instance_exec(&show)
        game_loop do
          tick += 1
          instance_exec(belt, tick, &step)
        end
      end
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end
end

# A TILE OF A BACKGROUND FROM THE DATA PACK TAKING TURNS THROUGH PICTURES OF ANOTHER SLOT
# (Builder::PackTilePictures), as a retail game rewrites a tile of its video memory while the map
# stays still: the conveyor of a machine, water at the edge of a lake. The answer key is the made-up
# data itself: every cell naming the tile shows the picture shown, in the cell's own bank and turn.
class TestPackTilePictures < Minitest::Test
  include PackTilePictureGames

  private def belt_game(...) = Dir.mktmpdir { |folder| belt_game_and_file(folder, ...).first }

  # Whether every drawn pixel of the cell at column +cell+ is +places+ in +bank+, turned as asked.
  # +color_of+ is handed a bank and a place and answers the colour.
  private def assert_cell_shows(screen, cell, places, bank, mirrored: false, upside_down: false, why: nil,
                                color_of: ->(at_bank, place) { BANKS.fetch(at_bank).fetch(place) })
    8.times do |y|
      8.times do |x|
        place = places.fetch(((upside_down ? 7 - y : y) * 8) + (mirrored ? 7 - x : x))
        next if place.zero?

        assert_equal color_of.(bank, place), screen.pixel((cell * 8) + x, y), "#{why}: the pixel (#{x}, #{y}) of cell #{cell}"
      end
    end
  end

  # Cell 0 shows its still tile, and cells 1 to 3 picture +picture+ of the belt, each its own way.
  private def assert_belt_shows(screen, picture, why)
    assert_cell_shows(screen, 0, PLACES[1], 0, why: why)
    assert_cell_shows(screen, 1, BELT[picture], 0, why: why)
    assert_cell_shows(screen, 2, BELT[picture], 0, mirrored: true, why: why)
    assert_cell_shows(screen, 3, BELT[picture], 1, upside_down: true, why: why)
  end

  private def screen_after(program, frames) = game_player.run(program, frames: frames).screen

  def test_the_tile_shows_the_first_picture_from_the_start
    assert_belt_shows(screen_after(belt_game { |_, _| nil }, 2), 0, "from the start")
  end

  def test_one_word_changes_every_cell_of_the_tile_on_the_next_frame
    program = belt_game { |belt, tick| belt.show 1 if tick == 3 }

    assert_belt_shows(screen_after(program, 2), 0, "before")
    assert_belt_shows(screen_after(program, 6), 1, "after")
  end

  def test_the_number_can_be_worked_out_as_the_game_runs
    program = belt_game { |belt, tick| belt.show((tick / 2) % 3) }

    # After an odd number of frames the pass shown and the one before it named the same picture.
    [3, 5, 7, 9].each { |frames| assert_belt_shows(screen_after(program, frames), (frames / 2) % 3, "after #{frames} frames") }
  end

  def test_a_number_naming_no_picture_changes_nothing
    program = belt_game do |belt, tick|
      belt.show 2 if tick == 2
      belt.show 3 if tick == 4
      belt.show(-1) if tick == 5
    end

    assert_belt_shows(screen_after(program, 8), 2, "after 3 and -1")
  end

  # A Genesis original keeps its tiles the left pixel in the high half of a byte, and its cells
  # in its own layout.
  def test_a_genesis_originals_tile_takes_turns_through_its_pictures
    program = belt_game(platform: :genesis, words: GENESIS_WORDS) { |belt, tick| belt.show 2 if tick == 3 }

    assert_belt_shows(screen_after(program, 2), 0, "before")
    assert_belt_shows(screen_after(program, 6), 2, "after")
  end

  # Two tiles of one group, each through its own pictures, turned by one word.
  def test_two_tiles_of_a_group_take_turns_together
    words = [ADVANCE_CELL.(3), *WORDS.drop(1), ADVANCE_CELL.(3, bank: 1, mirrored: true)]
    program = belt_game(words: words, second_key: true) { |belt, tick| belt.show 1 if tick == 3 }

    [[2, 0], [6, 1]].each do |frames, picture|
      screen = screen_after(program, frames)
      other = BELT[(picture + 1) % BELT.length]
      assert_cell_shows(screen, 0, other, 0, why: "after #{frames} frames")
      assert_cell_shows(screen, 1, BELT[picture], 0, why: "after #{frames} frames")
      assert_cell_shows(screen, 4, other, 1, mirrored: true, why: "after #{frames} frames")
    end
  end

  def test_a_tile_two_groups_name_is_refused
    error = refusal do |pack|
      tile_pictures :belt, tiles: { pack[:video].tile(2) => pack[:belt].tiles(0, across: 3) }
      tile_pictures :lake, tiles: { pack[:video].tile(2) => pack[:belt].tiles(0, across: 3) }
    end

    assert_match(/one group/, error.message)
  end

  def test_a_background_declared_in_a_scene_shows_the_picture_shown
    program = belt_game(in_scene: true) { |belt, tick| belt.show 1 if tick == 6 }

    assert_belt_shows(screen_after(program, 5), 0, "before")
    assert_belt_shows(screen_after(program, 10), 1, "after")
  end

  # The belt takes turns in the lair, a scene of its own colours after the title's, its still cells
  # beside it showing their own banks: the belt's runs are drawn in the colours the lair already
  # has, and take none of the palettes the title and the lists keep.
  def test_a_belt_in_a_scene_of_its_own_colours_takes_turns
    program = Dir.mktmpdir { |folder| lair_game_and_file(folder).first }
    lair = ->(bank, place) { PackTilePictureGames.scene_color(:lair, bank, place) }
    title = ->(bank, place) { PackTilePictureGames.scene_color(:title, bank, place) }

    screen = screen_after(program, TITLE_PASSES - 1)
    assert_cell_shows(screen, 0, PLACES[1], 0, why: "the title", color_of: title)
    assert_cell_shows(screen, 1, PLACES[3], 1, why: "the title", color_of: title)
    [[TITLE_PASSES + LAIR_BELT_TURNS - 2, 0], [TITLE_PASSES + LAIR_BELT_TURNS + 3, 1]].each do |frames, picture|
      screen = screen_after(program, frames)
      why = "after #{frames} frames"
      assert_cell_shows(screen, 0, PLACES[1], 0, why: why, color_of: lair)
      assert_cell_shows(screen, 1, BELT[picture], 0, why: why, color_of: lair)
      assert_cell_shows(screen, 2, PLACES[3], 2, why: why, color_of: lair)
      assert_cell_shows(screen, 3, BELT[picture], 1, upside_down: true, why: why, color_of: lair)
      assert_cell_shows(screen, 4, PLACES[1], 3, why: why, color_of: lair)
    end
  end

  private def refusal(&declares)
    Dir.mktmpdir do |folder|
      from = original(folder, :gba, [*PLACES, *BELT].map(&LOW_HALF_FIRST).join, WORDS)
      assert_raises(ArgumentError) do
        b = VBlank::Builder.new
        b.instance_eval do
          screen :tiled
          pack = data_pack from: from, version: "1" do |slots|
            slots.tiles :video, at: TILES_AT, count: PLACES.length
            slots.tiles :belt, at: BELT_AT, count: BELT.length
            slots.numbers :map, at: MAP_AT, count: WORDS.length, width: :half, signed: false
            slots.colors :palette, at: COLORS_AT, count: 32
          end
          instance_exec(pack, &declares)
        end
        b.finalize_program
      end
    end
  end

  def test_a_group_declared_after_a_background_that_draws_its_tiles_is_refused
    error = refusal do |pack|
      background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 4
      tile_pictures :belt, tiles: { pack[:video].tile(2) => pack[:belt].tiles(0, across: 3) }
    end

    assert_match(/before/, error.message)
  end

  def test_colors_given_with_tiles_from_the_pack_are_refused
    error = refusal do |pack|
      colors :pond, %i[transparent red]
      tile_pictures :belt, colors: :pond, tiles: { pack[:video].tile(2) => pack[:belt].tiles(0, across: 3) }
    end

    assert_match(/bank/, error.message)
  end

  def test_tiles_from_the_pack_with_different_numbers_of_pictures_are_refused
    error = refusal do |pack|
      tile_pictures :belt, tiles: { pack[:video].tile(2) => pack[:belt].tiles(0, across: 3),
                                    pack[:video].tile(3) => pack[:belt].tiles(0, across: 2) }
    end

    assert_match(/different numbers of pictures/, error.message)
  end

  def test_a_key_of_several_tiles_is_refused
    error = refusal do |pack|
      tile_pictures :belt, tiles: { pack[:video].tiles(2, across: 2) => pack[:belt].tiles(0, across: 3) }
    end

    assert_match(/one tile/, error.message)
  end
end
