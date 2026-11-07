# frozen_string_literal: true

require "digest"
require "tmpdir"
require "made_up_original"
require "made_up_original_layouts"

# SEARCHING WRITTEN-OUT CODE FOR THE ORIGINAL'S BYTES. A program written as C, JavaScript or Ruby
# holds an array as its numbers, in order, or (JavaScript's and Ruby's past a few hundred entries)
# as base64 text of its bytes packed as the array's kind keeps them. So the search reads both:
# every whole number in the text, in order, and every run of base64 decoded and unpacked each way
# an array can be packed. A needle is a run of numbers the original's bytes become in a program: a
# table's entries, or a tile's pixels in the colours its places pick.
module WrittenOutSearch
  PACKINGS = %w[C* c* v* s<* V* l<*].freeze

  # The tables of numbers +text+ holds, by the way they are written there (:numbers, :base64).
  private def number_runs_in(text)
    blobs = text.scan(%r{[A-Za-z0-9+/=\n]{64,}}).map { |blob| blob.delete("\n").unpack1("m") }
    { numbers: [text.scan(/-?\d+/).map(&:to_i)], base64: blobs.flat_map { |bytes| PACKINGS.map { |packing| bytes.unpack(packing) } } }
  end

  # The ways +runs+ (#number_runs_in) hold +needle+, a run of numbers, one after another.
  private def ways_holding(runs, needle)
    key = ",#{needle.join(',')},"
    runs.select { |_, lists| lists.any? { |list| ",#{list.join(',')},".include?(key) } }.keys
  end

  # Each of +programs+ ([name, all-in-one, left out, needles]) as the block writes it out holds
  # every needle when built all-in-one, and none when built with its pack left out. Hands back the
  # ways the all-in-one builds held them, one for each needle.
  private def ways_holding_needles(programs)
    programs.flat_map do |what, whole, left_out, needles|
      whole_runs = number_runs_in(yield(whole))
      left_runs = number_runs_in(yield(left_out))
      needles.flat_map do |needle|
        held = ways_holding(whole_runs, needle)
        refute_empty held, "#{what} built all-in-one holds the original's bytes #{needle.first(8)}..."
        assert_empty ways_holding(left_runs, needle), "#{what} built with its pack left out holds #{needle.first(8)}..."
        held
      end
    end
  end
end

# AN ORIGINAL FROM ANOTHER CONSOLE, ITS PACK LEFT OUT (MadeUpOriginalLayouts, made_up_original_layouts.rb):
# each console's layout read by the runtime from the pack it is handed as it starts, played as the
# all-in-one build plays, and written out with none of the made-up original's bytes in it.
module PackAtStartLayoutTests
  include MadeUpOriginalLayouts
  include WrittenOutSearch

  # Each layout's game built all-in-one, its pack file, and the game built with its pack left out
  # on a machine with no copy.
  private def layout_games(folder, layout)
    whole, file = layout_game(through_layout_pack(layout_original(folder, layout), layout))
    left_out, = layout_game(through_layout_pack(layout_original_nowhere(folder, layout), layout),
                            options: PackAtStartPictures::PACK_AT_START)
    [whole, file, left_out]
  end

  def test_each_consoles_layout_read_as_the_game_starts_plays_as_its_all_in_one_build
    LAYOUTS.each do |layout|
      Dir.mktmpdir do |folder|
        whole, file, left_out = layout_games(folder, layout)

        [1, 4, 9].each do |frames|
          assert_equal game_player.run(whole, frames: frames).screen.to_a,
                       game_player.hand_file(file).run(left_out, frames: frames).screen.to_a,
                       "#{layout.title} layout: after #{frames} frames the game handed its pack shows what the all-in-one build shows"
        end
      end
    end
  end

  # A tile of +layout+'s, its +places+, as a background keeps its pixels: each place's colour, and
  # 0xFFFF (see-through) at place 0.
  private def layout_tile_pixels(places) = places.map { |place| place.zero? ? 0xFFFF : PALETTE.fetch(place) }

  # Each layout's game as the block writes it out holds its tiles' pixels and its numbers built
  # all-in-one, and none of them built with its pack left out. A lowering's test file calls this.
  private def assert_layouts_written_without_the_originals_bytes(&write)
    Dir.mktmpdir do |folder|
      programs = LAYOUTS.map do |layout|
        whole, _, left_out = layout_games(folder, layout)
        ["#{layout.title} layout", whole, left_out, [*layout.tiles.map { |places| layout_tile_pixels(places) }, SPEEDS]]
      end
      ways_holding_needles(programs, &write)
      assert_layouts_written_without_the_originals_raw_bytes(folder, &write)
    end
  end

  # The program built with its pack left out holds none of the original's bytes as the original
  # keeps them (high byte first for a layout that does): each run of raw bytes, and the runs of
  # sixteen-bit numbers the same bytes make read in the layout's order. A build that held the pack
  # whole would hold these, where the decoded pixels and numbers above are what the game draws.
  private def assert_layouts_written_without_the_originals_raw_bytes(folder, &write)
    LAYOUTS.each do |layout|
      _, _, left_out = layout_games(folder, layout)
      runs = number_runs_in(write.(left_out))
      order = layout.high_byte_first ? "n*" : "v*"
      [layout.tile_bytes, layout.raw_color_bytes, layout.raw_speed_bytes, layout.offset_bytes, layout.word_bytes].each do |raw|
        [raw.bytes, raw.unpack(order)].each do |needle|
          assert_empty ways_holding(runs, needle), "#{layout.title} layout built with its pack left out holds raw bytes #{needle.first(8)}..."
        end
      end
    end
  end
