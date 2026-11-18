# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "made_up_original_layouts"

# A POSE THAT TAKES ITS COLOURS FROM ITS FRAME (Builder::PackPoses): each piece of a frame names a
# bank of the original's colours in its tile word, and the pose is drawn from that bank's list,
# `:<slot>_<bank>`. The made-up original keeps a frame as a Genesis game does (a word that counts
# the pieces, then eight bytes a piece), and its tile word holds the bank in bits 13 and 14, the
# console's four lines of colours. The answer key is the made-up data: each piece's tile in the
# colours of the bank its word names.
#
# The made-up original and its games, shared with the Genesis's own tests of one sprite facing
# frames of different banks (test/console/genesis/vblank/builder/test_pack_pose_bank_colors_on_the_genesis.rb)
# and with the registry of games that read a data pack (PackGames::PosesInBankColors, test/pack_games.rb).
module PackPoseBankColorGames
  include SharedConstants

  # Every constant here is made shareable where it is assigned: a test may play in a Ractor, and
  # the test helper freezes the constants a test class declares, not a module's.
  #
  # Four colours a tile, so the Game Boy Color can show them too.
  TILES = Ractor.make_shareable([
    (0...64).map { |at| 1 + (((at % 8) + (2 * (at / 8))) % 3) },
    (0...64).map { |at| (at / 8).even? ? 1 + ((at % 8) / 3) : 3 }
  ])
  # Four banks of sixteen colours, each place a colour of its own in each bank, every one a colour
  # the Genesis shows exactly.
  TURNS = [0, 7, 3, 5].freeze
  BANKS = Ractor.make_shareable(TURNS.map { |turn| MadeUpOriginalLayouts::PALETTE.rotate(turn) })
  OTHER = Ractor.make_shareable(MadeUpOriginalLayouts::PALETTE.rotate(11))

  FRAME = Ractor.make_shareable(VBlank::Original::FrameLayout.new(
    piece_bytes: 8, counted: true, count_bytes: 2, high_byte_first: true,
    y_at: 0, x_at: 6, position_bytes: 2, tile_at: 4, tile_bytes: 2, tile_bits: 11,
    flags_at: 4, flags_bytes: 2, mirrored_bit: 11, upside_down_bit: 12, bank_bit: 13, bank_bits: 2,
    size_at: 2, columns_bit: 2, rows_bit: 0, size_bits: 2, tile_order: :down_columns
  ))

  # A frame of two pieces of one tile each, side by side about the object's place: tile 0 left of
  # it and tile 1 right, each in the bank given. The word's top bit, the priority, is set too.
  def self.frame_of(left_bank, right_bank)
    pieces = [[-8, 0, left_bank], [0, 1, right_bank]].map do |x, tile, bank|
      [-8, 0, 0x5A, tile | (bank << 13) | 0x8000, x].pack("s>CCns>")
    end
    [pieces.length].pack("n") + pieces.join
  end
  FRAME_BYTES = 2 + (2 * 8)
  # The frames, one after another: all of bank 1, all of bank 2, and one of banks 1 and 3.
  IN_BANK_1 = 0
  IN_BANK_2 = FRAME_BYTES
  IN_TWO_BANKS = FRAME_BYTES * 2
  FRAMES = (frame_of(1, 1) + frame_of(2, 2) + frame_of(1, 3)).freeze

  COLORS_AT = 0x40
  FRAMES_AT = 0x100
  TILES_AT = 0x200
  ORIGIN = [8, 8].freeze

  private def original(folder)
    tiles = TILES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join
    levels = TURNS.flat_map { |turn| MadeUpOriginalLayouts::LEVELS.rotate(turn) }
    colors = levels.map { |red, green, blue| (red << 1) | (green << 5) | (blue << 9) }.pack("n*")
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    copy[COLORS_AT, colors.bytesize] = colors
    copy[FRAMES_AT, FRAMES.bytesize] = FRAMES
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :genesis,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A tiled game with the made-up original's pack, and whatever the block, handed the pack,
  # declares, then a loop that only waits.
  private def game_of(...) = game_and_file_of(...).first

  # The same game, and the pack file its build made (nil for a build that leaves its pack out).
  private def game_and_file_of(...)
    b = game_builder_of(...)
    [b.program, b.made_data_pack_file]
  end

  # The same game's builder, its program made, for a test of its pack's unpacking.
  private def game_builder_of(folder, options: VBlank::Cartridge::Options.new, &declares)
    from = original(folder)
    b = Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: TILES.length, colors: 16
        slots.numbers :frames, at: FRAMES_AT, count: FRAMES.bytesize, width: :byte, signed: false
        slots.colors :palette, at: COLORS_AT, count: 64
        slots.colors :two_banks, at: COLORS_AT, count: 32
      end
      instance_exec(pack, &declares)
      game_loop { wait_vblank }
    end
    b.finalize_program
    b
  end

  # The poses :first (the frame of bank 1) and :second (the frame of bank 2), declared in +game+.
  # Public, since a game's block calls back through it.
  def declare_poses_for(game, pack, colors: pack[:palette], **told)
    game.image :first, tiles: pack[:video], frame: pack[:frames].frame(IN_BANK_1, layout: FRAME), origin: ORIGIN, colors: colors, **told
    game.image :second, tiles: pack[:video], frame: pack[:frames].frame(IN_BANK_2, layout: FRAME), origin: ORIGIN, colors: colors, **told
  end

  # The pose each actor of #recolored_actors_builder faces: two share :first.
  ACTOR_POSES = %i[first second first].freeze

  # ACTORS SHARING POSES OF THE ORIGINAL'S FRAMES, as a title's actors are: a sprite for each of
  # ACTOR_POSES, each following the list its pose's frame picks, while the lists of banks 1 and 2
  # are recoloured through two sets of their own as the game plays. +size+ is every pose's size, so
  # a test can make the poses bigger and see what that costs a build. Gives back the builder, its
  # program made. Public, since PackStandInSizeTests builds it from an object of its own.
  def recolored_actors_builder(folder, size:, options: VBlank::Cartridge::Options.new)
    test = self
    other = see_through_first(OTHER)
    dusk = see_through_first(OTHER.rotate(3))
    from = original(folder)
    b = Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: TILES.length, colors: 16
        slots.numbers :frames, at: FRAMES_AT, count: FRAMES.bytesize, width: :byte, signed: false
        slots.colors :palette, at: COLORS_AT, count: 64
      end
      test.declare_poses_for(self, pack, size: size)
      colors :other, other
      colors :dusk, dusk
      ACTOR_POSES.each_with_index do |pose, at|
        sprite(:"actor_#{at}", at: [24 + (at * 40), 40 + (at * 8)], facing: { standing: pose }).draw_with colors_name_of(pose)
      end
      pass = var :pass, 0
      game_loop do
        pass += 1
        recolor :palette_1, %i[other dusk], showing: pass % 3
        recolor :palette_2, %i[dusk other], showing: (pass + 1) % 3
      end
    end
    b.finalize_program
    b
  end

  # Tile +tile+ at (at_x, at_y) of +screen+ shows each of its places in the colour +colors+ holds there.
  private def assert_tile_drawn_in(colors, screen, tile, at_x, at_y, what)
    TILES.fetch(tile).each_with_index do |place, at|
      assert_equal colors.fetch(place), screen.pixel(at_x + (at % 8), at_y + (at / 8)), "#{what}: the pixel at (#{at % 8}, #{at / 8})"
    end
  end

  # +colors+ as a `colors` list, its first place see-through.
  private def see_through_first(colors) = colors.each_with_index.map { |color, at| at.zero? ? :transparent : color }

  VBlank::Testing::InRactors.share_constants(self)
