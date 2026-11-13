# frozen_string_literal: true

require "digest"
require "tmpdir"
require "made_up_original_layouts"
require "pack_background_tests"

# TWO SCENES, EACH IN COLOURS OF ITS OWN, as a Genesis game's title and the screen after it are: each
# scene's background is read from a made-up Genesis original through a data pack, its cells drawn
# from two banks of fifteen colours of that scene's own, and two sprites of the scene's own are drawn
# in seven colours each, fourteen that fill a palette. Beside them a list every scene uses: the
# backdrop follows it, a sprite every scene shows is drawn with it, and the game tells it to hold :dusk
# on every even pass and its own colours on every odd one.
#
# Each scene needs three of the console's four palettes and the list every scene uses the fourth, so
# the two scenes together need seven. With only the backgrounds' colours taking turns, the list and
# both scenes' sprites keep three and leave one for a scene's two banks: the game fits only if each
# scene's sprite colours take turns too. The second scene comes in under the screen faded fully to
# black, and the fade lifts; the game later hands back to the first scene with no fade.
module SceneColorGames
  include PackBackgroundGames

  # The pass the screen is faded fully to black, the pass the second scene takes over, the step the
  # fade lifts by each pass after that (in percent), the pass the first scene takes over again, and
  # how many passes a test plays in all.
  BLACK_FROM_PASS = 4
  SECOND_SCENE_PASS = 6
  FADE_LIFT_PERCENT_PER_PASS = 25
  FIRST_SCENE_AGAIN_PASS = 14
  PASSES_PLAYED = 18

  # Where each scene's map and colours are in the made-up original: two banks of sixteen colours a
  # scene, the Genesis's nine bits a colour.
  ONE_MAP_AT = 0x20
  TWO_MAP_AT = 0x30
  ONE_COLORS_AT = 0x40
  TWO_COLORS_AT = 0x80

  # Two tiles whose pixels use every place from 1 to 15, and a blank one.
  TILES = [
    Array.new(64, 0),
    (0...64).map { |at| 1 + (at % 15) },
    (0...64).map { |at| 1 + ((at * 7) % 15) }
  ].freeze

  # Each scene's map: four cells, two drawn from each of its banks.
  MAP = [GENESIS_CELL.(1), GENESIS_CELL.(2, bank: 1), GENESIS_CELL.(1, bank: 1), GENESIS_CELL.(2)].freeze

  # The levels of place +place+ of bank +bank+ of +scene+ (0 or 1): sixty colours that differ in their
  # red and green levels, the Genesis's three bits each, and black at place 0.
  def self.bank_levels(scene, bank, place)
    return [0, 0, 0] if place.zero?

    number = (scene * 32) + (bank * 16) + place
    [number % 8, (number / 8) % 8, 2]
  end

  def self.widened(levels)
    widen = MadeUpOriginalLayouts::WIDEN
    red, green, blue = levels
    widen.(red) | (widen.(green) << 5) | (widen.(blue) << 10)
  end

  # The colour place +place+ of bank +bank+ of +scene+ shows.
  def self.bank_color(scene, bank, place) = widened(bank_levels(scene, bank, place))

  # The colour the pixel at (+x+, 0) of a scene's background shows: the cell's tile, bank and place.
  def self.background_color(scene, x)
    cell = MAP.fetch(x / 8)
    places = TILES.fetch(cell & 0x7FF)
    bank_color(scene, (cell >> 13) & 3, places.fetch(x % 8))
  end

  # The seven colours of sprite +which+ of +scene+, none another sprite's, a bank's or a list's.
  def self.sprite_palette(scene, which) = (0...7).map { |at| widened([at, (scene * 4) + which, 6]) }

  # The two colours the top half of the sprite's picture shows, a half of it each.
  def self.sprite_colors(scene, which) = sprite_palette(scene, which).first(2)

  # The sprite's picture: its top half in its first two colours, left and right, and each row of its
  # bottom half its other five in turn.
  def self.sprite_picture(scene, which)
    colors = sprite_palette(scene, which)
    Array.new(64) { |i| (i / 8) < 4 ? colors[(i % 8) < 4 ? 0 : 1] : colors[2 + ((i % 8) % 5)] }
  end

  SPRITES_AT = [[40, 40], [60, 40]].freeze

  # The list every scene uses, the colours it is told to hold, and where the sprite drawn with it stands.
  SCREEN = [:black, widened([0, 0, 3]), widened([0, 0, 5])].freeze
  DUSK = [widened([2, 0, 2]), widened([3, 0, 3]), widened([5, 0, 5])].freeze
  MOON_AT = [100, 40].freeze

  # The made-up Genesis original: the tiles, both maps and both scenes' banks.
  private def scene_colors_original(folder)
    tiles = TILES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    copy[ONE_MAP_AT, MAP.length * 2] = MAP.pack("n*")
    copy[TWO_MAP_AT, MAP.length * 2] = MAP.pack("n*")
    [ONE_COLORS_AT, TWO_COLORS_AT].each_with_index do |at, scene|
      levels = (0...2).flat_map { |bank| (0...16).map { |place| SceneColorGames.bank_levels(scene, bank, place) } }
      copy[at, 64] = GENESIS_COLORS.(levels)
    end
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :genesis,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The game, its original made in +folder+. +more_in_two+ is called inside the second scene, for a
  # test that gives it more pictures than the palettes left hold.
  private def scene_colors_game(folder, more_in_two: nil)
    original = scene_colors_original(folder)
    b = VBlank::Builder.new
    b.instance_eval do
      colors :screen_colors, SCREEN
      colors :dusk, DUSK
      screen :tiled, backdrop: :screen_colors
      pack = data_pack from: original, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: TILES.length, colors: 16
        slots.numbers :one_map, at: ONE_MAP_AT, count: MAP.length, width: :half, signed: false
        slots.numbers :two_map, at: TWO_MAP_AT, count: MAP.length, width: :half, signed: false
        slots.colors :one_colors, at: ONE_COLORS_AT, count: 32
        slots.colors :two_colors, at: TWO_COLORS_AT, count: 32
      end
      halves = ->(left, right) { Array.new(64) { |i| (i % 8) < 4 ? left : right } }
      image :moon, width: 8, height: 8, data: halves.(SCREEN[1], SCREEN[2]), colors: :screen_colors
      sprite(:moon, at: MOON_AT).draw_with :screen_colors
      %i[one two].each_with_index do |name, scene|
        2.times do |which|
          image :"#{name}_sprite_#{which}", width: 8, height: 8, data: SceneColorGames.sprite_picture(scene, which)
        end
      end
      state = var :state, 0
      pass = var :pass, 0
      level = var :level, 0
      scene(:one) do
        background :one_world, tiles: pack[:video], map: pack[:one_map], colors: pack[:one_colors], across: 4, cell: 8
        SPRITES_AT.each_with_index { |at, which| sprite :"one_sprite_#{which}", at: at }
      end
      scene(:two) do
        background :two_world, tiles: pack[:video], map: pack[:two_map], colors: pack[:two_colors], across: 4, cell: 8
        SPRITES_AT.each_with_index { |at, which| sprite :"two_sprite_#{which}", at: at }
        instance_eval(&more_in_two) if more_in_two
      end
      game_loop do
        pass += 1
        recolor :screen_colors, %i[dusk], showing: pass % 2
        level = 100 if pass == BLACK_FROM_PASS
        state = 1 if pass == SECOND_SCENE_PASS
        level -= FADE_LIFT_PERCENT_PER_PASS if pass > SECOND_SCENE_PASS
        level = 0 if level < 0
        state = 0 if pass == FIRST_SCENE_AGAIN_PASS
        fade :black, level
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
    b.finalize_program
    b.program
  end

  # A TITLE AND A SCREEN AFTER IT THAT NEEDS ALL FOUR PALETTES, as a Genesis game's story screen does
  # after its title. The title draws a sprite with each of two lists the game changes, and the
  # backdrop follows the first list's second colour. The lair's four sprites are fifteen colours
  # each, none another's. Nothing in the lair draws with either list, so on a Genesis the lair has the
  # four palettes to itself while it is up, and the lists are shown again as the title comes back.
  #
  # The game tells both lists to hold their other set on DUSK_PASS, while the title is up, and tells
  # the lights to hold their own again on LIGHTS_BACK_PASS, while the lair is up. So the title comes
  # back with the screen's list in the set it held as the title went, and the lights' in a set they
  # were told while the title was not up.
  DUSK_PASS = 2
  LAIR_PASS = 4
  LIGHTS_BACK_PASS = 6
  TITLE_AGAIN_PASS = 10
  LAIR_PASSES_PLAYED = 14
  TITLE_LISTS = {
    screen: [widened([0, 0, 1]), widened([0, 0, 3]), widened([0, 0, 5])],
    screen_dusk: [widened([1, 0, 1]), widened([3, 0, 3]), widened([5, 0, 5])],
    lights: [:black, widened([5, 5, 0]), widened([7, 7, 0])],
    lights_dim: [:black, widened([2, 2, 0]), widened([3, 3, 0])]
  }.freeze
  LOGO_AT = [10, 10].freeze
  LAMP_AT = [30, 10].freeze
  LAIR_SPRITES = 4

  # Where lair sprite +which+ stands, and its fifteen colours: its own blue level tells them apart from
  # the others'.
  def self.lair_sprite_at(which) = [10 + (which * 16), 40]
  def self.lair_picture(which) = Array.new(64) { |i| widened([i % 5, (i / 8) % 3, 2 + which]) }

  # The colours list +list+ (:screen or :lights) holds after pass +pass+.
  def self.list_after(list, pass)
    return TITLE_LISTS.fetch(list) if pass < DUSK_PASS
    return TITLE_LISTS.fetch(:screen_dusk) if list == :screen

    TITLE_LISTS.fetch(pass < LIGHTS_BACK_PASS ? :lights_dim : :lights)
  end

  private def lair_game
    b = VBlank::Builder.new
    b.instance_eval do
      TITLE_LISTS.each { |name, list| colors :"#{name}_colors", list }
      screen :tiled, backdrop: :screen_colors, backdrop_place: 1
      halves = ->(left, right) { Array.new(64) { |i| (i % 8) < 4 ? left : right } }
      image :logo, width: 8, height: 8, data: halves.(TITLE_LISTS[:screen][1], TITLE_LISTS[:screen][2]), colors: :screen_colors
      image :lamp, width: 8, height: 8, data: halves.(TITLE_LISTS[:lights][1], TITLE_LISTS[:lights][2]), colors: :lights_colors
      LAIR_SPRITES.times { |which| image :"lair_#{which}", width: 8, height: 8, data: SceneColorGames.lair_picture(which) }
      state = var :state, 0
      pass = var :pass, 0
      scene(:title) do
        sprite(:logo, at: LOGO_AT).draw_with :screen_colors
        sprite(:lamp, at: LAMP_AT).draw_with :lights_colors
      end
      scene(:lair) do
        LAIR_SPRITES.times { |which| sprite :"lair_#{which}", at: SceneColorGames.lair_sprite_at(which) }
      end
      game_loop do
        pass += 1
        if pass == DUSK_PASS
          recolor :screen_colors, %i[screen_dusk_colors], showing: 0
          recolor :lights_colors, %i[lights_dim_colors], showing: 0
        end
        recolor :lights_colors, %i[lights_dim_colors], showing: 1 if pass == LIGHTS_BACK_PASS
        state = 1 if pass == LAIR_PASS
        state = 0 if pass == TITLE_AGAIN_PASS
        case_var(:state) do
          when_val 0, :title
          when_val 1, :lair
        end
      end
    end
    b.finalize_program
    b.program
  end
end
