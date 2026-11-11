# frozen_string_literal: true

require "test_helper"
require "pose_color_list_tests"

# ONE SPRITE WHOSE POSES ARE DRAWN FROM DIFFERENT LISTS OF COLOURS, in the Genesis's own memory. The
# video chip keeps four palettes of sixteen colours, and each entry of its sprite table names one of
# them in two bits of the word that names its tile. A retail game writes that word every frame, so
# its sprite changes palette with its frame for nothing. These read the sprite table and the colour
# memory the console drew from: the entry of the pose showing names the palette that holds that
# pose's list.
class TestGenesisPoseColorLists < Minitest::Test
  include PoseColorListGames

  Genesis = VBlank::IR::Backends::Genesis
  Tiles = Genesis::Runtime::Tiles

  # Two lists the game changes keep a palette each, so the two poses name different palettes. (Two
  # short lists nothing changes can share one palette, each in places of its own.)
  def test_the_entry_of_the_pose_showing_names_the_palette_of_that_poses_list
    program = turning_sprite_game(before: ->(ship) { ship.draw_with({ warm: :warm, cold: :cold }) }) do |_ship, pass|
      recolor :warm, :glow if pass >= 200
      recolor :cold, :dusk if pass >= 200
    end
    first, second = memory_from_first_sprite(program, later: [TURN_PASS + 20])

    assert_equal words_of(WARM), palette_named_at(first, AT), "the first pose's entry names a palette holding :warm"
    assert_equal words_of(COLD), palette_named_at(second, AT), "the second pose's entry names a palette holding :cold"
    refute_equal palette_line_at(first, AT), palette_line_at(second, AT), "the two poses name different palettes"
  end

  # A sprite that follows its lists is drawn from the palettes the lists' own writes change, so the
  # entry names the same palette before and after the list is told to hold other colours.
  def test_a_followed_lists_colours_are_written_over_the_palette_its_pose_names
    program = turning_sprite_game(before: ->(ship) { ship.draw_with({ warm: :warm, cold: :cold }) }) do |_ship, pass|
      recolor :cold, :dusk if pass >= 60
    end
    _first, before, after = memory_from_first_sprite(program, later: [TURN_PASS + 20, 120])

    assert_equal words_of(COLD), palette_named_at(before, AT)
    assert_equal words_of(DUSK), palette_named_at(after, AT)
    assert_equal palette_line_at(before, AT), palette_line_at(after, AT), "the palette the entry names"
  end

  # EVERY LIST A SPRITE'S POSES USE IS COUNTED: four lists of fifteen colours fill the console's four
  # palettes, and a fifth is refused in words, though one sprite shows them all.
  def test_a_sprite_of_four_lists_takes_the_four_palettes_and_a_fifth_list_is_refused
    memory = played(built(many_lists_game(4)), frames: 30)
    held = (0...4).map do |list|
      (0...4).count { |line| memory.colors[(line * 16) + 1, 15].sort == list_colors(list).map { |color| word(color) }.sort }
    end

    assert_equal [1, 1, 1, 1], held, "how many palettes hold each of the four lists"

    error = assert_raises(Genesis::Art::TooMuch) { Genesis.new.build(many_lists_game(5)) }

    assert_match(/more colours than a Genesis can show/, error.message)
  end

  # A picture's pieces name one palette, so every sprite showing a picture follows its list or none
  # does: one of each is refused in words, naming the picture and the list.
  def test_a_picture_one_sprite_follows_and_another_shows_as_drawn_is_refused
    program = pose_colors_game do
      facing = { left: :left, right: :right }
      follower = sprite :follower, at: AT, facing: facing
      sprite :plain, at: [80, 40], facing: facing
      follower.draw_with({ warm: :warm })
      game_loop { recolor :warm, :glow }
    end
    error = assert_raises(VBlank::IR::Backends::NotMadeYet) { Genesis.new.build(genesis(program)) }

    assert_includes error.message, "picture :left"
    assert_includes error.message, "draw_with({ warm: :warm })"
  end

  private

  # What the console holds: its video memory and the 64 words of its colour memory.
  Memory = Data.define(:video, :colors)

  def genesis(program) = program.copy.tap { |copy| copy.console = :genesis }

  def built(program) = VBlank::Console.for(:genesis).builder.cartridge_for(genesis(program), title: "POSES")

  def played(rom, frames:)
    VBlank::Diagnostics::Emulator.with_cartridge(rom, file_name: "game.gen") do |core|
      frames.times { core.run_frame }
      Memory.new(video: core.vram, colors: core.cram.unpack("v*"))
    end
  end

  # The console's memory on the first frame its sprite table has an entry at AT, which is the
  # game's first pass shown, and again each of +later+ frames after that one. A cartridge shows
  # some frames before its first pass, so a frame is found by what the console holds and never
  # by a count from power-on.
  def memory_from_first_sprite(program, later: [])
    VBlank::Diagnostics::Emulator.with_cartridge(built(program), file_name: "game.gen") do |core|
      first = nil
      120.times do
        core.run_frame
        first = Memory.new(video: core.vram, colors: core.cram.unpack("v*"))
        break if entry_at(first, AT)
      end
      played = 0
      rest = later.map do |frames|
        (frames - played).times { core.run_frame }
        played = frames
        Memory.new(video: core.vram, colors: core.cram.unpack("v*"))
      end
      [first, *rest]
    end
  end

  # The four words of the sprite table's entry whose top left is +at+, or nil.
  def entry_at(memory, at)
    table = memory.video.byteslice(Tiles::SPRITES_AT, 80 * 8)
    (0...80).map { |row| table.byteslice(row * 8, 8).unpack("n4") }.find do |top, _, _, left|
      [(left & 0x1FF) - Tiles::SPRITE_ORIGIN, (top & 0x3FF) - Tiles::SPRITE_ORIGIN] == at
    end
  end

  # The palette, 0 to 3, the sprite table's entry at +at+ names: bits 13 and 14 of its tile word.
  def palette_line_at(memory, at)
    entry = entry_at(memory, at) or flunk "no entry of the sprite table is at #{at.inspect}"

    (entry[2] >> 13) & 3
  end

  # The colours of that palette at the places a list of three colours fills: its places 1 and 2.
  def palette_named_at(memory, at) = memory.colors[(palette_line_at(memory, at) * 16) + 1, 2]

  def word(color) = VBlank::Console::GenesisHardware.color_word(VBlank::Graphics::Color.resolve(color))

  def words_of(list) = list.drop(1).map { |color| word(color) }

  # The fifteen colours of list number +list+, each a colour the console shows exactly and no two
  # lists sharing one.
  def list_colors(list) = Array.new(15) { |at| VBlank::Graphics::Color.rgb((at % 8) * 4, list * 4, ((at / 8) * 4) + 4) }

  # One sprite facing a pose of each of +lists+ lists of fifteen colours, each pose drawn in every
  # colour of its list.
  def many_lists_game(lists)
    colors_of = ->(list) { list_colors(list) }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      names = Array.new(lists) do |list|
        colors :"list_#{list}", [:transparent, *colors_of.(list)]
        image :"pose_#{list}", width: 8, height: 8, places: Array.new(64) { |at| 1 + (at % 15) }, colors: :"list_#{list}"
        :"pose_#{list}"
      end
      sprite :all, at: [40, 40], facing: names.to_h { |name| [name, name] }
      game_loop { wait_vblank }
    end
    builder.finalize_program
    genesis(builder.program)
  end
end