end

class TestPackPoseBankColors < Minitest::Test
  include PackPoseBankColorGames

  # A game showing :first as a sprite at (40, 40) and :second as one at (80, 40), and whatever the
  # block, handed the two sprites, says.
  private def two_sprites_game(folder, &more)
    test = self
    game_of(folder) do |pack|
      test.declare_poses_for(self, pack)
      first = sprite :first, at: [40, 40]
      second = sprite :second, at: [80, 40]
      instance_exec(first, second, &more) if more
    end
  end
end

class TestPackPoseBankColors < Minitest::Test
  include PackPoseBankColorGames

  def test_each_frame_is_drawn_in_the_colors_of_the_bank_its_pieces_name
    Dir.mktmpdir do |folder|
      screen = game_player.run(two_sprites_game(folder), frames: 4).screen

      assert_tile_drawn_in(BANKS[1], screen, 0, 40, 40, "the frame of bank 1, left piece")
      assert_tile_drawn_in(BANKS[1], screen, 1, 48, 40, "the frame of bank 1, right piece")
      assert_tile_drawn_in(BANKS[2], screen, 0, 80, 40, "the frame of bank 2, left piece")
      assert_tile_drawn_in(BANKS[2], screen, 1, 88, 40, "the frame of bank 2, right piece")
    end
  end

  # A frame of one bank is a picture of that bank's list, so `colors_name_of` names the list and a
  # sprite told to draw with it shows what the game sets the list to hold.
  def test_a_sprite_drawn_with_its_frames_list_follows_recolor_of_that_list
    other = see_through_first(OTHER)
    Dir.mktmpdir do |folder|
      program = two_sprites_game(folder) do |first, _second|
        colors :other, other
        first.draw_with colors_name_of(:first)
        recolor :palette_1, :other
      end
      screen = game_player.run(program, frames: 5).screen

      assert_tile_drawn_in(OTHER, screen, 0, 40, 40, "the frame of bank 1, whose list holds :other")
      assert_tile_drawn_in(BANKS[2], screen, 1, 88, 40, "the frame of bank 2, whose list was not changed")
    end
  end

  def test_a_frames_list_takes_draw_with_as_any_sprite_does
    other = see_through_first(OTHER)
    Dir.mktmpdir do |folder|
      program = two_sprites_game(folder) do |_first, second|
        colors :other, other
        second.draw_with :other
      end
      screen = game_player.run(program, frames: 5).screen

      assert_tile_drawn_in(OTHER, screen, 0, 80, 40, "the frame of bank 2, drawn with :other")
      assert_tile_drawn_in(BANKS[1], screen, 0, 40, 40, "the frame of bank 1, as drawn")
    end
  end

  # ONE SPRITE IS DRAWN FROM ONE LIST where the console's build keeps one for a whole sprite
  # (Guardrails::Checks::PosesWithDifferentColors), as the Advance's does. So a sprite whose poses
  # are frames of different banks is refused there, naming each pose's list, which the game did not
  # write down, and the way round it: a sprite for each list. No run's player plays a refused game,
  # so it is the interpreter by name, the program built for the Advance.
  def test_a_sprite_whose_poses_are_frames_of_different_banks_is_refused_naming_their_lists
    test = self
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        test.declare_poses_for(self, pack)
        sprite :both, at: [40, 40], frames: %i[first second], rate: 8
      end
      program = program.copy.tap { |copy| copy.console = :gba }
      error = assert_raises(Reference::ProgramError) { Reference.new.run(program, frames: 2) }

      assert_includes error.message, "sprite :both"
      assert_includes error.message, ":first is drawn from :palette_1"
      assert_includes error.message, ":second is drawn from :palette_2"
      assert_includes error.message, "for the pictures of each list"
    end
  end

  # The way round it: a sprite for the poses of each bank, the game showing the one in use.
  def test_a_sprite_for_each_bank_shows_the_poses_of_different_banks_in_turn
    test = self
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        test.declare_poses_for(self, pack)
        sprite :first, at: [40, 40]
        second = sprite :second, at: [40, 40]
        second.hide
      end
      screen = game_player.run(program, frames: 4).screen

      assert_tile_drawn_in(BANKS[1], screen, 0, 40, 40, "the pose of bank 1, the pose of bank 2 hidden")
    end
  end

  # The bank's list is the one a game made from the same bank itself, or a background from the slot.
  def test_a_bank_the_game_declared_itself_is_the_same_list
    test = self
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        colors :palette_1, pack[:palette].bank(1)
        test.declare_poses_for(self, pack)
        sprite :first, at: [40, 40]
      end
      screen = game_player.run(program, frames: 4).screen

      assert_tile_drawn_in(BANKS[1], screen, 0, 40, 40, "the frame of bank 1")
    end
  end

  def test_a_game_list_named_as_a_bank_with_other_colors_is_refused
    test = self
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_of(folder) do |pack|
          colors :palette_1, %i[transparent red green blue]
          test.declare_poses_for(self, pack)
        end
      end

      assert_includes error.message, ":palette_1"
    end
  end

  def test_a_frame_with_pieces_in_two_banks_is_refused_naming_the_banks
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_of(folder) do |pack|
          image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN, colors: pack[:palette]
        end
      end

      assert_includes error.message, "image :mixed"
      assert_includes error.message, "banks 1 and 3"
      assert_includes error.message, "banks: [1, 3]"
    end
  end

  # A POSE TOLD THE BANKS ITS FRAME USES (`banks:`) keeps each piece in its own bank's colours, as a
  # console's sprite entry names its piece's bank, and one sprite shows and moves the whole frame.
  def test_a_pose_told_its_banks_draws_each_piece_in_its_own_banks_colors
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], banks: [3, 1]
        sprite :mixed, at: [40, 40]
      end
      screen = game_player.run(program, frames: 4).screen

      assert_tile_drawn_in(BANKS[1], screen, 0, 40, 40, "the piece of bank 1")
      assert_tile_drawn_in(BANKS[3], screen, 1, 48, 40, "the piece of bank 3")
    end
  end

  def test_one_sprite_moves_a_pose_of_two_banks_whole
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], banks: [1, 3]
        mixed = sprite :mixed, at: [40, 40]
        mixed.move_to(96, 64)
      end
      screen = game_player.run(program, frames: 4).screen

      assert_tile_drawn_in(BANKS[1], screen, 0, 96, 64, "the piece of bank 1, moved")
      assert_tile_drawn_in(BANKS[3], screen, 1, 104, 64, "the piece of bank 3, moved")
    end
  end

  # The banks of a frame of one bank: the pose is drawn in that bank's colours.
  def test_a_pose_told_banks_whose_frame_uses_one_of_them_is_drawn_in_that_bank
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        image :plain, tiles: pack[:video], frame: pack[:frames].frame(IN_BANK_2, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], banks: [1, 2]
        sprite :plain, at: [40, 40]
      end
      screen = game_player.run(program, frames: 4).screen

      assert_tile_drawn_in(BANKS[2], screen, 0, 40, 40, "the left piece of bank 2")
      assert_tile_drawn_in(BANKS[2], screen, 1, 48, 40, "the right piece of bank 2")
    end
  end

  def test_a_frame_with_a_piece_of_a_bank_not_in_banks_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_of(folder) do |pack|
          image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                        colors: pack[:palette], banks: [1, 2]
        end
      end

      assert_includes error.message, "image :mixed"
      assert_includes error.message, "bank 3"
    end
  end

  def test_banks_given_with_bank_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_of(folder) do |pack|
          image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                        colors: pack[:palette], banks: [1, 3], bank: 1
        end
      end

      assert_includes error.message, "banks:"
      assert_includes error.message, "bank:"
    end
  end

  # ONE BANK NAMED is a pose of that bank's list, as `bank:` makes one, so every console draws it as
  # any pose of one list, and `colors_name_of` names the list.
  def test_a_pose_told_one_bank_is_drawn_in_that_banks_list_on_every_console
    Dir.mktmpdir do |folder|
      list = nil
      program = game_of(folder) do |pack|
        image :plain, tiles: pack[:video], frame: pack[:frames].frame(IN_BANK_2, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], banks: [2]
        sprite :plain, at: [40, 40]
        list = colors_name_of(:plain)
      end
      screen = game_player.run(program, frames: 4).screen

      assert_equal :palette_2, list
      assert_tile_drawn_in(BANKS[2], screen, 0, 40, 40, "the left piece of bank 2")
      assert_tile_drawn_in(BANKS[2], screen, 1, 48, 40, "the right piece of bank 2")
    end
  end

  def test_a_pose_told_one_bank_of_a_frame_of_two_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_of(folder) do |pack|
          image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                        colors: pack[:palette], banks: [1]
        end
      end

      assert_includes error.message, "bank 3"
    end
  end

  # A pose keeps a byte for each pixel's place, so its banks' colours are 256 at most: sixteen banks
  # of sixteen-colour tiles.
  def test_more_banks_than_a_pose_can_hold_are_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_of(folder) do |pack|
          image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                        colors: pack[:palette], banks: (0..16).to_a
        end
      end

      assert_includes error.message, "17 banks"
      assert_includes error.message, "16 banks at most"
    end
  end

  def test_draw_with_on_a_sprite_of_a_pose_of_several_banks_is_refused
    other = see_through_first(OTHER)
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_of(folder) do |pack|
          colors :other, other
          image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                        colors: pack[:palette], banks: [1, 3]
          sprite(:mixed, at: [40, 40]).draw_with :other
        end
      end

      assert_includes error.message, "several banks"
      assert_includes error.message, "bank:"
      refute_includes error.message, "colors or more"
    end
  end

  # One sprite draws all its poses from one list on the Advance, so a pose of banks 1 and 3 beside a
  # pose of bank 1 alone is refused there, naming the banks as what differs, not the `colors:` slot
  # both share. No run's player plays a refused game, so it is the interpreter by name.
  def test_a_sprite_of_poses_naming_different_banks_is_refused_naming_banks
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], banks: [1, 3]
        image :plain, tiles: pack[:video], frame: pack[:frames].frame(IN_BANK_1, layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], banks: [1]
        sprite :both, at: [40, 40], frames: %i[mixed plain], rate: 8
      end
      program = program.copy.tap { |copy| copy.console = :gba }
      error = assert_raises(Reference::ProgramError) { Reference.new.run(program, frames: 2) }

      assert_includes error.message, "different banks"
      assert_includes error.message, "the same banks:"
    end
  end

  def test_banks_past_the_slot_of_colors_are_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_of(folder) do |pack|
          image :mixed, tiles: pack[:video], frame: pack[:frames].frame(IN_TWO_BANKS, layout: FRAME), origin: ORIGIN,
                        colors: pack[:two_banks], banks: [1, 3]
        end
      end

      assert_includes error.message, "banks:"
      assert_includes error.message, "0 to 1"
    end
  end

  # `bank:` makes a pose of one bank's pieces, so a frame of two banks is two poses, a sprite each.
  def test_a_frame_of_two_banks_is_two_poses_of_one_bank_each
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        frame = pack[:frames].frame(IN_TWO_BANKS, layout: FRAME)
        image :near, tiles: pack[:video], frame: frame, origin: ORIGIN, colors: pack[:palette], bank: 1
        image :far, tiles: pack[:video], frame: frame, origin: ORIGIN, colors: pack[:palette], bank: 3
        sprite :near, at: [40, 40]
        sprite :far, at: [40, 40]
      end
      screen = game_player.run(program, frames: 4).screen

      assert_tile_drawn_in(BANKS[1], screen, 0, 40, 40, "the piece of bank 1")
      assert_tile_drawn_in(BANKS[3], screen, 1, 48, 40, "the piece of bank 3")
    end
  end

  def test_a_bank_no_piece_of_the_frame_names_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_of(folder) do |pack|
          image :none, tiles: pack[:video], frame: pack[:frames].frame(IN_BANK_1, layout: FRAME), origin: ORIGIN,
                       colors: pack[:palette], bank: 2
        end
      end

      assert_includes error.message, "bank 2"
    end
  end

  def test_a_bank_past_the_slot_of_colors_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_of(folder) do |pack|
          image :first, tiles: pack[:video], frame: pack[:frames].frame(IN_BANK_2, layout: FRAME), origin: ORIGIN,
                        colors: pack[:two_banks]
        end
      end

      assert_includes error.message, "bank 2"
      assert_includes error.message, "2 banks"
    end
  end

  # A layout that names a bank still takes one list for the whole pose, the bank not read.
  def test_a_pose_given_one_list_is_drawn_in_it_whatever_bank_its_pieces_name
    test = self
    listed = see_through_first(OTHER)
    Dir.mktmpdir do |folder|
      program = game_of(folder) do |pack|
        colors :mine, listed
        test.declare_poses_for(self, pack, colors: :mine)
        sprite :second, at: [80, 40]
      end
      screen = game_player.run(program, frames: 4).screen

      assert_tile_drawn_in(OTHER, screen, 0, 80, 40, "the frame of bank 2, given :mine")
    end
  end

  def test_bank_given_to_a_pose_of_one_list_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_of(folder) do |pack|
          colors :mine, %i[transparent red green blue]
          image :first, tiles: pack[:video], frame: pack[:frames].frame(IN_BANK_1, layout: FRAME), origin: ORIGIN, colors: :mine, bank: 1
        end
      end

      assert_includes error.message, "bank:"
    end
  end

  def test_colors_name_of_a_picture_given_no_list_by_name_is_refused
    b = Builder.new
    error = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :tiled
        image :dot, width: 8, height: 8, places: [1] * 64, colors: %i[transparent red]
        colors_name_of(:dot)
      end
    end

    assert_includes error.message, "image :dot"
  end

  def test_a_layout_with_a_bank_bit_and_no_width_is_refused
    error = assert_raises(ArgumentError) { FRAME.with(bank_bits: nil) }

    assert_includes error.message, "bank_bits:"
  end

  def test_a_layout_whose_bank_ends_past_its_flags_is_refused
    error = assert_raises(ArgumentError) { FRAME.with(bank_bit: 15, bank_bits: 2) }

    assert_includes error.message, "bank_bit:"
  end

  # THE BANK IS IN THE PLAYER'S COPY, which a build that reads its pack as the game starts does not
  # hold. Such a build draws the pose in that bank's colours all the same, and a sprite told to draw
  # with its list follows the list the file picks: PackGames::PosesInBankColors (test/pack_games.rb)
  # holds those games to this build, and PackPoseBankColorsAtStartTests
  # (test/pack_pose_bank_colors_at_start_tests.rb) plays the rest.
end