end

# THE HELPERS FOR GAMES THAT DRAW PICTURES FROM THE PACK, kept once for PackAtStartTests and for
# PackAtStartPlaceTests.
module PackAtStartPictures
  include MadeUpOriginal

  # The build each of these games is made by: one for a computer, its data pack left out.
  PACK_AT_START = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # PICTURES DRAWN FROM THE PACK. The made-up original's sprite picture is four tiles of places
  # (SPRITE_PLACES), and each game below draws it, or a tile of it, one way each: as a sprite, a blit, a
  # place's face, in other colours, turned, or with only one of its two lists in the pack. Each is built
  # all-in-one and with the pack left out, handed a pack of these two slots.
  PICTURE_SLOTS = [VBlank::Original::Slot.colors(:palette, at: PALETTE_AT, count: 16),
                   VBlank::Original::Slot.tiles(:sprites, at: SPRITES_AT, count: 4)].freeze
  Ractor.make_shareable(PICTURE_SLOTS)

  # The sizes of the pictures of the games below: the whole 16x16 one, and the first tile of it.
  HERO = Ractor.make_shareable({ width: 16, height: 16 })
  MARK = Ractor.make_shareable({ width: 8, height: 8 })

  private def picture_pack_file
    VBlank::Original::Pack.holding(PICTURE_SLOTS.to_h { |slot| [slot.name, slot.cut_from(COPY)] }, sha1: SHA1, build_version: "1").to_bytes
  end

  # A game of the made-up original's two slots whose block (run on the builder, handed the pack) draws.
  private def picture_game(folder, options: VBlank::Cartridge::Options.new, tear_free: false, screen_kind: :bitmap, &draws)
    from = original(folder)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen screen_kind, **(tear_free ? { tear_free: true } : {})
      clear_screen :black if screen_kind == :bitmap
      pack = data_pack(from: from, version: "1") do |slots|
        slots.colors :palette, at: PALETTE_AT, count: 16
        slots.tiles :sprites, at: SPRITES_AT, count: 4
      end
      instance_exec(pack, &draws)
    end
    b.finalize_program
    b.program
  end

  # The game drawn both ways plays alike: the all-in-one build on the interpreter, and the build with
  # its pack left out handed the pack file, on this run's player.
  private def assert_pictures_play_alike(what, tear_free: false, screen_kind: :bitmap, &draws)
    Dir.mktmpdir do |folder|
      whole = picture_game(folder, tear_free: tear_free, screen_kind: screen_kind, &draws)
      left_out = picture_game(folder, options: PACK_AT_START, tear_free: tear_free, screen_kind: screen_kind, &draws)

      [1, 3].each do |frames|
        shown = game_player.run(whole, frames: frames).screen.to_a
        assert_operator shown.flatten.uniq.length, :>, 2, "#{what}: the all-in-one build draws the picture"
        assert_equal shown, game_player.hand_file(picture_pack_file).run(left_out, frames: frames).screen.to_a,
                     "#{what}: after #{frames} frames the game handed its pack shows what the all-in-one build shows"
      end
    end
  end
