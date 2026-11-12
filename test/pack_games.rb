# frozen_string_literal: true

require "digest"
require "tmpdir"
require "made_up_original"
require "made_up_original_layouts"
require "pack_at_start_tests"
require "pack_sound_tests"
require "pack_scores_at_start_tests"
require "pack_background_tests"
require "pack_slot_view_games"
require "all/vblank/builder/test_pack_backdrops"
require "all/vblank/builder/test_pack_color_lists"
require "all/vblank/builder/test_pack_poses"
require "all/vblank/builder/test_pack_poses_of_words"
require "pack_pose_of_shapes_games"
require "pack_pose_read_by_the_game_games"
require "all/vblank/builder/test_pack_pose_bank_colors"
require "all/vblank/dsl/test_pack_background_set_cell"
require "pack_place_games"

# EVERY SMALL GAME THAT READS A DATA PACK, REGISTERED ONCE. A game's data is read from its pack two
# ways: all-in-one, the pack read as the game is built, and with the pack left out
# (`pack_at_start: true`), the pack handed as a file as the game starts, which is what a shell
# build is. Each verb that takes a pack handle was taught the second way separately, so each needs
# a game here: PackParityTests (test/pack_parity_tests.rb) builds every one both ways on each run
# that hands a game a file, and holds the second build to the first, or to a refusal in plain words.
#
# TO REGISTER A GAME, add one `game` line to the kit whose made-up original it reads (or a kit of
# its own for a new original):
#
#   game(:sprite_of_pack_tiles, passes: 3) do |folder, options|
#     pictures(folder, options) { |pack| ... }
#   end
#
# The block is run on an instance of the kit, so the kit's helpers are its to call. It builds the
# game as +options+ say from a made-up original written into +folder+, and gives back `built(program,
# pack_file)`. It is called twice, with ALL_IN_ONE and with LEFT_OUT, and the pack file the game is
# handed is the first build's. `passes:` is how long to play it, and `presses:` the buttons held
# on each frame that has any (`{ 1 => [:a], 20 => [:b] }`).
#
# A GAME THAT NAMES FRAMES OF ITS ORIGINAL (`pack[:frames].frame(at, layout:)`) gives back
# `built_by(builder)`, which keeps its data pack: the parity check then plays the pack's unpacking
# from the copy and hands the build with its pack left out the file that writes, as a shell does,
# so the layout (a reader the game wrote among them) runs as game code on the copy's bytes.
#
# A VERB NOT MADE FOR A PACK LEFT OUT YET is registered too, marked `refused:` with a phrase of
# its refusal and which runs refuse it. Once the verb is made the game builds, the test fails
# saying so, and taking the mark off makes the test hold the two builds alike.
#
# A GAME THE TWO BUILDS SHOW DIFFERENTLY TODAY, a fault not yet mended, is marked `differs:` with
# what differs. The test then requires that they differ, so it fails when the fault is mended and
# the mark comes off. It is not a skip: the game is built and played both ways on every run.
#
# test/interpreter/vblank/builder/test_pack_parity_coverage.rb fails when a line of the builder
# that takes a pack handle, or asks whether the pack is left out, is reached by no game here.
module PackGames
  ALL_IN_ONE = VBlank::Cartridge::Options.new
  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # WHICH RUNS REFUSE A GAME BUILT WITH ITS PACK LEFT OUT. The builder refuses on every run. A
  # lowering refuses only where a build for a computer is made, so the interpreter plays the game,
  # and must play it as the all-in-one build.
  REFUSED_BY = %i[builder computer_build computer_build_mixing_at_recording_rates].freeze

  # A refusal: a phrase its words hold besides the fix, and who refuses (one of REFUSED_BY).
  # +names_fix+ is false for a refusal whose words do not say yet that building all-in-one works;
  # the test fails once they do, and the mark comes off.
  Refusal = Data.define(:phrase, :by, :names_fix) do
    def initialize(phrase:, by:, names_fix: true) = super
  end

  # One registered game. +kit+ is the class its block runs on an instance of.
  Game = Data.define(:name, :kit, :passes, :presses, :refused, :differs, :makes)

  # One build of a game: its program, the pack file the build made (nil with the pack left out),
  # and its data pack (DSL::DataPack), whose unpacking the parity check plays, where the game's
  # line gives it back (Kit#built_by). A game that names frames of its original must.
  Built = Data.define(:program, :pack_file, :data_pack) do
    def initialize(program:, pack_file:, data_pack: nil) = super
  end

  # What a kit is: the helpers of one made-up original, and the games that read it.
  class Kit
    include VBlank::Testing

    def self.game(name, passes:, presses: {}, refused: nil, differs: nil, &makes)
      Game.new(name: name, kit: self, passes: passes, presses: presses, refused: refused, differs: differs, makes: makes)
    end

    def self.refused_by_builder(phrase, names_fix: true) = Refusal.new(phrase: phrase, by: :builder, names_fix: names_fix)

    # +game+ built as +options+ say, from an original written into +folder+.
    # The block is the game's own, run here so that it calls this kit's helpers by name.
    def build(game, folder, options) = instance_exec(folder, options, &game.makes)

    private def built(program, pack_file = nil) = Built.new(program: program, pack_file: pack_file)

    # The build +builder+ made, its program made, with its data pack.
    private def built_by(builder)
      Built.new(program: builder.program, pack_file: builder.made_data_pack_file, data_pack: builder.declared_data_pack)
    end
  end

  # THE MADE-UP ADVANCE ORIGINAL'S PICTURES (MadeUpOriginal): its sprite picture of four tiles and
  # its colours, drawn each way a picture is, and its bytes as pixels and as letters.
  class Pictures < Kit
    include PackAtStartPictures

    OWN_COLORS = [:transparent, :white, :red, :green, :blue, :yellow, :cyan, :magenta, :orange, :gray, 0x3D45, 0x247E].freeze

    private def pictures(folder, options, **screen, &draws)
      built(picture_game(folder, options: options, **screen, &draws), picture_pack_file)
    end

    GAMES = [
      game(:sprite_of_pack_tiles, passes: 3) do |folder, options|
        pictures(folder, options) do |pack|
          image :hero, **HERO, colors: pack[:palette], places: pack[:sprites].tiles(0, across: 2, down: 2)
          sprite :hero, at: [30, 20]
          game_loop { wait_vblank }
        end
      end,
      game(:blits_of_pack_pictures, passes: 3) do |folder, options|
        pictures(folder, options) do |pack|
          image :hero, **HERO, colors: pack[:palette], places: pack[:sprites].tiles(0, across: 2, down: 2)
          image :mark, **MARK, colors: pack[:palette], places: pack[:sprites].tile(0)
          game_loop do
            wait_vblank
            blit :hero, 100, 60
            blit :mark, 10, 10
          end
        end
      end,
      game(:turned_blits_of_a_pack_picture, passes: 3) do |folder, options|
        pictures(folder, options) do |pack|
          image :hero, **HERO, colors: pack[:palette], places: pack[:sprites].tiles(0, across: 2, down: 2)
          game_loop do
            wait_vblank
            blit mirror(:hero), 20, 20
            blit upside_down(:hero), 60, 20
            blit upside_down(mirror(:hero)), 100, 20
          end
        end
      end,
      game(:pack_picture_drawn_with_another_list, passes: 3) do |folder, options|
        pictures(folder, options, screen_kind: :tiled) do |pack|
          image :hero, **HERO, colors: pack[:palette], places: pack[:sprites].tiles(0, across: 2, down: 2)
          colors :warm, [:transparent, *Array.new(15) { |at| rgb(31 - at, at * 2, at / 2) }]
          hero = sprite :hero, at: [30, 20]
          hero.draw_with :warm
          game_loop { wait_vblank }
        end
      end,
      game(:picture_in_pack_colors, passes: 3) do |folder, options|
        pictures(folder, options) do |pack|
          image :held, width: 8, height: 8, colors: pack[:palette], places: TILE_PLACES[1]
          game_loop do
            wait_vblank
            blit :held, 30, 30
            blit mirror(:held), 50, 30
          end
        end
      end,
      game(:pictures_in_banks_of_pack_colors, passes: 3) do |folder, options|
        pictures(folder, options) do |pack|
          image :banked, width: 8, height: 8, colors: pack[:palette].bank(0, size: 8), places: TILE_PLACES[1]
          image :second_bank, width: 8, height: 8, colors: pack[:palette].bank(1, size: 8), places: TILE_PLACES[0]
          game_loop do
            wait_vblank
            blit :banked, 30, 30
            blit :second_bank, 60, 30
          end
        end
      end,
      game(:picture_of_pack_places_in_own_colors, passes: 3) do |folder, options|
        pictures(folder, options) do |pack|
          image :held, width: 16, height: 16, colors: OWN_COLORS, places: pack[:sprites].tiles(0, across: 2, down: 2)
          sprite :held, at: [30, 20]
          game_loop { wait_vblank }
        end
      end,
      # Only a console that draws places plays it; every other refuses it however it is built.
      game(:face_of_a_place_in_a_pack_picture, passes: 3) do |folder, options|
        pictures(folder, options, tear_free: true) do |pack|
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
      end,
      # The tiles of a load are worked out as the game is built, from a picture the build does not hold.
      game(:sprite_tiles_loaded_from_a_pack_picture, passes: 4, refused: refused_by_builder("copy from image :hero")) do |folder, options|
        pictures(folder, options, screen_kind: :tiled) do |pack|
          colors :ball, OWN_COLORS
          image :hero, **HERO, colors: :ball, places: pack[:sprites].tiles(0, across: 2, down: 2)
          set = sprite_tiles :ball_tiles, count: 4, colors: :ball
          image :spin, tiles_from: :ball_tiles, pieces: [[0, 0, 0], [8, 0, 1], [0, 8, 2], [8, 8, 3]]
          sprite :ball, at: [40, 20], facing: { spin: :spin }
          pass = var :pass, 0
          game_loop do
            pass += 1
            set.copy_from :hero, at: 0, count: 4, to: 0 if pass == 1
          end
        end
      end,
      game(:picture_of_pack_pixels, passes: 2) do |folder, options|
        built(pixels_art_game(folder, options: options), pixels_pack_file)
      end,
      game(:font_of_pack_pixels, passes: 3) do |folder, options|
        built(lettering_game(folder, options: options), lettering_pack_file)
      end,
      game(:changing_number_in_pack_digits_painted, passes: 4) do |folder, options|
        built(changing_number_game(folder, :bitmap, options: options), lettering_pack_file)
      end,
      game(:changing_number_in_pack_digits_on_tiles, passes: 4) do |folder, options|
        built(changing_number_game(folder, :tiled, options: options), lettering_pack_file)
      end,
      game(:tiles_and_a_table_from_the_pack, passes: 9) do |folder, options|
        built(game_program(through_pack(folder), options: options), made_up_pack_file)
      end,
      game(:picture_of_pack_pixels_in_pack_colors, passes: 2) do |folder, options|
        from = original(folder)
        b = VBlank::Builder.new(options: options)
        b.instance_eval do
          screen :bitmap
          # The whole copy read as 256 colours, so every byte of the picture has a colour.
          pack = data_pack(from: from, version: "1") do |slots|
            slots.colors :every_color, at: 0, count: 256
            slots.pixels :art, at: SPRITES_AT, count: 64
          end
          image :art, width: 8, height: 8, colors: pack[:every_color], places: pack[:art].pixels(0, 64)
          game_loop do
            clear_screen :blue
            blit :art, 20, 20
          end
        end
        b.finalize_program
        built(b.program, b.made_data_pack_file)
      end,
      # With the pack left out a picture of the pack takes its colours, places and size alone.
      game(:pack_picture_given_another_option, passes: 2, refused: refused_by_builder("and nothing else")) do |folder, options|
        pictures(folder, options) do |pack|
          image :hero, width: 8, height: 8, colors: pack[:palette], places: pack[:sprites].tile(0), transparent: :black
          game_loop do
            wait_vblank
            blit :hero, 10, 10
          end
        end
      end,
      # A picture drawn in characters is made of the game's own colours, and only its list is the pack's.
      game(:drawn_picture_in_pack_colors, passes: 2) do |folder, options|
        pictures(folder, options) do |pack|
          image(:ship, { "." => :transparent, "#" => :red, "*" => :green, colors: pack[:palette] }) { "..#..\n.#*#.\n#####" }
          game_loop do
            wait_vblank
            blit :ship, 10, 10
          end
        end
      end,
      game(:font_of_pack_pixels_folding_case, passes: 2, refused: refused_by_builder("cannot fold one case")) do |folder, options|
        from = original(folder)
        b = VBlank::Builder.new(options: options)
        b.instance_eval do
          screen :bitmap
          pack = data_pack(from: from, version: "1") { |slots| slots.pixels :letters, at: SPRITES_AT, count: 120 }
          font :lettering, glyphs: { "A" => pack[:letters].pixels(0, 30), "B" => pack[:letters].pixels(30, 24) }, height: 6, fold: :upper
          game_loop do
            clear_screen :blue
            draw_text "ab", 10, 10, :red, font: :lettering
          end
        end
        b.finalize_program
        built(b.program, b.made_data_pack_file)
      end
    ].freeze
  end

  # A WHOLE SCREEN OF A COMPUTER GAME: a picture 320 by 200, one byte a pixel, in a table of 256
  # colours, both in the original's data and neither in its program, as a DOS game keeps its
  # title. It is wider and taller than some consoles' screens, and what is past an edge is not drawn.
  class ScreenPictures < Kit
    WIDTH = 320
    HEIGHT = 200
    COLORS_AT = 0x20
    PIXELS_AT = 0x300
    COPY_SIZE = PIXELS_AT + (WIDTH * HEIGHT)
    # Every colour differs from the others, and every row of the picture from the rows beside it.
    COLORS = Array.new(256) { |place| ((place * 131) + 7) & 0x7FFF }.freeze
    PIXELS = Array.new(WIDTH * HEIGHT) { |at| ((at % WIDTH) + ((at / WIDTH) * 37) + (at / 4096)) & 0xFF }.freeze

    private def screen_original(folder)
      copy = "\0".b * COPY_SIZE
      copy[COLORS_AT, COLORS.length * 2] = COLORS.pack("v*")
      copy[PIXELS_AT, PIXELS.length] = PIXELS.pack("C*")
      path = File.join(folder, "made_up_screen.bin")
      File.binwrite(path, copy)
      VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :pc,
                                 settings_file: File.join(folder, "made_up.yml"),
                                 releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => COPY_SIZE } })
    end

    GAMES = [
      game(:whole_screen_picture_in_256_pack_colors, passes: 2) do |folder, options|
        from = screen_original(folder)
        b = VBlank::Builder.new(options: options)
        b.instance_eval do
          screen :bitmap
          pack = data_pack(from: from, version: "1") do |slots|
            slots.colors :title_colors, at: COLORS_AT, count: 256, layout: :gba
            slots.pixels :title_screen, at: PIXELS_AT, count: WIDTH * HEIGHT
          end
          image :title_screen, width: WIDTH, height: HEIGHT, colors: pack[:title_colors], places: pack[:title_screen]
          game_loop do
            wait_vblank
            blit :title_screen, 0, 20
          end
        end
        b.finalize_program
        built(b.program, b.made_data_pack_file)
      end
    ].freeze
  end

  # A FONT CUT FROM A STRIP THAT IS A PICTURE OF THE PACK: a row of numerals as an original keeps
  # it, one picture cut into a picture for each character. The strip is eleven characters, each
  # 4x6, cut from a slot of pixels that starts before it, so a piece read from the wrong row or
  # column of the slot shows; the made-up copy's bytes there differ from each to the next.
  class StripFonts < Kit
    include MadeUpOriginal

    CHARACTERS = " 0123456789"
    PIECE_WIDTH = 4
    STRIP_WIDTH = CHARACTERS.length * PIECE_WIDTH
    STRIP_HEIGHT = 6
    STRIP_FIRST = 20
    ART_BYTES = STRIP_FIRST + (STRIP_WIDTH * STRIP_HEIGHT) + 16
    STRIP_COLORS = Array.new(256) { |place| ((place * 37) + 5) & 0x7FFF }.freeze
    # Places the game holds, for a strip that takes only its colours from the pack.
    HELD_PLACES = Array.new(STRIP_WIDTH * STRIP_HEIGHT) { |at| ((at * 7) + (at / STRIP_WIDTH)) % 16 }.freeze

    # A game of the made-up original's colours and a slot of its bytes as pixels, whose block (run
    # on the builder, handed the pack) declares the font :numerals; it then draws a number that
    # changes every pass, a fixed one and words in that font.
    private def strip_font_game(folder, options, &declares)
      from = original(folder)
      b = VBlank::Builder.new(options: options)
      b.instance_eval do
        screen :bitmap
        pack = data_pack(from: from, version: "1") do |slots|
          slots.colors :palette, at: PALETTE_AT, count: 16
          slots.pixels :art, at: 0, count: ART_BYTES
        end
        instance_exec(pack, &declares)
        shown = var :shown, 7
        game_loop do
          clear_screen :blue
          draw_number shown, 10, 10, digits: 3, font: :numerals
          draw_number shown, 10, 30, digits: 4, leading_zeros: true, font: :numerals
          draw_number 905, 10, 50, digits: 3, font: :numerals
          draw_text "31 20", 60, 50, font: :numerals
          shown.store!(shown + 148)
        end
      end
      b.finalize_program
      built(b.program, b.made_data_pack_file)
    end

    GAMES = [
      game(:font_cut_from_a_strip_of_pack_pixels, passes: 4) do |folder, options|
        strip_font_game(folder, options) do |pack|
          image :numeral_strip, width: STRIP_WIDTH, height: STRIP_HEIGHT, colors: STRIP_COLORS,
                                places: pack[:art].pixels(STRIP_FIRST, STRIP_WIDTH * STRIP_HEIGHT)
          font :numerals, strip: :numeral_strip, characters: CHARACTERS
        end
      end,
      game(:font_cut_from_a_strip_with_a_see_through_place, passes: 4) do |folder, options|
        see_through = COPY.getbyte(STRIP_FIRST + 5)
        strip_font_game(folder, options) do |pack|
          image :numeral_strip, width: STRIP_WIDTH, height: STRIP_HEIGHT, colors: STRIP_COLORS, see_through: see_through,
                                places: pack[:art].pixels(STRIP_FIRST, STRIP_WIDTH * STRIP_HEIGHT)
          font :numerals, strip: :numeral_strip, characters: CHARACTERS
        end
      end,
      game(:font_cut_from_a_strip_in_pack_colors, passes: 4) do |folder, options|
        strip_font_game(folder, options) do |pack|
          image :numeral_strip, width: STRIP_WIDTH, height: STRIP_HEIGHT, colors: pack[:palette], places: HELD_PLACES
          font :numerals, strip: :numeral_strip, characters: CHARACTERS
        end
      end,
      # A turned strip's pieces are not runs of the slot's rows.
      game(:font_cut_from_a_turned_strip, passes: 4, refused: refused_by_builder("numeral_strip_mirrored")) do |folder, options|
        strip_font_game(folder, options) do |pack|
          image :numeral_strip, width: STRIP_WIDTH, height: STRIP_HEIGHT, colors: STRIP_COLORS,
                                places: pack[:art].pixels(STRIP_FIRST, STRIP_WIDTH * STRIP_HEIGHT)
          font :numerals, strip: mirror(:numeral_strip), characters: CHARACTERS
        end
      end
    ].freeze
  end

  # EACH CONSOLE'S LAYOUT (MadeUpOriginalLayouts): tiles, a bank of colours, and tables of numbers
  # of two and four bytes, signed and not, as each console keeps them.
  class Layouts < Kit
    include MadeUpOriginalLayouts

    private def layout_tiles_and_tables(folder, options, layout)
      built(*layout_game(through_layout_pack(layout_original(folder, layout), layout), options: options))
    end

    GAMES = [
      game(:tiles_and_tables_in_the_colors_layout, passes: 9) { |folder, options| layout_tiles_and_tables(folder, options, LAYOUTS.fetch(0)) },
      game(:tiles_and_tables_in_the_super_nintendos_four_colors, passes: 9) do |folder, options|
        layout_tiles_and_tables(folder, options, LAYOUTS.fetch(1))
      end,
      game(:tiles_and_tables_in_the_super_nintendos_sixteen_colors, passes: 9) do |folder, options|
        layout_tiles_and_tables(folder, options, LAYOUTS.fetch(2))
      end,
      game(:tiles_and_tables_in_the_genesis_layout, passes: 9) { |folder, options| layout_tiles_and_tables(folder, options, LAYOUTS.fetch(3)) },
      game(:tiles_and_tables_of_a_computer_game_as_the_genesis, passes: 9) do |folder, options|
        layout_tiles_and_tables(folder, options, LAYOUTS.fetch(4))
      end,
      game(:tiles_and_tables_of_a_computer_game_as_the_color, passes: 9) do |folder, options|
        layout_tiles_and_tables(folder, options, LAYOUTS.fetch(5))
      end
    ].freeze
  end

  # A BACKGROUND OF THE ORIGINAL'S OWN TILES, MAP AND COLOURS (PackBackgroundGames), in three
  # consoles' layouts, its banks drawn with other lists, stepped, walked, recoloured and drawn in.
  class Backgrounds < Kit
    include PackBackgroundGames

    WALK_STEPS = 5
    # A list of the game's own in place of a bank: the made-up palette turned, its first place see-through.
    TURNED_LIST = ->(turn) { MadeUpOriginalLayouts::PALETTE.rotate(turn).each_with_index.map { |color, at| at.zero? ? :transparent : color } }
    WORDS_OF_TWO_BANKS = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(3, mirrored: true),
                          ADVANCE_CELL.(1, bank: 1, upside_down: true)].freeze

    private def advance_background(folder, options, words, **shape, &more)
      built(*pack_game_and_file(original(folder, :gba, advance_tiles, words), 4, words, options: options, cell: 8, **shape, &more))
    end

    private def genesis_background(folder, options, words, **shape, &more)
      tiles = PLACES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join
      built(*pack_game_and_file(original(folder, :genesis, tiles, words), 4, words, options: options, cell: 8, **shape, &more))
    end

    # A game of the Advance original whose block (run on the builder, handed the pack) declares
    # the screen and everything on it.
    private def advance_game_of(folder, options, words, &declares)
      from = original(folder, :gba, advance_tiles, words)
      b = VBlank::Builder.new(options: options)
      b.instance_eval do
        pack = data_pack from: from, version: "1" do |slots|
          slots.tiles :video, at: TILES_AT, count: 4
          slots.numbers :map, at: MAP_AT, count: words.length, width: :half, signed: false
          slots.colors :palette, at: COLORS_AT, count: 32
          slots.colors :shimmer, at: TILES_AT, count: 64
        end
        instance_exec(pack, &declares)
      end
      b.finalize_program
      built(b.program, b.made_data_pack_file)
    end

    GAMES = [
      game(:background_of_an_advance_original, passes: 3) do |folder, options|
        words = [ADVANCE_CELL.(1), ADVANCE_CELL.(1, mirrored: true), ADVANCE_CELL.(2, bank: 1, upside_down: true),
                 ADVANCE_CELL.(3, bank: 1, mirrored: true, upside_down: true),
                 ADVANCE_CELL.(0), ADVANCE_CELL.(1), ADVANCE_CELL.(2), ADVANCE_CELL.(1, bank: 1)]
        advance_background(folder, options, words, across: 4)
      end,
      game(:background_of_a_super_nintendo_originals_big_cells, passes: 3) do |folder, options|
        video = Array.new(19) { |at| PLACES.fetch(at % 4) }
        video[0] = PLACES[1]
        video[1] = PLACES[2]
        video[16] = PLACES[3]
        video[17] = PLACES[1]
        words = [SNES_CELL.(0), SNES_CELL.(0, bank: 1, mirrored: true), SNES_CELL.(1, upside_down: true), SNES_CELL.(1, bank: 1)]
        tiles = video.map(&MadeUpOriginalLayouts::FOUR_PLANES).join
        built(*pack_game_and_file(original(folder, :snes, tiles, words), 19, words, across: 2, cell: 16, options: options))
      end,
      # A Color original's two maps, joined by the port's unpacking into map cells of VBlank's own.
      game(:background_of_map_cells_from_a_color_original, passes: 3) do |folder, options|
        built(*color_cells_game_and_file(color_original(folder), options: options))
      end,
      game(:background_of_map_cells_walked_by_bank_names, passes: COLOR_WALK_STEPS + 3) do |folder, options|
        built(*color_cells_game_and_file(color_original(folder), walked: true, options: options))
      end,
      game(:background_of_a_genesis_original, passes: 3) do |folder, options|
        words = [GENESIS_CELL.(1), GENESIS_CELL.(1, mirrored: true), GENESIS_CELL.(2, bank: 1, upside_down: true),
                 GENESIS_CELL.(3, bank: 1, mirrored: true, upside_down: true)]
        genesis_background(folder, options, words, across: 4)
      end,
      # The tiles from one tile of the slot on: the map's tile 0 is the slot's tile 1.
      game(:background_from_one_tile_of_the_slot_on, passes: 2) do |folder, options|
        advance_game_of(folder, options, [ADVANCE_CELL.(0), ADVANCE_CELL.(1, bank: 1), ADVANCE_CELL.(2, mirrored: true)]) do |pack|
          screen :tiled
          background :world, tiles: pack[:video].tile(1), map: pack[:map], colors: pack[:palette], across: 3
          game_loop { wait_vblank }
        end
      end,
      game(:background_bank_drawn_with_another_list, passes: 3) do |folder, options|
        other = TURNED_LIST.(3)
        advance_background(folder, options, WORDS_OF_TWO_BANKS, across: 2) do |world|
          colors :other, other
          world.draw_with({ palette_0: :other })
          game_loop { wait_vblank }
        end
      end,
      game(:background_banks_stepped_through_lists, passes: 5) do |folder, options|
        lists = [3, 5, 9, 11].map(&TURNED_LIST)
        words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(3), ADVANCE_CELL.(1, bank: 1, mirrored: true)]
        advance_background(folder, options, words, across: 4) do |world|
          lists.each_with_index { |list, at| colors :"other_#{at}", list }
          step = var :step, 0
          game_loop do
            world.draw_with({ palette_0: %i[other_0 other_1], palette_1: %i[other_2 other_3] }, showing: step)
            wait_vblank
            step.store!(step + 1)
          end
        end
      end,
      # Which banks the map uses is in the file, so a game names every bank its screen steps. Here
      # no cell is drawn from bank 1.
      game(:background_bank_no_cell_uses_stepped, passes: 4) do |folder, options|
        lists = [3, 5].map(&TURNED_LIST)
        advance_background(folder, options, [ADVANCE_CELL.(1), ADVANCE_CELL.(2, mirrored: true), ADVANCE_CELL.(3)], across: 3) do |world|
          lists.each_with_index { |list, at| colors :"other_#{at}", list }
          step = var :step, 0
          game_loop do
            world.draw_with({ palette_0: %i[other_0 other_1], palette_1: %i[other_0 other_1] }, showing: step)
            wait_vblank
            step.store!(step + 1)
          end
        end
      end,
      game(:background_told_only_a_bank_no_cell_uses, passes: 3) do |folder, options|
        other = TURNED_LIST.(3)
        advance_background(folder, options, [ADVANCE_CELL.(1), ADVANCE_CELL.(2, mirrored: true)], across: 2) do |world|
          colors :other, other
          world.draw_with({ palette_1: :other })
          game_loop { wait_vblank }
        end
      end,
      # A screen brought up from black a bank at a time: each step of each walk is made from the
      # file's colours.
      game(:background_banks_walked_up_from_black, passes: WALK_STEPS + 3) do |folder, options|
        advance_background(folder, options, WORDS_OF_TWO_BANKS, across: 4) do |world|
          walks = { palette_0: color_walk(:palette_0, from: :black, steps: WALK_STEPS),
                    palette_1: color_walk(:palette_1, from: :black, steps: WALK_STEPS) }
          step = var :step, 0
          game_loop do
            world.draw_with(walks, showing: step)
            wait_vblank
            step.store!(step + 1)
          end
        end
      end,
      # One walk, and no bank named: the build with its pack left out draws every bank with it.
      game(:background_given_one_walk_alone, passes: WALK_STEPS + 3) do |folder, options|
        words = [ADVANCE_CELL.(1, bank: 1), ADVANCE_CELL.(2, bank: 1, mirrored: true), ADVANCE_CELL.(3, bank: 1)]
        advance_background(folder, options, words, across: 3) do |world|
          step = var :step, 0
          game_loop do
            world.draw_with color_walk(:palette_1, from: :white, steps: WALK_STEPS), showing: step
            wait_vblank
            step.store!(step + 1)
          end
        end
      end,
      game(:background_of_a_genesis_original_walked, passes: WALK_STEPS + 3) do |folder, options|
        words = [GENESIS_CELL.(1), GENESIS_CELL.(2, bank: 1, upside_down: true), GENESIS_CELL.(3, bank: 1, mirrored: true)]
        genesis_background(folder, options, words, across: 3) do |world|
          walks = { palette_0: color_walk(:palette_0, from: :black, steps: WALK_STEPS),
                    palette_1: color_walk(:palette_1, from: :white, steps: WALK_STEPS) }
          step = var :step, 0
          game_loop do
            world.draw_with(walks, showing: step)
            wait_vblank
            step.store!(step + 1)
          end
        end
      end,
      game(:background_bank_drawn_with_another_bank, passes: 3) do |folder, options|
        words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2), ADVANCE_CELL.(3, bank: 1), ADVANCE_CELL.(1, bank: 1, mirrored: true)]
        advance_background(folder, options, words, across: 4) do |world|
          world.draw_with({ palette_0: :palette_1 })
          game_loop { wait_vblank }
        end
      end,
      game(:picture_drawn_in_a_backgrounds_bank, passes: 3) do |folder, options|
        advance_background(folder, options, [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1)], across: 2) do |_world|
          image :mark, width: 8, height: 8, colors: :palette_1, places: (0...64).map { |at| 1 + (at % 3) }
          sprite :mark, at: [40, 40]
          game_loop { wait_vblank }
        end
      end,
      # `recolor` of a bank reaches a sprite drawn with it and the background's cells of that bank.
      game(:background_bank_recolored, passes: 6) do |folder, options|
        other = TURNED_LIST.(3)
        words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(3, bank: 1, mirrored: true)]
        advance_background(folder, options, words, across: 3) do |world|
          colors :other, other
          world.draw_with({ palette_0: :palette_0, palette_1: :palette_1 })
          image :dot, width: 8, height: 8, places: Array.new(64, 2), colors: :palette_1
          dot = sprite :dot, at: [40, 40]
          dot.draw_with :palette_1
          pass = var :pass, 0
          game_loop do
            recolor :palette_1, %i[other palette_0], showing: pass - 2
            pass += 1
          end
        end
      end,
      # A background that follows two banks the game recolours, each at a pass of its own: a
      # title brought down to another set of colours a palette line at a time. Which cells are of
      # which bank is in the file, and a list's write changes only its own bank's.
      game(:background_following_two_banks_recolored, passes: 8) do |folder, options|
        first = TURNED_LIST.(3)
        second = TURNED_LIST.(5)
        words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(3, mirrored: true), ADVANCE_CELL.(1, bank: 1, upside_down: true),
                 ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(0), ADVANCE_CELL.(3, bank: 1), ADVANCE_CELL.(2)]
        advance_background(folder, options, words, across: 4) do |world|
          colors :first, first
          colors :second, second
          world.draw_with({ palette_0: :palette_0, palette_1: :palette_1 })
          # A list the game recolours is one a sprite draws with: a dot in each bank's.
          %i[palette_0 palette_1].each_with_index do |bank, at|
            image :"dot_#{at}", width: 8, height: 8, places: Array.new(64, 2), colors: bank
            sprite(:"dot_#{at}", at: [40 + (at * 20), 40]).draw_with bank
          end
          pass = var :pass, 0
          game_loop do
            pass += 1
            recolor :palette_0, :first if pass >= 3
            recolor :palette_1, %i[second palette_0], showing: pass - 5 if pass >= 5
          end
        end
      end,
      # The backdrop follows a bank's list: the bank's colour at a place, which no picture can show.
      game(:backdrop_following_a_backgrounds_bank, passes: 2) do |folder, options|
        advance_game_of(folder, options, [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1)]) do |pack|
          colors :sky, pack[:palette].bank(1)
          screen :tiled, backdrop: :sky, backdrop_place: 3
          background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 2
          game_loop { wait_vblank }
        end
      end,
      # A shimmer: four lists, each a bank of another slot of the pack, and a background that
      # draws one of its own banks with each of them in turn.
      game(:background_bank_stepped_through_lists_of_the_pack, passes: 7) do |folder, options|
        advance_game_of(folder, options, WORDS_OF_TWO_BANKS) do |pack|
          screen :tiled
          shimmers = Array.new(4) { |bank| colors :"shimmer#{bank}", pack[:shimmer].bank(bank) }
          rays = background :rays, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 4
          step = var :step, 0
          game_loop do
            rays.draw_with({ palette_1: shimmers }, showing: step)
            wait_vblank
            step.store!(step + 1)
          end
        end
      end,
      game(:background_from_the_pack_faded, passes: 7) do |folder, options|
        words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(3), ADVANCE_CELL.(1, bank: 1, mirrored: true)]
        advance_background(folder, options, words, across: 4) do |_world|
          level = var :level, 0
          game_loop do
            fade :black, level
            wait_vblank
            level.store!(level + 15)
          end
        end
      end,
      game(:background_from_the_pack_scrolled, passes: 6) do |folder, options|
        words = Array.new(64) { |at| ADVANCE_CELL.(1 + (at % 3), bank: (at / 3) % 2, mirrored: at.odd?, upside_down: (at % 5).zero?) }
        advance_background(folder, options, words, across: 8) do |world|
          game_loop do
            wait_vblank
            world.scroll_by 3, 1
          end
        end
      end
    ].freeze
  end

  # A CELL OF A BACKGROUND FROM THE PACK WRITTEN WITH `set_cell` (PackBackgroundSetCellGames): the
  # font cells an original stores in the map its picture is in.
  class WrittenCells < Kit
    include PackBackgroundSetCellGames

    TURNED_LIST = ->(turn) { MadeUpOriginalLayouts::PALETTE.rotate(turn).each_with_index.map { |color, at| at.zero? ? :transparent : color } }

    private def advance_cells_game(folder, options, words, **told, &more)
      from = original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words)
      built(*pack_game_and_file(from, PLACES.length, words, across: 4, options: options, **told, &more))
    end

    GAMES = [
      game(:font_cells_written_on_a_genesis_background, passes: 5) { |folder, options| built(*genesis_text_game(folder, options: options)) },
      # The font's space is a tile that draws nothing, which is known only once the file is read.
      game(:font_cells_blanked_again, passes: 8) { |folder, options| built(*genesis_text_game(folder, blank_at: 4, options: options)) },
      game(:turned_cell_written_on_an_advance_background, passes: 5) do |folder, options|
        built(*advance_turned_cell_game(folder, options: options))
      end,
      game(:big_cell_written_on_a_super_nintendo_background, passes: 5) { |folder, options| built(*snes_big_cell_game(folder, options: options)) },
      game(:cell_numbers_in_a_gap_and_outside_the_told_cells, passes: 5) do |folder, options|
        first = GENESIS_CELL.(FIRST_FONT_TILE, bank: 1)
        built(*numbered_game(folder, [first, first + 2], [first + 2, first + 1, first - 1, first + 3], options: options))
      end,
      game(:told_cells_far_apart, passes: 5) do |folder, options|
        plain = GENESIS_CELL.(FIRST_FONT_TILE)
        turned = GENESIS_CELL.(FIRST_FONT_TILE, mirrored: true)
        other_bank = GENESIS_CELL.(FIRST_FONT_TILE + 1, bank: 1)
        built(*numbered_game(folder, [other_bank, plain, turned], [turned, other_bank, plain + 0x400, plain], options: options))
      end,
      game(:cells_written_on_a_scenes_background, passes: 6) { |folder, options| built(*scene_text_game(folder, options: options)) },
      # A written cell is drawn with the list the background is told to draw its bank with.
      game(:written_cell_drawn_with_other_lists, passes: 7) do |folder, options|
        lists = [3, 5].map(&TURNED_LIST)
        base = ADVANCE_CELL.(FIRST_FONT_TILE, bank: 1)
        advance_cells_game(folder, options, MAP_TILES.flatten.map { |tile| ADVANCE_CELL.(tile) }, set_cells: base..(base + 1)) do |world|
          lists.each_with_index { |list, at| colors :"other_#{at}", list }
          pass = var :pass, 0
          game_loop do
            world.draw_with({ palette_1: %i[other_0 other_1] }, showing: pass - 2)
            wait_vblank
            pass += 1
            world.set_cell 1, 0, base + 1 if pass == 2
          end
        end
      end,
      game(:written_cell_whose_bank_is_recolored, passes: 7) do |folder, options|
        other = TURNED_LIST.(3)
        base = ADVANCE_CELL.(FIRST_FONT_TILE, bank: 1)
        words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(1), ADVANCE_CELL.(2)]
        advance_cells_game(folder, options, words, set_cells: base..(base + 1)) do |world|
          colors :other, other
          world.draw_with({ palette_0: :palette_0, palette_1: :palette_1 })
          image :dot, width: 8, height: 8, places: Array.new(64, 2), colors: :palette_1
          dot = sprite :dot, at: [40, 40]
          dot.draw_with :palette_1
          pass = var :pass, 0
          game_loop do
            recolor :palette_1, %i[other palette_0], showing: pass - 3
            pass += 1
            world.set_cell 2, 0, base + 1 if pass == 2
          end
        end
      end,
      # A cell written on a background that follows two banks the game recolours: the written
      # tile is one the build holds, and follows its bank's list as the map's tiles do.
      game(:written_cell_on_a_background_following_two_banks, passes: 8) do |folder, options|
        first = TURNED_LIST.(3)
        second = TURNED_LIST.(5)
        base = ADVANCE_CELL.(FIRST_FONT_TILE, bank: 1)
        words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(1), ADVANCE_CELL.(2)]
        advance_cells_game(folder, options, words, set_cells: base..(base + 1)) do |world|
          colors :first, first
          colors :second, second
          world.draw_with({ palette_0: :palette_0, palette_1: :palette_1 })
          %i[palette_0 palette_1].each_with_index do |bank, at|
            image :"dot_#{at}", width: 8, height: 8, places: Array.new(64, 2), colors: bank
            sprite(:"dot_#{at}", at: [40 + (at * 20), 40]).draw_with bank
          end
          pass = var :pass, 0
          game_loop do
            pass += 1
            world.set_cell 2, 0, base + 1 if pass == 2
            recolor :palette_0, :first if pass >= 3
            recolor :palette_1, :second if pass >= 5
          end
        end
      end,
      # `set_tile` names a tile of the background's own, and which tiles the map draws is in the file.
      game(:set_tile_by_a_number_on_a_pack_background, passes: 4, refused: refused_by_builder("set_cell")) do |folder, options|
        advance_cells_game(folder, options, MAP_TILES.flatten.map { |tile| ADVANCE_CELL.(tile) }, set_cells: [ADVANCE_CELL.(3)]) do |world|
          which = var :which, 0
          game_loop do
            wait_vblank
            world.set_tile 0, 0, which
            which.store!((which + 1) & 1)
          end
        end
      end
    ].freeze
  end

  # A SCREEN'S BACKDROP FROM THE PACK (PackBackdropGames): a slot's first colour, a bank's, and a
  # place of either, on a screen whose one cell is a background of the pack too.
  class Backdrops < Kit
    include PackBackdropGames

    # A Genesis original keeps a colour in nine bits, high byte first: sixteen made-up colours,
    # none of them black, and a screen that shows nothing else.
    GENESIS_COLORS_AT = 0x10
    GENESIS_COLORS = Array.new(16) { |at| (((at * 3) % 8) << 1) | ((7 - (at % 8)) << 5) | (((at + 2) % 8) << 9) }.freeze

    private def backdrop_game(folder, options, &screen_options)
      from = backdrop_original(folder)
      built(game_with_backdrop(from, options: options, &screen_options), backdrop_pack_file(from))
    end

    GAMES = [
      game(:backdrop_from_a_slot, passes: 3) { |folder, options| backdrop_game(folder, options) { |pack| { backdrop: pack[:palette] } } },
      game(:backdrop_from_a_bank, passes: 3) { |folder, options| backdrop_game(folder, options) { |pack| { backdrop: pack[:palette].bank(1) } } },
      game(:backdrop_place_of_a_slot, passes: 3) do |folder, options|
        backdrop_game(folder, options) { |pack| { backdrop: pack[:palette], backdrop_place: 19 } }
      end,
      game(:backdrop_place_of_a_bank, passes: 3) do |folder, options|
        backdrop_game(folder, options) { |pack| { backdrop: pack[:palette].bank(1), backdrop_place: 7 } }
      end,
      game(:backdrop_of_a_genesis_original, passes: 2) do |folder, options|
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
          screen :tiled, backdrop: pack[:palette], backdrop_place: 5
          game_loop { wait_vblank }
        end
        b.finalize_program
        built(b.program, b.made_data_pack_file)
      end
    ].freeze
  end

  # A LIST OF COLOURS FROM THE PACK (PackColorListGames): a whole slot or a bank of it, drawn
  # with, recoloured with, walked and drawn in.
  class ColorLists < Kit
    include PackColorListGames

    GAMES = [
      game(:sprite_recolored_through_banks_of_a_slot, passes: 6) do |folder, options|
        built(*recoloring_game_and_file(banks_from_pack(layout_original(folder, GENESIS)), options: options))
      end,
      game(:sprite_drawn_with_a_whole_slot, passes: 3) do |folder, options|
        built(*whole_slot_game_and_file(layout_original(folder, GENESIS), options: options))
      end,
      game(:list_from_the_pack_walked_up_from_white, passes: WALK_STEPS + 2) do |folder, options|
        built(*walking_game_and_file(layout_original(folder, GENESIS), options: options))
      end,
      game(:picture_drawn_in_a_list_from_the_pack_blitted, passes: 2) do |folder, options|
        built(*blitting_game_and_file(layout_original(folder, GENESIS), options: options))
      end,
      # What the game paints from a list as it runs, in a list of colours from the pack.
      game(:tiles_painted_from_a_list_in_pack_colors, passes: 4) do |folder, options|
        from = layout_original(folder, GENESIS)
        test = self
        builder = Builder.new(options: options)
        builder.instance_eval do
          screen :tiled
          pack = test.palette_pack_of(self, from)
          colors :ink, pack[:palette].bank(1, size: BANK_SIZE)
          canvas = list :canvas, capacity: 64, width: :byte
          repeat(64) { canvas.push 0x21 }
          box = tiles :box, from: canvas, count: 2, colors: :ink
          background :front, tiles: :box, map: [[1, 2]]
          pass = var :pass, 0
          game_loop do
            pass += 1
            if pass == 2
              canvas[0] = 0x13
              box.changed
            end
          end
        end
        builder.finalize_program
        built(builder.program, builder.made_data_pack_file)
      end,
      # A sprite's picture the game paints from a list, in a list of colours from the pack, and
      # the same sprite drawn with another bank of the pack once the game says so.
      game(:sprite_picture_painted_from_a_list_in_pack_colors, passes: 6) do |folder, options|
        from = layout_original(folder, GENESIS)
        test = self
        builder = Builder.new(options: options)
        builder.instance_eval do
          screen :tiled
          pack = test.palette_pack_of(self, from)
          colors :ink, pack[:palette].bank(1, size: BANK_SIZE)
          colors :other_ink, pack[:palette].bank(2, size: BANK_SIZE)
          canvas = list :canvas, capacity: 32, width: :byte
          repeat(32) { canvas.push 0x21 }
          letter = image :letter, from: canvas, width: 8, height: 8, colors: :ink
          tag = sprite :letter, at: [40, 20]
          pass = var :pass, 0
          game_loop do
            pass += 1
            tag.draw_with :other_ink if pass >= 4
            if pass == 2
              canvas[0] = 0x13
              letter.changed
            end
          end
        end
        builder.finalize_program
        built(builder.program, builder.made_data_pack_file)
      end,
      # Drawn with another list, a picture given as colours is swapped by finding each pixel's
      # place in its own list, which a build that does not hold the list cannot do.
      game(:picture_of_colors_in_a_pack_list_drawn_with_another_list, passes: 3, refused: refused_by_builder("places:")) do |folder, options|
        from = layout_original(folder, GENESIS)
        test = self
        builder = Builder.new(options: options)
        builder.instance_eval do
          screen :tiled
          pack = test.palette_pack_of(self, from)
          colors :bank_1, pack[:palette].bank(1, size: BANK_SIZE)
          colors :bank_2, pack[:palette].bank(2, size: BANK_SIZE)
          image :ship, width: 8, height: 8, colors: :bank_1, data: Array.new(64) { |at| BANKS.fetch(1).fetch(1 + (at % 3)) }
          ship = sprite :ship, at: [40, 40]
          ship.draw_with :bank_2
          game_loop { wait_vblank }
        end
        builder.finalize_program
        built(builder.program, builder.made_data_pack_file)
      end,
      # A picture given as colours is drawn in them, whatever its list holds.
      game(:picture_of_colors_drawn_in_a_list_from_the_pack, passes: 2) do |folder, options|
        from = layout_original(folder, GENESIS)
        test = self
        builder = Builder.new(options: options)
        builder.instance_eval do
          screen :bitmap
          pack = test.palette_pack_of(self, from)
          colors :bank_1, pack[:palette].bank(1, size: BANK_SIZE)
          image :ship, width: 2, height: 1, colors: :bank_1, data: [BANKS.fetch(1).fetch(1), BANKS.fetch(1).fetch(2)]
          game_loop do
            clear_screen :black
            blit :ship, 20, 20
            wait_vblank
          end
        end
        builder.finalize_program
        built(builder.program, builder.made_data_pack_file)
      end
    ].freeze
  end

  # A POSE THAT IS ONE OF THE ORIGINAL'S FRAMES (PackPoseGames): a count and five bytes a piece.
  class Poses < Kit
    include PackPoseGames

    private def pose(folder, options, size: REACH, **shape, &more)
      built_by(pose_game_builder(original(folder), size: size, options: options, **shape, &more))
    end

    GAMES = [
      game(:pose_of_an_originals_frame, passes: 3) { |folder, options| pose(folder, options) },
      game(:pose_of_a_larger_size, passes: 3) { |folder, options| pose(folder, options, size: [32, 40]) },
      game(:pose_of_a_frame_of_a_given_count, passes: 3) do |folder, options|
        pose(folder, options, frame_at: 2, layout: FRAME.with(counted: false), count: PIECES.length)
      end,
      game(:pose_drawn_with_another_list, passes: 3) do |folder, options|
        other = MadeUpOriginalLayouts::PALETTE.last(4)
        pose(folder, options) do |hero|
          colors :other, [:transparent, *other.drop(1)]
          hero.draw_with :other
        end
      end,
      game(:pose_turned_round, passes: 3) { |folder, options| pose(folder, options, size: [32, 24], turned: :mirror) },
      game(:pose_turned_upside_down, passes: 3) { |folder, options| pose(folder, options, size: [16, 40], turned: :upside_down) },
      game(:pose_in_a_bank_of_pack_colors, passes: 3) do |folder, options|
        pose(folder, options, pose_colors: ->(pack) { pack[:palette].bank(1, size: 4) })
      end,
      # A pose's size is worked out from its frame's pieces, which a build that leaves its pack
      # out does not hold.
      game(:pose_given_no_size, passes: 3, refused: refused_by_builder("size:", names_fix: false)) do |folder, options|
        built_by(pose_game_builder(original(folder), options: options))
      end
    ].freeze
  end

  # A POSE WHOSE FRAME IS THE CONSOLE'S OWN SPRITE ENTRIES (PackPoseOfWordsGames): parts of two
  # bytes, and pieces of several tiles each way.
  class PosesOfWords < Kit
    include PackPoseOfWordsGames

    private def pose_of_words(folder, options, layout: FRAME, high_byte_first: true)
      built_by(pose_from_pack_builder(original(folder, high_byte_first: high_byte_first), layout: layout, size: REACH, options: options))
    end

    GAMES = [
      game(:pose_of_pieces_of_mixed_sizes, passes: 3) { |folder, options| pose_of_words(folder, options) },
      game(:pose_of_tiles_across_rows, passes: 3) { |folder, options| pose_of_words(folder, options, layout: FRAME.with(tile_order: :across_rows)) },
      game(:pose_of_words_low_byte_first, passes: 3) do |folder, options|
        pose_of_words(folder, options, layout: FRAME.with(high_byte_first: false), high_byte_first: false)
      end
    ].freeze
  end

  # A POSE WHOSE FRAME'S PIECES ARE EVERY SHAPE AND SIZE OF THE ADVANCE'S (PackPoseOfShapesGames):
  # each piece's size read through the console's table, as game code with the pack left out.
  class PosesOfShapes < Kit
    include PackPoseOfShapesGames

    GAMES = [
      game(:pose_of_every_advance_shape_and_size, passes: 3) do |folder, options|
        built_by(pose_of_shapes_builder(original(folder), options: options))
      end
    ].freeze
  end

  # POSES WHOSE FRAMES THE GAME READS WITH A READER OF ITS OWN, given a value from each pose
  # (PackPoseReadByTheGameGames): the reader run as game code with the pack left out.
  class PosesReadByTheGame < Kit
    include PackPoseReadByTheGameGames

    GAMES = [
      game(:poses_of_one_frame_read_by_the_game_for_two_blocks, passes: 3) do |folder, options|
        built_by(poses_read_by_the_game_builder(original(folder), options: options))
      end
    ].freeze
  end

  # A POSE IN THE COLOURS OF THE BANK ITS FRAME NAMES (PackPoseBankColorGames).
  class PosesInBankColors < Kit
    include PackPoseBankColorGames

    SIZE = [16, 8].freeze
    OTHER_LIST = OTHER.each_with_index.map { |color, at| at.zero? ? :transparent : color }.freeze

    # A game of the poses :first (a frame of bank 1) and :second (a frame of bank 2), each given
    # the size of its two pieces, and whatever the block, run on the builder, declares.
    private def poses_in_bank_colors(folder, options, &more)
      test = self
      built_by(game_builder_of(folder, options: options) do |pack|
        test.declare_poses_for(self, pack, size: SIZE)
        instance_exec(pack, &more)
      end)
    end

    GAMES = [
      game(:poses_in_the_banks_their_frames_name, passes: 3) do |folder, options|
        poses_in_bank_colors(folder, options) do |_pack|
          sprite :first, at: [40, 40]
          sprite :second, at: [80, 40]
        end
      end,
      # A swap by place needs no name: the pose's own list is the file's, the other the game's.
      game(:pose_in_its_frames_bank_drawn_with_another_list, passes: 3) do |folder, options|
        other = OTHER_LIST
        poses_in_bank_colors(folder, options) do |_pack|
          colors :other, other
          sprite :first, at: [40, 40]
          second = sprite :second, at: [80, 40]
          second.draw_with :other
        end
      end,
      # A list of a bank, declared by the pose, is recoloured by its name whichever way it is built.
      game(:bank_list_beside_poses_in_bank_colors_recolored, passes: 5) do |folder, options|
        other = OTHER_LIST
        poses_in_bank_colors(folder, options) do |_pack|
          colors :other, other
          sprite :first, at: [40, 40]
          image :dot, width: 8, height: 8, places: Array.new(64, 2), colors: :palette_2
          dot = sprite :dot, at: [80, 60]
          dot.draw_with :palette_2
          recolor :palette_2, :other
        end
      end,
      # With the pack left out the list a pose's frame picks is named for the pose, and the sprite
      # follows whichever bank's list the file picks.
      game(:pose_in_its_frames_bank_followed_by_its_lists_name, passes: 5) do |folder, options|
        other = OTHER_LIST
        poses_in_bank_colors(folder, options) do |_pack|
          colors :other, other
          first = sprite :first, at: [40, 40]
          first.draw_with colors_name_of(:first)
          recolor :palette_1, :other
        end
      end,
      # Told to follow its pose's list by a hash, as a sprite of several poses is.
      game(:pose_in_its_frames_bank_following_its_list, passes: 5) do |folder, options|
        other = OTHER_LIST
        poses_in_bank_colors(folder, options) do |_pack|
          colors :other, other
          second = sprite :second, at: [80, 40]
          second.draw_with({ colors_name_of(:second) => colors_name_of(:second) })
          recolor :palette_2, :other
        end
      end,
      # Only the pieces of the bank given are painted, the file saying which those are.
      game(:pose_of_one_banks_pieces, passes: 3) do |folder, options|
        built_by(game_builder_of(folder, options: options) do |pack|
          frame = pack[:frames].frame(IN_TWO_BANKS, layout: FRAME)
          image :near, tiles: pack[:video], frame: frame, origin: ORIGIN, colors: pack[:palette], bank: 1, size: SIZE
          image :far, tiles: pack[:video], frame: frame, origin: ORIGIN, colors: pack[:palette], bank: 3, size: SIZE
          sprite :near, at: [40, 40]
          sprite :far, at: [40, 40]
        end)
      end
    ].freeze
  end

  # RECORDED SOUND FROM THE PACK (PackSoundTests): a recording's samples, and an instrument's rate,
  # hold point and envelope.
  class Sounds < Kit
    include PackSoundTests

    GAMES = [
      game(:recordings_of_pack_samples, passes: 10, presses: { 1 => [:a], 5 => [:b] }) do |folder, options|
        built(sound_game(folder, options: options), sound_pack_file)
      end,
      game(:recording_of_the_pack_in_a_song_and_an_effect, passes: 50, presses: { 1 => [:a], 20 => [:b] }) do |folder, options|
        built(scored_sound_game(folder, options: options), sound_pack_file)
      end,
      game(:two_recordings_of_one_length_from_one_slot, passes: 10, presses: { 1 => [:a], 5 => [:b] }) do |folder, options|
        built(two_stretches_game(folder, options: options), sound_pack_file)
      end,
      game(:instrument_hold_and_envelope_from_the_pack, passes: 80,
                                                        presses: { 1 => [:a], 8 => [:b], 20 => [:up], 50 => [:down] }) do |folder, options|
        built(settings_at_start_game(folder, from_pack: %i[holds_from envelope], options: options), settings_pack_file)
      end,
      # A build for a computer lays its sound out from its recordings' rates, so it must know each.
      game(:instrument_rate_from_the_pack, passes: 80, presses: { 1 => [:a], 8 => [:b], 20 => [:up], 50 => [:down] },
                                           refused: Refusal.new(phrase: "rate", by: :computer_build_mixing_at_recording_rates)) do |folder, options|
        built(settings_at_start_game(folder, from_pack: %i[rate holds_from envelope], options: options), settings_pack_file)
      end,
      # ...unless the game names the rate its sound is mixed at, as a port of a game whose sound
      # driver mixed at one rate does.
      game(:instrument_rate_from_the_pack_mixed_at_a_named_rate, passes: 80,
                                                                 presses: { 1 => [:a], 8 => [:b], 20 => [:up], 50 => [:down] }) do |folder, options|
        built(settings_at_start_game(folder, from_pack: %i[rate holds_from envelope], options: options, mix_rate: 13_379),
              settings_pack_file)
      end,
      # A recording's length from the pack too, shorter than its slot, read back from its own end.
      game(:instrument_length_from_the_pack, passes: 80, presses: { 1 => [:a], 8 => [:b], 20 => [:up], 50 => [:down] }) do |folder, options|
        built(settings_at_start_game(folder, from_pack: %i[holds_from envelope length], options: options), settings_pack_file)
      end,
      game(:instrument_chip_envelope_from_the_pack, passes: 20, presses: { 1 => [:a] },
                                                    refused: refused_by_builder("chip envelope")) do |folder, options|
        from = original(folder)
        b = VBlank::Builder.new(options: options)
        b.instance_eval do
          screen :bitmap
          enable_sound
          pack = data_pack(from: from, version: "1") do |slots|
            slots.samples :bang, at: SOUND_AT, count: SOUND_COUNT
            slots.numbers :shapes, at: ENVELOPE_AT, count: 3, width: :byte, signed: false
          end
          tone = instrument :tone, pcm: pack[:bang], rate: SOUND_RATE, envelope: pack[:shapes].snes_envelope(0)
          game_loop do
            wait_vblank
            tone.play(:E4) if pressed(:a)
          end
        end
        b.finalize_program
        built(b.program, b.made_data_pack_file)
      end
    ].freeze
  end

  # SONGS AND SOUND EFFECTS WHOSE PARTS READ THEIR NOTES FROM THE PACK (PackScoresAtStartTests'
  # notes, in a made-up original that holds each part's records one slot after another).
  class Scores < Kit
    include PackScoresAtStartTests

    COPY_SIZE = 4096
    # PackScoresAtStartTests::TUNE without its note of an instrument the part does not name, which
    # a build that reads the notes refuses.
    NAMED_TUNE = [[0, 12, 60, OWN, OWN], [12, 12, 64, 0, 12], [24, 12, 67, 1, OWN], [36, 0, 72, OWN, 9], [60, 0, 64, 1, OWN]].freeze

    private def score_original(folder, parts)
      copy = "\0".b * COPY_SIZE
      parts.each_value.with_index { |notes, place| copy[place * MOST * PackNote::BYTES, MOST * PackNote::BYTES] = records(notes) }
      copy[SETTINGS_AT, SHAPE.length + 1] = [*SHAPE, HOLDS_FROM].pack("C*")
      copy[TIMING_AT, TIMING.length * 2] = TIMING.pack("v*")
      path = File.join(folder, "made_up_songs.bin")
      File.binwrite(path, copy)
      VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                                 settings_file: File.join(folder, "made_up.yml"),
                                 releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => COPY_SIZE } })
    end

    # A game whose songs and sound effects the block makes, handed a way to get a part's notes by
    # slot name and the instrument settings of the pack. It plays song 0 on A and effect 0 on B.
    private def scores_game(folder, options, parts, instruments: {}, &scores)
      from = score_original(folder, parts)
      b = VBlank::Builder.new(options: options)
      b.instance_eval do
        screen :bitmap
        enable_sound
        pack = data_pack(from: from, version: "1") do |slots|
          parts.each_key.with_index { |name, place| slots.notes name, at: place * MOST * PackNote::BYTES, count: MOST }
          slots.numbers :settings, at: SETTINGS_AT, count: SHAPE.length + 1, width: :byte, signed: false
          slots.numbers :timing, at: TIMING_AT, count: TIMING.length, width: :half, signed: false
        end
        # A part takes the slot's handle itself too, where its notes name no instrument.
        # A word for the notes written by hand (`recorded:`) means nothing to the pack's.
        notes_of = lambda do |name, whole_slot: false, **|
          whole_slot ? pack[name] : pack[name].notes(instruments: instruments.fetch(name, []))
        end
        settings = { envelope: pack[:settings].envelope(0), holds_from: pack[:settings].number(SHAPE.length) }
        timing = { length: pack[:timing].number(0), loop_from: pack[:timing].number(1) }
        made = instance_exec(notes_of, settings, timing, &scores)
        music = songs :music, made.fetch(:songs)
        effects = (sound_effects :sfx, made[:effects] if made[:effects])
        game_loop do
          wait_vblank
          music.play 0 if pressed(:a)
          effects.play 0 if effects && pressed(:b)
        end
      end
      b.finalize_program
      built(b.program, b.made_data_pack_file)
    end

    GAMES = [
      game(:song_of_pack_notes, passes: 90, presses: { 1 => [:a] }) do |folder, options|
        scores_game(folder, options, { melody: MELODY, bass: BASS }) do |notes_of|
          { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody), volume: 12),
                                      Part.new(notes: notes_of.(:bass, whole_slot: true), volume: 10)],
                              tempo: 150, length: 96, plays_once: true)] }
        end
      end,
      game(:sound_effect_of_pack_notes_over_a_song, passes: 70, presses: { 1 => [:a], 20 => [:b] }) do |folder, options|
        scores_game(folder, options, { melody: MELODY, blip: BLIP }) do |notes_of|
          { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody))], tempo: 150, length: 96)],
            effects: [Score.new(parts: [Part.new(notes: notes_of.(:blip), volume: 14)], tempo: 150, length: 24, priority: 3)] }
        end
      end,
      # Parts that play recordings, their notes naming instruments, an instrument's hold point and
      # another's envelope numbers of the pack too.
      game(:recorded_parts_of_pack_notes, passes: 130, presses: { 1 => [:a], 40 => [:b] }) do |folder, options|
        test = self
        scores_game(folder, options, { tune: NAMED_TUNE, blip: BLIP }, instruments: { tune: %i[bell bass], blip: %i[horn] }) do |notes_of, settings|
          test.declare_recorded_scores(self, notes_of, settings)
        end
      end,
      # A recorded part's loudness in 512ths, none of it past the recording's size, which a build
      # holding the records refuses.
      game(:recorded_loudness_of_pack_notes, passes: 150, presses: { 1 => [:a] }) do |folder, options|
        test = self
        loud = LOUD_TUNE.map { |note| note[5] == 900 ? [*note.first(5), 400] : note }
        scores_game(folder, options, { loud: loud }) { |notes_of| test.declare_loud_scores(self, notes_of) }
      end,
      # Each note's speaker on a square part and its noise clock on the noise voice, none of them
      # one that is no speaker or no clock, which a build holding the records refuses.
      game(:sided_and_clocked_pack_notes, passes: 150, presses: { 1 => [:a] }) do |folder, options|
        sided = SIDED.reject { |note| note[6] == 9 }
        clocked = CLOCKED.reject { |note| note[7] == 0xF2 }
        scores_game(folder, options, { lead: sided, drum: clocked }) do |notes_of|
          { songs: [Score.new(parts: [Part.new(notes: notes_of.(:lead), pan: :right), Part.new(notes: notes_of.(:drum), plays: :noise)],
                              tempo: 150, length: 84, loop_from: 20)] }
        end
      end,
      # A song whose length and loop are numbers of the pack, as a sound driver's song keeps them.
      game(:song_of_pack_notes_and_pack_length, passes: 200, presses: { 1 => [:a] }) do |folder, options|
        scores_game(folder, options, { lead: LEAD, low: LOW, drum: DRUM, wave: WAVE }) do |notes_of, _settings, timing|
          { songs: [Score.new(parts: [Part.new(notes: notes_of.(:lead), duty: :quarter, transpose: 2), Part.new(notes: notes_of.(:low)),
                                      Part.new(notes: notes_of.(:drum), plays: :noise), Part.new(notes: notes_of.(:wave), plays: :wave)],
                              tempo: 150, longest: 300, **timing)] }
        end
      end,
      # A length from the pack with no most it can be leaves the build no room to make.
      game(:song_of_pack_length_naming_no_longest, passes: 90, presses: { 1 => [:a] }, refused: refused_by_builder("longest:")) do |folder, options|
        scores_game(folder, options, { melody: MELODY }) do |notes_of, _settings, timing|
          { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody))], tempo: 150, length: timing.fetch(:length), plays_once: true)] }
        end
      end,
      # With the notes in the file, the build cannot work out how long the song is.
      game(:song_of_pack_notes_naming_no_length, passes: 90, presses: { 1 => [:a] }, refused: refused_by_builder("length")) do |folder, options|
        scores_game(folder, options, { melody: MELODY }) do |notes_of|
          { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody))], tempo: 150, plays_once: true)] }
        end
      end
    ].freeze
  end

  # ONE SLOT READ IN SEVERAL SHAPES THROUGH VIEWS (PackSlotViewGames): a stretch of video memory
  # kept as one slot of sixteen-colour tiles, and parts of it read as tiles of a byte a pixel, a
  # map of bytes, a picture of pixels and tables of numbers.
  class SlotViews < Kit
    include PackSlotViewGames

    GAMES = [
      # Only a console that turns a background plays it; every other refuses it however it is built.
      game(:backgrounds_of_two_shapes_viewed_in_one_slot, passes: 5) do |folder, options|
        built(*two_shapes_game_and_file(slot_view_original(folder), views: true, options: options) do |layer|
          layer.turns_around(*PIVOT, map_point: MIDDLE).scale(2.0)
          spin = var :spin, 0
          game_loop do
            spin += 11
            layer.rotate spin
          end
        end)
      end,
      game(:pixels_and_tables_viewed_in_a_slot_of_tiles, passes: 9) do |folder, options|
        built(*table_and_pixels_game_and_file(slot_view_original(folder), views: true, options: options))
      end
    ].freeze
  end

  # COLOURS READ AS THE GAME STARTS, COMPARED WHILE THE GAME IS BUILT: what the build checks of two
  # lists of colours when one of them is markers (IR::StartFile, "MARKERS"), whose colours it does
  # not hold. Each is a game the all-in-one build accepts, so the build with the pack left out must
  # take it too.
  class ColorsComparedAtStart < Kit
    include PackColorListGames

    # A made-up Genesis original whose four colours hold one colour twice, at places 1 and 2.
    TWICE_AT = 0x10
    TWICE = [0x0000, 0x000E, 0x000E, 0x00E0].freeze
    RED = 0x001F
    GREEN = 0x03E0

    private def original_holding_one_color_twice(folder)
      copy = "\0".b * (TWICE_AT + 8)
      copy[TWICE_AT, 8] = TWICE.pack("n*")
      path = File.join(folder, "made_up_twice.bin")
      File.binwrite(path, copy)
      VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :genesis,
                                 settings_file: File.join(folder, "made_up.yml"),
                                 releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
    end

    GAMES = [
      # The sprite's own list holds red at two places, and the pack's list one colour at both, so
      # the swap by the first place draws every red pixel right.
      game(:picture_of_colors_drawn_with_a_pack_list_agreeing_at_a_repeated_place, passes: 3) do |folder, options|
        from = original_holding_one_color_twice(folder)
        b = Builder.new(options: options)
        b.instance_eval do
          pack = data_pack(from: from, version: "1") { |slots| slots.colors :palette, at: TWICE_AT, count: TWICE.length }
          screen :tiled
          colors :from_pack, pack[:palette]
          image :ship, width: 8, height: 8, colors: %i[transparent red red green], data: Array.new(64) { |at| at.even? ? RED : GREEN }
          ship = sprite :ship, at: [40, 40]
          ship.draw_with :from_pack
          game_loop { wait_vblank }
        end
        b.finalize_program
        built(b.program, b.made_data_pack_file)
      end,
      # A background of pictures given as colours in a list from the pack is never drawn with
      # another list, and another list the game recolours leaves it as it is.
      game(:background_of_pictures_of_colors_in_a_pack_list_beside_a_recolored_list, passes: 4) do |folder, options|
        from = layout_original(folder, GENESIS)
        test = self
        builder = Builder.new(options: options)
        builder.instance_eval do
          screen :tiled
          pack = test.palette_pack_of(self, from)
          colors :bank_1, pack[:palette].bank(1, size: BANK_SIZE)
          colors :bank_2, pack[:palette].bank(2, size: BANK_SIZE)
          colors :bank_3, pack[:palette].bank(3, size: BANK_SIZE)
          image :brick, width: 8, height: 8, colors: :bank_1, data: Array.new(64) { |at| BANKS.fetch(1).fetch(1 + (at % 3)) }
          tiles :wall_tiles, "#" => :brick
          background :wall, tiles: :wall_tiles, map: ["##"]
          image :ship, width: 8, height: 8, colors: :bank_2, places: SHIP
          ship = sprite :ship, at: SHIP_AT
          ship.draw_with :bank_2
          pass = var :pass, 0
          game_loop do
            pass += 1
            recolor :bank_2, :bank_3 if pass == 2
          end
        end
        builder.finalize_program
        built(builder.program, builder.made_data_pack_file)
      end,
      # A canvas in a list from the pack stamps a picture drawn in that list, each pixel at the
      # place of its colour in the canvas's list.
      game(:canvas_in_a_pack_list_stamping_a_picture_in_that_list, passes: 4) do |folder, options|
        from = layout_original(folder, GENESIS)
        test = self
        builder = Builder.new(options: options)
        builder.instance_eval do
          screen :tiled
          pack = test.palette_pack_of(self, from)
          colors :ink, pack[:palette].bank(1, size: BANK_SIZE)
          image :ship, width: 8, height: 8, colors: :ink, places: SHIP
          board = canvas :board, width: 16, height: 8, colors: :ink
          background :box, tiles: :board, map: board.cells
          pass = var :pass, 0
          game_loop do
            pass += 1
            board.blit :ship, 4, 0 if pass == 2
          end
        end
        builder.finalize_program
        built(builder.program, builder.made_data_pack_file)
      end
    ].freeze
  end

  # POSES IN THE BANK THEIR FRAMES NAME, ONE SPRITE SHOWING TWO (PackPoseBankColorGames), on a
  # console whose build keeps one list of colours for a whole sprite.
  class PosesSharingTheirFramesBank < Kit
    include PackPoseBankColorGames

    SIZE = [16, 8].freeze
    # One piece a frame: each piece of the frame of bank 1 read as a frame of its own.
    PIECE_FRAME = FRAME.with(counted: false)

    GAMES = [
      # Two frames that name one bank are drawn from one list all-in-one, so one sprite shows both.
      game(:one_sprite_showing_two_frames_of_one_bank, passes: 12) do |folder, options|
        built_by(game_builder_of(folder, options: options) do |pack|
          image :left, tiles: pack[:video], frame: pack[:frames].frame(IN_BANK_1 + 2, layout: PIECE_FRAME, count: 1), origin: ORIGIN,
                       colors: pack[:palette], size: SIZE
          image :right, tiles: pack[:video], frame: pack[:frames].frame(IN_BANK_1 + 10, layout: PIECE_FRAME, count: 1), origin: ORIGIN,
                        colors: pack[:palette], size: SIZE
          sprite :both, at: [40, 40], frames: %i[left right], rate: 4
        end)
      end
    ].freeze
  end

  # A LIT 3D ROOM READ FROM A DATA PACK (PackPlaceGames): its points and faces, how many faces are
  # used, its shading and where its viewer starts. Only a console that draws a place plays it.
  class Places < Kit
    GAMES = [
      game(:lit_place_shading_and_viewer_from_pack, passes: PackPlaceGames::PASSES) do |folder, options|
        built(*PackPlaceGames.pack_room_game(folder, options))
      end
    ].freeze
  end

  KITS = [Pictures, ScreenPictures, StripFonts, Layouts, Backgrounds, WrittenCells, Backdrops, ColorLists, Poses, PosesOfWords, PosesOfShapes, PosesReadByTheGame, PosesInBankColors,
          Sounds, Scores, SlotViews, ColorsComparedAtStart, PosesSharingTheirFramesBank, Places].freeze

  # Every registered game.
  ALL = KITS.flat_map { |kit| kit::GAMES }.freeze

  # Shareable, since a test may run in a Ractor: each game with its block, and each kit's constants.
  Ractor.make_shareable(ALL)
  KITS.each { |kit| kit.constants(false).each { |name| Ractor.make_shareable(kit.const_get(name)) } }

  # The game registered as +name+.
  def self.named(name) = ALL.find { |game| game.name == name } || raise(KeyError, "no pack game is registered as #{name.inspect}")
end