end

# A PLACE'S FACE DRAWN FROM THE PACK. Only a console that draws places plays it (the Advance), so it
# sits in test/console/gba/ and not with PackAtStartTests.
module PackAtStartPlaceTests
  include PackAtStartPictures

  def test_a_face_of_a_place_drawn_from_the_pack_is_drawn_as_the_all_in_one_build_draws_it
    assert_pictures_play_alike("a face", tear_free: true) do |pack|
      image :mark, **MARK, colors: pack[:palette], places: pack[:sprites].tile(0)
      place :room do
        face point(-1.0, 1.0, 2.0), point(1.0, 1.0, 2.0), point(1.0, -1.0, 2.0), point(-1.0, -1.0, 2.0),
             picture: :mark, on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]]
      end
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop do
        wait_vblank
        draw_place :room, seen_by: eye
      end
    end
  end
end

# A GAME BUILT WITH ITS DATA PACK LEFT OUT, handed the pack file as it starts. The made-up original
# and its game are made_up_original.rb's (MadeUpOriginal): built all-in-one there, the pack is made
# from the copy as the game is built and the game holds what it read. Built here with
# `pack_at_start: true`, the build reads no copy at all, the program holds none of the original's
# bytes, and the pack is a file handed to the program as it starts (hand_file).
#
# The answer key is the same game built all-in-one, played on the interpreter, and the interpreter
# reading the same pack file (Reference#hand_file).
#
# Only a build for a computer can leave the pack out: a cartridge holds its own data, and nothing
# hands a cartridge a file. So these tests are not in test/all/, which every cartridge run plays,
# and not in test/console/ (but for a place's face, which only the Advance draws). They are played through game_player by each run whose player reads a
# file as it starts: the interpreter (test/interpreter/vblank/builder/test_pack_at_start_interpreter.rb)
# and the game as C, as JavaScript and as Ruby, checked against it on every frame
# (test/lowering/{native,js,ruby}/vblank/ir/backends/*/test_*_pack_at_start.rb). That a cartridge
# build refuses is test_data_packs.rb's.
module PackAtStartTests
  include PackAtStartPictures

  # The pack file a player's machine makes from the made-up copy: each slot cut from it, as the
  # all-in-one build cuts them.
  # +build_version+ is the build it names.
  private def made_up_pack_file(build_version: "1")
    slots = [VBlank::Original::Slot.colors(:palette, at: PALETTE_AT, count: 16),
             VBlank::Original::Slot.tiles(:walls, at: TILES_AT, count: 2),
             VBlank::Original::Slot.numbers(:speeds, at: SPEEDS_AT, count: 8, width: :byte, signed: false)]
    VBlank::Original::Pack.holding(slots.to_h { |slot| [slot.name, slot.cut_from(COPY)] }, sha1: SHA1,
                                                                                         build_version: build_version).to_bytes
  end

  # The made-up original's one release, as the unpacking of a build with no copy is handed it.
  private def made_up_release = VBlank::Original::Release.from("Test", { "sha1" => SHA1, "size" => COPY_SIZE })

  # The made-up original on a machine where no copy of it is set.
  private def original_nowhere(folder)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: {}, settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => SHA1, "size" => COPY_SIZE } })
  end

  # A game as `vblank build` builds one, reading the made-up original's tiles and table through its
  # data pack, on a machine with no copy: only a build that leaves its pack out can make it.
  private def game_reading_pack_with_no_copy(folder)
    from = original_nowhere(folder)
    VBlank.game("MADE UP", consoles: %i[gba]) do
      screen :bitmap
      pack = data_pack(from: from, version: "1") do |slots|
        slots.colors :palette, at: PALETTE_AT, count: 16
        slots.tiles :walls, at: TILES_AT, count: 2
      end
      image :wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
      tiles :walls, 0 => :wall
      background :room, tiles: :walls, map: [[0, 0]]
      game_loop { wait_vblank }
    end
  end

  # The game built with its pack left out, and the same game built all-in-one.
  private def pack_at_start_game(folder) = game_program(through_pack(folder), options: PACK_AT_START)
  private def all_in_one_game(folder) = game_program(through_pack(folder))

  include WrittenOutSearch

  # A tile of the made-up original, the +bytes+ of its places, as a background keeps its pixels:
  # each place's colour, and 0xFFFF (see-through) at place 0.
  private def tile_pixels_of(bytes)
    VBlank::IR::Assets.places_packed_in(bytes).map { |place| place.zero? ? 0xFFFF : PALETTE.fetch(place) & 0x7FFF }
  end

  # A bigger game than #game_program, so JavaScript and Ruby write its arrays as base64: eight
  # tiles from the pack, and a table of 300 bytes of the copy.
  BIG_TILES = 8
  FILLER_BYTES = 300

  private def big_game_program(folder, options:)
    from = original(folder)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      pack = data_pack(from: from, version: "1") do |slots|
        slots.colors :palette, at: PALETTE_AT, count: 16
        slots.tiles :walls, at: TILES_AT, count: BIG_TILES
        slots.numbers :filler, at: 0, count: FILLER_BYTES, width: :byte, signed: false
      end
      names = (0...BIG_TILES).map { |at| :"wall_#{at}" }
      names.each_with_index { |name, at| image name, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(at) }
      tiles :walls, names.each_with_index.to_h { |name, at| [at, name] }
      background :room, tiles: :walls, map: [(0...BIG_TILES).to_a]
      filler = table :filler, pack[:filler]
      step = var :step, 0
      game_loop do
        wait_vblank
        draw_rect_at filler[step] & 127, 40, 4, 4, :white
        step = (step + 1) & 255
      end
    end
    b.finalize_program
    b.program
  end

  # Each program the search is made in, built both ways from the made-up original, with the runs of
  # numbers its bytes become there: [name, all-in-one, left out, needles].
  private def programs_searched(folder)
    tile = ->(at) { tile_pixels_of(COPY.byteslice(TILES_AT + (at * 32), 32)) }
    heights = ->(builder) { unpacked_pack(builder, folder) }
    reads_heights = lambda do |builder|
      made = heights.call(builder)
      [made[:palette], made[:walls].tile(0), made[:walls].tile(1), builder.table(:speeds, made[:heights])]
    end
    drawn = ->(place) { place.zero? ? -1 : PALETTE.fetch(place) & 0x7FFF }
    hero = SPRITE_PLACES.map(&drawn)
    mirrored = hero.each_slice(16).flat_map(&:reverse)
    draws_hero = lambda do |options|
      picture_game(folder, options: options) do |pack|
        image :hero, **HERO, colors: pack[:palette], places: pack[:sprites].tiles(0, across: 2, down: 2)
        game_loop do
          wait_vblank
          blit :hero, 10, 10
          blit mirror(:hero), 40, 10
        end
      end
    end
    [["the game", all_in_one_game(folder), pack_at_start_game(folder), [tile.call(0), tile.call(1), SPEEDS]],
     ["the game of pictures", draws_hero.call(VBlank::Cartridge::Options.new), draws_hero.call(PACK_AT_START), [hero, mirrored]],
     ["the bigger game", big_game_program(folder, options: VBlank::Cartridge::Options.new),
      big_game_program(folder, options: PACK_AT_START), [*(0...BIG_TILES).map(&tile), COPY.bytes.first(FILLER_BYTES)]],
     ["the game of unpacked slots", game_program(reads_heights), game_program(reads_heights, options: PACK_AT_START),
      [tile.call(0), tile.call(1), HEIGHTS]],
     ["the unpacking", heights.call(VBlank::Builder.new).unpacking.program,
      heights.call(VBlank::Builder.new(options: PACK_AT_START)).unpacking(release: made_up_release).program,
      COPY.bytes.each_slice(64).to_a]]
  end

  # Each program as the block writes it out (as C, JavaScript or Ruby) holds every needle when
  # built all-in-one, so the search can find them, and none when built with its pack left out.
  # +ways+ are the ways the lowering writes an array (:numbers, :base64), each of which the
  # all-in-one builds are seen to hold the original's bytes in. A lowering's test file calls this.
  private def assert_written_without_the_originals_bytes(ways:, &write)
    Dir.mktmpdir do |folder|
      found = ways_holding_needles(programs_searched(folder), &write)
      assert_equal ways.sort, found.uniq.sort, "the all-in-one builds hold the original's bytes in every way an array is written"
    end
  end

  def test_a_sprite_from_the_pack_is_drawn_as_the_all_in_one_build_draws_it
    assert_pictures_play_alike("a sprite") do |pack|
      image :hero, **HERO, colors: pack[:palette], places: pack[:sprites].tiles(0, across: 2, down: 2)
      sprite :hero, at: [30, 20]
      game_loop { wait_vblank }
    end
  end

  def test_a_picture_blitted_from_the_pack_is_drawn_as_the_all_in_one_build_draws_it
    assert_pictures_play_alike("a blit") do |pack|
      image :hero, **HERO, colors: pack[:palette], places: pack[:sprites].tiles(0, across: 2, down: 2)
      image :mark, **MARK, colors: pack[:palette], places: pack[:sprites].tile(0)
      game_loop do
        wait_vblank
        blit :hero, 100, 60
        blit :mark, 10, 10
      end
    end
  end

  def test_a_picture_from_the_pack_turned_is_drawn_as_the_all_in_one_build_draws_it
    assert_pictures_play_alike("a turned picture") do |pack|
      image :hero, **HERO, colors: pack[:palette], places: pack[:sprites].tiles(0, across: 2, down: 2)
      game_loop do
        wait_vblank
        blit mirror(:hero), 20, 20
        blit upside_down(:hero), 60, 20
        blit upside_down(mirror(:hero)), 100, 20
      end
    end
  end

  def test_a_picture_from_the_pack_drawn_in_other_colors_is_drawn_as_the_all_in_one_build_draws_it
    assert_pictures_play_alike("a recoloured sprite", screen_kind: :tiled) do |pack|
      image :hero, **HERO, colors: pack[:palette], places: pack[:sprites].tiles(0, across: 2, down: 2)
      colors :warm, [:transparent, *Array.new(15) { |at| rgb(31 - at, at * 2, at / 2) }]
      hero = sprite :hero, at: [30, 20]
      hero.draw_with :warm
      game_loop { wait_vblank }
    end
  end

  def test_a_picture_taking_only_its_colors_from_the_pack_is_drawn_as_the_all_in_one_build_draws_it
    assert_pictures_play_alike("colors from the pack") do |pack|
      image :held, width: 8, height: 8, colors: pack[:palette], places: TILE_PLACES[1]
      game_loop do
        wait_vblank
        blit :held, 30, 30
        blit mirror(:held), 50, 30
      end
    end
  end

  def test_a_picture_taking_a_bank_of_colors_from_the_pack_is_drawn_as_the_all_in_one_build_draws_it
    assert_pictures_play_alike("a bank of colors from the pack") do |pack|
      image :banked, width: 8, height: 8, colors: pack[:palette].bank(0, size: 8), places: TILE_PLACES[1]
      image :second_bank, width: 8, height: 8, colors: pack[:palette].bank(1, size: 8), places: TILE_PLACES[0]
      game_loop do
        wait_vblank
        blit :banked, 30, 30
        blit :second_bank, 60, 30
      end
    end
  end

  def test_a_picture_taking_only_its_places_from_the_pack_is_drawn_as_the_all_in_one_build_draws_it
    assert_pictures_play_alike("places from the pack") do |pack|
      own = [:transparent, :white, :red, :green, :blue, :yellow, :cyan, :magenta, :orange, :gray, rgb(5, 10, 15), rgb(30, 3, 9)]
      image :held, width: 16, height: 16, colors: own, places: pack[:sprites].tiles(0, across: 2, down: 2)
      sprite :held, at: [30, 20]
      game_loop { wait_vblank }
    end
  end

  def test_a_game_handed_its_pack_as_it_starts_plays_as_its_all_in_one_build
    Dir.mktmpdir do |folder|
      left_out = pack_at_start_game(folder)
      whole = all_in_one_game(folder)

      [1, 4, 9].each do |frames|
        assert_equal game_player.run(whole, frames: frames).screen.to_a,
                     game_player.hand_file(made_up_pack_file).run(left_out, frames: frames).screen.to_a,
                     "after #{frames} frames the game handed its pack shows what the all-in-one build shows"
      end
    end
  end

  # The build never reads the copy: a machine with none builds the game all the same.
  def test_a_game_that_leaves_its_pack_out_builds_with_no_copy_present
    Dir.mktmpdir do |folder|
      nowhere = original_nowhere(folder)
      program = game_program(lambda do |builder|
        pack = builder.data_pack(from: nowhere, version: "1") do |slots|
          slots.colors :palette, at: PALETTE_AT, count: 16
          slots.tiles :walls, at: TILES_AT, count: 2
          slots.numbers :speeds, at: SPEEDS_AT, count: 8, width: :byte, signed: false
        end
        [pack[:palette], pack[:walls].tile(0), pack[:walls].tile(1), builder.table(:speeds, pack[:speeds])]
      end, options: PACK_AT_START)

      assert_equal game_player.run(all_in_one_game(folder), frames: 4).screen.to_a,
                   game_player.hand_file(made_up_pack_file).run(program, frames: 4).screen.to_a
    end
  end

  def test_a_game_handed_no_pack_stops_saying_so
    Dir.mktmpdir do |folder|
      refused = assert_raises(VBlank::IR::ProgramError) { game_player.run(pack_at_start_game(folder), frames: 2) }

      assert_match "no data pack", refused.message
    end
  end

  # A pack of another size is another game's, or another build's.
  def test_a_pack_of_the_wrong_size_is_refused
    Dir.mktmpdir do |folder|
      refused = assert_raises(VBlank::IR::ProgramError) do
        game_player.hand_file("#{made_up_pack_file}more").run(pack_at_start_game(folder), frames: 2)
      end

      assert_match "data pack", refused.message
      assert_match made_up_pack_file.bytesize.to_s, refused.message
    end
  end

  # The pack says which build of the game it was made for (Original::Pack); a pack for another
  # build is the same size and is still not this build's.
  def test_a_pack_made_for_another_build_is_refused
    Dir.mktmpdir do |folder|
      other = made_up_pack_file(build_version: "2")
      refused = assert_raises(VBlank::IR::ProgramError) { game_player.hand_file(other).run(pack_at_start_game(folder), frames: 2) }

      assert_match "not the data pack", refused.message
    end
  end

  # THE UNPACKING, BUILT WITH NO COPY PRESENT. A shell makes its pack on the player's machine by
  # playing the game's unpacking program, handed the player's copy as it starts. Built with the pack
  # left out, that program holds none of the copy either: it is built for a copy of a known size
  # (the release's), and reads the copy from the file it is handed.
  private def unpacking_without_copy(folder)
    unpacked_pack(VBlank::Builder.new(options: PACK_AT_START), folder).unpacking(release: made_up_release)
  end

  def test_the_unpacking_built_with_no_copy_unpacks_the_copy_it_is_handed
    Dir.mktmpdir do |folder|
      unpacking = unpacking_without_copy(folder)
      played = game_player.hand_file(COPY).run(unpacking.program, frames: 8)

      assert_equal({ palette: PALETTE.pack("v*"), walls: TILE_BYTES, heights: HEIGHTS.pack("C*") }, unpacking.slot_bytes_in(played))
    end
  end

  def test_the_unpacking_refuses_a_copy_of_another_size
    Dir.mktmpdir do |folder|
      refused = assert_raises(VBlank::IR::ProgramError) do
        game_player.hand_file(COPY.byteslice(0, 100)).run(unpacking_without_copy(folder).program, frames: 8)
      end

      assert_match "copy of the original", refused.message
    end
  end

  # The whole way a player's machine goes: the unpacking handed the copy, its slots written as the
  # pack file, and the game handed that file, playing as the game built all-in-one does.
  def test_a_pack_unpacked_from_the_copy_plays_the_game_left_out_of_it
    Dir.mktmpdir do |folder|
      unpacking = unpacking_without_copy(folder)
      slots = unpacking.slot_bytes_in(game_player.hand_file(COPY).run(unpacking.program, frames: 8))
      pack = VBlank::Original::Pack.holding(slots, sha1: SHA1, build_version: "1").to_bytes
      reads_slots = lambda do |builder|
        made = unpacked_pack(builder, folder)
        [made[:palette], made[:walls].tile(0), made[:walls].tile(1), builder.table(:speeds, made[:heights])]
      end
      held = ->(builder) { [PALETTE, TILE_PLACES[0], TILE_PLACES[1], builder.table(:speeds, HEIGHTS, width: :byte, signed: false)] }

      assert_equal game_player.run(game_program(held), frames: 5).screen.to_a,
                   game_player.hand_file(pack).run(game_program(reads_slots, options: PACK_AT_START), frames: 5).screen.to_a
    end
  end
end
